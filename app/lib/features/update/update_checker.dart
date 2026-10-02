import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/platform/platform_capabilities.dart';

/// 非强制更新的轻提示状态：冷启动检查发现新版本时写入，HomeShell 渲染成
/// 底部小条。用户「忽略」后清空并记住该版本不再打扰。
///
/// 定义在这里（而不是 widget 里）是为了避免 widget 与本文件互相 import。
final updateNoticeProvider = StateProvider<Map<String, dynamic>?>((ref) => null);

final _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

/// 更新地址必须与 API 同源、全程 HTTPS，并携带合法的 SHA-256 元数据。
///
/// APK 仍由系统浏览器下载；HTTPS 负责传输完整性，哈希用于拒绝不完整或被错误
/// 发布的版本记录。后续若改为应用内下载，必须在打开安装器前校验实际文件哈希。
@visibleForTesting
Uri? trustedApkUri(Map<String, dynamic> data, {String? apiBaseUrl}) {
  final base = Uri.tryParse(apiBaseUrl ?? AppConfig.apiBaseUrl);
  final apk = Uri.tryParse(data['apk_url'] as String? ?? '');
  final sha256 = data['sha256'] as String? ?? '';
  final versionCode = data['version_code'];
  if (base == null ||
      apk == null ||
      base.scheme.toLowerCase() != 'https' ||
      apk.scheme.toLowerCase() != 'https' ||
      !apk.hasScheme ||
      apk.userInfo.isNotEmpty ||
      apk.host.toLowerCase() != base.host.toLowerCase() ||
      apk.port != base.port ||
      !apk.path.startsWith('/yzu-apk/') ||
      !apk.path.toLowerCase().endsWith('.apk') ||
      apk.hasQuery ||
      apk.hasFragment ||
      !_sha256Pattern.hasMatch(sha256) ||
      versionCode is! int ||
      versionCode <= 0) {
    return null;
  }
  return apk;
}

/// 版本更新检查服务（设计文档 P0-9）：
/// 启动时请求 /api/version/latest。普通可选更新只静默缓存，用户可从系统推送
/// 或“我的 → 检查更新”进入详情。
///
/// 产品铁律（review R30）：**任何构建都不执行服务端的强制更新标志**——老用户
/// 的升级路径必须零弹窗，服务端 is_force_update 不能突破这一约束；更新引导
/// 只走非模态提示条与版本定向推送。
class UpdateService {
  UpdateService(this._ref);

  final Ref _ref;

  static const _kIgnoredVersionCode = 'ignored_version_code';
  static const _kCachedUpdate = 'cached_update_v1';
  static bool _autoChecked = false; // 每次冷启动只自动检查一次

  /// 启动自动检查：普通更新和失败都保持静默。
  Future<void> checkOnLaunch(BuildContext context) async {
    if (!PlatformCapabilities.usesApkUpdates(defaultTargetPlatform)) return;
    if (_autoChecked) return;
    _autoChecked = true;
    try {
      await _check(context, manual: false);
    } catch (_) {
      // 自动检查失败（断网等）不提示，下次启动再试
    }
  }

  /// 「我的」页手动检查：无论结果都给出反馈。
  Future<void> checkManually(BuildContext context) async {
    if (!PlatformCapabilities.usesApkUpdates(defaultTargetPlatform)) {
      await _openAppleDistribution(context);
      return;
    }
    try {
      final hasUpdate = await _check(context, manual: true);
      if (!hasUpdate && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(e, fallback: '检查更新失败'))),
        );
      }
    }
  }

  /// 返回是否检测到需要展示的更新。
  Future<bool> _check(BuildContext context, {required bool manual}) async {
    final data = await latestUpdate();
    if (data == null) return false;
    final latestCode = data['version_code'] as int? ?? 0;
    final apkUri = trustedApkUri(data);
    if (apkUri == null) {
      throw const FormatException('服务器返回了不可信的更新地址或无效校验值');
    }

    // 用户已忽略过该版本 → 自动检查不再打扰；手动检查仍展示详情。
    if (!manual) {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt(_kIgnoredVersionCode) == latestCode) return false;
    }
    if (!context.mounted) return false;
    if (manual) {
      await context.push('/update');
    } else {
      // 自动检查：既不能有全屏弹窗挡课表，也不能毫无提醒（用户明确要求）。
      // 改投底部轻提示条——非模态、一行、可忽略。已被忽略的版本在上面
      // 提前 return 了，不会走到这里。
      _ref.read(updateNoticeProvider.notifier).state = data;
    }
    return true;
  }

  /// Fetch and cache a validated update record for the dedicated detail page.
  Future<Map<String, dynamic>?> latestUpdate() async {
    final info = await PackageInfo.fromPlatform();
    final currentCode = int.tryParse(info.buildNumber) ?? 0;

    final resp = await _ref
        .read(dioProvider)
        .get<Map<String, dynamic>>(
          '/api/version/latest',
          queryParameters: {'current_code': currentCode},
        );
    final data = resp.data?['data'] as Map<String, dynamic>? ?? {};
    if (data['has_update'] != true) {
      // 服务端权威判定"已是最新"：清掉可能过期的本地缓存（review R31），
      // 详情页不能再拿旧缓存冒充可更新记录。
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kCachedUpdate);
      return null;
    }
    if (trustedApkUri(data) == null) {
      throw const FormatException('服务器返回了不可信的更新地址或无效校验值');
    }
    final safe = <String, dynamic>{
      'has_update': true,
      'version_name': data['version_name']?.toString() ?? '',
      'version_code': data['version_code'],
      'apk_url': data['apk_url']?.toString() ?? '',
      'sha256': data['sha256']?.toString() ?? '',
      'release_notes': data['release_notes']?.toString() ?? '',
      'is_force_update': data['is_force_update'] == true,
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCachedUpdate, jsonEncode(safe));
    return safe;
  }

  /// 本地缓存的更新记录（review R31）：只允许展示**严格比当前新**的版本。
  /// 升级后缓存里的旧版本记录一律视为失效并清除。
  Future<Map<String, dynamic>?> cachedUpdate() async {
    final raw = (await SharedPreferences.getInstance()).getString(_kCachedUpdate);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || trustedApkUri(decoded) == null) {
        return null;
      }
      final info = await PackageInfo.fromPlatform();
      final currentCode = int.tryParse(info.buildNumber) ?? 0;
      final cachedCode = decoded['version_code'];
      if (cachedCode is! int || cachedCode <= currentCode) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_kCachedUpdate);
        return null;
      }
      return decoded;
    } catch (_) {
      // Ignore malformed local state and refresh from the signed API record.
    }
    return null;
  }

  Future<void> ignoreVersion(int versionCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kIgnoredVersionCode, versionCode);
  }

  Future<bool> download(Map<String, dynamic> data) async {
    final uri = trustedApkUri(data);
    if (uri == null) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _openAppleDistribution(BuildContext context) async {
    final appStoreUri = AppConfig.trustedIosAppStoreUri();
    try {
      if (appStoreUri != null &&
          await launchUrl(appStoreUri, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {
      // App Store 尚不可用或设备无法处理链接时，使用下方可理解的提示兜底。
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('iOS 版本通过 App Store 或 TestFlight 更新')),
      );
    }
  }
}

final updateServiceProvider = Provider<UpdateService>(
  (ref) => UpdateService(ref),
);
