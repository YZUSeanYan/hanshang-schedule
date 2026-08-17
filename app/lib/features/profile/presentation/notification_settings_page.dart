import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/notifications/course_live_service.dart';
import '../../../core/notifications/push_service.dart';
import '../../auth/data/auth_repository.dart';
import 'profile_page.dart';

/// 通知设置二级页：实时通知 / 账户通知 / 开启系统通知 统一管理。
class NotificationSettingsPage extends ConsumerWidget {
  const NotificationSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authStateProvider).valueOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('通知设置')),
      body: ListView(
        children: [
          // 实时通知（灵动岛）：开关 + 适配系统说明
          Consumer(
            builder: (context, ref, _) {
              return CourseLiveTile(service: ref.watch(courseLiveServiceProvider));
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.mark_email_unread_outlined),
            title: const Text('账户通知'),
            subtitle: const Text('查看通知或重新开启系统权限'),
            trailing: const Icon(Icons.chevron_right),
            onTap: user == null ? null : () => context.push('/notifications'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('开启系统通知'),
            subtitle: const Text('接收账户消息与课程提醒；被系统彻底杀死后可能延迟或无法送达'),
            onTap: user == null ? null : () async {
              try {
                await ref.read(pushServiceProvider).enableForUser(user.id);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('系统通知已开启')),
                  );
                }
              } catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$error')),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }
}
