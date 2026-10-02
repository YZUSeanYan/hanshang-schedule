import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:yzu_schedule/core/utils/week_calculator.dart';
import 'dart:ffi';
import 'package:sqlite3/open.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/constants/section_times.dart';
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/core/settings/section_time_settings.dart';
import 'package:yzu_schedule/core/notifications/reminder_service.dart';
import 'package:yzu_schedule/core/widget/widget_service.dart';
import 'package:yzu_schedule/features/schedule/presentation/section_time_settings_page.dart';

class MemorySettings extends SectionTimeSettings {
  MemorySettings(super.db);
  SectionTimeConfig value = const SectionTimeConfig.defaults();
  @override
  Future<SectionTimeConfig> load() async => value;
  @override
  Future<void> save(SectionTimeConfig config) async {
    value = config;
  }
}

class Reminders extends Fake implements ReminderServiceApi {
  int updates = 0;
  @override
  Future<void> reschedule() async {
    updates++;
  }
}

class Widgets extends WidgetService {
  Widgets(super.db);
  int updates = 0;
  @override
  Future<void> refresh() async {
    updates++;
  }
}

void main() {
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  test('10月1日按课程日期切换，上午不变，之后所有节次准确前移30分钟', () {
    const config = SectionTimeConfig.defaults();
    final before = config.forDate(DateTime(2026, 9, 30));
    final after = config.forDate(DateTime(2026, 10, 1));
    expect(before[5].$1, '14:30');
    expect(after[5].$1, '14:00');
    for (var i = 0; i < 12; i++) {
      expect(
          SectionTimeConfig.minutes(before[i].$1)! -
              SectionTimeConfig.minutes(after[i].$1)!,
          i < 5 ? 0 : 30);
      expect(
          SectionTimeConfig.minutes(before[i].$2)! -
              SectionTimeConfig.minutes(after[i].$2)!,
          i < 5 ? 0 : 30);
    }
    expect(after.last, ('19:55', '20:40'));
  });
  test('冬季跨年保持，5月1日恢复春夏', () {
    const config = SectionTimeConfig.defaults();
    for (final date in [
      DateTime(2026, 12, 31),
      DateTime(2027, 1, 1),
      DateTime(2027, 4, 30)
    ]) {
      expect(config.startOf(6, date), '14:00');
    }
    expect(config.startOf(6, DateTime(2027, 5, 1)), '14:30');
  });
  test('自定义在所有日期生效，序列化保留所有节次且不可被原列表修改', () {
    final times = [...SectionTimes.springSummer];
    times[0] = ('07:30', '08:20');
    final config = SectionTimeConfig.custom(times);
    times[0] = ('00:00', '00:01');
    final loaded = SectionTimeConfig.decode(config.encode());
    expect(loaded.custom, config.custom);
    expect(loaded.startOf(1, DateTime(2026, 10, 1)), '07:30');
    expect(loaded.startOf(6, DateTime(2026, 10, 1)), '14:30');
    expect(() => loaded.custom!.clear(), throwsUnsupportedError);
  });
  test('拒绝非法、反向和重叠时间，允许无课间，允许不同课时长度', () {
    for (final slot in [
      ('24:00', '24:30'),
      ('8:00', '08:45'),
      ('08:00', '08:00'),
      ('08:50', '08:10'),
      ('08:00', '09:00')
    ]) {
      final times = [...SectionTimes.springSummer]..[0] = slot;
      expect(() => SectionTimeConfig.custom(times), throwsFormatException);
    }
    expect(() => SectionTimeConfig.custom([]), throwsFormatException);
    expect(
        SectionTimeConfig.validate(
            [...SectionTimes.springSummer]..[0] = ('07:00', '08:55')),
        isNull);
  });
  test('坏配置与未知版本回退安全默认', () {
    for (final raw in [
      null,
      '{}',
      'invalid',
      '{"version":2,"mode":"custom"}',
      '{"version":1,"mode":"custom","times":[]}'
    ]) {
      expect(SectionTimeConfig.decode(raw).automatic, isTrue);
    }
  });
  test('保存后关闭数据库重新打开仍保留，恢复默认能移除自定义', () async {
    final dir = await Directory.systemTemp.createTemp('section-times');
    final file = File('${dir.path}/test.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    final custom = SectionTimeConfig.custom(
        [...SectionTimes.springSummer]..[0] = ('07:30', '08:20'));
    await SectionTimeSettings(db).save(custom);
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    expect((await SectionTimeSettings(db).load()).custom, custom.custom);
    await SectionTimeSettings(db).save(const SectionTimeConfig.defaults());
    expect((await SectionTimeSettings(db).load()).automatic, isTrue);
    await db.close();
    await dir.delete(recursive: true);
  });
  test('实际提醒重排使用自定义时间，重启缓存与新提醒一致', () async {
    SharedPreferences.setMockInitialValues({});
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final now = DateTime.now();
      final semester = await db.into(db.semesters).insert(
          SemestersCompanion.insert(
              name: '测试学期',
              startDate: mondayOf(now),
              isCurrent: const Value(true)));
      final course = await db.into(db.courses).insert(CoursesCompanion.insert(
          semesterId: semester, name: '测试课程', color: 0, updatedAt: now));
      await db.into(db.schedules).insert(SchedulesCompanion.insert(
          courseId: course,
          dayOfWeek: now.add(const Duration(days: 1)).weekday,
          startSection: 6,
          endSection: 6,
          weeksType: WeeksType.every,
          updatedAt: now));
      await db.into(db.settingsEntries).insert(SettingsEntriesCompanion.insert(
          key: 'reminder_enabled', value: 'true'));
      await SectionTimeSettings(db).save(SectionTimeConfig.custom(
          [...SectionTimes.springSummer]..[5] = ('13:30', '14:15')));
      final service = ReminderService(db);
      await service.reschedule();
      final scheduled =
          calls.where((c) => c.method == 'zonedSchedule').toList();
      expect(scheduled, isNotEmpty);
      for (final c in scheduled) {
        expect((c.arguments as Map)['body'], contains('13:30 开始'));
        expect((c.arguments as Map)['scheduledDateTime'], contains('13:15:00'));
      }
      final prefs = await SharedPreferences.getInstance();
      final cache =
          jsonDecode(prefs.getString(ReminderService.pendingRemindersPrefsKey)!)
              as List;
      expect(cache.length, scheduled.length);
      for (final c in cache) {
        final date = tz.TZDateTime.fromMillisecondsSinceEpoch(
            tz.local, c['time'] as int);
        expect(date.hour, 13);
        expect(date.minute, 15);
      }
      calls.clear();
      await SectionTimeSettings(db).save(const SectionTimeConfig.defaults());
      await service.reschedule();
      expect(calls.where((c) => c.method == 'cancel').length, cache.length);
      for (final c in calls.where((c) => c.method == 'zonedSchedule')) {
        final args = c.arguments as Map;
        final date = DateTime.parse(args['scheduledDateTime'] as String);
        expect(
            args['body'],
            contains(
                '${const SectionTimeConfig.defaults().startOf(6, date)} 开始'));
      }
    } finally {
      await db.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
  testWidgets('切换自定义、填入模板、保存与重新进入，联动提醒和小组件', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final settings = MemorySettings(db);
    final reminders = Reminders();
    final widgets = Widgets(db);
    Widget app() => ProviderScope(overrides: [
          sectionTimeSettingsProvider.overrideWithValue(settings),
          reminderServiceProvider.overrideWithValue(reminders),
          widgetServiceProvider.overrideWithValue(widgets)
        ], child: const MaterialApp(home: SectionTimeSettingsPage()));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '上课 08:00'))
            .onPressed,
        isNull);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('填入秋冬时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(settings.value.custom, SectionTimes.autumnWinter);
    expect(reminders.updates, 1);
    expect(widgets.updates, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(settings.value.automatic, isTrue);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
  testWidgets('逐节编辑时间并阻止反向时间保存', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final settings = MemorySettings(db);
    final reminders = Reminders();
    final widgets = Widgets(db);
    await tester.pumpWidget(ProviderScope(overrides: [
      sectionTimeSettingsProvider.overrideWithValue(settings),
      reminderServiceProvider.overrideWithValue(reminders),
      widgetServiceProvider.overrideWithValue(widgets)
    ], child: const MaterialApp(home: SectionTimeSettingsPage())));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上课 08:00'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '09');
    await tester.enterText(find.byType(TextField).at(1), '30');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 节下课时间必须晚于上课时间'), findsOneWidget);
    expect(settings.value.automatic, isTrue);
    expect(reminders.updates, 0);
    await tester.tap(find.text('上课 09:30'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '07');
    await tester.enterText(find.byType(TextField).at(1), '30');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(settings.value.custom!.first, ('07:30', '08:45'));
    expect(reminders.updates, 1);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
  testWidgets('未保存的改动返回时可继续编辑或放弃', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final settings = MemorySettings(db);
    await tester.pumpWidget(ProviderScope(
        overrides: [sectionTimeSettingsProvider.overrideWithValue(settings)],
        child: MaterialApp(
            home: Builder(
                builder: (context) => TextButton(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                            builder: (_) => const SectionTimeSettingsPage())),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('每节课时间'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    expect(settings.value.automatic, isTrue);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}
