import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import 'schedule_repository.dart';

/// 调休覆盖仓库：放假（当天不上课）与补课（某天按指定星期上课）。
class OverrideRepository {
  OverrideRepository(this._db);

  final AppDatabase _db;
  static const _uuidGen = Uuid();

  Stream<List<ScheduleOverride>> watchAll() =>
      (_db.select(_db.scheduleOverrides)
            ..orderBy([(o) => OrderingTerm.asc(o.date)]))
          .watch();

  Future<int> upsert({
    required String date,
    required String kind,
    int weekday = 0,
    String note = '',
  }) async {
    final now = DateTime.now();
    final existing = await (_db.select(_db.scheduleOverrides)
          ..where((o) => o.date.equals(date)))
        .getSingleOrNull();
    if (existing != null) {
      await (_db.update(_db.scheduleOverrides)
            ..where((o) => o.id.equals(existing.id)))
          .write(ScheduleOverridesCompanion(
        kind: Value(kind),
        weekday: Value(_sanitizedWeekday(kind, weekday)),
        note: Value(note),
        updatedAt: Value(now),
      ));
      return existing.id;
    }
    return _db.into(_db.scheduleOverrides).insert(
          ScheduleOverridesCompanion.insert(
            uuid: Value(_uuidGen.v4()),
            date: date,
            kind: kind,
            weekday: Value(_sanitizedWeekday(kind, weekday)),
            note: Value(note),
            updatedAt: now,
          ),
        );
  }

  /// 编辑既有调休记录（可改日期，review R27）：必须按原记录 ID 更新，
  /// 且日期变化时清掉旧日期——否则旧日期行保留，两天都"放假"。
  /// 若旧记录有 uuid，同步走"更新"契约（远端按 uuid 覆盖整行）。
  Future<void> updateRecord({
    required int id,
    required String date,
    required String kind,
    int weekday = 0,
    String note = '',
  }) async {
    final row = await (_db.select(_db.scheduleOverrides)
          ..where((o) => o.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    await _db.transaction(() async {
      if (row.date != date) {
        // 同一日期已被其他记录占用：删除本记录（含墓碑），让 upsert 接管
        final occupant = await (_db.select(_db.scheduleOverrides)
              ..where((o) => o.date.equals(date)))
            .getSingleOrNull();
        if (occupant != null && occupant.id != id) {
          await remove(id);
          await upsert(date: date, kind: kind, weekday: weekday, note: note);
          return;
        }
      }
      await (_db.update(_db.scheduleOverrides)
            ..where((o) => o.id.equals(id)))
          .write(ScheduleOverridesCompanion(
        date: Value(date),
        kind: Value(kind),
        weekday: Value(_sanitizedWeekday(kind, weekday)),
        note: Value(note),
        updatedAt: Value(DateTime.now()),
      ));
    });
  }

  /// kind/weekday 组合校验（review R28）：off 恒为 0；makeup 必须落在
  /// 1-7，非法值（如从 off 行编辑过来时的 0）回退为该日自然星期由调用方
  /// 传入——这里兜底夹回 1（周一），仓库层绝不落库 weekday=0 的补课。
  static int _sanitizedWeekday(String kind, int weekday) {
    if (kind != 'makeup') return 0;
    return weekday < 1 || weekday > 7 ? 1 : weekday;
  }

  Future<void> remove(int id) async {
    await _db.transaction(() async {
      final row = await (_db.select(_db.scheduleOverrides)
            ..where((o) => o.id.equals(id)))
          .getSingleOrNull();
      if (row == null) return;
      if (row.uuid.isNotEmpty) {
        // 墓碑同步：删除必须让其他设备知道
        await _db.into(_db.pendingDeletions).insert(
              PendingDeletionsCompanion.insert(
                entity: 'override',
                uuid: row.uuid,
                parentUuid: const Value(''),
                deletedAt: DateTime.now(),
              ),
            );
      }
      await (_db.delete(_db.scheduleOverrides)..where((o) => o.id.equals(id)))
          .go();
    });
  }
}

final overrideRepositoryProvider = Provider<OverrideRepository>(
  (ref) => OverrideRepository(ref.read(databaseProvider)),
);

final overridesProvider = StreamProvider<List<ScheduleOverride>>(
  (ref) => ref.read(overrideRepositoryProvider).watchAll(),
);

/// 某天实际按哪个星期的课表上课：
/// - 无覆盖 → 自然星期（1-7）
/// - 放假（off）→ null（当天不上课）
/// - 补课（makeup）→ 指定星期
int? effectiveWeekday(List<ScheduleOverride> overrides, DateTime date) {
  final key =
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  for (final row in overrides) {
    if (row.date != key) continue;
    if (row.kind == 'off') return null;
    if (row.kind == 'makeup' && row.weekday >= 1 && row.weekday <= 7) {
      return row.weekday;
    }
  }
  return date.weekday;
}

/// 调休说明（展示用）：如「补周三的课」「放假」。
String overrideLabel(ScheduleOverride row) {
  if (row.kind == 'off') return row.note.isNotEmpty ? row.note : '放假';
  const names = ['一', '二', '三', '四', '五', '六', '日'];
  final base = '补周${names[(row.weekday - 1).clamp(0, 6)]}的课';
  return row.note.isNotEmpty ? '$base · ${row.note}' : base;
}
