import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/features/schedule/data/event_repository.dart';

/// AI 日程 2.0 数据库层测试：
/// - LocalEvents CRUD 与删除墓碑（entity='event'，同步推送依据）；
/// - v2 → v3 迁移：旧表数据保留，新增 local_events 可用。
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('LocalEvents CRUD 与墓碑', () {
    test('新建日程字段齐全且出现在监听流中', () async {
      final repo = EventRepository(db);
      final id = await repo.createEvent(const EventDraft(
        title: '图书馆自习',
        eventType: 'event',
        date: '2026-09-18',
        startTime: '15:00',
        endTime: '17:00',
        busySections: '9,10,11',
        location: '逸夫馆',
        remindMinutes: 30,
        source: 'voice',
      ));
      final events = await repo.watchAll().first;
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.id, id);
      expect(e.uuid, isNotEmpty);
      expect(e.title, '图书馆自习');
      expect(e.eventType, 'event');
      expect(e.date, '2026-09-18');
      expect(e.startTime, '15:00');
      expect(e.busySections, '9,10,11');
      expect(e.remindMinutes, 30);
      expect(e.source, 'voice');
      expect(e.updatedAt.millisecondsSinceEpoch, greaterThan(0));
    });

    test('删除日程写入墓碑（同步推送依据）', () async {
      final repo = EventRepository(db);
      final id = await repo.createEvent(const EventDraft(title: '例会'));
      await repo.deleteEvent(id);
      expect(await db.select(db.localEvents).get(), isEmpty);
      final tombstones = await db.select(db.pendingDeletions).get();
      expect(tombstones, hasLength(1));
      expect(tombstones.single.entity, 'event');
      expect(tombstones.single.uuid, isNotEmpty);
    });

    test('更新日程刷新 updatedAt（LWW 依据）', () async {
      final repo = EventRepository(db);
      final id = await repo.createEvent(const EventDraft(title: '考试'));
      // drift 默认按秒存时间，把记录回拨到昨天，再验证更新会刷新时间戳
      await (db.update(db.localEvents)..where((e) => e.id.equals(id))).write(
        LocalEventsCompanion(
          updatedAt: Value(DateTime.now().subtract(const Duration(days: 1))),
        ),
      );
      final before = (await db.select(db.localEvents).get()).single;
      await repo.updateEvent(before.copyWith(title: '考试（延期）'));
      final after = (await db.select(db.localEvents).get()).single;
      expect(after.title, '考试（延期）');
      expect(after.updatedAt.isAfter(before.updatedAt), isTrue);
    });
  });

  group('迁移 v2 → v3', () {
    test('旧表数据保留，新增 local_events 可读写', () async {
      final migrated = AppDatabase.forTesting(NativeDatabase.memory(
        setup: (rawDb) {
          // 手工搭出 v2 骨架（semesters 各列与 v2 生成 DDL 对齐），
          // 并置 user_version=2 让 drift 走 onUpgrade 而非 onCreate。
          rawDb.execute(
            "CREATE TABLE semesters ("
            "id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "
            "uuid TEXT NOT NULL DEFAULT '', "
            "name TEXT NOT NULL, "
            "start_date INTEGER NOT NULL, "
            "total_weeks INTEGER NOT NULL DEFAULT 20, "
            "is_current INTEGER NOT NULL DEFAULT 0, "
            "updated_at INTEGER NOT NULL DEFAULT 0);",
          );
          rawDb.execute(
            "INSERT INTO semesters (uuid, name, start_date, total_weeks, is_current, updated_at) "
            "VALUES ('sem-uuid-1', '2026秋', 1788131200, 20, 1, 1788131200);",
          );
          // v5 迁移会给 courses 加 short_name 列，骨架里必须带上
          rawDb.execute(
            "CREATE TABLE courses ("
            "id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "
            "uuid TEXT NOT NULL DEFAULT '', "
            "semester_id INTEGER NOT NULL, "
            "name TEXT NOT NULL, "
            "teacher TEXT NOT NULL DEFAULT '', "
            "color INTEGER NOT NULL DEFAULT 0, "
            "note TEXT NOT NULL DEFAULT '', "
            "updated_at INTEGER NOT NULL DEFAULT 0);",
          );
          rawDb.execute('PRAGMA user_version = 2;');
        },
      ));
      addTearDown(migrated.close);

      // onUpgrade 跑过后新表可用
      final repo = EventRepository(migrated);
      await repo.createEvent(const EventDraft(title: '迁移后新日程'));
      expect(await repo.watchAll().first, hasLength(1));

      // v2 旧数据仍在且可读
      final semesters = await migrated.select(migrated.semesters).get();
      expect(semesters, hasLength(1));
      expect(semesters.single.uuid, 'sem-uuid-1');
      expect(semesters.single.name, '2026秋');
      expect(semesters.single.isCurrent, isTrue);
    });
  });
}
