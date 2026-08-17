import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/week_calculator.dart';
import '../../schedule/data/schedule_repository.dart';

/// 云端同步仓库（设计文档阶段 4）。
///
/// 策略：**客户端权威 + 按记录 updated_at 的 last-write-wins**。
/// - push：把本地全部记录 + 待删除墓碑一次性推上去（学生课表数据量极小，
///   全量推送换来零状态追踪成本；服务端只接受更新的记录）；
/// - pull：按服务端 cursor（synced_at, time.time_ns）增量拉取，
///   逐条与本地比较 updated_at，更新的覆盖本地；墓碑执行本地删除。
///
/// 冲突语义：同一门课两台设备同时改，**最后写入的赢**；
/// 输的一方下次 pull 时拿到赢家版本覆盖本地。
class SyncRepository {
  SyncRepository(this._db, this._dio);

  final AppDatabase _db;
  final Dio _dio;

  static const _cursorKey = 'sync_cursor';
  static const _lastSyncKey = 'sync_last_at';

  // ---------- 对外入口 ----------

  /// 执行一次完整同步（push → pull）。返回人类可读的结果摘要。
  Future<String> sync() async {
    // 先修复旧版本可能遗留的重复“当前学期”，避免把脏状态再次上传。
    await _db.transaction(_normalizeCurrentSemesters);
    final pushSummary = await _push();
    final pullSummary = await _pull();
    final now = DateTime.now();
    await _setSetting(_lastSyncKey, now.toIso8601String());
    return '上传 $pushSummary，下载 $pullSummary';
  }

