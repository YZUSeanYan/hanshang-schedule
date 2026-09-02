import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 隐私政策同意状态（金标联盟/应用商店合规：首次启动必须先经用户同意）。
///
/// key 带版本号：政策重大更新时递增，存量用户下次启动会重新弹窗同意。
/// v1 = 2026-08-13 首版；v2 = 2026-09-02 第 2 版（新增「我们不收集的信息」红线、
/// AI 解析脱敏细节、联系方式变更）。
class PrivacyConsent {
  static const _key = 'privacy_consented_at_v2';

  Future<bool> hasConsented() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_key);
  }

  Future<void> agree() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, DateTime.now().millisecondsSinceEpoch);
  }
}

final privacyConsentProvider = Provider<PrivacyConsent>(
  (ref) => PrivacyConsent(),
);

/// 启动门禁：读取本地同意状态（无记录 = 首次启动，需先弹隐私政策）。
final privacyGateProvider = FutureProvider<bool>((ref) async {
  return ref.read(privacyConsentProvider).hasConsented();
});
