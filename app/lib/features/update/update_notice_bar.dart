import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'update_checker.dart';

/// 悬浮底栏胶囊的占位高度（不含安全区）：6 上边距 + 66 内容高。
/// 提示条要落在这段预留区之上，与其余页面让出的 `bottom + 76` 同一约定。
const double kGlassNavBarZone = 72;

/// 底部轻提示条：悬浮底栏正上方预留区里的一个小条。
///
/// 设计约束（用户明确要求）：**不能像强制更新那样用全屏弹窗挡课表**，但也
/// 不能毫无提醒。所以刻意做成——
/// - 非模态：没有遮罩、不抢焦点、不挡课表，可继续看和操作；
/// - 贴在底栏胶囊正上方的预留区，不占正文版面；
/// - 一行说完，右侧「查看 / 忽略」两个按钮；
/// - 「忽略」后该版本永久不再出现；不点则每次冷启动最多出现一次。
///
/// 风格与 App 其余浮层一致（surfaceContainerHigh + 18 圆角 + 细阴影）。
class UpdateNoticeBar extends ConsumerWidget {
  const UpdateNoticeBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final data = ref.watch(updateNoticeProvider);
    if (data == null) return const SizedBox.shrink();

    final versionName = data['version_name']?.toString() ?? '';
    final versionCode =
        data['version_code'] is int ? data['version_code'] as int : 0;

    return Material(
      color: colors.surfaceContainerHigh,
      elevation: 3,
      shadowColor: colors.shadow.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => context.push('/update'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.system_update_alt_rounded,
                  size: 18,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 10),
              // 标题优先保证完整：空间不足时先缩字号再省略（信息完整 > 字号）
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    versionName.isEmpty ? '发现新版本' : '发现新版本 $versionName',
                    maxLines: 1,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => context.push('/update'),
                child: const Text('查看'),
              ),
              IconButton(
                tooltip: '忽略此版本',
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  // 先收起再写忽略记录，避免下一帧还闪一下
                  ref.read(updateNoticeProvider.notifier).state = null;
                  await ref.read(updateServiceProvider).ignoreVersion(versionCode);
                },
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: colors.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 把轻提示条叠在主壳底部预留区（悬浮底栏正上方），不进入正文流。
///
/// 用 Stack + Positioned 而不是 Scaffold 的 bottomSheet：后者会被键盘顶起、
/// 也会挤动正文布局；这里要的是「浮在那儿、不参与布局」。
class UpdateNoticeOverlay extends ConsumerWidget {
  const UpdateNoticeOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(updateNoticeProvider) != null;
    // 与 liquid_glass 的胶囊底栏同一套边距（14 左右）+ 上方留 10 呼吸
    final bottomInset =
        MediaQuery.paddingOf(context).bottom + kGlassNavBarZone + 10;
    return Positioned(
      left: 14,
      right: 14,
      bottom: bottomInset,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          offset: visible ? Offset.zero : const Offset(0, 0.35),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 240),
            opacity: visible ? 1 : 0,
            child: const UpdateNoticeBar(),
          ),
        ),
      ),
    );
  }
}
