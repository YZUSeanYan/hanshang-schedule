import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/features/ai_schedule/presentation/event_detail_sheet.dart';
import 'package:yzu_schedule/features/schedule/data/event_repository.dart';
import 'package:yzu_schedule/features/schedule/data/schedule_repository.dart';

void main() {
  testWidgets('详情页→编辑→改类型→保存 全链路（回归：弹层 pop 后 ref 销毁导致保存丢失）', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = EventRepository(db);
    final id = await repo.createEvent(const EventDraft(
      title: '赛前面试（补）', eventType: 'event', date: '2026-09-23',
      source: 'text',
    ));
    final event = await (db.select(db.localEvents)..where((e) => e.id.equals(id))).getSingle();

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showEventDetailSheet(context, event),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // 详情层里点「编辑」（内部先 pop 详情再开编辑器——正是疑似问题路径）
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('编辑日程'), findsOneWidget);
    await tester.tap(find.text('待办'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final after = await (db.select(db.localEvents)..where((e) => e.id.equals(id))).getSingle();
    expect(after.eventType, 'ddl');
    await db.close();
  });
}
