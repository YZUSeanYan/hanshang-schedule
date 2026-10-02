import 'dart:async';
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
    this.aiAccent = false,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// AI 主行动作样式（中间的「添加」）：渐变圆钮 + 小星星点缀 +
  /// 呼吸微光 + 按压弹性动画；不改变「添加」语义，只传达 AI 能力感。
  final bool aiAccent;
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
    this.onDestinationLongPressStart,
    this.onDestinationLongPressMoveUpdate,
    this.onDestinationLongPressEnd,
    this.onVoiceActivate,
  });

  final int currentIndex;
  final List<GlassDestination> destinations;
  final ValueChanged<int> onDestinationSelected;
  final void Function(int index)? onDestinationLongPressStart;
  final void Function(int index, LongPressMoveUpdateDetails details)?
      onDestinationLongPressMoveUpdate;
  final void Function(int index)? onDestinationLongPressEnd;

  /// AI 主行动作变身后的语音入口（打开语音录入层，Future 在关闭后完成）
  final Future<void> Function()? onVoiceActivate;

  @override
  State<LiquidGlassNavBar> createState() => _LiquidGlassNavBarState();
}

class _LiquidGlassNavBarState extends State<LiquidGlassNavBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    // 平滑优先：放慢到 480ms，去抖动的 easeOutCubic（曾是 320ms easeOutBack 过冲）
    duration: const Duration(milliseconds: 480),
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
                          // easeOutCubic：平滑减速无过冲（用户反馈原 easeOutBack 太跳）
                          final t = Curves.easeOutCubic.transform(
                            _slide.value,
                          );
                          final position = Alignment.lerp(
                            _alignOf(_from, count),
                            _alignOf(current, count),
                            t,
                          )!;
                          // 滑动中段轻微"果冻拉伸"：幅度收敛，配合慢速更顺滑
                          final stretch =
                              1 + 0.10 * math.sin(math.pi * _slide.value);
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
                          child: widget.destinations[i].aiAccent
                              ? _AiNavButton(
                                  destination: widget.destinations[i],
                                  selected: i == current,
                                  pageActive: i == current,
                                  onTap: () => widget.onDestinationSelected(i),
                                  onVoice: widget.onVoiceActivate ?? () async {},
                                  onLongPressStart:
                                      widget.onDestinationLongPressStart ==
                                              null
                                          ? null
                                          : () => widget
                                              .onDestinationLongPressStart!(i),
                                )
                              : GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => widget.onDestinationSelected(i),
                                  onLongPressStart:
                                      widget.onDestinationLongPressStart ==
                                              null
                                          ? null
                                          : (_) => widget
                                              .onDestinationLongPressStart!(i),
                                  onLongPressMoveUpdate: widget
                                              .onDestinationLongPressMoveUpdate ==
                                          null
                                      ? null
                                      : (details) => widget
                                          .onDestinationLongPressMoveUpdate!(
                                              i, details),
                                  onLongPressEnd:
                                      widget.onDestinationLongPressEnd == null
                                          ? null
                                          : (_) => widget
                                              .onDestinationLongPressEnd!(i),
                                  child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        i == current
                                            ? widget
                                                .destinations[i].selectedIcon
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

/// AI 主行动作按钮（底部导航中间的「添加」）。
///
/// 形态由所在页自动驱动：进入「添加」页即丝滑变身「语音」按钮
/// （图标翻转+文字渐变，约 300ms），点按直接进语音录入；离开添加页
/// 自动变回「添加」。两个形态都是与普通导航项一致的扁平「图标+文字」。
/// 长按仍是全局语音入口。
class _AiNavButton extends StatefulWidget {
  const _AiNavButton({
    required this.destination,
    required this.selected,
    required this.pageActive,
    required this.onTap,
    required this.onVoice,
    this.onLongPressStart,
  });

  final GlassDestination destination;
  final bool selected;

  /// 当前是否已在「添加」页：是则呈现为语音按钮
  final bool pageActive;
  final VoidCallback onTap;

  /// 语音入口：打开语音录入层
  final Future<void> Function() onVoice;
  final VoidCallback? onLongPressStart;

  @override
  State<_AiNavButton> createState() => _AiNavButtonState();
}

class _AiNavButtonState extends State<_AiNavButton>
    with TickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 110),
  );
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    _breathe.repeat(reverse: true);
  }

  @override
  void dispose() {
    _press.dispose();
    _breathe.dispose();
    super.dispose();
  }

  void _handleTap() {
    // 添加页上它是语音按钮：点按直接进语音录入；其余页面点按=正常切页
    if (widget.pageActive) {
      // 弹层自管错误；未 await 的 Future 只兜底静默
      widget.onVoice().catchError((_) {});
    } else {
      widget.onTap();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion && _breathe.isAnimating) _breathe.stop();
    final voiceMode = widget.pageActive;
    final contentColor = (voiceMode || widget.selected)
        ? scheme.primary
        : scheme.onSurfaceVariant;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      onLongPressStart: widget.onLongPressStart == null
          ? null
          : (_) => widget.onLongPressStart!(),
      onTapDown: (_) => _press.forward(),
      onTapUp: (_) => _press.reverse(),
      onTapCancel: () => _press.reverse(),
      child: AnimatedBuilder(
        animation: Listenable.merge([_press, _breathe]),
        builder: (context, _) {
          final scale = _press.status == AnimationStatus.reverse
              ? 0.85 + 0.15 * Curves.elasticOut.transform(1 - _press.value)
              : 1 - 0.15 * Curves.easeOut.transform(_press.value);
          final sparkleAlpha = reduceMotion
              ? 0.9
              : 0.45 + 0.55 * Curves.easeInOut.transform(_breathe.value);
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Transform.scale(
                scale: scale,
                child: SizedBox(
                  width: 26,
                  height: 24,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Center(
                        child: AnimatedSwitcher(
                          duration:
                              Duration(milliseconds: reduceMotion ? 0 : 300),
                          switchInCurve: Curves.easeOutBack,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                            opacity: animation,
                            child: RotationTransition(
                              turns: Tween<double>(begin: -0.18, end: 0)
                                  .animate(animation),
                              child: ScaleTransition(
                                scale: Tween<double>(begin: 0.55, end: 1)
                                    .animate(animation),
                                child: child,
                              ),
                            ),
                          ),
                          child: Icon(
                            voiceMode
                                ? Icons.mic_none_rounded
                                : (widget.selected
                                    ? widget.destination.selectedIcon
                                    : widget.destination.icon),
                            key: ValueKey(voiceMode),
                            size: 24,
                            color: contentColor,
                          ),
                        ),
                      ),
                      // 右上角小星星：AI 能力暗示（语音形态保留）
                      Positioned(
                        right: -1,
                        top: -2,
                        child: Icon(
                          Icons.auto_awesome,
                          size: 9,
                          color:
                              scheme.primary.withValues(alpha: sparkleAlpha),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 3),
              AnimatedSwitcher(
                duration: Duration(milliseconds: reduceMotion ? 0 : 260),
                child: Text(
                  voiceMode ? '语音' : widget.destination.label,
                  key: ValueKey(voiceMode ? 'voice' : 'add'),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: (voiceMode || widget.selected)
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: contentColor,
                  ),
                ),
              ),
            ],
          );
        },
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
