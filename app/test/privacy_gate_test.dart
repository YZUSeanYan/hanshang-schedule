// 隐私政策门禁（金标联盟合规）测试。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:yzu_schedule/features/privacy/data/privacy_consent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('首次启动（无记录）门禁应返回 false', () async {
    SharedPreferences.setMockInitialValues({});
    final consent = PrivacyConsent();
    expect(await consent.hasConsented(), isFalse);
  });

  test('同意后门禁返回 true 且持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final consent = PrivacyConsent();
    await consent.agree();
    expect(await consent.hasConsented(), isTrue);

    // 重新创建实例（模拟重启）仍为 true
    expect(await PrivacyConsent().hasConsented(), isTrue);
  });

  test('已同意的老用户（升级场景）门禁直接放行', () async {
    SharedPreferences.setMockInitialValues({
      'privacy_consented_at': 1700000000000,
    });
    expect(await PrivacyConsent().hasConsented(), isTrue);
  });

  test('privacyGateProvider 读取同意状态', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(await container.read(privacyGateProvider.future), isFalse);
  });
}
