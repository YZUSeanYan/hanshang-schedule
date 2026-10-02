import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/constants/course_colors.dart';
import '../../../core/database/app_database.dart';
import '../../../core/utils/week_calculator.dart';

// ==================== 数据库与仓库 Provider ====================

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final scheduleRepositoryProvider = Provider<ScheduleRepository>(
  (ref) => ScheduleRepository(ref.read(databaseProvider)),
);

/// 一门课及其全部上课时间段
class CourseEntry {
  const CourseEntry({required this.course, required this.slots});

  final Course course;
  final List<Schedule> slots;
}

/// 课程编辑页提交的时间段草稿（无 id/updatedAt）
class SlotDraft {
  const SlotDraft({
    required this.dayOfWeek,
    required this.startSection,
    required this.endSection,
    required this.weeksType,
    this.customWeeks = const [],
    this.location = '',
  });

  final int dayOfWeek;
  final int startSection;
  final int endSection;
  final WeeksType weeksType;
  final List<int> customWeeks;
  final String location;
}

/// 批量导入使用的课程草稿。仓库会在同一数据库事务内写入整批课程，
/// 任一条失败时全部回滚，避免重试后出现半份课表或重复课程。
class CourseDraft {
  const CourseDraft({
    required this.name,
    this.shortName = '',
    this.teacher = '',
    this.color,
    this.note = '',
    required this.slots,
  });

  final String name;
  final String shortName;
  final String teacher;
  final int? color;
  final String note;
  final List<SlotDraft> slots;
}

/// 课程仓库：学期与课程的读写入口。
class ScheduleRepository {
  ScheduleRepository(this._db);

  final AppDatabase _db;

  static const _uuidGen = Uuid();

  // ---------- 学期 ----------

  /// 监听当前学期（无则 null）
  Stream<Semester?> watchCurrentSemester() {
    final query = _db.select(_db.semesters)
      ..where((s) => s.isCurrent.equals(true))
      // 历史同步数据若短暂出现多个“当前学期”，页面仍应可用。同步层会
      // 随后修复不变量；这里确定性选择最后更新的一条，避免整页崩溃。
      ..orderBy([
        (s) => OrderingTerm.desc(s.updatedAt),
        (s) => OrderingTerm.desc(s.id),
      ])
      ..limit(1);
    return query.watchSingleOrNull();
  }

  Stream<List<Semester>> watchAllSemesters() =>
      _db.select(_db.semesters).watch();

  /// 新建学期并设为当前学期。startMonday 会被规整到所在周的周一。
  Future<int> createSemester({
    required String name,
    required DateTime startMonday,
    int totalWeeks = 20,
  }) async {
    final monday = mondayOf(startMonday);
    final now = DateTime.now();
    return _db.transaction(() async {
      await (_db.update(
        _db.semesters,
      )..where((s) => s.isCurrent.equals(true))).write(
        SemestersCompanion(
          isCurrent: const Value(false),
          updatedAt: Value(now),
        ),
      );
      return _db
          .into(_db.semesters)
          .insert(
            SemestersCompanion.insert(
              uuid: Value(_uuidGen.v4()),
              name: name,
              startDate: monday,
              totalWeeks: Value(totalWeeks),
              isCurrent: const Value(true),
              updatedAt: Value(now),
            ),
          );
    });
  }

  Future<void> updateSemester(Semester semester) async {
    // 同步 LWW 依据：任何本地修改都要刷新 updatedAt
    final now = DateTime.now();
    await _db.transaction(() async {
      if (semester.isCurrent) {
        await (_db.update(_db.semesters)..where(
              (s) => s.isCurrent.equals(true) & s.id.isNotValue(semester.id),
            ))
            .write(
              SemestersCompanion(
                isCurrent: const Value(false),
                updatedAt: Value(now),
              ),
            );
      }
      await _db
          .update(_db.semesters)
          .replace(semester.copyWith(updatedAt: now));
    });
  }

  Future<void> setCurrentSemester(int id) async {
    final now = DateTime.now();
    await _db.transaction(() async {
      await (_db.update(
        _db.semesters,
      )..where((s) => s.isCurrent.equals(true))).write(
        SemestersCompanion(
          isCurrent: const Value(false),
          updatedAt: Value(now),
        ),
      );
      await (_db.update(_db.semesters)..where((s) => s.id.equals(id))).write(
        SemestersCompanion(isCurrent: const Value(true), updatedAt: Value(now)),
      );
    });
  }

