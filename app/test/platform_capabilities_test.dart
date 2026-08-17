import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/config/app_config.dart';
import 'package:yzu_schedule/core/platform/platform_capabilities.dart';
import 'package:yzu_schedule/features/course_import/data/school_url_policy.dart';

void main() {
  test('Android 正式构建拒绝 HTTP 生产接口', () {
    expect(PlatformCapabilities.usesApkUpdates(TargetPlatform.android), isTrue);
    expect(
      PlatformCapabilities.allowsApiBaseUrl(
        TargetPlatform.android,
        'http://schedule.example.com/yzu',
        allowDevelopmentHttp: false,
      ),
      isFalse,
    );
    expect(
      PlatformCapabilities.pendingNotificationLimit(TargetPlatform.android),
      isNull,
    );
  });

  test('所有平台正式构建只允许 HTTPS', () {
    expect(
      PlatformCapabilities.allowsApiBaseUrl(
        TargetPlatform.iOS,
        'http://schedule.example.com/yzu',
        allowDevelopmentHttp: false,
      ),
      isFalse,
    );
    expect(
      PlatformCapabilities.allowsApiBaseUrl(
        TargetPlatform.iOS,
        'https://schedule.example.com/yzu',
        allowDevelopmentHttp: false,
      ),
      isTrue,
    );
  });

  test('debug 构建只为本机和私网保留 HTTP', () {
    expect(
      PlatformCapabilities.allowsApiBaseUrl(
        TargetPlatform.android,
        'http://10.0.2.2:8000',
      ),
      isTrue,
    );
    expect(
      PlatformCapabilities.allowsApiBaseUrl(
        TargetPlatform.android,
        'http://example.com/api',
      ),
      isFalse,
    );
  });

  test('iOS 不使用 APK 更新且限制待通知数量', () {
    expect(PlatformCapabilities.usesApkUpdates(TargetPlatform.iOS), isFalse);
    expect(
      PlatformCapabilities.pendingNotificationLimit(TargetPlatform.iOS),
      64,
    );
  });

  test('App Store 地址只接受 Apple HTTPS 主机', () {
    expect(
      AppConfig.trustedIosAppStoreUri('https://apps.apple.com/cn/app/id123'),
      Uri.parse('https://apps.apple.com/cn/app/id123'),
    );
    expect(
      AppConfig.trustedIosAppStoreUri('http://apps.apple.com/cn/app/id123'),
      isNull,
    );
    expect(
      AppConfig.trustedIosAppStoreUri('https://example.com/app.ipa'),
      isNull,
    );
  });

  test('教务页面策略只接受扬大 HTTPS 域名', () {
    expect(isAllowedSchoolUri(Uri.parse('https://webvpn.yzu.edu.cn/')), isTrue);
    expect(isAllowedSchoolUri(Uri.parse('https://yzu.edu.cn/')), isTrue);
    expect(isAllowedSchoolUri(Uri.parse('http://webvpn.yzu.edu.cn/')), isFalse);
    expect(isAllowedSchoolUri(Uri.parse('https://yzu.edu.cn.example.com/')),
        isFalse);
  });

  test('默认 API 地址为本地开发地址，正式构建必须注入 HTTPS', () {
    expect(AppConfig.apiBaseUrl, 'http://localhost:8000');
  });
}
