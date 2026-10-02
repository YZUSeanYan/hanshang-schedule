import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:uuid/uuid.dart';

import '../utils/week_calculator.dart';

part 'app_database.g.dart';

/// 时间列统一按毫秒整数持久化。
///
/// Drift 的 DateTime 默认只存秒（毫秒被截断），而同步协议按
/// updated_at 毫秒做 last-write-wins：同一秒内两次修改会得到相同
/// 版本，后改的永远传不上去（review R05）。全库统一挂此转换器，
/// v7 迁移负责把存量秒值放大 1000 倍。
class DateTimeMsConverter extends TypeConverter<DateTime, int> {
  const DateTimeMsConverter();

  @override
  DateTime fromSql(int fromDb) => DateTime.fromMillisecondsSinceEpoch(fromDb);

  @override
  int toSql(DateTime value) => value.millisecondsSinceEpoch;
}

/// 学期表：id, name(如"2026秋"), start_date(开学周一), total_weeks, is_current
class Semesters extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid =>
      text().withDefault(const Constant(''))(); // 同步全局键（v2 新增）
  TextColumn get name => text()();
  IntColumn get startDate => integer()
      .map(const DateTimeMsConverter())(); // 开学第一周的周一（毫秒存储）
  IntColumn get totalWeeks => integer().withDefault(const Constant(20))();
  BoolColumn get isCurrent => boolean().withDefault(const Constant(false))();
  IntColumn get updatedAt => integer()
      .clientDefault(() => DateTime.now().millisecondsSinceEpoch)
      .map(const DateTimeMsConverter())(); // v2 新增，LWW 比较依据（毫秒存储）
}

/// 课程表：一门课可有多个上课时间段（Schedules）
class Courses extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid =>
      text().withDefault(const Constant(''))(); // 同步全局键（v2 新增）
  IntColumn get semesterId =>
      integer().references(Semesters, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get shortName =>
      text().withDefault(const Constant(''))(); // 用户自定义简称（卡片优先显示），空=用 name
  TextColumn get teacher => text().withDefault(const Constant(''))();
  IntColumn get color => integer()(); // ARGB int，创建时按课名哈希自动分配
  TextColumn get note => text().withDefault(const Constant(''))();
  IntColumn get updatedAt =>
      integer().map(const DateTimeMsConverter())(); // 毫秒存储
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
  IntColumn get updatedAt =>
      integer().map(const DateTimeMsConverter())(); // 毫秒存储
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
  IntColumn get lastSyncedAt => integer()
      .nullable()
      .map(const DateTimeMsConverter())(); // 毫秒存储
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
  TextColumn get entity => text()(); // "semester" / "course" / "schedule" / "event"
  TextColumn get uuid => text()(); // 被删记录的 uuid
  TextColumn get parentUuid => text()
      .withDefault(const Constant(''))(); // semester_uuid / course_uuid（墓碑推送需要）
  IntColumn get deletedAt =>
      integer().map(const DateTimeMsConverter())(); // 毫秒存储
}

/// 个人日程表（AI 日程 2.0，schema v3 新增）。
///
/// 与课程的区别：不挂学期、不按周次循环。一次性日程（event/ddl/exam）用绝对
/// 日期 date；周期日程（recurring）用 weekday（1=周一…7=周日）长期有效。
/// busySections 是客户端按本地作息算好的占用节次（逗号分隔），共同空闲直接取用。
class LocalEvents extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid =>
      text().withDefault(const Constant(''))(); // 同步全局键
  TextColumn get title => text()();
  TextColumn get shortTitle =>
      text().withDefault(const Constant(''))(); // 课表格子上的简写（AI 生成），空=用 title
  TextColumn get eventType =>
      text().withDefault(const Constant('event'))(); // event / ddl / exam / recurring
  TextColumn get date =>
      text().withDefault(const Constant(''))(); // 一次性日程 YYYY-MM-DD；recurring 为空
  IntColumn get weekday =>
      integer().withDefault(const Constant(0))(); // recurring 专用；其余为 0
  TextColumn get startTime =>
      text().withDefault(const Constant(''))(); // HH:MM，可空
  TextColumn get endTime => text().withDefault(const Constant(''))();
  IntColumn get startSection =>
      integer().withDefault(const Constant(0))(); // 节次表达起始节，0=未用
  IntColumn get endSection => integer().withDefault(const Constant(0))();
  TextColumn get busySections => text().withDefault(const Constant(''))();
  TextColumn get location => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();
  IntColumn get color =>
      integer().withDefault(const Constant(0))(); // ARGB32；0=按标题哈希取色
  IntColumn get remindMinutes =>
      integer().withDefault(const Constant(-1))(); // -1=跟随全局默认，0=不提醒
  TextColumn get source =>
      text().withDefault(const Constant('manual'))(); // voice / text / manual
  IntColumn get updatedAt =>
      integer().map(const DateTimeMsConverter())(); // 毫秒存储
}

/// 调休/放假覆盖表（放假某天不上课；补课某天按指定星期上课）。
///
/// 例：国庆 10/1-10/7 放假（kind=off），10/11 周六补周三的课
/// （kind=makeup, weekday=3）。周/日视图据此改写当天的课程展示。
class ScheduleOverrides extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid => text().withDefault(const Constant(''))();
  TextColumn get date => text()(); // YYYY-MM-DD
  TextColumn get kind => text()(); // off（放假）| makeup（补课）
  IntColumn get weekday =>
      integer().withDefault(const Constant(0))(); // makeup 补哪一天的课（1-7）
  TextColumn get note => text().withDefault(const Constant(''))();
  IntColumn get updatedAt =>
      integer().map(const DateTimeMsConverter())(); // 毫秒存储
}