  /// 删除学期（课程级联删除）。删除前把全链路的 uuid 记入待删除队列，
  /// 下次同步时以墓碑形式推送云端（阶段 4）。
  Future<void> deleteSemester(int id) async {
    await _db.transaction(() async {
      final semester = await (_db.select(
        _db.semesters,
      )..where((s) => s.id.equals(id))).getSingleOrNull();
      if (semester == null) return;
      final courseRows = await (_db.select(
        _db.courses,
      )..where((c) => c.semesterId.equals(id))).get();
      for (final course in courseRows) {
        await _recordCourseDeletion(course);
      }
      await _recordDeletion('semester', semester.uuid, '');
      // 显式级联删除：不依赖 SQLite 外键 PRAGMA（NativeDatabase 默认不开外键，
      // 靠 onDelete cascade 会留下孤儿数据）
      for (final course in courseRows) {
        await (_db.delete(
          _db.schedules,
        )..where((s) => s.courseId.equals(course.id))).go();
      }
      await (_db.delete(
        _db.courses,
      )..where((c) => c.semesterId.equals(id))).go();
      await (_db.delete(_db.semesters)..where((s) => s.id.equals(id))).go();

      // 删掉的若是当前学期，必须立刻补选一个：is_current 一旦全是 false，
      // 课表页/课前提醒/小组件都会取不到学期而整页空白。取最近更新的一个，
      // 与网页版 currentSemester 的回退规则一致。
      if (semester.isCurrent) {
        final rest = await (_db.select(_db.semesters)
              ..orderBy([
                (s) => OrderingTerm.desc(s.updatedAt),
                (s) => OrderingTerm.desc(s.id),
              ])
              ..limit(1))
            .getSingleOrNull();
        if (rest != null) {
          await (_db.update(_db.semesters)..where((s) => s.id.equals(rest.id)))
              .write(SemestersCompanion(
            isCurrent: const Value(true),
            updatedAt: Value(DateTime.now()),
          ));
        }
      }
    });
  }

  /// 记录一条待推送的删除（墓碑）
  Future<void> _recordDeletion(String entity, String uuid, String parentUuid) {
    if (uuid.isEmpty) return Future.value(); // v1 存量数据没 uuid 就不推墓碑
    return _db
        .into(_db.pendingDeletions)
        .insert(
          PendingDeletionsCompanion.insert(
            entity: entity,
            uuid: uuid,
            parentUuid: Value(parentUuid),
            deletedAt: DateTime.now(),
          ),
        );
  }

  /// 记录一门课及其全部时间段的删除墓碑
  Future<void> _recordCourseDeletion(Course course) async {
    final slots = await (_db.select(
      _db.schedules,
    )..where((s) => s.courseId.equals(course.id))).get();
    for (final slot in slots) {
      await _recordDeletion('schedule', slot.uuid, course.uuid);
    }
    final semester = await (_db.select(
      _db.semesters,
    )..where((s) => s.id.equals(course.semesterId))).getSingleOrNull();
    await _recordDeletion('course', course.uuid, semester?.uuid ?? '');
  }

  // ---------- 课程 ----------

  /// 监听某学期的全部课程（含时间段）。
  ///
  /// 必须同时 watch courses 和 schedules（review R08）：只 watch courses 时，
  /// "仅修改课程时段"（updateSlot/deleteSlot、远端同步时段）不会触发课程流
  /// 重算，UI/提醒/自动同步会一直沿用旧时段。
  Stream<List<CourseEntry>> watchCourseEntries(int semesterId) {
    final courseStream = (_db.select(_db.courses)
          ..where((c) => c.semesterId.equals(semesterId)))
        .watch();
    final slotStream = (_db.select(_db.schedules).join([
      innerJoin(_db.courses, _db.courses.id.equalsExp(_db.schedules.courseId)),
    ])..where(_db.courses.semesterId.equals(semesterId)))
        .watch()
        .map((rows) => [for (final row in rows) row.readTable(_db.schedules)]);
    return _combineLatest2<List<Course>, List<Schedule>, List<CourseEntry>>(
      courseStream,
      slotStream,
      (courses, slots) {
        final byCourse = <int, List<Schedule>>{};
        for (final slot in slots) {
          byCourse.putIfAbsent(slot.courseId, () => []).add(slot);
        }
        return [
          for (final course in courses)
            CourseEntry(course: course, slots: byCourse[course.id] ?? const []),
        ];
      },
    );
  }

