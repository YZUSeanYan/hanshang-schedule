import 'dart:io';

import 'package:aliyun_push/aliyun_push.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../network/api_client.dart';
import 'reminder_service.dart';

abstract interface class PushServiceApi {
  Future<bool> shouldPrompt();
  Future<bool> consented();
  Future<void> declineInitialPrompt();
  Future<void> enableForUser(int userId);
  Future<void> restoreForUser(int userId);
  Future<void> unbind();
  Future<Map<String, dynamic>> inbox();
  Future<void> markRead(int id);
  Future<void> markAllRead();
  Future<void> deleteNotification(int id);
  Future<void> clearNotifications();
}

class PushService implements PushServiceApi {
  PushService(this._ref);

  static const _promptedKey = 'notification_permission_prompted_v1';
  static const _consentKey = 'notification_push_consent_v1';
  final Ref _ref;
  final AliyunPush _push = AliyunPush();
  bool _initialized = false;
  bool _receiverRegistered = false;
  int? _boundUserId;

  @override
  Future<bool> shouldPrompt() async {
    if (!Platform.isAndroid) return false;
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_promptedKey) ?? false);
  }

  @override
  Future<bool> consented() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_consentKey) ?? false;
  }

  @override
  Future<void> declineInitialPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_promptedKey, true);
    await prefs.setBool(_consentKey, false);
  }

  @override
  Future<void> enableForUser(int userId) async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_promptedKey, true);
    final reminders = _ref.read(reminderServiceProvider);
    await reminders.requestPermission();
    final granted = await reminders.hasPermission();
    await prefs.setBool(_consentKey, granted);
    if (!granted) {
      throw StateError('未获得系统通知权限，可稍后在系统设置中开启');
    }
    await _initializeAndBind(userId);
  }

  @override
  Future<void> restoreForUser(int userId) async {
    if (await consented()) await _initializeAndBind(userId);
  }

  Future<void> _initializeAndBind(int userId) async {
    if (AppConfig.aliyunPushAppKey.isEmpty ||
        AppConfig.aliyunPushAppSecret.isEmpty) {
      throw StateError('当前安装包未配置原生推送，请更新到正式版本');
    }
    if (!_initialized) {
      _registerSafeReceiver();
      final result = await _push
          .initPush(
            appKey: AppConfig.aliyunPushAppKey,
            appSecret: AppConfig.aliyunPushAppSecret,
          )
          .timeout(const Duration(seconds: 12));
      if (result['code'] != kAliyunPushSuccessCode) {
        throw StateError(result['errorMsg']?.toString() ?? '推送服务初始化失败');
      }
      await _push.setLogLevel(AliyunPushLogLevel.none);
      final channel = await _push.createAndroidChannel(
        'account_messages',
        '账户通知',
        4,
        '管理员发送的重要账户消息与服务通知',
        showBadge: true,
        light: true,
        vibration: true,
      );
      if (channel['code'] != kAliyunPushSuccessCode &&
          channel['code'] != kAliyunPushNotSupport) {
        throw StateError(channel['errorMsg']?.toString() ?? '账户通知渠道创建失败');
      }
      _initialized = true;
    }
    if (_boundUserId != userId) {
      final response = await _ref
          .read(dioProvider)
          .get<Map<String, dynamic>>('/api/notifications/binding');
      final data = response.data?['data'];
      final account = data is Map<String, dynamic>
          ? data['account']?.toString().trim() ?? ''
          : '';
      if (account.isEmpty) throw const FormatException('服务器未返回有效的推送绑定标识');
      final result = await _push
          .bindAccount(account)
          .timeout(const Duration(seconds: 12));
      if (result['code'] != kAliyunPushSuccessCode) {
        throw StateError(result['errorMsg']?.toString() ?? '推送账号绑定失败');
      }
      // 必须在设备登记前记录绑定状态。否则登记接口超时后 logout 会误以为
      // 从未绑定，旧账号可能继续在此设备接收通知。
      _boundUserId = userId;
    }
    final deviceId = await _push.getDeviceId().timeout(
      const Duration(seconds: 8),
    );
    if (deviceId.trim().isEmpty) throw StateError('推送服务未返回设备标识');
    final android = await DeviceInfoPlugin().androidInfo;
    final package = await PackageInfo.fromPlatform();
    final maker = android.manufacturer.trim();
    final model = android.model.trim();
    final label = [maker, model]
        .where((part) => part.isNotEmpty)
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    await _ref
        .read(dioProvider)
        .post<void>(
          '/api/notifications/devices',
          data: {
            'device_id': deviceId,
            'label': label.isEmpty ? 'Android 设备' : label,
            'platform': 'android',
            'app_version': '${package.version}+${package.buildNumber}',
          },
        )
        .timeout(const Duration(seconds: 12));
  }

  void _registerSafeReceiver() {
    if (_receiverRegistered) return;
    // EMAS 会在前台、后台、点击和移除通知时回调 Flutter。所有回调都必须
    // 安全注册；否则旧插件会对空回调使用 `!`，通知到达就可能抛异常。
    Future<void> ignore(Map<dynamic, dynamic> _) async {}
    _push.addMessageReceiver(
      onNotification: ignore,
      onMessage: ignore,
      onNotificationOpened: ignore,
      onNotificationRemoved: ignore,
      onAndroidNotificationReceivedInApp: ignore,
      onAndroidNotificationClickedWithNoAction: ignore,
    );
    _receiverRegistered = true;
  }

  @override
  Future<void> unbind() async {
    if (!_initialized || _boundUserId == null) return;
    try {
      await _push.unbindAccount().timeout(const Duration(seconds: 8));
    } finally {
      _boundUserId = null;
    }
  }

  @override
  Future<Map<String, dynamic>> inbox() async {
    final response = await _ref
        .read(dioProvider)
        .get<Map<String, dynamic>>('/api/notifications');
    return response.data!['data'] as Map<String, dynamic>;
  }

  @override
  Future<void> markRead(int id) async {
    await _ref.read(dioProvider).post<void>('/api/notifications/$id/read');
  }

  @override
  Future<void> markAllRead() async {
    await _ref.read(dioProvider).post<void>('/api/notifications/read-all');
  }

  @override
  Future<void> deleteNotification(int id) async {
    await _ref.read(dioProvider).delete<void>('/api/notifications/$id');
  }

  @override
  Future<void> clearNotifications() async {
    await _ref.read(dioProvider).delete<void>('/api/notifications');
  }
}

final pushServiceProvider = Provider<PushServiceApi>((ref) => PushService(ref));
