import 'package:flutter/foundation.dart';

/// 集中描述 Android / iOS 的能力差异，避免业务代码散落平台判断。
class PlatformCapabilities {
  PlatformCapabilities._();

  /// Android 正式版沿用现有 APK 更新接口；iOS 必须走 App Store/TestFlight。
  static bool usesApkUpdates(TargetPlatform platform) =>
      platform == TargetPlatform.android;

  /// 所有正式构建都只允许 HTTPS，避免账号、JWT、同步数据和教务密文
  /// 通过明文链路传输。debug 构建仅为本机/私网联调保留 HTTP。
  static bool allowsApiBaseUrl(
    TargetPlatform platform,
    String baseUrl, {
    bool allowDevelopmentHttp = kDebugMode,
  }) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
    if (uri.scheme.toLowerCase() == 'https') return true;
    if (!allowDevelopmentHttp || uri.scheme.toLowerCase() != 'http') {
      return false;
    }
    final host = uri.host.toLowerCase();
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '10.0.2.2' ||
        host.startsWith('10.') ||
        host.startsWith('192.168.') ||
        _isPrivate172Host(host);
  }

  static bool _isPrivate172Host(String host) {
    final parts = host.split('.');
    if (parts.length != 4 || parts.first != '172') return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }

  /// iOS 只保留有限数量的待发送本地通知；Android 继续使用现有调度数量。
  static int? pendingNotificationLimit(TargetPlatform platform) =>
      platform == TargetPlatform.iOS ? 64 : null;
}
