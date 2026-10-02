import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/core/network/api_client.dart';
import 'package:yzu_schedule/core/storage/token_storage.dart';
import 'package:yzu_schedule/core/utils/week_calculator.dart';
import 'package:yzu_schedule/core/settings/section_time_settings.dart';
import 'package:yzu_schedule/features/auth/data/auth_repository.dart';
import 'package:yzu_schedule/features/course_import/data/llm_import_repository.dart';
import 'package:yzu_schedule/features/schedule/data/schedule_repository.dart';
import 'package:yzu_schedule/features/schedule/data/override_repository.dart';
import 'package:yzu_schedule/features/sync/data/sync_repository.dart';
import 'package:yzu_schedule/import/yzu_parser.dart';

class Adapter implements HttpClientAdapter {
  Adapter(this.handle);
  final Future<Map<String, dynamic>> Function(RequestOptions) handle;
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async =>
    ResponseBody.fromString(jsonEncode({'data': await handle(o)}), 200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  @override
  void close({bool force = false}) {}
}
Dio client(Future<Map<String, dynamic>> Function(RequestOptions) handle) =>
  Dio(BaseOptions(baseUrl:'https://example.test'))..httpClientAdapter=Adapter(handle);
Map<String,dynamic> event(String uuid, int timestamp, {bool deleted=false}) =>
  {'uuid':uuid,'title':'event','updated_at':timestamp,'deleted':deleted};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for(final version in [1,2,3,4,5]) {
    test('MIGRATION v$version -> v6 preserves existing course', () async {
      final raw = sql.sqlite3.openInMemory();
      var db = AppDatabase.forTesting(NativeDatabase.opened(raw, closeUnderlyingOnClose:false));
      final repo=ScheduleRepository(db);
      final sid=await repo.createSemester(name:'old', startMonday:DateTime(2026,9,7));
      await repo.createCourse(semesterId:sid,name:'existing',slots:[]);
      await db.close();
      raw.execute('DROP TABLE schedule_overrides');
      if(version<5) raw.execute('ALTER TABLE courses DROP COLUMN short_name');
      if(version<3) {
        raw.execute('DROP TABLE local_events');
      } else if(version<4) {
        raw.execute('ALTER TABLE local_events DROP COLUMN short_title');
      }
      if(version<2) {
        raw.execute('ALTER TABLE semesters DROP COLUMN uuid');
        raw.execute('ALTER TABLE semesters DROP COLUMN updated_at');
        raw.execute('ALTER TABLE courses DROP COLUMN uuid');
        raw.execute('ALTER TABLE schedules DROP COLUMN uuid');
        raw.execute('DROP TABLE pending_deletions');
      }
      raw.execute('PRAGMA user_version=$version');
      db=AppDatabase.forTesting(NativeDatabase.opened(raw, closeUnderlyingOnClose:false));
      addTearDown(() async {await db.close();raw.dispose();});
      expect((await db.select(db.courses).get()).single.name,'existing');
      expect((await db.select(db.courses).get()).single.uuid,isNotEmpty);
    });
  }
  test('SYNC keeps tombstone created while push is in flight', () async {
    final db=AppDatabase.forTesting(NativeDatabase.memory()); addTearDown(db.close);
    final arrived=Completer<void>(), release=Completer<void>();
    final dio=client((o) async {
      if(o.path.endsWith('/push')) {arrived.complete();await release.future;return {'applied':{}};}
      return {'cursor':1};
    });
    final run=SyncRepository(db,dio).sync();
    await arrived.future;
    await db.into(db.pendingDeletions).insert(PendingDeletionsCompanion.insert(
      entity:'event',uuid:'deleted-during-push',deletedAt:DateTime.now()));
    release.complete();await run;
    expect(await db.select(db.pendingDeletions).get(),hasLength(1));
  });
  test('SYNC must send all 501 overrides', () async {
    final db=AppDatabase.forTesting(NativeDatabase.memory()); addTearDown(db.close);
    for(var i=0;i<501;i++) {
      await db.into(db.scheduleOverrides).insert(ScheduleOverridesCompanion.insert(
        uuid:Value('o$i'),date:DateTime(2026,1,1).add(Duration(days:i)).toIso8601String().substring(0,10),
        kind:'off',updatedAt:DateTime(2026)));
    }
    var sent=0;
    await SyncRepository(db,client((o) async {
      if(o.path.endsWith('/push')) {sent+=(o.data['overrides'] as List).length;return {'applied':{}};}
      return {'cursor':1};
    })).sync();
    expect(sent,501);
  });
  test('SYNC older remote tombstone must not delete a newer local edit', () async {
    final db=AppDatabase.forTesting(NativeDatabase.memory()); addTearDown(db.close);
    await db.into(db.localEvents).insert(LocalEventsCompanion.insert(uuid:const Value('e'),title:'old edit',updatedAt:DateTime.fromMillisecondsSinceEpoch(1000)));
    await SyncRepository(db,client((o) async => o.path.endsWith('/push')
      ? {'applied':{}} : await (() async {
        // User edits after push has completed but before the pull response arrives.
        await db.update(db.localEvents).write(LocalEventsCompanion(title:const Value('new edit'),updatedAt:Value(DateTime.fromMillisecondsSinceEpoch(3000))));
        return {'events':[event('e',2000,deleted:true)],'cursor':1};
      })())).sync();
    expect(await db.select(db.localEvents).get(),hasLength(1));
  });
  test('ACCOUNT in-flight A pull must not write into B database', () async {
    final db=AppDatabase.forTesting(NativeDatabase.memory()); addTearDown(db.close);
    final arrived=Completer<void>(),release=Completer<void>();
    final sync=SyncRepository(db,client((o)async {
      if(o.path.endsWith('/push'))return {'applied':{}};
      arrived.complete();await release.future;
      return {'events':[event('account-a-event',1000)],'cursor':999};
    })).sync();
    await arrived.future;
    final prefs=await SharedPreferences.getInstance();await prefs.setInt('last_logged_in_user_id',1);
    final container=ProviderContainer(overrides:[
      databaseProvider.overrideWithValue(db),tokenStorageProvider.overrideWithValue(MemoryTokenStorage()),
      dioProvider.overrideWithValue(client((o)async=>{'access_token':'B','refresh_token':'B',
        'user':{'id':2,'username':'B','email':'b@example.test'}})),
    ]);addTearDown(container.dispose);
    await container.read(authRepositoryProvider).login('b','test');
    release.complete();await sync;
    expect(await db.select(db.localEvents).get(),isEmpty);
    expect((await db.select(db.settingsEntries).get()).where((e)=>e.key=='sync_cursor'),isEmpty);
  });
  test('LWW two edits within one second must preserve latest value remotely', () async {
    final db=AppDatabase.forTesting(NativeDatabase.memory()); addTearDown(db.close);
    await db.into(db.localEvents).insert(LocalEventsCompanion.insert(uuid:const Value('e'),title:'first',updatedAt:DateTime.fromMillisecondsSinceEpoch(1100)));
    Map<String,dynamic>? remote;
    var cursor=0;
    final sync=SyncRepository(db,client((o) async {
      if(o.path.endsWith('/push')) {
        final incoming=Map<String,dynamic>.from((o.data['events'] as List).single);
        if(remote==null || incoming['updated_at']>remote!['updated_at']) {remote=incoming;cursor++;}
        return {'applied':{}};
      }
      return {'events': o.queryParameters['since']<cursor?[remote]:[],'cursor':cursor};
    }));
    await sync.sync();
    await db.update(db.localEvents).write(LocalEventsCompanion(title:const Value('second'),updatedAt:Value(DateTime.fromMillisecondsSinceEpoch(1900))));
    await sync.sync();
    expect(remote!['title'],'second');
  });
  test('ACCOUNT switch clears holiday overrides', () async {
    final db=AppDatabase.forTesting(NativeDatabase.memory()); addTearDown(db.close);
    await OverrideRepository(db).upsert(date:'2026-10-01',kind:'off',note:'account A');
    final prefs=await SharedPreferences.getInstance();await prefs.setInt('last_logged_in_user_id',1);
    final container=ProviderContainer(overrides:[
      databaseProvider.overrideWithValue(db), tokenStorageProvider.overrideWithValue(MemoryTokenStorage()),
      dioProvider.overrideWithValue(client((o) async => {'access_token':'test','refresh_token':'test',
        'user':{'id':2,'username':'B','email':'b@example.test'}})),
    ]); addTearDown(container.dispose);
    await container.read(authRepositoryProvider).login('b','test');
    expect(await db.select(db.scheduleOverrides).get(),isEmpty);
  });
  test('REACTIVITY slot-only edit emits updated course entries', () async {
    final db=AppDatabase.forTesting(NativeDatabase.memory()); addTearDown(db.close);
    final repo=ScheduleRepository(db);
    final sid=await repo.createSemester(name:'semester',startMonday:DateTime(2026,9,7));
    await repo.createCourse(semesterId:sid,name:'course',slots:[const SlotDraft(dayOfWeek:1,startSection:1,endSection:2,weeksType:WeeksType.every)]);
    final values=<List<CourseEntry>>[];
    final initial=Completer<void>();
    final sub=repo.watchCourseEntries(sid).listen((v){values.add(v);if(!initial.isCompleted)initial.complete();});
    addTearDown(sub.cancel);await initial.future;
    final slot=(await db.select(db.schedules).get()).single;
    await repo.updateSlot(slot.copyWith(dayOfWeek:3));
    await Future<void>.delayed(const Duration(milliseconds:100));
    expect(values.last.single.slots.single.dayOfWeek,3);
  });
  test('OVERRIDE two devices creating same date remain editable', () async {
    final db=AppDatabase.forTesting(NativeDatabase.memory()); addTearDown(db.close);
    await OverrideRepository(db).upsert(date:'2026-10-01',kind:'off');
    await SyncRepository(db,client((o) async=>o.path.endsWith('/push')?{'applied':{}}:
      {'overrides':[{'uuid':'other-device','date':'2026-10-01','kind':'makeup','weekday':3,'updated_at':2000}],'cursor':1})).sync();
    await OverrideRepository(db).upsert(date:'2026-10-01',kind:'off');
    expect(await db.select(db.scheduleOverrides).get(),hasLength(1));
  });
  test('PRIVACY sanitization removes password/token input attributes', () {
    const html='<html><input type="password" value="synthetic-password"><input type="hidden" name="token" value="synthetic-token"></html>';
    final output=stripIdentityInfo(html);
    expect(output, isNot(contains('synthetic-password')));
    expect(output, isNot(contains('synthetic-token')));
  });
  test('IMPORT capture after SPA term switch must use current term response', () {
    String body(String name) => jsonEncode([
      {'kcmc':name,'xqj':1,'startSection':1,'endSection':2}
    ]);
    final parsed = YzuParser.parseCapture({
      'url':'https://example.test/schedule',
      'html':'',
      'captured':[
        {'url':'https://example.test/api/schedule?term=A','body':body('term A')},
        {'url':'https://example.test/api/schedule?term=B','body':body('term B')},
      ],
    });
    expect(parsed.courses.single.name,'term B');
  });
  test('WEEKS even weeks must exclude week 3 and 5', () {
    expect(occursInWeek(WeeksType.even,[],3),isFalse);
    expect(occursInWeek(WeeksType.even,[],5),isFalse);
  });
  test('IMPORT accepted sections must be renderable by section-time config', () {
    final parsed=LlmImportRepository.mapCoursesResponse([
      {'name':'synthetic course','slots':[{'day_of_week':1,'start_section':13,'end_section':14}]}
    ]);
    expect(parsed,hasLength(1));
    // This is the same indexing operation used by DayView and reminders.
    expect(()=>const SectionTimeConfig.defaults().startOf(parsed.single.slots.single.startSection,DateTime(2026,10,1)),returnsNormally);
  });
}
