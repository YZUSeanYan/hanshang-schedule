import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/privacy_consent.dart';
import 'privacy_policy_page.dart';
import '../../../core/remote_features/remote_feature_manifest.dart';

/// 首次启动隐私政策门禁：未同意前不挂载业务路由，
/// 不同意则退出应用（符合应用商店/金标联盟对隐私授权的要求）。
class PrivacyGateView extends ConsumerWidget {
  const PrivacyGateView({super.key, this.policy = bundledPrivacyPolicy});

  final RemotePrivacyPolicy policy;

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
      home: _PrivacyGateScaffold(policy: policy),
    );
  }
}

class _PrivacyGateScaffold extends ConsumerWidget {
  const _PrivacyGateScaffold({required this.policy});

  final RemotePrivacyPolicy policy;

  Future<void> _agree(BuildContext context, WidgetRef ref) async {
    await ref.read(privacyConsentProvider).agree(policyId: policy.id);
    // 重算门禁状态，触发主应用挂载
    ref.invalidate(privacyGateProvider);
    ref.invalidate(privacyPolicyGateProvider(policy.id));
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
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      const Text(
                        '隐私政策提示',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '欢迎使用邗上课表。在使用前，请你仔细阅读并了解'
                        '《邗上课表隐私政策》（点击下方链接查看全文）。'
                        '当前政策于 ${policy.effectiveDate} 生效。'
                        '${policy.summary}'
                        '${policy.id == bundledPrivacyPolicyId ? '本次为处理说明补充，已同意上一版的用户无需再次确认。' : '如你此前同意的是旧版政策，本次仍需重新确认。'}'
                        '为提供账号登录、课表导入与同步、课程提醒等服务，我们需要处理：',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '• 账号信息：用户名、邮箱与加密后的登录会话；\n'
                        '• 课表数据：你主动创建或导入的学期、课程与时间安排；\n'
                        '• 设备信息：仅在开启通知后用于消息送达；\n'
                        '• AI 智能解析：经你确认后才上传；截图请先裁掉身份信息，表格文本由服务器脱敏。',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '我们不接收、不传输、不存储你的教务系统账号和密码；'
                        '不会索取通讯录、定位、相机或麦克风权限，不出售你的个人信息。'
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
                    builder: (_) => PrivacyPolicyPage(policy: policy),
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
