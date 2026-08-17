import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/schedule/data/schedule_repository.dart';
import 'app_theme.dart';

/// 主题控制器：深色模式 + 自定义主题色（阶段 5），持久化到本地 settings 表。
class ThemeController extends Notifier<ThemeMode> {
  static const _modeKey = 'theme_mode';
  static const _seedKey = 'theme_seed';

  @override
  ThemeMode build() {
    _restore();
    return ThemeMode.system; // 恢复完成前先跟随系统
  }

  Future<void> _restore() async {
    final settings = ref.read(settingsRepositoryProvider);
    final saved = await settings.get(_modeKey);
    final mode = ThemeMode.values.asNameMap()[saved];
    if (mode != null && mode != state) state = mode;

    final seedRaw = await settings.get(_seedKey);
    final seedValue = int.tryParse(seedRaw ?? '');
    if (seedValue != null) {
      ref.read(themeSeedProvider.notifier).state = Color(seedValue);
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    await ref.read(settingsRepositoryProvider).set(_modeKey, mode.name);
  }

  Future<void> setSeed(Color color) async {
    ref.read(themeSeedProvider.notifier).state = color;
    await ref
        .read(settingsRepositoryProvider)
        .set(_seedKey, color.toARGB32().toString());
  }
}

final themeControllerProvider =
    NotifierProvider<ThemeController, ThemeMode>(ThemeController.new);

/// 当前主题种子色（默认邗上绿）
final themeSeedProvider = StateProvider<Color>((ref) => AppTheme.defaultSeed);
