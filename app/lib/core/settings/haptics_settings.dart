import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/schedule/data/schedule_repository.dart';

/// 触感反馈开关（默认开启）：长按「添加」语音录入等交互的震动。
class HapticsEnabled extends Notifier<bool> {
  static const _key = 'haptics_enabled';

  @override
  bool build() {
    _restore();
    return true;
  }

  Future<void> _restore() async {
    final saved = await ref.read(settingsRepositoryProvider).get(_key);
    final enabled = saved != '0';
    if (enabled != state) state = enabled;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    await ref
        .read(settingsRepositoryProvider)
        .set(_key, value ? '1' : '0');
  }
}

final hapticsEnabledProvider =
    NotifierProvider<HapticsEnabled, bool>(HapticsEnabled.new);
