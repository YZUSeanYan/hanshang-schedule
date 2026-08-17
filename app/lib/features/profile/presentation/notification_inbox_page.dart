import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/push_service.dart';

class NotificationInboxPage extends ConsumerStatefulWidget {
  const NotificationInboxPage({super.key});

  @override
  ConsumerState<NotificationInboxPage> createState() =>
      _NotificationInboxPageState();
}

class _NotificationInboxPageState extends ConsumerState<NotificationInboxPage> {
  late Future<Map<String, dynamic>> _future;
  bool _markingAll = false;

  @override
  void initState() {
    super.initState();
    _future = ref.read(pushServiceProvider).inbox();
  }

  Future<void> _reload() async {
    final next = ref.read(pushServiceProvider).inbox();
    if (!mounted) return;
    setState(() => _future = next);
    try {
      await next;
    } catch (_) {
      // FutureBuilder renders the retry state.
    }
  }

  Future<void> _markAllRead() async {
    if (_markingAll) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _markingAll = true);
    try {
      await ref.read(pushServiceProvider).markAllRead();
      await _reload();
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(pushServiceProvider).deleteNotification(item['id'] as int);
      await _reload();
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    }
  }

  Future<void> _clearAll() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空全部通知'),
        content: const Text('将删除收件箱中的全部通知，且不可恢复。确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => navigator.pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => navigator.pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(pushServiceProvider).clearNotifications();
      await _reload();
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('清空失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('通知中心'),
      actions: [
        TextButton(
          onPressed: _markingAll ? null : _markAllRead,
          child: Text(_markingAll ? '处理中…' : '全部已读'),
        ),
        IconButton(
          tooltip: '清空全部通知',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: _clearAll,
        ),
      ],
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: FilledButton.tonal(
              onPressed: _reload,
              child: const Text('重新加载'),
            ),
          );
        }
        final items = (snapshot.data?['items'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        if (items.isEmpty) return const Center(child: Text('暂无通知'));
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = items[index];
              final unread = item['read_at'] == null;
              return Card(
                child: ListTile(
                  leading: Icon(
                    unread
                        ? Icons.notifications_active
                        : Icons.notifications_none,
                  ),
                  title: Text(item['title'] as String? ?? ''),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(item['body'] as String? ?? ''),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (unread) const Badge(),
                      IconButton(
                        tooltip: '删除这条通知',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteItem(item),
                      ),
                    ],
                  ),
                  onTap: () async {
                    if (unread) {
                      try {
                        await ref
                            .read(pushServiceProvider)
                            .markRead(item['id'] as int);
                        await _reload();
                      } catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('操作失败：$error')),
                          );
                        }
                      }
                    }
                  },
                ),
              );
            },
          ),
        );
      },
    ),
  );
}
