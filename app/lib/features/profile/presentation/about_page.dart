import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../auth/data/auth_repository.dart';
import '../data/reward_ad_service.dart';

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

  /// 「看广告免费支持作者」确认弹窗 → 激励视频 → 感谢反馈。
  Future<void> _showRewardConfirm(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('看广告支持作者'),
        content: const Text(
          '将播放一段由第三方广告联盟提供的短视频广告，看完即可完成一次对作者的免费支持。\n\n'
          '广告内容与邗上课表无关，播放过程中产生的数据处理遵循广告平台的隐私政策。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('再想想'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始观看'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final user = ref.read(authStateProvider).valueOrNull;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('广告加载中，请稍候…'),
        duration: Duration(seconds: 1),
      ),
    );
    try {
      final rewarded = await RewardAdService.show(
        userId: user?.id.toString() ?? '',
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(rewarded ? '感谢支持，你的鼓励收到啦！' : '看完整个广告才算支持成功，期待下次见面'),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('广告没能播放出来，稍后再试试（$e）')),
      );
    }
  }

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
                  subtitle: Text('生效日期：2026 年 9 月 2 日'),
                  childrenPadding: EdgeInsets.fromLTRB(18, 0, 18, 20),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      '邗上课表仅为提供账号登录、课表导入与同步、课程提醒、账户通知和故障排查而处理必要信息。\n\n'
                      '1. 账号与课表：保存用户名、邮箱、加密登录会话及用户主动创建或导入的学期、课程和时间安排。\n\n'
                      '2. 我们不收集的信息：不收集、不传输、不存储你的姓名、学号、教务系统账号密码和课表页面原文。课表导入在你的设备上本地完成；你在 App 或网页内登录学校系统时，账号密码只存在于你的设备与学校系统之间——我们的服务器没有接收这类信息的接口。\n\n'
                      '3. AI 智能解析：使用「AI 智能解析」时，经你明确确认后，当前课表页面内容会先在设备上自动抹除姓名、学号等身份信息，再上传服务器；服务器收到后立即再次脱敏，清洗出课程结构后交由第三方大模型（小米 MiMo）解析一次，解析完成即丢弃——不保存原文、不写入日志。不使用该功能则不会有任何页面上传。\n\n'
                      '4. 通知：只有在用户明确同意并授予系统通知权限后，才初始化阿里云移动研发平台 EMAS 移动推送 SDK，并将不可读的内部用户编号与当前设备绑定，用于向该账户的设备发送通知。SDK 可能按其个人信息处理规则处理设备标识、应用信息、网络信息和推送日志。拒绝通知不影响课表基本功能。\n\n'
                      '5. 权限：网络权限用于登录与同步；通知权限用于课程和账户消息。我们不会索取通讯录、定位、相机或麦克风权限。\n\n'
                      '6. 保存与共享：数据仅在实现功能和安全审计所需期限内保存；除云服务基础设施和依法要求外，不出售或向无关第三方共享个人信息。\n\n'
                      '7. 用户权利：可在 App 内退出登录、关闭通知，并可联系管理员申请查询、更正或删除账号及云端数据。注销后依法需要保留的安全日志除外，其余关联数据将删除。\n\n'
                      '8. 激励视频广告：仅在你在「支持作者」中主动确认后，App 才初始化穿山甲广告联盟 SDK 并播放激励视频广告；广告由第三方投放，其内容不代表本应用立场，播放过程中 SDK 可能按其隐私政策处理设备标识、应用信息与网络信息。不观看广告不影响任何功能。\n\n'
                      '9. 联系方式：admin@hanshang.seanyan.store。政策发生重大变化时将通过 App、网站或通知提示。',
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
                        if (RewardAdService.isConfigured) ...[
                          const SizedBox(height: 16),
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.volunteer_activism_outlined),
                            label: const Text('看广告免费支持作者'),
                            onPressed: () => _showRewardConfirm(context),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
              if (data.icpBeian.isNotEmpty) ...[
                const SizedBox(height: 28),
                GestureDetector(
                  onTap: () async {
                    final uri = Uri.tryParse('https://beian.miit.gov.cn');
                    if (uri != null) {
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    }
                  },
                  child: Text(
                    data.icpBeian,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: colors.outline),
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
    required this.icpBeian,
  });

  factory _AboutContent.fromJson(Map<String, dynamic> json) => _AboutContent(
        displayName: json['display_name'] as String? ?? '邗上课表',
        intro: json['intro'] as String? ?? '',
        websiteUrl: json['website_url'] as String? ?? '',
        avatarMedia: json['avatar_media'] as String? ?? '',
        paymentQrMedia: json['payment_qr_media'] as String? ?? '',
        icpBeian: json['icp_beian'] as String? ?? '',
      );

  final String displayName;
  final String intro;
  final String websiteUrl;
  final String avatarMedia;
  final String paymentQrMedia;
  final String icpBeian;
}