@DriftDatabase(
  tables: [
    Semesters,
    Courses,
    Schedules,
    SettingsEntries,
    SyncStates,
    PendingDeletions,
    LocalEvents,
    ScheduleOverrides,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'yzu_schedule'));

  /// 测试/调试用：自定义执行器（如内存数据库）
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (migrator, from, to) async {
          // 迁移原则（review R11 教训）：
          // 1. 全部 DDL（加列/建表）先执行，再做任何数据回填——
          //    typed 查询会按"当前 schema"物化所有列，DDL 没跑完前
          //    一次 typed select 就会踩到尚不存在的列。
          // 2. 带非恒定默认值（currentDateAndTime）的加列必须走原生
          //    SQL 恒定默认值 + Dart 回填，SQLite 拒绝非恒定默认值。
          // 3. 回填/缩放一律用 customSelect/customStatement 原生 SQL，
          //    绕开 typed 查询的 schema 前提。
          if (from < 2) {
            // v2：三张主表加 uuid，新增待删除队列表
            await customStatement(
                "ALTER TABLE semesters ADD COLUMN uuid TEXT NOT NULL DEFAULT ''");
            // updated_at 原用 currentDateAndTime 默认值（非恒定），v1 库升级
            // 会被 SQLite 拒绝；改恒定 0 占位，DDL 完成后回填当前时间。
            await customStatement(
                'ALTER TABLE semesters ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0');
            await customStatement(
                "ALTER TABLE courses ADD COLUMN uuid TEXT NOT NULL DEFAULT ''");
            await customStatement(
                "ALTER TABLE schedules ADD COLUMN uuid TEXT NOT NULL DEFAULT ''");
            await migrator.createTable(pendingDeletions);
          }
          if (from < 3) {
            // v3：AI 日程 2.0，新增个人日程表
            await migrator.createTable(localEvents);
          }
          if (from < 4 && from >= 3) {
            // v4：日程新增 shortTitle（AI 简写，课表格子展示用）。
            // 从 <3 升级时 createTable(localEvents) 已含此列，只给 v3 老表补列。
            await migrator.addColumn(localEvents, localEvents.shortTitle);
          }
          if (from < 5) {
            // v5：课程新增 shortName（用户自定义简称，卡片优先显示）
            await migrator.addColumn(courses, courses.shortName);
          }
          if (from < 6) {
            // v6：调休/放假覆盖表（调休课表）
            await migrator.createTable(scheduleOverrides);
          }
          if (from < 2) {
            // 存量数据补发 uuid（否则同步时无法对账）。原生 SQL 回填，
            // 避免 typed 查询读取尚未补齐的列（如 courses.short_name）。
            const uuidGen = Uuid();
            final semesterIds =
                await customSelect('SELECT id FROM semesters').get();
            for (final row in semesterIds) {
              await customStatement('UPDATE semesters SET uuid = ? WHERE id = ?',
                  [uuidGen.v4(), row.data['id']]);
            }
            final courseIds = await customSelect('SELECT id FROM courses').get();
            for (final row in courseIds) {
              await customStatement('UPDATE courses SET uuid = ? WHERE id = ?',
                  [uuidGen.v4(), row.data['id']]);
            }
            final scheduleIds =
                await customSelect('SELECT id FROM schedules').get();
            for (final row in scheduleIds) {
              await customStatement('UPDATE schedules SET uuid = ? WHERE id = ?',
                  [uuidGen.v4(), row.data['id']]);
            }
            // updated_at 占位 0 的行回填当前时间，恢复 LWW 可比性
            await customStatement(
                'UPDATE semesters SET updated_at = ? WHERE updated_at = 0',
                [DateTime.now().millisecondsSinceEpoch]);
          }
          if (from < 7) {
            // v7：时间列从秒精度升级到毫秒（DateTimeMsConverter）。
            // 守卫 1e11：秒级时间戳（~1.7e9）必然小于 1e11，毫秒级
            // （~1.7e12）必然大于，重复升级或半新半旧数据都安全。
            const secondEpochCeiling = 100000000000;
            const msColumns = <String, List<String>>{
              'semesters': ['start_date', 'updated_at'],
              'courses': ['updated_at'],
              'schedules': ['updated_at'],
              'sync_states': ['last_synced_at'],
              'pending_deletions': ['deleted_at'],
              'local_events': ['updated_at'],
              'schedule_overrides': ['updated_at'],
            };
            // 只缩放真实存在的表：本连接可能是部分 schema（测试骨架），
            // 上面 DDL 建出来的表此时已存在，缺的跳过即可。
            final existingTables = {
              for (final row in await customSelect(
                      "SELECT name FROM sqlite_master WHERE type = 'table'")
                  .get())
                row.data['name'] as String
            };
            for (final entry in msColumns.entries) {
              if (!existingTables.contains(entry.key)) continue;
              for (final column in entry.value) {
                // sync_states.last_synced_at 可空，NULL 不受影响
                await customStatement(
                  'UPDATE ${entry.key} SET $column = $column * 1000 '
                  'WHERE $column IS NOT NULL AND $column > 0 AND $column < ?',
                  [secondEpochCeiling],
                );
              }
            }
          }
        },
      );
}
