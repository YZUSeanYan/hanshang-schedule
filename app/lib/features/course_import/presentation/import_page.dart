import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/widgets/liquid_glass.dart';
import '../../share/data/share_repository.dart';
import '../../sync/data/sync_repository.dart';

/// 教务导入入口页（Tab 2）。
///
/// 三条路径：扬州大学 WebVPN 手动导入（推荐）、AI 通用教务导入（Beta，
/// 任意学校教务网址 + 云端大模型兜底解析）、同学分享口令导入。
class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key});

  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  final _shareCodeController = TextEditingController();
  final _genericUrlController = TextEditingController();
  bool _claiming = false;

  @override
  void dispose() {
    _shareCodeController.dispose();
    _genericUrlController.dispose();
    super.dispose();
  }

  bool get _shareCodeReady =>
      _shareCodeController.text.trim().length == 6 && !_claiming;

  bool get _genericUrlReady => _genericUrlController.text.trim().isNotEmpty;

  Future<void> _openGenericImport() async {
    var input = _genericUrlController.text.trim();
    if (!input.contains('://')) input = 'https://$input';
    final uri = Uri.tryParse(input);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入正确的教务系统网址（https:// 开头）')),
      );
      return;
    }
    context.push('/import/webview-generic', extra: uri.toString());
  }

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
      extendBodyBehindAppBar: true,
      appBar: buildGlassAppBar(
        context: context,
        title: const Text('导入课表'),
      ),
      body: ListView(
        // 穿透式顶栏：视口延伸到玻璃 AppBar 后方，列表滚动穿过时实时模糊
        padding: EdgeInsets.fromLTRB(
          24,
          24 + MediaQuery.paddingOf(context).top + kToolbarHeight,
          24,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          const SizedBox(height: 16),
          Icon(Icons.school_outlined, size: 72, color: colorScheme.primary),
          const SizedBox(height: 16),
          Text('从教务系统导入课表',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
            '扬州大学推荐用 WebVPN 手动导入；其他学校可试用 AI 通用导入（Beta）。',
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
                  Text('扬州大学 · VPN 手动导入（推荐）',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    '仅适用扬州大学（经 WebVPN 进教务系统）。'
                    '登录过程完全显示在 App 内，遇到验证码或二次验证也能由你本人继续操作。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
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
                      Icon(Icons.auto_awesome, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('AI 通用教务导入（Beta）',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '适用任意学校：输入你学校教务系统网址，在 App 内登录到课表页后抓取，'
                    '识别不出结构时由服务器 AI 大模型兜底解析（需你确认后才会上传页面内容）。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _genericUrlController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: '例如 https://jwgl.example.edu.cn',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _genericUrlReady ? _openGenericImport : null,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('打开教务系统'),
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
