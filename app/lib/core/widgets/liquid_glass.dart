import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 液态玻璃视觉组件（v1.0.32 视觉升级）：
/// 悬浮胶囊底栏 + 玻璃化顶栏，内容滚动穿透时实时背景模糊（BackdropFilter）。
///
/// 性能约束：模糊区域仅顶/底两条常驻小面积；若低配机滚动掉帧，
/// 优先调低 [LiquidGlassContainer.blur] 与 AppBar 的模糊 sigma。

/// 毛玻璃容器基元：圆角裁剪 + 背景模糊 + 半透明底色 + 高光描边。
class LiquidGlassContainer extends StatelessWidget {
  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 30,
    this.blur = 18,
    this.tintOpacity,
    this.highlightOpacity,
  });

  final Widget child;
  final double borderRadius;
  final double blur;

  /// 底色不透明度；null 时按深浅模式取默认（亮 0.72 / 暗 0.58）
  final double? tintOpacity;
  final double? highlightOpacity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tint = theme.colorScheme.surface.withValues(
      alpha: tintOpacity ?? (dark ? 0.58 : 0.72),
    );
    final highlight = Colors.white.withValues(
      alpha: highlightOpacity ?? (dark ? 0.10 : 0.60),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: highlight),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 底部导航项描述（与 NavigationDestination 对应的轻量数据类）。
class GlassDestination {
  const GlassDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// 悬浮胶囊毛玻璃底栏。
///
/// 内容从胶囊后方滚动穿透（需配合 HomeShell 的 extendBody: true）；
/// 切换 Tab 时高亮块滑动并伴随"果冻拉伸"（滑动中段 scaleX 放大后回弹）。
class LiquidGlassNavBar extends StatefulWidget {
  const LiquidGlassNavBar({
    super.key,
    required this.currentIndex,
    required this.destinations,
    required this.onDestinationSelected,
  });

  final int currentIndex;
  final List<GlassDestination> destinations;
  final ValueChanged<int> onDestinationSelected;

  @override
  State<LiquidGlassNavBar> createState() => _LiquidGlassNavBarState();
}

class _LiquidGlassNavBarState extends State<LiquidGlassNavBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: 1.0,
  );

  /// 滑动起点索引（当前高亮块从哪里出发）
  late int _from = widget.currentIndex;

  @override
  void didUpdateWidget(LiquidGlassNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex != oldWidget.currentIndex) {
      _from = oldWidget.currentIndex;
      _slide.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  Alignment _alignOf(int index, int count) =>
      Alignment(-1 + 2 * index / (count - 1), 0);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 胶囊悬浮：底部至少留 10px，有手势条时让出整个手势区
    final bottomInset = math.max(10.0, MediaQuery.paddingOf(context).bottom);
    final count = widget.destinations.length;
    final current = widget.currentIndex;

    return Container(
      margin: EdgeInsets.fromLTRB(14, 6, 14, bottomInset),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: LiquidGlassContainer(
        child: SizedBox(
          height: 66,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth = constraints.maxWidth / count;
              return Stack(
                children: [
                  // ---- 液态高亮 pill（在导航项下层） ----
                  Positioned.fill(
                    child: Padding(
                      // 不加水平 padding：pill 层须与下方 Row 同坐标系，
                      // 否则两端项的遮罩会向内偏移、不与图标居中
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: AnimatedBuilder(
                        animation: _slide,
                        builder: (context, _) {
                          // easeOutBack 带轻微过冲：高亮块滑过头再弹回
                          final t = Curves.easeOutBack.transform(
                            _slide.value,
                          );
                          final position = Alignment.lerp(
                            _alignOf(_from, count),
                            _alignOf(current, count),
                            t,
                          )!;
                          // 滑动中段"果冻拉伸"：中点最宽，到站恢复
                          final stretch =
                              1 + 0.16 * math.sin(math.pi * _slide.value);
                          return Transform.scale(
                            scaleX: stretch,
                            child: Align(
                              alignment: position,
                              child: FractionallySizedBox(
                                widthFactor: 1 / count,
                                child: Container(
                                  margin: EdgeInsets.symmetric(
                                    horizontal: itemWidth * 0.14,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.secondaryContainer
                                        .withValues(alpha: 0.9),
                                    borderRadius: BorderRadius.circular(22),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  // ---- 导航项 ----
                  Row(
                    children: [
                      for (var i = 0; i < count; i++)
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.onDestinationSelected(i),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  i == current
                                      ? widget.destinations[i].selectedIcon
                                      : widget.destinations[i].icon,
                                  size: 24,
                                  color: i == current
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  widget.destinations[i].label,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: i == current
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: i == current
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 玻璃化顶栏：配合 `Scaffold(extendBodyBehindAppBar: true)` 使用，
/// 滚动内容从顶栏后方穿过时实时模糊提白。
///
/// 用法与 AppBar 一致：`appBar: buildGlassAppBar(context: context, title: ...)`。
PreferredSizeWidget buildGlassAppBar({
  required BuildContext context,
  Widget? title,
  List<Widget> actions = const [],
}) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return AppBar(
    title: title,
    actions: actions,
    centerTitle: false,
    elevation: 0,
    scrolledUnderElevation: 0,
    surfaceTintColor: Colors.transparent,
    backgroundColor: Colors.transparent,
    flexibleSpace: ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          color: theme.colorScheme.surface.withValues(
            alpha: dark ? 0.55 : 0.70,
          ),
        ),
      ),
    ),
  );
}
