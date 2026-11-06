// 计算 Flutter ColorScheme.fromSeed(seedColor: 0xFF158A63) 的完整 Material 3 色板
// 复刻 Flutter 3.44 的 fromSeed 实现：SchemeTonalSpot + contrastLevel 0。
import 'package:material_color_utilities/material_color_utilities.dart';

String hex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

void dumpScheme(String label, DynamicScheme s) {
  final entries = <String, DynamicColor>{
    'primary': MaterialDynamicColors.primary,
    'onPrimary': MaterialDynamicColors.onPrimary,
    'primaryContainer': MaterialDynamicColors.primaryContainer,
    'onPrimaryContainer': MaterialDynamicColors.onPrimaryContainer,
    'secondary': MaterialDynamicColors.secondary,
    'onSecondary': MaterialDynamicColors.onSecondary,
    'secondaryContainer': MaterialDynamicColors.secondaryContainer,
    'onSecondaryContainer': MaterialDynamicColors.onSecondaryContainer,
    'tertiary': MaterialDynamicColors.tertiary,
    'onTertiary': MaterialDynamicColors.onTertiary,
    'tertiaryContainer': MaterialDynamicColors.tertiaryContainer,
    'onTertiaryContainer': MaterialDynamicColors.onTertiaryContainer,
    'error': MaterialDynamicColors.error,
    'onError': MaterialDynamicColors.onError,
    'errorContainer': MaterialDynamicColors.errorContainer,
    'onErrorContainer': MaterialDynamicColors.onErrorContainer,
    'surface': MaterialDynamicColors.surface,
    'surfaceDim': MaterialDynamicColors.surfaceDim,
    'surfaceBright': MaterialDynamicColors.surfaceBright,
    'surfaceContainerLowest': MaterialDynamicColors.surfaceContainerLowest,
    'surfaceContainerLow': MaterialDynamicColors.surfaceContainerLow,
    'surfaceContainer': MaterialDynamicColors.surfaceContainer,
    'surfaceContainerHigh': MaterialDynamicColors.surfaceContainerHigh,
    'surfaceContainerHighest': MaterialDynamicColors.surfaceContainerHighest,
    'onSurface': MaterialDynamicColors.onSurface,
    'onSurfaceVariant': MaterialDynamicColors.onSurfaceVariant,
    'outline': MaterialDynamicColors.outline,
    'outlineVariant': MaterialDynamicColors.outlineVariant,
    'inverseSurface': MaterialDynamicColors.inverseSurface,
    'inverseOnSurface': MaterialDynamicColors.inverseOnSurface,
    'inversePrimary': MaterialDynamicColors.inversePrimary,
    'surfaceTint': MaterialDynamicColors.surfaceTint,
    'scrim': MaterialDynamicColors.scrim,
  };
  print('== $label ==');
  entries.forEach((name, color) {
    print('$name: ${hex(color.getArgb(s))}');
  });
}

void main() {
  final hct = Hct.fromInt(0xFF158A63);
  dumpScheme('light', SchemeTonalSpot(sourceColorHct: hct, isDark: false, contrastLevel: 0.0));
  dumpScheme('dark', SchemeTonalSpot(sourceColorHct: hct, isDark: true, contrastLevel: 0.0));

  // 课程色：安卓 CourseColors.textOn 的 alphaBlend 结果（浅色 0.70*base on 黑，深色 0.42*base on 白）
  print('== macaron course palette ==');
  const macaron = [
    0xFFA8D8EA, 0xFFFFCBCB, 0xFFB5EAD7, 0xFFFFDAC1, 0xFFC7CEEA,
    0xFFF6E6AD, 0xFFA2E1DB, 0xFFF3B0C3, 0xFFBFD8B8, 0xFFE7C6E7,
  ];
  int blend(int base, int bg, double alpha) {
    final r = ((base >> 16 & 0xFF) * alpha + (bg >> 16 & 0xFF) * (1 - alpha)).round();
    final g = ((base >> 8 & 0xFF) * alpha + (bg >> 8 & 0xFF) * (1 - alpha)).round();
    final b = ((base & 0xFF) * alpha + (bg & 0xFF) * (1 - alpha)).round();
    return 0xFF000000 | r << 16 | g << 8 | b;
  }
  for (final color in macaron) {
    print('${hex(color)} textLight=${hex(blend(color, 0x000000, 0.70))} textDark=${hex(blend(color, 0xFFFFFF, 0.42))}');
  }
}
