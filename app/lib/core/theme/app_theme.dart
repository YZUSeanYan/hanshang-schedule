import 'package:flutter/material.dart';

/// 应用主题骨架（Material 3）。
///
/// 设计规范（设计文档 6.2）：
/// - 深色模式不是简单反色：背景用深灰而非纯黑；
/// - 圆角卡片、充足留白，信息层级不超过 3 级；
/// - 阶段 5：种子色由 ThemeController 持久化选择，见 theme_controller.dart。
class AppTheme {
  AppTheme._();

  /// 默认品牌种子色（邗上绿）
  static const Color defaultSeed = Color(0xFF158A63);

  /// 预设主题色板（「我的」页可选）
  static const List<Color> presetSeeds = [
    Color(0xFF158A63), // 邗上绿（默认）
    Color(0xFF3A7BD5), // 清爽蓝
    Color(0xFF43A047), // 竹青绿
    Color(0xFF8E24AA), // 葡萄紫
    Color(0xFFE53935), // 枫叶红
    Color(0xFFFB8C00), // 蜜柑橙
    Color(0xFF00ACC1), // 湖水青
    Color(0xFF5C6BC0), // 靛蓝
    Color(0xFFEC407A), // 樱粉
  ];

  /// 深色模式背景：深灰而非纯黑，减少 OLED 下的刺眼对比
  static const Color darkBackground = Color(0xFF121417);

  static ThemeData light(Color seed) {
    return _base(ColorScheme.fromSeed(seedColor: seed));
  }

  static ThemeData dark(Color seed) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    return _base(scheme).copyWith(scaffoldBackgroundColor: darkBackground);
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      scaffoldBackgroundColor: scheme.surface,
      // 全界面一镜到底过渡：平滑滑动 + 淡入 + 轻微缩放（Material 3 动效）
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _SmoothPageTransitionsBuilder(),
          TargetPlatform.iOS: _SmoothPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
      ),
      // 全局形状与浮层统一：卡片 16、对话框 22、底部弹层 24、SnackBar 悬浮
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 68,
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return TextStyle(
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          );
        }),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

/// 一镜到底页面过渡：平滑滑动（4% 位移）+ 淡入 + 轻微缩放。
/// 全界面统一（MaterialApp.router 的 pageTransitionsTheme 注入）。
class _SmoothPageTransitionsBuilder extends PageTransitionsBuilder {
  const _SmoothPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.04, 0),
        end: Offset.zero,
      ).animate(curved),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.985, end: 1.0).animate(curved),
          child: child,
        ),
      ),
    );
  }
}
