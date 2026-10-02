import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/remote_features/remote_feature_manifest.dart';
import '../../../core/remote_features/remote_feature_providers.dart';
import '../data/about_repository.dart';

class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  late Future<AboutContent> _content;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(aboutRepositoryProvider);
    final cached = repo.cached;
    if (cached != null) {
      // 有缓存先即时渲染，再静默刷新（头像/收款码另有磁盘缓存）
      _content = Future.value(cached);
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _refreshSilently(repo));
    } else {
      _content = repo.load();
    }
  }

  Future<void> _refreshSilently(AboutRepository repo) async {
    try {
      final fresh = await repo.load();
      if (mounted) setState(() => _content = Future.value(fresh));
    } catch (_) {
      // 静默刷新失败保留缓存内容
    }
  }

  void _retry() => setState(() => _content = ref.read(aboutRepositoryProvider).load());

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final policy =
        ref.watch(remoteFeatureManifestProvider).valueOrNull?.privacyPolicy ??
            bundledPrivacyPolicy;
    return Scaffold(
      appBar: AppBar(title: const Text('关于邗上课表')),
      body: FutureBuilder<AboutContent>(
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
                child: FutureBuilder<File?>(
                  future: data.avatarMedia.isEmpty
                      ? Future<File?>.value(null)
                      : ref.read(aboutRepositoryProvider).avatarFile(),
                  builder: (context, avatar) {
                    final file = avatar.data;
                    if (file != null) {
                      return CircleAvatar(
                        radius: 54,
                        backgroundColor: colors.primaryContainer,
                        backgroundImage: FileImage(file),
                      );
                    }
                    if (avatar.connectionState != ConnectionState.done) {
                      return CircleAvatar(
                        radius: 54,
                        backgroundColor: colors.primaryContainer,
                        child: const CircularProgressIndicator(),
                      );
                    }
                    return CircleAvatar(
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
                    );
                  },
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
                child: ExpansionTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('隐私政策'),
                  subtitle: Text(
                      '生效日期：${policy.effectiveDate}（第 ${policy.revision} 版）'),
                  childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      policy.id == bundledPrivacyPolicyId
                          ? '邗上课表仅为提供账号登录、课表导入与同步、课程提醒、账户通知和故障排查而处理必要信息。\n\n'
                              '1. 账号与课表：保存用户名、邮箱、加密登录会话及用户主动创建或导入的学期、课程和时间安排。登录密码只以 bcrypt 不可逆哈希存储，任何人（含管理员）都无法得知明文。App 内刷新令牌存放于系统安全存储，网页版使用 Secure + HttpOnly Cookie，脚本无法读取。\n\n'
                              '2. 教务账号与密码：我们不接收、不传输、不存储你的教务系统账号和密码。登录学校系统时，账号密码只经过你的设备与学校系统服务器；我们的服务器不存在接收教务密码的接口。\n\n'
                              '3. AI 智能解析：仅在你主动选择文件并确认后触发（每用户每天限 10 次）。截图由服务器转交小米 MiMo 作一次识别；截图无法在上传前可靠自动遮盖身份信息，请先裁掉姓名、学号等无关区域。XLSX、XLS、CSV 文件由服务器只读提取有界的单元格文本并脱敏常见身份信息后，再交给 MiMo。原始文件、提取文本和模型响应均不写入数据库或业务日志，解析完成即从内存丢弃。旧的课表页面 AI 兜底继续按设备端和服务端双重脱敏规则处理。不使用 AI 导入则不会上传上述内容。\n\n'
                              '4. 通知：只有在用户明确同意并授予系统通知权限后，才初始化阿里云移动研发平台 EMAS 移动推送 SDK，并将不可读的内部用户编号与当前设备绑定，用于向该账户的设备发送通知。SDK 可能按其个人信息处理规则处理设备标识、应用信息、网络信息和推送日志。拒绝通知不影响课表基本功能。\n\n'
                              '5. 权限：App 使用网络与网络状态、通知、开机恢复提醒、闹钟和提醒，以及推送和提醒所需的唤醒锁、振动、前台服务等普通技术权限。文件通过系统选择器获得单个文件的一次性授权，不申请读写外部存储权限。不索取通讯录、定位、相机、麦克风或蓝牙权限。\n\n'
                              '6. 保存与共享：数据存储于境内的阿里云服务器，仅在实现功能和安全审计所需期限内保存；除上述云服务基础设施（阿里云、小米 MiMo，范围以本政策为限）和依法要求外，不出售或向无关第三方共享个人信息。\n\n'
                              '7. 用户权利：可在 App 内退出登录、关闭通知，并可通过 z40681992@163.com 联系管理员申请查询、更正或删除账号及云端数据。注销后依法需要保留的安全日志除外，其余关联数据将删除。\n\n'
                              '8. 联系方式与政策更新：z40681992@163.com。政策发生重大变化时将通过 App 内提示、网站公告或推送告知，并可能要求重新阅读并同意。'
                          : policy.body,
                      style: const TextStyle(height: 1.6),
                    ),
                  ],
                ),
              ),
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
