import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android release registrant includes notification and device plugins', () {
    final registrant = File(
      'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
    ).readAsStringSync();

    expect(registrant, contains('com.aliyun.ams.push.AliyunPushPlugin'));
    expect(
      registrant,
      contains('dev.fluttercommunity.plus.device_info.DeviceInfoPlusPlugin'),
    );
  });

  test('Aliyun log-level channel always completes its Flutter result', () {
    final plugin = File(
      'plugins/aliyun_push/android/src/main/java/com/aliyun/ams/push/AliyunPushPlugin.java',
    ).readAsStringSync();
    final branch = plugin
        .split('} else if ("setPluginLogEnabled".equals(methodName)) {')[1]
        .split('} else if ("setAndroidBadgeNum".equals(methodName)) {')[0];

    expect(branch, contains('handleSuccess(result);'));
    expect(branch, contains('handleError(result'));
  });

  test('release is arm64-only and excludes unconfigured vendor push SDKs', () {
    final appGradle = File('android/app/build.gradle.kts').readAsStringSync();
    final pushGradle = File(
      'plugins/aliyun_push/android/build.gradle',
    ).readAsStringSync();

    expect(appGradle, contains('abiFilters += listOf("arm64-v8a")'));
    // AAR 预编译 jniLibs 不走 ndk.abiFilters，必须显式排除非 arm64 ABI，
    // 否则 armeabi-v7a/x86_64 库会泄漏进包（2026-08-13 构建审计发现）。
    expect(appGradle, contains('excludes += setOf('));
    expect(appGradle, contains('"lib/armeabi-v7a/**"'));
    expect(appGradle, contains('"lib/x86_64/**"'));
    // R8/资源收缩暂缓（低风险路线：先出 arm64-only 候选包）。历史上有
    // WorkDatabase_Impl 被裁剪导致冷启动崩溃的记录，重新开启必须与真实
    // arm64 设备全量回归捆绑；本断言防止无意识地提前恢复 R8。
    expect(appGradle, contains('isMinifyEnabled = false'));
    expect(appGradle, contains('isShrinkResources = false'));
    expect(pushGradle, isNot(contains('alicloud-android-third-push')));
  });

  test('native push callbacks are detached safely', () {
    final plugin = File(
      'plugins/aliyun_push/android/src/main/java/com/aliyun/ams/push/AliyunPushPlugin.java',
    ).readAsStringSync();

    expect(
      plugin,
      contains('if (TextUtils.isEmpty(method) || attachedChannel == null)'),
    );
    expect(plugin, contains('channel = null;'));
    expect(plugin, contains('if (sInstance == this) sInstance = null;'));
    expect(plugin, contains('Third-party vendor channels are not configured'));
  });

  test('push notifications request maximum priority for banner delivery', () {
    final receiver = File(
      'plugins/aliyun_push/android/src/main/java/com/aliyun/ams/push/AliyunPushMessageReceiver.java',
    ).readAsStringSync();

    // 小米/红米会把低优先级通知收进“不重要通知”且不弹横幅；
    // hookNotificationBuild 必须显式提到最高优先级，并标记为消息类别。
    expect(receiver, contains('builder.setPriority(Notification.PRIORITY_MAX);'));
    expect(receiver, contains('builder.setPriority(NotificationCompat.PRIORITY_MAX);'));
    expect(receiver, contains('notification.priority = Notification.PRIORITY_MAX;'));
    expect(receiver, contains('builder.setCategory(Notification.CATEGORY_MESSAGE);'));
    expect(receiver, contains('builder.setCategory(NotificationCompat.CATEGORY_MESSAGE);'));
  });

  test(
    'push binding state is recorded before fallible device registration',
    () {
      final source = File(
        'lib/core/notifications/push_service.dart',
      ).readAsStringSync();
      final boundIndex = source.indexOf('_boundUserId = userId;');
      final deviceIndex = source.indexOf(
        'final deviceId = await _push.getDeviceId()',
      );

      expect(boundIndex, greaterThan(0));
      expect(deviceIndex, greaterThan(boundIndex));
    },
  );

  test('forced update dialog blocks system back navigation', () {
    final source = File(
      'lib/features/update/update_checker.dart',
    ).readAsStringSync();
    expect(source, contains('PopScope('));
    expect(source, contains('canPop: !isForce'));
  });
}
