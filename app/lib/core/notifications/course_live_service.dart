import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';


/// 上课实时通知（灵动岛）服务：课程进行中显示常驻进度通知。
///
/// 触发时机：App 启动/数据变化/前台每分钟刷新（主服务 watch 里调用 refresh）。
/// Android 16+（API 36）走 promoted ongoing，系统把它提升到屏幕上方/灵动岛；
/// 支持版本：原生 Android 16、ColorOS 16、小米 HyperOS 3.0.300、荣耀 MagicOS 10+。
class CourseLiveService {
  CourseLiveService();

  static const _channel = MethodChannel('hanshang/course_live');
  static const _enabledKey = 'course_live_enabled';

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
    if (!value) {
      try { await _channel.invokeMethod('cancel'); } catch (_) {}
    } else {
      await refresh();
    }
  }

  /// 上课中状态刷新（**已按需求取消常驻通知**，2026-08-15）。
  ///
  /// 设计变更：上课前由 reminder_service 弹课前提醒通知（带勿扰/取消按钮），
  /// 上课过程中不再显示常驻通知。本方法仅确保常驻通知被清理。
  Future<void> refresh() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }

}

final courseLiveServiceProvider = Provider<CourseLiveService>(
  (ref) => CourseLiveService(),
);
