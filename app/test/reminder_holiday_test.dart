import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/core/notifications/reminder_service.dart';
import 'package:yzu_schedule/core/settings/section_time_settings.dart';
import 'package:yzu_schedule/core/utils/week_calculator.dart';

/// 上课提醒 × 调休覆盖 回归测试（修复：调休放假期间课前提醒照发）。
///
/// 可观察面 = reschedule() 写入 SharedPreferences 的待提醒缓存
/// （pendingRemindersPrefsKey），不直接断言插件内部调用。
/// Android 平台假实现：zonedSchedule 捕获到测试列表，其余走通道 mock。
/// 必须继承 Android 类——插件的 resolve 只认 is AndroidFlutterLocalNotificationsPlugin。
class _FakeAndroidPlugin extends AndroidFlutterLocalNotificationsPlugin {
  final scheduled = <(int, String?, tz.TZDateTime)>[];

  @override
  Future<void> zonedSchedule(
    int id,
    String? title,
    String? body,
    tz.TZDateTime scheduledDate,
    AndroidNotificationDetails? notificationDetails, {
    required AndroidScheduleMode scheduleMode,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    scheduled.add((id, title, scheduledDate));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ReminderService service;
  final now = DateTime.now();

  final fakePlugin = _FakeAndroidPlugin();

  setUp(() async {
    // 平台实例 + 插件通道双 mock：测试环境无原生端
    FlutterLocalNotificationsPlatform.instance = fakePlugin;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async {
        // initialize/权限类方法返回 bool；zonedSchedule/cancel 返回 void → null
        // ignore: avoid_print
        print('CHANNEL: ' + call.method);
        const boolMethods = ['initialize', 'areNotificationsEnabled', 'requestNotificationsPermission', 'canScheduleExactNotifications'];
        return boolMethods.contains(call.method) ? true : null;
      },
    );
    SharedPreferences.setMockInitialValues({'reminder_enabled': 'true'});
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = ReminderService(db);
  });

  tearDown(() async => db.close());

  tz.TZDateTime _tomorrow() {
    final n = tz.TZDateTime.now(tz.local);
    return tz.TZDateTime(tz.local, n.year, n.month, n.day + 1);
  }

  String _dateKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// 种子：明天（第 2 周）高等数学第 1-2 节。
  Future<int> _seedTomorrowCourse() async {
    final tomorrow = _tomorrow();
    final semesterStart = tomorrow.subtract(const Duration(days: 8));
    final semesterId = await db.into(db.semesters).insert(SemestersCompanion.insert(
          uuid: Value('sem-t'),
          name: '测试学期',
          startDate: DateTime(
              semesterStart.year, semesterStart.month, semesterStart.day),
          totalWeeks: const Value(20),
          isCurrent: const Value(true),
          updatedAt: Value(now),
        ));
    final courseId = await db.into(db.courses).insert(CoursesCompanion.insert(
          uuid: Value('course-math'),
          semesterId: semesterId,
          name: '高等数学',
          color: 0xFF158A63,
          updatedAt: DateTime.now(),
        ));
    await db.into(db.schedules).insert(SchedulesCompanion.insert(
          uuid: Value('sched-math'),
          courseId: courseId,
          dayOfWeek: tomorrow.weekday,
          startSection: 1,
          endSection: 2,
          weeksType: WeeksType.every,
          location: const Value('文津楼201'),
          updatedAt: DateTime.now(),
        ));
    return courseId;
  }

  /// 种子：一门只排在指定星期（非明天）的课。
  Future<int> _seedOtherDayCourse(int makeupWeekday) async {
    final tomorrow = _tomorrow();
    final semesterStart = tomorrow.subtract(const Duration(days: 8));
    final semesterId = await db.into(db.semesters).insert(SemestersCompanion.insert(
          uuid: Value('sem-t'),
          name: '测试学期',
          startDate: DateTime(
              semesterStart.year, semesterStart.month, semesterStart.day),
          totalWeeks: const Value(20),
          isCurrent: const Value(true),
          updatedAt: Value(now),
        ));
    final courseId = await db.into(db.courses).insert(CoursesCompanion.insert(
          uuid: Value('course-eng'),
          semesterId: semesterId,
          name: '大学英语',
          color: 0xFF0B57D0,
          updatedAt: DateTime.now(),
        ));
    await db.into(db.schedules).insert(SchedulesCompanion.insert(
          uuid: Value('sched-eng'),
          courseId: courseId,
          dayOfWeek: makeupWeekday,
          startSection: 1,
          endSection: 2,
          weeksType: WeeksType.every,
          location: const Value('文津楼301'),
          updatedAt: DateTime.now(),
        ));
    return courseId;
  }

  Future<void> _seedOverride(String kind, int weekday) async {
    final tomorrow = _tomorrow();
    await db.into(db.scheduleOverrides).insert(ScheduleOverridesCompanion.insert(
          uuid: Value('ov-$kind'),
          date: _dateKey(tomorrow),
          kind: kind,
          weekday: Value(weekday),
          updatedAt: DateTime.now(),
        ));
  }

  Future<List<Map<String, dynamic>>> _pendingReminders() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(ReminderService.pendingRemindersPrefsKey);
    if (raw == null) return const [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  test('无覆盖：明天的课程正常排提醒（基线）', () async {
    await service.setEnabled(true);
    await _seedTomorrowCourse();
    final tomorrow = _tomorrow();
    await service.reschedule();
    final pending = await _pendingReminders();
    expect(
      pending.where((p) => (p['title'] as String).contains('高等数学')),
      isNotEmpty,
    );
  });

  test('调休放假（off）：放假当天不发提醒，其余周照常', () async {
    await service.setEnabled(true);
    await _seedTomorrowCourse();
    await _seedOverride('off', 0);
    await service.reschedule();
    final pending = await _pendingReminders();
    final tomorrow = _tomorrow();
    final onHoliday = pending.where((p) {
      if (!(p['title'] as String).contains('高等数学')) return false;
      final t = DateTime.fromMillisecondsSinceEpoch(p['time'] as int);
      return t.year == tomorrow.year && t.month == tomorrow.month && t.day == tomorrow.day;
    });
    // 放假当天（明天）不得有任何课程提醒
    expect(onHoliday, isEmpty);
    // 未来其他周四的提醒照常排（10-08、10-15、10-22……）
    expect(
      pending.where((p) => (p['title'] as String).contains('高等数学')),
      isNotEmpty,
    );
  });

  test('调休补课（makeup）：按指定星期的课表排提醒', () async {
    await service.setEnabled(true);
    final tomorrow = _tomorrow();
    // 课程只排在明天的后两天（自然星期取不到），靠补课覆盖拉回明天
    final makeupWeekday = tomorrow.weekday % 7 + 1;
    await _seedOtherDayCourse(makeupWeekday);
    await _seedOverride('makeup', makeupWeekday);
    await service.reschedule();
    final pending = await _pendingReminders();
    final classReminder = pending
        .where((p) => (p['title'] as String).contains('大学英语'))
        .toList();
    expect(classReminder, isNotEmpty);
    // 提醒时间按「明天」的日期算（补课在明天上），不是补课对应星期的日期
    final reminderTime =
        DateTime.fromMillisecondsSinceEpoch(classReminder.first['time'] as int);
    expect(reminderTime.year, tomorrow.year);
    expect(reminderTime.month, tomorrow.month);
    expect(reminderTime.day, tomorrow.day);
  });
}
