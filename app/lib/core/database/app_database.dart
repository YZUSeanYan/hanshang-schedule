import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:uuid/uuid.dart';

import '../utils/week_calculator.dart';

part 'app_database.g.dart';

/// 学期表：id, name(如"2026秋"), start_date(开学周一), total_weeks, is_current
class Semesters extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid =>
      text().withDefault(const Constant(''))(); // 同步全局键（v2 新增）
  TextColumn get name => text()();
  DateTimeColumn get startDate => dateTime()(); // 开学第一周的周一
  IntColumn get totalWeeks => integer().withDefault(const Constant(20))();
  BoolColumn get isCurrent => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt =>
      dateTime().withDefault(currentDateAndTime)(); // v2 新增，LWW 比较依据
}

/// 课程表：一门课可有多个上课时间段（Schedules）
class Courses extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid =>
      text().withDefault(const Constant(''))(); // 同步全局键（v2 新增）
  IntColumn get semesterId =>
      integer().references(Semesters, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get teacher => text().withDefault(const Constant(''))();
  IntColumn get color => integer()(); // ARGB int，创建时按课名哈希自动分配
  TextColumn get note => text().withDefault(const Constant(''))();
  DateTimeColumn get updatedAt => dateTime()();
}

/// 上课安排表：一门课的一条时间段
class Schedules extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid =>
      text().withDefault(const Constant(''))(); // 同步全局键（v2 新增）
  IntColumn get courseId =>
      integer().references(Courses, #id, onDelete: KeyAction.cascade)();
  IntColumn get dayOfWeek => integer()(); // 1=周一 ... 7=周日
  IntColumn get startSection => integer()();
  IntColumn get endSection => integer()();
  IntColumn get weeksType => intEnum<WeeksType>()();
  TextColumn get customWeeks =>
      text().withDefault(const Constant('[]'))(); // JSON 数组
  TextColumn get location => text().withDefault(const Constant(''))();
  DateTimeColumn get updatedAt => dateTime()();
}

/// 设置表：key-value（主题色、深色模式、提醒提前分钟、作息表 JSON 等）
class SettingsEntries extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// 同步状态表：记录各实体最后同步时间与脏标记（阶段 4 云端同步使用）
class SyncStates extends Table {
  TextColumn get entity => text()(); // 如 "schedule:<semesterId>" / "settings"
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {entity};
}

/// 待推送的删除记录（v2 新增）。
///
/// 本地删除是物理删除（级联干净），但云端需要墓碑通知其他设备，
/// 所以删除时先在这里记一条，下次同步以 deleted=true 推送后清除。
class PendingDeletions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entity => text()(); // "semester" / "course" / "schedule"
  TextColumn get uuid => text()(); // 被删记录的 uuid
  TextColumn get parentUuid => text()
      .withDefault(const Constant(''))(); // semester_uuid / course_uuid（墓碑推送需要）
  DateTimeColumn get deletedAt => dateTime()();
}

@DriftDatabase(
  tables: [
    Semesters,
    Courses,
    Schedules,
    SettingsEntries,
    SyncStates,
    PendingDeletions
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'yzu_schedule'));

  /// 测试/调试用：自定义执行器（如内存数据库）
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            // v2：三张主表加 uuid，新增待删除队列表
            await migrator.addColumn(semesters, semesters.uuid);
            await migrator.addColumn(semesters, semesters.updatedAt);
            await migrator.addColumn(courses, courses.uuid);
            await migrator.addColumn(schedules, schedules.uuid);
            await migrator.createTable(pendingDeletions);
            // 存量数据补发 uuid（否则同步时无法对账）
            const uuidGen = Uuid();
            for (final row in await migrator.database.select(semesters).get()) {
              await (migrator.database.update(semesters)
                    ..where((s) => s.id.equals(row.id)))
                  .write(SemestersCompanion(uuid: Value(uuidGen.v4())));
            }
            for (final row in await migrator.database.select(courses).get()) {
              await (migrator.database.update(courses)
                    ..where((c) => c.id.equals(row.id)))
                  .write(CoursesCompanion(uuid: Value(uuidGen.v4())));
            }
            for (final row in await migrator.database.select(schedules).get()) {
              await (migrator.database.update(schedules)
                    ..where((s) => s.id.equals(row.id)))
                  .write(SchedulesCompanion(uuid: Value(uuidGen.v4())));
            }
          }
        },
      );
}
