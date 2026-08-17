import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';

class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  late Future<_AboutContent> _content;

  @override
  void initState() {
    super.initState();
    _content = _load();
  }

  Future<_AboutContent> _load() async {
    final response =
        await ref.read(dioProvider).get<Map<String, dynamic>>('/api/about');
    return _AboutContent.fromJson(
        response.data!['data'] as Map<String, dynamic>);
  }

  void _retry() => setState(() => _content = _load());

  String _mediaUrl(String name) =>
      '${AppConfig.apiBaseUrl}/api/about/media/${Uri.encodeComponent(name)}';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('关于邗上课表')),
      body: FutureBuilder<_AboutContent>(
        future: _content,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_outlined,
                        size: 44, color: colors.outline),
                    const SizedBox(height: 12),
                    const Text('暂时无法加载介绍内容'),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                        onPressed: _retry, child: const Text('重新加载')),
                  ],
                ),
              ),
            );
          }
          final data = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
            children: [
              Center(
                child: data.avatarMedia.isNotEmpty
                    ? CircleAvatar(
                        radius: 54,
                        backgroundColor: colors.primaryContainer,
                        backgroundImage:
                            NetworkImage(_mediaUrl(data.avatarMedia)),
                      )
                    : CircleAvatar(
                        radius: 54,
                        backgroundColor: colors.primaryContainer,
                        child: Text(
                          '邗',
                          style: TextStyle(
                            color: colors.onPrimaryContainer,
                            fontSize: 38,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 18),
              Text(
                data.displayName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colors.primary,
                    ),
              ),
              if (data.intro.isNotEmpty) ...[
                const SizedBox(height: 24),
                Card(
                  elevation: 0,
                  color: colors.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: SelectableText(
                      data.intro,
                      style: Theme.of(context)
                          .textTheme
                          .bodyLarge
                          ?.copyWith(height: 1.65),
                    ),
                  ),
                ),
              ],
              if (data.websiteUrl.isNotEmpty) ...[
                const SizedBox(height: 12),
                ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  tileColor: colors.surfaceContainerLow,
                  leading: const Icon(Icons.language_outlined),
                  title: const Text('官方网站'),
                  subtitle: Text(data.websiteUrl,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.open_in_new, size: 19),
                  onTap: () async {
                    final uri = Uri.tryParse(data.websiteUrl);
                    if (uri == null ||
                        !await launchUrl(uri,
                            mode: LaunchMode.externalApplication)) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('无法打开这个链接')),
                        );
                      }
                    }
                  },
                ),
              ],
              const SizedBox(height: 12),
              Card(
                elevation: 0,
                color: colors.surfaceContainerLow,
                child: const ExpansionTile(
                  leading: Icon(Icons.privacy_tip_outlined),
                  title: Text('隐私政策'),
                  subtitle: Text('生效日期：2026 年 8 月 13 日'),
                  childrenPadding: EdgeInsets.fromLTRB(18, 0, 18, 20),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      '邗上课表仅为提供账号登录、课表导入与同步、课程提醒、账户通知和故障排查而处理必要信息。\n\n'
                      '1. 账号与课表：保存用户名、邮箱、加密登录会话及用户主动创建或导入的学期、课程和时间安排。\n\n'
                      '2. 教务凭据：仅在用户主动开启凭据同步后处理；密码先在设备端使用 AES-GCM 加密，服务端只保存密文，管理员无法读取明文。\n\n'
                      '3. 通知：只有在用户明确同意并授予系统通知权限后，才初始化阿里云移动研发平台 EMAS 移动推送 SDK，并将不可读的内部用户编号与当前设备绑定，用于向该账户的设备发送通知。SDK 可能按其个人信息处理规则处理设备标识、应用信息、网络信息和推送日志。拒绝通知不影响课表基本功能。\n\n'
                      '4. 权限：网络权限用于登录与同步；通知权限用于课程和账户消息。我们不会索取通讯录、定位、相机或麦克风权限。\n\n'
                      '5. 保存与共享：数据仅在实现功能和安全审计所需期限内保存；除云服务基础设施和依法要求外，不出售或向无关第三方共享个人信息。\n\n'
                      '6. 用户权利：可在 App 内退出登录、关闭通知，并可联系管理员申请查询、更正或删除账号及云端数据。注销后依法需要保留的安全日志除外，其余关联数据将删除。\n\n'
                      '7. 联系方式：admin@hanshang.seanyan.store。政策发生重大变化时将通过 App、网站或通知提示。',
                      style: TextStyle(height: 1.6),
                    ),
                  ],
                ),
              ),
              if (data.paymentQrMedia.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text('支持作者', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                Card(
                  elevation: 0,
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 360),
                          child: Image.network(
                            _mediaUrl(data.paymentQrMedia),
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Padding(
                              padding: EdgeInsets.all(32),
                              child: Text('收款码加载失败'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text('请在确认收款人信息后自愿支持',
                            style: TextStyle(color: colors.outline)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _AboutContent {
  const _AboutContent({
    required this.displayName,
    required this.intro,
    required this.websiteUrl,
    required this.avatarMedia,
    required this.paymentQrMedia,
  });

  factory _AboutContent.fromJson(Map<String, dynamic> json) => _AboutContent(
        displayName: json['display_name'] as String? ?? '邗上课表',
        intro: json['intro'] as String? ?? '',
        websiteUrl: json['website_url'] as String? ?? '',
        avatarMedia: json['avatar_media'] as String? ?? '',
        paymentQrMedia: json['payment_qr_media'] as String? ?? '',
      );

  final String displayName;
  final String intro;
  final String websiteUrl;
  final String avatarMedia;
  final String paymentQrMedia;
}