  /// 新增课程（含时间段）。颜色缺省按课名哈希分配马卡龙色。
  Future<int> createCourse({
    required int semesterId,
    required String name,
    String shortName = '',
    String teacher = '',
    int? color,
    String note = '',
    required List<SlotDraft> slots,
  }) async {
    final now = DateTime.now();
    return _db.transaction(
      () => _createCourseRow(
        semesterId: semesterId,
        name: name,
        shortName: shortName,
        teacher: teacher,
        color: color,
        note: note,
        slots: slots,
        now: now,
      ),
    );
  }

  Future<int> createCourses({
    required int semesterId,
    required List<CourseDraft> courses,
  }) {
    final now = DateTime.now();
    return _db.transaction(() async {
      for (final course in courses) {
        await _createCourseRow(
          semesterId: semesterId,
          name: course.name,
          shortName: course.shortName,
          teacher: course.teacher,
          color: course.color,
          note: course.note,
          slots: course.slots,
          now: now,
        );
      }
      return courses.length;
    });
  }

  Future<int> _createCourseRow({
    required int semesterId,
    required String name,
    String shortName = '',
    required String teacher,
    required int? color,
    required String note,
    required List<SlotDraft> slots,
    required DateTime now,
  }) async {
    final courseId = await _db
        .into(_db.courses)
        .insert(
          CoursesCompanion.insert(
            uuid: Value(_uuidGen.v4()),
            semesterId: semesterId,
            name: name,
            shortName: Value(shortName),
            teacher: Value(teacher),
            color: color ?? CourseColors.forCourseName(name).toARGB32(),
            note: Value(note),
            updatedAt: now,
          ),
        );
    await _insertSlots(courseId, slots, now);
    return courseId;
  }

  /// 更新课程：基本信息原地更新，时间段整体替换（简单可靠）。
  Future<void> updateCourse({
    required int courseId,
    required String name,
    String? shortName,
    String teacher = '',
    int? color,
    String note = '',
    required List<SlotDraft> slots,
  }) async {
    final now = DateTime.now();
    await _db.transaction(() async {
      await (_db.update(
        _db.courses,
      )..where((c) => c.id.equals(courseId))).write(
        CoursesCompanion(
          name: Value(name),
          shortName:
              shortName != null ? Value(shortName) : const Value.absent(),
          teacher: Value(teacher),
          note: Value(note),
          updatedAt: Value(now),
          color: color != null ? Value(color) : const Value.absent(),
        ),
      );
      final oldSlots = await (_db.select(
        _db.schedules,
      )..where((s) => s.courseId.equals(courseId))).get();
      final courseRow = await (_db.select(
        _db.courses,
      )..where((c) => c.id.equals(courseId))).getSingleOrNull();
      for (final slot in oldSlots) {
        await _recordDeletion('schedule', slot.uuid, courseRow?.uuid ?? '');
      }
      await (_db.delete(
        _db.schedules,
      )..where((s) => s.courseId.equals(courseId))).go();
      await _insertSlots(courseId, slots, now);
    });
  }

  Future<void> deleteCourse(int courseId) async {
    await _db.transaction(() async {
      final course = await (_db.select(
        _db.courses,
      )..where((c) => c.id.equals(courseId))).getSingleOrNull();
      if (course == null) return;
      await _recordCourseDeletion(course);
      await (_db.delete(
        _db.schedules,
      )..where((s) => s.courseId.equals(courseId))).go();
      await (_db.delete(_db.courses)..where((c) => c.id.equals(courseId))).go();
    });
  }

  /// 原地更新一条时间段（AI 调课用）：刷新 updatedAt 让 LWW 同步到其他设备。
  Future<void> updateSlot(Schedule slot) async {
    await _db
        .update(_db.schedules)
        .replace(slot.copyWith(updatedAt: DateTime.now()));
  }

  /// 新增一条时间段（AI 单次调课的"目标时段"用，review R24）：
  /// 生成 uuid 并入同步，不触碰该课程的其他时段。
  Future<void> createSlot({
    required int courseId,
    required SlotDraft draft,
  }) async {
    await _insertSlots(courseId, [draft], DateTime.now());
  }

