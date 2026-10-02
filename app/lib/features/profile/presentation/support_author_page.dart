// 支持作者页（「我的」→「支持作者」二级页）。
//
// 仅扫码支持（服务端托管的收款码）。激励视频广告已按用户决策整体移除。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/about_repository.dart';

class SupportAuthorPage extends ConsumerStatefulWidget {
  const SupportAuthorPage({super.key});

  @override
  ConsumerState<SupportAuthorPage> createState() => _SupportAuthorPageState();
}

class _SupportAuthorPageState extends ConsumerState<SupportAuthorPage> {
  late Future<File> _qrFile;

  @override
  void initState() {
    super.initState();
    _qrFile = ref.read(aboutRepositoryProvider).paymentQrFile();
    // 预热失败（如离线）由弹层内的重试呈现；这里先标记已处理，
    // 避免未监听的 Future 错误逃逸
    _qrFile.ignore();
  }

  void _retry() => setState(
      () => _qrFile = ref.read(aboutRepositoryProvider).paymentQrFile());

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('支持作者')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
        children: [
          Card(
            elevation: 0,
            color: colors.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                '邗上课表是一款免费应用，也没有任何内购。如果你觉得它好用，'
                '可以通过下面任意一种方式支持作者——都完全自愿，不支持也不影响任何功能。',
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(height: 1.65),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SupportOptionCard(
            icon: Icons.qr_code_2_rounded,
            title: '扫码支持',
            subtitle: '打开收款码，用微信或支付宝扫码，金额随意',
            onTap: () => _showQrSheet(context),
          ),
          const SizedBox(height: 28),
          Text(
            '无论是否支持，都谢谢你使用邗上课表。',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.outline),
          ),
        ],
      ),
    );
  }

  Future<void> _showQrSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: FutureBuilder<File>(
          future: _qrFile,
          builder: (sheetContext, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline_rounded,
                        size: 44, color: Theme.of(sheetContext).colorScheme.outline),
                    const SizedBox(height: 12),
                    const Text('收款码暂时加载不出来'),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _retry,
                      child: const Text('重新加载'),
                    ),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('扫码支持',
                      style: Theme.of(sheetContext)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 14),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 380),
                    child: Image.file(
                      snapshot.data!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('图片加载失败，请检查网络后重试'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '长按可保存图片 · 请在确认收款人信息后自愿支持',
                    style: Theme.of(sheetContext)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                            color: Theme.of(sheetContext).colorScheme.outline),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 支持方式选项卡：图标 + 标题 + 一行说明，与其他设置页卡片同款 chrome。
class _SupportOptionCard extends StatelessWidget {
  const _SupportOptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, size: 28, color: colors.primary),
        title: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded, size: 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
