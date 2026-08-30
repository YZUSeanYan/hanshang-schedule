import 'package:flutter/services.dart';

/// 穿山甲激励视频「看广告支持作者」服务。
///
/// 凭据经 --dart-define 注入（PANGLE_AD_APP_ID / PANGLE_AD_REWARD_SLOT），
/// 两者缺一即视为未配置：入口按钮隐藏，原生侧不会初始化广告 SDK，
/// 正式包因此不含任何广告行为。
class RewardAdService {
  RewardAdService._();

  static const MethodChannel _channel = MethodChannel('hanshang/reward_ad');

  static const String appId = String.fromEnvironment('PANGLE_AD_APP_ID');
  static const String rewardSlotId = String.fromEnvironment(
    'PANGLE_AD_REWARD_SLOT',
  );

  /// 广告入口是否可用（构建时注入了完整凭据）
  static bool get isConfigured => appId.isNotEmpty && rewardSlotId.isNotEmpty;

  /// 展示激励视频；看完并发放奖励返回 true，中途关闭返回 false。
  ///
  /// 抛出 PlatformException（not_configured/init_failed/load_failed/busy）。
  static Future<bool> show({String userId = ''}) async {
    if (!isConfigured) {
      throw PlatformException(code: 'not_configured', message: '广告服务未配置');
    }
    final result = await _channel.invokeMethod<bool>('show', {
      'appId': appId,
      'slotId': rewardSlotId,
      'userId': userId,
    });
    return result == true;
  }
}
