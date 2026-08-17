import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/privacy_consent.dart';
import 'privacy_policy_page.dart';

/// 首次启动隐私政策门禁：未同意前不挂载业务路由，
/// 不同意则退出应用（符合应用商店/金标联盟对隐私授权的要求）。
class PrivacyGateView extends ConsumerWidget {
  const PrivacyGateView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: '邗上课表',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF158A63),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: const _PrivacyGateScaffold(),
    );
  }
}

class _PrivacyGateScaffold extends ConsumerWidget {
  const _PrivacyGateScaffold();

  Future<void> _agree(BuildContext context, WidgetRef ref) async {
    await ref.read(privacyConsentProvider).agree();
    // 重算门禁状态，触发主应用挂载
    ref.invalidate(privacyGateProvider);
  }

  Future<void> _disagree(BuildContext context) async {
    final quit = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确定不同意吗？'),
        content: const Text('不同意隐私政策将无法使用邗上课表。你可以随时退出后重新安装再次选择。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('再想想'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('不同意并退出'),
          ),
        ],
      ),
    );
    if (quit == true) {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('欢迎使用邗上课表')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            children: [
              const Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: 8),
                      Text(
                        '隐私政策提示',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 12),
                      Text(
                        '欢迎使用邗上课表。在使用前，请你仔细阅读并了解'
                        '《邗上课表隐私政策》（点击下方链接查看全文）。'
                        '为提供账号登录、课表导入与同步、课程提醒等服务，我们需要处理：',
                      ),
                      SizedBox(height: 8),
                      Text(
                        '• 账号信息：用户名、邮箱与加密后的登录会话；\n'
                        '• 课表数据：你主动创建或导入的学期、课程与时间安排；\n'
                        '• 设备信息：仅在开启通知后用于消息送达；\n'
                        '• 教务凭据：仅在主动开启同步时，先在设备端加密再上传。',
                      ),
                      SizedBox(height: 8),
                      Text(
                        '我们不会索取通讯录、定位、相机或麦克风权限，不出售你的个人信息。'
                        '你可以随时在「我的-关于」中查看完整隐私政策，'
                        '退出登录即可清除登录状态。',
                      ),
                    ],
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PrivacyPolicyPage(),
                  ),
                ),
                child: const Text('查看《邗上课表隐私政策》全文'),
              ),
              const SizedBox(height: 4),
              FilledButton(
                onPressed: () => _agree(context, ref),
                child: const Text('同意并继续'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _disagree(context),
                child: const Text('不同意并退出'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
