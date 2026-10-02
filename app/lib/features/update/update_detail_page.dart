import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import 'update_checker.dart';

class UpdateDetailPage extends ConsumerStatefulWidget {
  const UpdateDetailPage({super.key});

  @override
  ConsumerState<UpdateDetailPage> createState() => _UpdateDetailPageState();
}

class _UpdateDetailPageState extends ConsumerState<UpdateDetailPage> {
  late Future<Map<String, dynamic>?> _future;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>?> _load() async {
    final service = ref.read(updateServiceProvider);
    try {
      // 服务端应答（含"已是最新"= null）是权威结果，不回退旧缓存
      //（review R31：升级后旧缓存会被 cachedUpdate 判失效，且网络正常时
      // 服务端说无更新就显示无更新）。
      return await service.latestUpdate();
    } catch (_) {
      // 仅网络失败时允许展示缓存（cachedUpdate 保证 version_code > 当前）
      return await service.cachedUpdate();
    }
  }

  Future<void> _retry() async {
    setState(() => _future = ref.read(updateServiceProvider).latestUpdate());
  }

  Future<void> _ignore(Map<String, dynamic> data) async {
    final code = data['version_code'] as int? ?? 0;
    if (code > 0) await ref.read(updateServiceProvider).ignoreVersion(code);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _download(Map<String, dynamic> data) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final opened = await ref.read(updateServiceProvider).download(data);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开下载页面，请检查浏览器设置')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(error, fallback: '打开下载失败'))),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('更新详情')),
        body: FutureBuilder<Map<String, dynamic>?>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _MessageState(
                icon: Icons.cloud_off_outlined,
                title: '暂时无法检查更新',
                actionLabel: '重试',
                onAction: _retry,
              );
            }
            final data = snapshot.data;
            if (data == null) {
              return const _MessageState(
                icon: Icons.check_circle_outline,
                title: '当前已是最新版本',
              );
            }
            final notes = (data['release_notes']?.toString() ?? '')
                .split('\n')
                .map((line) => line.trim())
                .where((line) => line.isNotEmpty)
                .toList(growable: false);
            // 强制更新已按产品决策整体移除（review R30）：详情页永远是
            // 可选更新形态，服务端标志不再改变按钮可用性。
            return SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                children: [
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.system_update_alt_rounded,
                          size: 36,
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(height: 18),
                        Text(
                          '邗上课表 ${data['version_name']}',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 6),
                        const Text('可选更新 · 你可以稍后再决定'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('本次更新', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: notes.isEmpty
                          ? const Text('修复已知问题并改善使用体验。')
                          : Column(
                              children: [
                                for (final line in notes)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 6),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Padding(
                                          padding: EdgeInsets.only(top: 3),
                                          child: Icon(Icons.check_circle_outline, size: 18),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(child: Text(line)),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(Icons.privacy_tip_outlined),
                      title: Text('隐私说明已更新'),
                      subtitle: Text('补充截图与表格 AI 导入说明；老用户无需再次全屏确认。'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _opening ? null : () => _download(data),
                    icon: _opening
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined),
                    label: Text(_opening ? '正在打开…' : '下载安装'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('稍后再说'),
                  ),
                  TextButton(
                    onPressed: () => _ignore(data),
                    child: const Text('忽略此版本'),
                  ),
                ],
              ),
            );
          },
        ),
      );
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 52),
              const SizedBox(height: 14),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      );
}
