import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../share/data/share_repository.dart';
import '../../sync/data/sync_repository.dart';
import '../data/credential_vault_repository.dart';

/// 教务导入入口页（Tab 2）。
///
/// 核心差异化功能：内置「WebVPN → 统一身份认证 → 教务系统」一键引导，
/// 用户全程在 App 内完成登录，点一次按钮即可抓取课表。
///
/// 教务凭据同步默认关闭；用户主动同意后，App 只上传客户端 AES-GCM 密文。
class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key});

  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  static const _preferenceKey = 'academic_credential_sync_enabled';
  bool _credentialSyncEnabled = false;
  bool _preferenceLoading = true;
  final _shareCodeController = TextEditingController();
  bool _claiming = false;

  @override
  void dispose() {
    _shareCodeController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadPreference();
  }

  Future<void> _loadPreference() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _credentialSyncEnabled = preferences.getBool(_preferenceKey) ?? false;
      _preferenceLoading = false;
    });
  }

  Future<void> _setCredentialSync(bool enabled) async {
    if (enabled) {
      final hasKey =
          await ref.read(credentialVaultRepositoryProvider).hasLocalKey();
      if (!hasKey) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请退出并重新登录一次，以初始化本机加密密钥')),
          );
        }
        return;
      }
      if (!mounted) return;
      final consent = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开启教务凭据同步？'),
          content: const Text(
            '仅在识别到教务系统登录页并提交登录时读取学号和密码。'
            '数据会先在本机加密，服务器只保存无法直接读取的密文；同步后会立即进行服务器往返校验。',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('同意并开启')),
          ],
        ),
      );
      if (consent != true) return;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_preferenceKey, enabled);
    if (mounted) setState(() => _credentialSyncEnabled = enabled);
  }

  Future<void> _deleteCredential() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除已同步的教务凭据？'),
        content: const Text('服务器上的客户端加密密文会被永久删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(credentialVaultRepositoryProvider).delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除教务凭据密文')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$error')),
        );
      }
    }
  }

  bool get _shareCodeReady =>
      _shareCodeController.text.trim().length == 6 && !_claiming;

  Future<void> _previewShareCode() async {
    final code = _shareCodeController.text.trim().toUpperCase();
    setState(() => _claiming = true);
    try {
      final preview = await ref.read(shareRepositoryProvider).preview(code);
      if (!mounted) return;
      // 预览成功后立即复位：对话框打开期间按钮必须可用（否则"导入我的课表"
      // 会一直禁用，直到对话框被关闭）
      setState(() => _claiming = false);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(preview.semesterName.isEmpty
              ? '课表预览'
              : '${preview.semesterName} · 课表预览'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${preview.courseCount} 门课程 · 有效期至 '
                  '${preview.expiresAt.toLocal().toString().substring(0, 16)}',
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                        color: Theme.of(dialogContext).colorScheme.outline,
                      ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: preview.courses.length,
                    itemBuilder: (context, index) {
                      final course = preview.courses[index];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.menu_book_outlined, size: 20),
                        title: Text(course.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            if (course.teacher.isNotEmpty) course.teacher,
                            '${course.slotCount} 个时间段',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '导入后创建一份独立副本，可自由编辑，不会影响分享者的课表。',
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                        color: Theme.of(dialogContext).colorScheme.outline,
                      ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _claiming
                  ? null
                  : () => _claimShare(dialogContext, code, false),
              child: const Text('导入我的课表'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(apiErrorMessage(error, fallback: '预览失败，请确认口令是否正确')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }

  bool _claimInFlight = false;

  Future<void> _claimShare(
      BuildContext dialogContext, String code, bool replaceExisting) async {
    if (_claimInFlight) return;
    _claimInFlight = true;
    try {
      final count =
          await ref.read(shareRepositoryProvider).claim(code, replaceExisting: replaceExisting);
      // 拉取云端，让新课表出现在"全部学期"里
      await ref.read(syncRepositoryProvider).sync();
      if (!dialogContext.mounted) return;
      Navigator.of(dialogContext).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入 $count 门课程，可在课表页右上角切换到新课表')),
        );
      }
    } on DioException catch (error) {
      // 已有同名同开学日的学期：让用户确认是否覆盖
      if (error.response?.statusCode == 409 && !replaceExisting) {
        if (!dialogContext.mounted) return;
        final confirmed = await showDialog<bool>(
          context: dialogContext,
          builder: (context) => AlertDialog(
            title: const Text('已有同一学期的课表'),
            content: const Text('你已有相同名称和开学日期的课表，是否用分享的课表覆盖它？'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('覆盖')),
            ],
          ),
        );
        if (confirmed == true && dialogContext.mounted) {
          _claimInFlight = false; // 允许递归重试（覆盖模式）
          return _claimShare(dialogContext, code, true);
        }
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(error, fallback: '导入失败，请稍后重试'))),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(error, fallback: '导入失败，请稍后重试'))),
        );
      }
    } finally {
      _claimInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('导入课表')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 16),
          Icon(Icons.school_outlined, size: 72, color: colorScheme.primary),
          const SizedBox(height: 16),
          Text('从教务系统导入课表',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
            '推荐在 App 内打开 WebVPN 手动完成登录与导入；也可以试用服务器代为建立一次短时会话。',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 32),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('VPN 手动导入（推荐）',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    '登录过程完全显示在 App 内，遇到验证码或二次验证也能由你本人继续操作。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.key_outlined),
                    title: const Text('同步教务登录信息（实验）'),
                    subtitle: const Text('登录时在本机加密后同步；下次只自动填入，不自动登录'),
                    value: _credentialSyncEnabled,
                    onChanged: _preferenceLoading ? null : _setCredentialSync,
                  ),
                  if (_credentialSyncEnabled)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.verified_user_outlined),
                      title: const Text('端到端加密已开启'),
                      subtitle: const Text('保存后会下载解密并逐字比对，验证服务器往返完整性'),
                      trailing: TextButton(
                        onPressed: _deleteCredential,
                        child: const Text('删除云端密文'),
                      ),
                    ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => context.push('/import/webview'),
                    icon: const Icon(Icons.vpn_lock),
                    label: const Text('打开 WebVPN 手动导入'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.group_outlined, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('口令导入（同学分享）',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '输入同学分享的 6 位口令，预览确认后创建一份独立课表副本。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _shareCodeController,
                    maxLength: 6,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[A-Za-z2-9]')),
                      LengthLimitingTextInputFormatter(6),
                    ],
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: '例如 K7M2QP',
                      counterText: '',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.pin_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _shareCodeReady ? _previewShareCode : null,
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('查看课表预览'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('小贴士', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    '· 校园网环境可直连教务系统，无需 WebVPN；\n'
                    '· 请在「常用服务 → 班级课表」中选择自己对应的班级；\n'
                    '· 导入结果可以在课表页继续手动调整。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