  /// 删除一条时间段并记墓碑（AI 取消某节课用）。
  Future<void> deleteSlot(Schedule slot) async {
    await _db.transaction(() async {
      final course = await (_db.select(
        _db.courses,
      )..where((c) => c.id.equals(slot.courseId))).getSingleOrNull();
      await _recordDeletion('schedule', slot.uuid, course?.uuid ?? '');
      await (_db.delete(
        _db.schedules,
      )..where((s) => s.id.equals(slot.id))).go();
    });
  }

  Future<void> _insertSlots(
    int courseId,
    List<SlotDraft> slots,
    DateTime now,
  ) async {
    for (final slot in slots) {
      await _db
          .into(_db.schedules)
          .insert(
            SchedulesCompanion.insert(
              uuid: Value(_uuidGen.v4()),
              courseId: courseId,
              dayOfWeek: slot.dayOfWeek,
              startSection: slot.startSection,
              endSection: slot.endSection,
              weeksType: slot.weeksType,
              customWeeks: Value(jsonEncode(slot.customWeeks)),
              location: Value(slot.location),
              updatedAt: now,
            ),
          );
    }
  }
}

// ==================== 设置仓库（key-value） ====================

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.read(databaseProvider)),
);

class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  Future<String?> get(String key) async {
    final row = await (_db.select(
      _db.settingsEntries,
    )..where((e) => e.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> set(String key, String value) async {
    await _db
        .into(_db.settingsEntries)
        .insertOnConflictUpdate(
          SettingsEntriesCompanion(key: Value(key), value: Value(value)),
        );
  }
}

// ==================== 页面用 Provider ====================

/// 当前学期（可能为 null → 引导用户先创建学期）
final currentSemesterProvider = StreamProvider<Semester?>(
  (ref) => ref.read(scheduleRepositoryProvider).watchCurrentSemester(),
);

/// 今天是当前学期的第几周；未开学/已结束返回 null（假期中）
final currentWeekProvider = Provider<int?>((ref) {
  final semester = ref.watch(currentSemesterProvider).valueOrNull;
  if (semester == null) return null;
  final raw = weekNumberOf(semester.startDate, DateTime.now());
  return clampWeek(raw, semester.totalWeeks);
});

/// 某学期全部课程（含时间段）
final courseEntriesProvider = StreamProvider<List<CourseEntry>>((ref) {
  final semester = ref.watch(currentSemesterProvider).valueOrNull;
  if (semester == null) return Stream.value(const <CourseEntry>[]);
  return ref.read(scheduleRepositoryProvider).watchCourseEntries(semester.id);
});

/// 轻量 combineLatest：任一输入流发出新值且两路都已有值时就发出组合结果。
/// drift 的 watch() 是广播流，两路订阅互不干扰。
Stream<R> _combineLatest2<A, B, R>(
  Stream<A> streamA,
  Stream<B> streamB,
  R Function(A, B) combine,
) {
  late StreamController<R> controller;
  StreamSubscription<A>? subA;
  StreamSubscription<B>? subB;
  A? latestA;
  B? latestB;
  var hasA = false;
  var hasB = false;
  var emitting = false;

  void emit() {
    if (!hasA || !hasB || emitting) return;
    emitting = true;
    controller.add(combine(latestA as A, latestB as B));
    emitting = false;
  }

  controller = StreamController<R>(
    onListen: () {
      subA = streamA.listen(
        (value) {
          latestA = value;
          hasA = true;
          emit();
        },
        onError: controller.addError,
        onDone: () => subB == null ? controller.close() : null,
      );
      subB = streamB.listen(
        (value) {
          latestB = value;
          hasB = true;
          emit();
        },
        onError: controller.addError,
        onDone: () => subA == null ? controller.close() : null,
      );
    },
    onPause: () {
      subA?.pause();
      subB?.pause();
    },
    onResume: () {
      subA?.resume();
      subB?.resume();
    },
    onCancel: () async {
      await subA?.cancel();
      await subB?.cancel();
    },
  );
  return controller.stream;
}

/// 时间段在周次 [week] 是否上课（解析 customWeeks JSON 后走统一判断）
bool slotOccursInWeek(Schedule slot, int week) {
  final custom = (jsonDecode(slot.customWeeks) as List).cast<int>();
  return occursInWeek(slot.weeksType, custom, week);
}
