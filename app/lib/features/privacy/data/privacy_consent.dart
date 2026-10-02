import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/remote_features/remote_feature_manifest.dart';

/// 隐私政策同意状态（金标联盟/应用商店合规：首次启动必须先经用户同意）。
///
/// key 带版本号：政策重大更新时递增，存量用户下次启动会重新弹窗同意。
/// v1 = 2026-08-13；v2 = 2026-09-02；v3 = 2026-09-13（截图与表格 AI 导入）；
/// v4 = 2026-09-16（AI 日程、个人日程同步、语音转写与麦克风权限）。
///
/// 注意：政策升到 v7（2026-09-22，三端文本统一）后这个字面量**刻意保持不变**——
/// v7 只订正表述、不新增处理目的和系统权限，因此沿用 v4 的同意记录，
/// 存量用户不会被再次弹窗。键名与政策版本号因此不再一一对应，改动前请先读这段。
class PrivacyConsent {
  static const _key = 'privacy_consented_at_v4';

  static String _keyFor(String policyId) {
    if (policyId == bundledPrivacyPolicy.id) return _key;
    if (!RegExp(r'^privacy-[a-zA-Z0-9._-]{1,64}$').hasMatch(policyId)) {
      throw ArgumentError.value(policyId, 'policyId', 'Invalid policy id');
    }
    return 'privacy_consented_at_$policyId';
  }

  Future<bool> hasConsented({String policyId = bundledPrivacyPolicyId}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _keyFor(policyId);
    return prefs.containsKey(key);
  }

  Future<void> agree({String policyId = bundledPrivacyPolicyId}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _keyFor(policyId),
      DateTime.now().millisecondsSinceEpoch,
    );
  }
}

final privacyConsentProvider = Provider<PrivacyConsent>(
  (ref) => PrivacyConsent(),
);

/// 启动门禁：读取本地同意状态（无记录 = 首次启动，需先弹隐私政策）。
final privacyGateProvider = FutureProvider<bool>((ref) async {
  return ref.read(privacyConsentProvider).hasConsented();
});

/// Versioned remote policy gate. A signed policy id gets an independent local
/// consent record, so a major policy update can be delivered without an APK.
final privacyPolicyGateProvider = FutureProvider.family<bool, String>(
  (ref, policyId) =>
      ref.read(privacyConsentProvider).hasConsented(policyId: policyId),
);
