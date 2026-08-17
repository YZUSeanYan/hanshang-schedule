import 'package:flutter/material.dart';

/// 隐私政策全文页（内容与网页版保持一致，生效日期 2026-08-13）。
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    const sections = <(String, String)>[
      ('生效日期', '2026 年 8 月 13 日'),
      (
        '我们处理的信息',
        '为提供账号登录、课表导入与同步、课程提醒、账户通知和安全保障，'
            '我们处理用户名、邮箱、加密会话以及你主动创建或导入的学期、课程与时间安排。'
      ),
      (
        '教务凭据',
        '只有你主动开启凭据同步后才会处理。密码先在设备端使用 AES-GCM 加密，'
            '服务端只保存密文，管理员无法读取明文。'
      ),
      (
        '通知与第三方 SDK',
        '仅在您明确同意并授予通知权限后启用提醒与推送；Android 应用同意后将使用'
            '杭州阿里云智能科技有限公司提供的 EMAS 移动推送 SDK。'
            'SDK 可能按其个人信息处理规则处理设备标识、应用信息、网络信息及推送日志。'
            '拒绝通知不影响基本功能。'
      ),
      (
        '权限、保存和共享',
        '网络权限用于登录与同步，通知权限用于课程和账户消息。'
            '我们不会索取通讯录、定位、相机或麦克风权限。'
            '数据仅在实现功能和安全审计所需期限内保存，不出售个人信息；'
            '除云服务基础设施及依法要求外，不向无关第三方共享。'
      ),
      (
        '你的权利',
        '你可以退出登录、关闭通知，并联系管理员查询、更正或删除账号及云端数据。'
            '注销后依法需保留的安全日志除外，其余关联数据会删除。'
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('邗上课表隐私政策')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (title, body) in sections) ...[
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(body, style: const TextStyle(height: 1.5)),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
