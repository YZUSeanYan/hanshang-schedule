import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/platform/platform_capabilities.dart';

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
/// 启动时请求 /api/version/latest，有新版本弹窗提示，可"忽略此版本"。
class UpdateService {
  UpdateService(this._ref);

  final Ref _ref;

  static const _kIgnoredVersionCode = 'ignored_version_code';
  static bool _autoChecked = false; // 每次冷启动只自动检查一次

  /// 启动自动检查：静默失败，有更新才打扰用户。
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

  /// 返回是否有更新弹出了对话框。
  Future<bool> _check(BuildContext context, {required bool manual}) async {
    final info = await PackageInfo.fromPlatform();
    final currentCode = int.tryParse(info.buildNumber) ?? 0;

    final resp = await _ref
        .read(dioProvider)
        .get<Map<String, dynamic>>(
          '/api/version/latest',
          queryParameters: {'current_code': currentCode},
        );
    final data = resp.data?['data'] as Map<String, dynamic>? ?? {};
    if (data['has_update'] != true) return false;

    final latestCode = data['version_code'] as int? ?? 0;
    final isForce = data['is_force_update'] == true;
    final apkUri = _trustedApkUri(data);
    if (apkUri == null) {
      throw const FormatException('服务器返回了不可信的更新地址或无效校验值');
    }

    // 非强制更新且用户已忽略过该版本 → 自动检查不再打扰；手动检查仍提示
    if (!isForce && !manual) {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt(_kIgnoredVersionCode) == latestCode) return false;
    }

    if (!context.mounted) return false;
    await _showUpdateDialog(
      context,
      data,
      isForce: isForce,
      latestCode: latestCode,
      apkUri: apkUri,
    );
    return true;
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

  Uri? _trustedApkUri(Map<String, dynamic> data) {
    return trustedApkUri(data);
  }

  Future<void> _showUpdateDialog(
    BuildContext context,
    Map<String, dynamic> data, {
    required bool isForce,
    required int latestCode,
    required Uri apkUri,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: !isForce, // 强制更新不允许点空白关闭
      builder: (dialogContext) => PopScope(
        canPop: !isForce,
        child: AlertDialog(
          title: Text('发现新版本 ${data['version_name']}'),
          content: Text(
            (data['release_notes'] as String?)?.isNotEmpty == true
                ? data['release_notes'] as String
                : '修复已知问题，建议更新。',
          ),
          actions: [
            if (!isForce)
              TextButton(
                onPressed: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setInt(_kIgnoredVersionCode, latestCode);
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                },
                child: const Text('忽略此版本'),
              ),
            if (!isForce)
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('下次再说'),
              ),
            FilledButton(
              onPressed: () async {
                final opened = await launchUrl(
                  apkUri,
                  mode: LaunchMode.externalApplication,
                );
                if (!opened && dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('无法打开下载页面，请检查浏览器设置')),
                  );
                }
                if (opened && !isForce && dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('立即更新'),
            ),
          ],
        ),
      ),
    );
  }
}

final updateServiceProvider = Provider<UpdateService>(
  (ref) => UpdateService(ref),
);
