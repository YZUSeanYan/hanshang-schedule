import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;


import '../../features/schedule/data/schedule_repository.dart';
import '../constants/section_times.dart';
import '../database/app_database.dart';
import '../utils/location_formatter.dart';
import '../utils/week_calculator.dart';

/// 课前提醒通知的快捷操作后台回调（@pragma 保证 release 混淆后可被 plugin 找到）。
/// - remind_dismiss：直接取消该条通知
/// - remind_dnd：通过 MethodChannel 让原生打开系统勿扰设置页
@pragma('vm:entry-point')
void _onNotificationAction(NotificationResponse response) {
  final id = response.id;
  switch (response.actionId) {
    case 'remind_dismiss':
      if (id != null) {
        FlutterLocalNotificationsPlugin().cancel(id);
      }
      break;
    case 'remind_dnd':
      const MethodChannel('hanshang/reminder_action')
          .invokeMethod('toggleDnd');
      break;
  }
}


/// 上课提醒服务（设计文档阶段 4）。
///
/// 方案：
/// - 每次课程/学期变化后，为未来 7 天的每节课排一条**本地通知**
///   （默认提前 15 分钟，可在设置中改）；
/// - 用 `inexactAllowWhileIdle`：不需要申请精确闹钟权限，
///   息屏/Doze 下也能送达（允许几分钟误差，对上课提醒够用）；
/// - 同时把待提醒列表写入 SharedPreferences，
///   原生 BootReceiver 在手机重启后据此重新挂闹钟（重启不失效）。
abstract interface class ReminderServiceApi {
  Future<void> requestPermission();

  Future<bool> hasPermission();

  Future<bool> isEnabled();

  Future<void> setEnabled(bool enabled);

  Future<int> leadMinutes();

  Future<void> setLeadMinutes(int minutes);

  Future<void> reschedule();

  Future<void> sendTestNotification();
}

class ReminderService implements ReminderServiceApi {
  ReminderService(this._db);

  final AppDatabase _db;
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const _channelId = 'class_reminders';
  static const _channelName = '上课提醒';
  static const _enabledKey = 'reminder_enabled';
  static const _leadMinutesKey = 'reminder_lead_minutes';

  /// SharedPreferences 键：待提醒列表（原生 BootReceiver 读取）
  static const pendingRemindersPrefsKey = 'pending_reminders';

  @override
  Future<bool> isEnabled() async =>
      (await _getSetting(_enabledKey)) == 'true'; // 必须由用户主动开启

  @override
  Future<void> setEnabled(bool enabled) async {
    await init();
    if (!enabled) {
      await _setSetting(_enabledKey, 'false');
      await _plugin.cancelAll();
      await _writePendingCache(const []);
    } else {
      await _ensurePermission();
      await _setSetting(_enabledKey, 'true');
      await reschedule();
    }
  }

  @override
  Future<int> leadMinutes() async =>
      int.tryParse(await _getSetting(_leadMinutesKey) ?? '') ?? 15;

  @override
  Future<void> setLeadMinutes(int minutes) async {
    await _setSetting(_leadMinutesKey, '$minutes');
    await reschedule();
  }