  Future<DateTime?> lastSyncAt() async {
    final raw = await _getSetting(_lastSyncKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  // ---------- push ----------

  Future<String> _push() async {
    final semesters = await _db.select(_db.semesters).get();
    final courses = await _db.select(_db.courses).get();
    final schedules = await _db.select(_db.schedules).get();
    final deletions = await _db.select(_db.pendingDeletions).get();

    // uuid → 记录，用于给墓碑补 parent 字段
    final semesterUuidById = {for (final s in semesters) s.id: s.uuid};
    final courseUuidById = {for (final c in courses) c.id: c.uuid};

    Map<String, dynamic> semesterToJson(Semester s) => {
          'uuid': s.uuid,
          'name': s.name,
          'start_date':
              '${s.startDate.year.toString().padLeft(4, '0')}-${s.startDate.month.toString().padLeft(2, '0')}-${s.startDate.day.toString().padLeft(2, '0')}',
          'total_weeks': s.totalWeeks,
          'is_current': s.isCurrent,
          'updated_at': s.updatedAt.millisecondsSinceEpoch,
          'deleted': false,
        };

    Map<String, dynamic> courseToJson(Course c) => {
          'uuid': c.uuid,
          'semester_uuid': semesterUuidById[c.semesterId] ?? '',
          'name': c.name,
          'teacher': c.teacher,
          'color': c.color,
          'note': c.note,
          'updated_at': c.updatedAt.millisecondsSinceEpoch,
          'deleted': false,
        };

    Map<String, dynamic> scheduleToJson(Schedule s) => {
          'uuid': s.uuid,
          'course_uuid': courseUuidById[s.courseId] ?? '',
          'day_of_week': s.dayOfWeek,
          'start_section': s.startSection,
          'end_section': s.endSection,
          'weeks_type': s.weeksType.index,
          'custom_weeks': (jsonDecode(s.customWeeks) as List).join(','),
          'location': s.location,
          'updated_at': s.updatedAt.millisecondsSinceEpoch,
          'deleted': false,
        };

    final semesterItems = [for (final s in semesters) semesterToJson(s)];
    final courseItems = [for (final c in courses) courseToJson(c)];
    final scheduleItems = [for (final s in schedules) scheduleToJson(s)];

    // 墓碑：按实体类型塞进对应列表（deleted=true，字段用最小合法值）
    for (final d in deletions) {
      final tombstone = {
        'uuid': d.uuid,
        'updated_at': d.deletedAt.millisecondsSinceEpoch,
        'deleted': true,
      };
      switch (d.entity) {
        case 'semester':
          semesterItems.add({
            ...tombstone,
            'name': '',
            'start_date': '1970-01-01',
            'total_weeks': 20,
            'is_current': false,
          });
        case 'course':
          courseItems.add({
            ...tombstone,
            'semester_uuid': d.parentUuid,
            'name': '',
            'teacher': '',
            'color': 0,
            'note': '',
          });
        case 'schedule':
          scheduleItems.add({
            ...tombstone,
            'course_uuid': d.parentUuid,
            'day_of_week': 1,
            'start_section': 1,
            'end_section': 1,
            'weeks_type': 0,
            'custom_weeks': '',
            'location': '',
          });
      }
    }

    // 服务端对每类记录设置单次 500 条上限，避免异常客户端用超大 JSON
    // 占满内存。正常用户通常只需一批；数据较多时透明分批，不改变同步语义。
    const batchSize = 500;
    final maxItems = math.max(
      1,
      math.max(
        semesterItems.length,
        math.max(courseItems.length, scheduleItems.length),
      ),
    );
    var total = 0;
    for (var start = 0; start < maxItems; start += batchSize) {
      List<Map<String, dynamic>> batch(List<Map<String, dynamic>> items) =>
          start >= items.length
              ? <Map<String, dynamic>>[]
              : items.sublist(start, math.min(start + batchSize, items.length));
      final resp = await _dio.post<Map<String, dynamic>>(
        '/api/sync/push',
        data: {
          'semesters': batch(semesterItems),
          'courses': batch(courseItems),
          'schedules': batch(scheduleItems),
        },
      );
      final data = resp.data?['data'] as Map<String, dynamic>?;
      final applied = data?['applied'] as Map<String, dynamic>?;
      total += ((applied?['semesters'] as num?)?.toInt() ?? 0) +
          ((applied?['courses'] as num?)?.toInt() ?? 0) +
          ((applied?['schedules'] as num?)?.toInt() ?? 0);
    }

    // 推送成功后清除墓碑队列
    await (_db.delete(_db.pendingDeletions)).go();

    return '$total 条';
  }

  // ---------- pull ----------

  Future<String> _pull() async {
    final cursor = int.tryParse(await _getSetting(_cursorKey) ?? '0') ?? 0;
    final resp = await _dio.get<Map<String, dynamic>>(
      '/api/sync/pull',
      queryParameters: {'since': cursor},
    );
    final data = resp.data?['data'] as Map<String, dynamic>?;
    if (data == null) return '0 条';

    var changes = 0;
    var repaired = 0;
    await _db.transaction(() async {
      changes += await _applySemesters(data['semesters'] as List? ?? []);
      changes += await _applyCourses(data['courses'] as List? ?? []);
      changes += await _applySchedules(data['schedules'] as List? ?? []);
      repaired = await _normalizeCurrentSemesters();
    });
    await _setSetting(_cursorKey, '${data['cursor'] ?? cursor}');
    // 兼容尚未升级的服务端：若拉取本身带来了重复状态，把本地修复立即
    // 回传云端，而不是等待下一次自动同步。
    if (repaired > 0) await _push();
    return '${changes + repaired} 条';
  }

  /// 保证本地至多一个当前学期。最后更新者胜出；其余记录刷新 updatedAt，
  /// 让修复能通过 LWW 同步到其他设备，而不是只掩盖本机异常。
  Future<int> _normalizeCurrentSemesters() async {
    final current = await (_db.select(_db.semesters)
          ..where((s) => s.isCurrent.equals(true))
          ..orderBy([
            (s) => OrderingTerm.desc(s.updatedAt),
            (s) => OrderingTerm.desc(s.id),
          ]))
        .get();
    if (current.length <= 1) return 0;

    var repairMillis = DateTime.now().millisecondsSinceEpoch;
    for (final semester in current) {
      if (semester.updatedAt.millisecondsSinceEpoch >= repairMillis) {
        repairMillis = semester.updatedAt.millisecondsSinceEpoch + 1;
      }
    }
    for (var index = 1; index < current.length; index++) {
      await (_db.update(_db.semesters)
            ..where((s) => s.id.equals(current[index].id)))
          .write(SemestersCompanion(
        isCurrent: const Value(false),
        updatedAt: Value(
          DateTime.fromMillisecondsSinceEpoch(repairMillis + index - 1),
        ),
      ));
    }
    return current.length - 1;
  }

  Future<int> _applySemesters(List items) async {
    var changes = 0;
    for (final item in items) {
      final map = item as Map<String, dynamic>;
      final uuid = map['uuid'] as String;
      final remoteUpdated = DateTime.fromMillisecondsSinceEpoch(
          (map['updated_at'] as num).toInt());
      final local = await (_db.select(_db.semesters)
            ..where((s) => s.uuid.equals(uuid)))
          .getSingleOrNull();
      if (map['deleted'] == true) {
        if (local != null) {
          await (_db.delete(_db.semesters)..where((s) => s.id.equals(local.id)))
              .go();
          changes++;
        }
        continue;
      }
      if (local == null) {
        await _db.into(_db.semesters).insert(SemestersCompanion.insert(
              uuid: Value(uuid),
              name: map['name'] as String,
              startDate: DateTime.parse(map['start_date'] as String),
              totalWeeks: Value((map['total_weeks'] as num).toInt()),
              isCurrent: Value(map['is_current'] as bool? ?? false),
              updatedAt: Value(remoteUpdated),
            ));
        changes++;
      } else if (remoteUpdated.isAfter(local.updatedAt)) {
        await (_db.update(_db.semesters)..where((s) => s.id.equals(local.id)))
            .write(SemestersCompanion(
          name: Value(map['name'] as String),
          startDate: Value(DateTime.parse(map['start_date'] as String)),
          totalWeeks: Value((map['total_weeks'] as num).toInt()),
          isCurrent: Value(map['is_current'] as bool? ?? false),
          updatedAt: Value(remoteUpdated),
        ));
        changes++;
      }
    }
    return changes;
  }

  Future<int> _applyCourses(List items) async {
    var changes = 0;
    for (final item in items) {
      final map = item as Map<String, dynamic>;
      final uuid = map['uuid'] as String;
      final remoteUpdated = DateTime.fromMillisecondsSinceEpoch(
          (map['updated_at'] as num).toInt());
      final local = await (_db.select(_db.courses)
            ..where((c) => c.uuid.equals(uuid)))
          .getSingleOrNull();
      if (map['deleted'] == true) {
        if (local != null) {
          await (_db.delete(_db.courses)..where((c) => c.id.equals(local.id)))
              .go();
          changes++;
        }
        continue;
      }
      // 找所属学期的本地 id（本学期还没同步到就跳过，下轮同步自愈）
      final semester = await (_db.select(_db.semesters)
            ..where((s) => s.uuid.equals(map['semester_uuid'] as String)))
          .getSingleOrNull();
      if (semester == null) continue;
      if (local == null) {
        await _db.into(_db.courses).insert(CoursesCompanion.insert(
              uuid: Value(uuid),
              semesterId: semester.id,
              name: map['name'] as String,
              teacher: Value(map['teacher'] as String? ?? ''),
              color: (map['color'] as num?)?.toInt() ?? 0,
              note: Value(map['note'] as String? ?? ''),
              updatedAt: remoteUpdated,
            ));
        changes++;
      } else if (remoteUpdated.isAfter(local.updatedAt)) {
        await (_db.update(_db.courses)..where((c) => c.id.equals(local.id)))
            .write(CoursesCompanion(
          name: Value(map['name'] as String),
          teacher: Value(map['teacher'] as String? ?? ''),
          color: Value((map['color'] as num?)?.toInt() ?? 0),
          note: Value(map['note'] as String? ?? ''),
          updatedAt: Value(remoteUpdated),
        ));
        changes++;
      }
    }
    return changes;
  }

  Future<int> _applySchedules(List items) async {
    var changes = 0;
    for (final item in items) {
      final map = item as Map<String, dynamic>;
      final uuid = map['uuid'] as String;
      final remoteUpdated = DateTime.fromMillisecondsSinceEpoch(
          (map['updated_at'] as num).toInt());
      final local = await (_db.select(_db.schedules)
            ..where((s) => s.uuid.equals(uuid)))
          .getSingleOrNull();
      if (map['deleted'] == true) {
        if (local != null) {
          await (_db.delete(_db.schedules)..where((s) => s.id.equals(local.id)))
              .go();
          changes++;
        }
        continue;
      }
      final course = await (_db.select(_db.courses)
            ..where((c) => c.uuid.equals(map['course_uuid'] as String)))
          .getSingleOrNull();
      if (course == null) continue;
      // custom_weeks 服务端存逗号分隔字符串，本地存 JSON 数组。
      // 容忍范围写法（如 "1-18" 或 "1-8,10,12"），逐段展开成平铺列表。
      final weeksList = _parseWeeksList(map['custom_weeks'] as String? ?? '');
      if (local == null) {
        await _db.into(_db.schedules).insert(SchedulesCompanion.insert(
              uuid: Value(uuid),
              courseId: course.id,
              dayOfWeek: (map['day_of_week'] as num).toInt(),
              startSection: (map['start_section'] as num).toInt(),
              endSection: (map['end_section'] as num).toInt(),
              weeksType: WeeksType.values[(map['weeks_type'] as num).toInt()],
              customWeeks: Value(jsonEncode(weeksList)),
              location: Value(map['location'] as String? ?? ''),
              updatedAt: remoteUpdated,
            ));
        changes++;
      } else if (remoteUpdated.isAfter(local.updatedAt)) {
        await (_db.update(_db.schedules)..where((s) => s.id.equals(local.id)))
            .write(SchedulesCompanion(
          dayOfWeek: Value((map['day_of_week'] as num).toInt()),
          startSection: Value((map['start_section'] as num).toInt()),
          endSection: Value((map['end_section'] as num).toInt()),
          weeksType:
              Value(WeeksType.values[(map['weeks_type'] as num).toInt()]),
          customWeeks: Value(jsonEncode(weeksList)),
          location: Value(map['location'] as String? ?? ''),
          updatedAt: Value(remoteUpdated),
        ));
        changes++;
      }
    }
    return changes;
  }

  // ---------- settings 读写 ----------

  /// 把服务端周次字符串解析成平铺整数列表；"1-8,10,12" 与 "1,2,3" 均支持。
  static List<int> _parseWeeksList(String raw) {
    final result = <int>[];
    for (final piece in raw.split(',')) {
      final trimmed = piece.trim();
      if (trimmed.isEmpty) continue;
      final range = trimmed.split('-');
      if (range.length == 2) {
        final start = int.tryParse(range[0]);
        final end = int.tryParse(range[1]);
        if (start == null || end == null) continue;
        final low = start < end ? start : end;
        final high = start < end ? end : start;
        for (var week = low; week <= high; week++) {
          result.add(week);
        }
      } else {
        final week = int.tryParse(trimmed);
        if (week != null) result.add(week);
      }
    }
    return result.toSet().toList()..sort();
  }

  Future<String?> _getSetting(String key) async {
    final row = await (_db.select(_db.settingsEntries)
          ..where((s) => s.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> _setSetting(String key, String value) async {
    await _db.into(_db.settingsEntries).insertOnConflictUpdate(
        SettingsEntriesCompanion(key: Value(key), value: Value(value)));
  }
}

/// 同步仓库 Provider
final syncRepositoryProvider = Provider<SyncRepository>(
  (ref) => SyncRepository(
    ref.read(databaseProvider),
    ref.read(dioProvider),
  ),
);