  /// 初始化插件与时区（App 启动时调用一次）。
  Future<void> init() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    // 目标用户都在国内，直接固定东八区，避免额外依赖设备时区查询
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));

    const androidSettings =
        AndroidInitializationSettings('@drawable/ic_notification');
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings),
      onDidReceiveBackgroundNotificationResponse: _onNotificationAction,
    );
    _initialized = true;
  }

  Future<void> _ensurePermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    if (await android.areNotificationsEnabled() == true) return;
    if (await android.requestNotificationsPermission() != true) {
      throw StateError('通知权限未开启，请在系统设置中允许邗上课表发送通知');
    }
  }

  @override
  Future<void> requestPermission() async {
    await init();
    await _ensurePermission();
  }

  @override
  Future<bool> hasPermission() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return android == null || await android.areNotificationsEnabled() == true;
  }

  @override
  Future<void> sendTestNotification() async {
    await init();
    await _ensurePermission();
    await _plugin.show(
      900000,
      '邗上课表通知测试',
      '通知工作正常，上课前会按你的设置提醒。',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: '按设置的提前时间发送上课提醒',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_notification',
        ),
      ),
    );
  }

  /// 重排未来 7 天的全部上课提醒（课程/学期/设置变化后调用）。
  @override
  Future<void> reschedule() async {
    await init();
    // 只取消上一批真正排过课的提醒 id，绝不能 cancelAll——否则会连同
    // "测试通知"（id 900000）一起删掉，用户刚发完通知就消失了。
    for (final old in await _readPendingCache()) {
      final id = old['id'];
      if (id is int && id > 0) await _plugin.cancel(id);
    }
    if (!await isEnabled()) {
      await _writePendingCache(const []);
      return;
    }

    final semester = await (_db.select(_db.semesters)
          ..where((s) => s.isCurrent.equals(true))
          ..orderBy([
            (s) => OrderingTerm.desc(s.updatedAt),
            (s) => OrderingTerm.desc(s.id),
          ])
          ..limit(1))
        .getSingleOrNull();
    if (semester == null) {
      await _writePendingCache(const []);
      return;
    }
    final courses = await (_db.select(_db.courses)
          ..where((c) => c.semesterId.equals(semester.id)))
        .get();
    final slots = await _db.select(_db.schedules).get();
    final slotsByCourse = <int, List<Schedule>>{};
    for (final s in slots) {
      slotsByCourse.putIfAbsent(s.courseId, () => []).add(s);
    }

    final lead = await leadMinutes();
    final now = tz.TZDateTime.now(tz.local);
    final pending = <Map<String, dynamic>>[];
    var notifyId = 1;

    // 排未来 28 天；即使用户几周不打开 App，提醒也不会在第 8 天断档。
    for (var offset = 0; offset < 28; offset++) {
      final day = now.add(Duration(days: offset));
      final week = weekNumberOf(semester.startDate, day);
      if (week < 1 || week > semester.totalWeeks) continue;

      for (final course in courses) {
        for (final slot in slotsByCourse[course.id] ?? const <Schedule>[]) {
          if (slot.dayOfWeek != day.weekday) continue;
          List<int> customWeeks;
          try {
            customWeeks = (jsonDecode(slot.customWeeks) as List).cast<int>();
          } catch (_) {
            customWeeks = const [];
          }
          if (!occursInWeek(slot.weeksType, customWeeks, week)) continue;

          final start = SectionTimes.startOf(slot.startSection);
          final parts = start.split(':');
          final classTime = tz.TZDateTime(tz.local, day.year, day.month,
              day.day, int.parse(parts[0]), int.parse(parts[1]));
          final remindAt = classTime.subtract(Duration(minutes: lead));
          if (remindAt.isBefore(now)) continue;

          final title = '还有$lead分钟上课：${course.name}';
          final body = '$start 开始 · 第${slot.startSection}-${slot.endSection}节'
              '${slot.location.isEmpty ? '' : ' · ${formatCourseLocation(slot.location)}'}';
          // 通知 id 要稳定：同一天同一门课只提醒最早的那节
          final id = notifyId++;
          await _plugin.zonedSchedule(
            id,
            title,
            body,
            remindAt,
            const NotificationDetails(
              android: AndroidNotificationDetails(
                _channelId,
                _channelName,
                importance: Importance.high,
                priority: Priority.high,
                icon: '@drawable/ic_notification',
                channelDescription: '按设置的提前时间发送上课提醒',
                // 快捷操作：打开勿扰模式 / 取消通知
                actions: [
                  AndroidNotificationAction(
                    'remind_dnd', '打开勿扰模式',
                    showsUserInterface: false,
                    allowGeneratedReplies: false,
                  ),
                  AndroidNotificationAction(
                    'remind_dismiss', '取消通知',
                    showsUserInterface: false,
                    allowGeneratedReplies: false,
                  ),
                ],
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            // iOS 遗留必填参数（本 App 只发 Android，但签名要求）
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
          );
          pending.add({
            'id': id,
            'title': title,
            'body': body,
            'time': remindAt.millisecondsSinceEpoch,
          });
        }
      }
    }
    await _writePendingCache(pending);
  }

  /// 把待提醒列表写进 SharedPreferences（原生 BootReceiver 重启后读取重挂）
  Future<void> _writePendingCache(List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(pendingRemindersPrefsKey, jsonEncode(items));
  }

  /// 读取上一批排课提醒（重启后由原生侧写入的同一缓存，结构相同）
  Future<List<Map<String, dynamic>>> _readPendingCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(pendingRemindersPrefsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
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

/// 提醒服务 Provider
final reminderServiceProvider = Provider<ReminderServiceApi>(
  (ref) => ReminderService(ref.read(databaseProvider)),
);
