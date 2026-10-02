import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/network/api_client.dart';
import '../../../core/settings/section_time_settings.dart';
import '../../../core/widgets/liquid_glass.dart';
import '../../ai_schedule/presentation/ai_input_card.dart';
import '../../ai_schedule/presentation/event_detail_sheet.dart';
import '../../schedule/data/event_repository.dart';
import '../../share/data/share_repository.dart';
import '../../sync/data/sync_repository.dart';
import '../data/import_telemetry.dart';
import '../data/llm_import_repository.dart';
import '../data/schedule_file_picker.dart';

/// 「添加」页（Tab 2，设计稿 1/3）。
///
/// 四个区块自上而下：标题区（添加/课程与日程，轻松安排。）、
/// 「导入课表」卡片（截图/扬大教务/Excel/其他学校教务/分享口令 + 导入帮助）、
/// 「添加日程」区（手动添加 + AI 输入卡）、「即将进行」日程列表。
class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key});

  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  final _shareCodeController = TextEditingController();
  final _genericUrlController = TextEditingController();
  bool _claiming = false;
  bool _fileImporting = false;
  bool _lastImportWasImage = true;
  int _fileImportElapsed = 0;
  int _fileImportEstimate = 22;
  Timer? _fileImportTimer;
  String? _fileImportErrorTitle;
  String? _fileImportErrorDetail;

  void _startFileProgress({required bool image}) {
    _fileImportTimer?.cancel();
    setState(() {
      _fileImporting = true;
      _lastImportWasImage = image;
      _fileImportElapsed = 0;
      _fileImportEstimate = image ? 22 : 16;
      _fileImportErrorTitle = null;
      _fileImportErrorDetail = null;
    });
    _fileImportTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _fileImportElapsed++);
    });
  }

  void _showFileImportError(Object error) {
    var title = '暂时没有识别成功';
    var detail = '请确认文件中包含完整课表，并换一张更清晰的截图或表格后重试。';
    if (error is DioException) {
      final status = error.response?.statusCode;
      final data = error.response?.data;
      final code = data is Map ? data['code'] : null;
      final serverMessage = data is Map && data['message'] is String
          ? data['message'] as String
          : null;
      if (status == 422 || code == 42245 || code == 42246 || code == 42247) {
        title = code == 42246 ? '这张图片不适合识别' : '没有识别到课表';
        detail = serverMessage ??
            (code == 42246 ? '请更换一张只包含课表的图片。' : '请上传包含星期、节次和课程信息的完整截图或表格。');
      } else if (status == 413) {
        title = '文件太大';
        detail = _lastImportWasImage ? '请将截图压缩到 8 MB 以内。' : '请将表格精简到 5 MB 以内。';
      } else if (status == 400) {
        title = '文件格式无法读取';
        detail = '文件可能损坏，或实际格式与扩展名不一致。请重新导出后再试。';
      } else if (status == 401 || status == 403) {
        title = '登录状态已失效';
        detail = '请重新登录后再次选择文件。';
      } else if (status == 429) {
        title = '今天的 AI 识别次数已用完';
        detail = '可以改用教务系统导入，或明天再试。';
      } else if (status == 502) {
        title = 'AI 服务暂时繁忙';
        detail = '文件没有保存。请稍后重试，或改用教务系统导入。';
      } else if (status == 504) {
        title = '本次识别超时';
        detail = '复杂课表可能需要更久。请裁掉无关区域或精简表格后重试。';
      } else if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout) {
        title = '网络连接中断';
        detail = '请检查网络后重试，已选择的文件没有保存到服务器。';
      }
    }
    setState(() {
      _fileImportErrorTitle = title;
      _fileImportErrorDetail = detail;
    });
  }

  Future<void> _pickAndParseFile({required bool image}) async {
    if (_fileImporting) return;
    final file = await ScheduleFilePicker.pick(image: image);
    if (file == null) return;
    final maxBytes = image ? 8 * 1024 * 1024 : 5 * 1024 * 1024;
    if (file.size > maxBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(image ? '课表截图不能超过 8 MB' : '表格文件不能超过 5 MB')),
        );
      }
      return;
    }
    final bytes = file.bytes;
    unawaited(ref.read(importTelemetryProvider).record(
      image ? 'screenshot' : 'excel',
      'pick',
      'success',
      detail: file.size < 1024 * 1024
          ? 'size=<1m'
          : (file.size < 5 * 1024 * 1024 ? 'size=1m_5m' : 'size=5m_8m'),
    ));
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(image ? '发送截图给 AI 识别？' : '解析表格文件？'),
        content: Text(
          image
              ? '截图会通过服务器发送给小米 MiMo，仅用于本次识别且不会保存。建议先裁掉姓名、学号等无关区域。'
              : '文件会上传到服务器，只读提取并脱敏单元格文本后交给小米 MiMo 识别，原文件不会保存。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('继续识别'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _startFileProgress(image: image);
    try {
      final parsed = await ref
          .read(llmImportRepositoryProvider)
          .parseFile(filename: file.name, bytes: bytes);
      unawaited(ref.read(importTelemetryProvider).record(
        image ? 'screenshot' : 'excel', 'preview', 'success'));
      if (mounted) context.push('/import/preview', extra: parsed);
    } catch (error) {
      final dioError = error is DioException ? error : null;
      if (dioError?.response == null) {
        // 无响应＝网络层失败，服务端不会有 parse 记录，避免重复计数
        unawaited(ref.read(importTelemetryProvider).record(
          image ? 'screenshot' : 'excel',
          'upload',
          'fail',
          detail: 'net',
        ));
      }
      if (mounted) _showFileImportError(error);
    } finally {
      _fileImportTimer?.cancel();
      if (mounted) setState(() => _fileImporting = false);
    }
  }

  @override
  void dispose() {
    _fileImportTimer?.cancel();
    _shareCodeController.dispose();
    _genericUrlController.dispose();
    super.dispose();
  }

  int get _remainingSeconds => (_fileImportEstimate - _fileImportElapsed)
      .clamp(0, _fileImportEstimate)
      .toInt();

  double get _estimatedProgress {
    if (_fileImportElapsed <= 0) return .06;
    return (_fileImportElapsed / _fileImportEstimate)
        .clamp(.06, .92)
        .toDouble();
  }

  String get _fileImportStage {
    if (_fileImportElapsed < 4) return '正在安全上传文件…';
    if (_fileImportElapsed < 11) return '正在读取课程、星期和节次…';
    return '正在合并同一课程并检查识别结果…';
  }

  Future<void> _previewShareCode(String code) async {
    unawaited(ref.read(importTelemetryProvider).record('sharecode', 'input', 'success'));
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
          title: Text(
            preview.semesterName.isEmpty
                ? '课表预览'
                : '${preview.semesterName} · 课表预览',
          ),
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
                        title: Text(
                          course.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
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
    BuildContext dialogContext,
    String code,
    bool replaceExisting,
  ) async {
    if (_claimInFlight) return;
    _claimInFlight = true;
    try {
      final count = await ref
          .read(shareRepositoryProvider)
          .claim(code, replaceExisting: replaceExisting);
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
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('覆盖'),
              ),
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
          SnackBar(
            content: Text(apiErrorMessage(error, fallback: '导入失败，请稍后重试')),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(apiErrorMessage(error, fallback: '导入失败，请稍后重试')),
          ),
        );
      }
    } finally {
      _claimInFlight = false;
    }
  }

  Widget _buildFileProgress(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final overtime = _fileImportElapsed >= _fileImportEstimate;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.primary.withValues(alpha: .22)),
      ),
      child: Column(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 900),
            builder: (context, value, child) => Transform.rotate(
              angle: value * 6.283,
              child: child,
            ),
            onEnd: () {
              if (mounted && _fileImporting) setState(() {});
            },
            child: Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: scheme.primary, width: 3),
              ),
              child: const Icon(Icons.auto_awesome),
            ),
          ),
          const SizedBox(height: 12),
          const Text('正在识别课表', style: TextStyle(fontWeight: FontWeight.w700)),
          Text(
            overtime ? '复杂课表可能还需要一点时间' : '预计还需约 $_remainingSeconds 秒',
            style:
                TextStyle(color: scheme.primary, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _estimatedProgress, minHeight: 7),
          const SizedBox(height: 8),
          Text(_fileImportStage, style: Theme.of(context).textTheme.bodySmall),
          TextButton.icon(
            onPressed: () => context.push('/about'),
            icon: const Icon(Icons.privacy_tip_outlined, size: 18),
            label: const Text('文件仅用于本次识别 · 查看隐私政策'),
          ),
        ],
      ),
    );
  }

  Widget _buildFileError(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .errorContainer
              .withValues(alpha: .5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_fileImportErrorTitle!,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(_fileImportErrorDetail!),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _pickAndParseFile(image: _lastImportWasImage),
              icon: const Icon(Icons.refresh),
              label: const Text('重新选择文件'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: buildGlassAppBar(
        context: context,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('添加',
                style:
                    text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            Text(
              '课程与日程，轻松安排。',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: ListView(
        // 穿透式顶栏：视口延伸到玻璃 AppBar 后方，列表滚动穿过时实时模糊；
        // 底部让出悬浮导航高度（76）+ 手势区
        padding: EdgeInsets.fromLTRB(
          24,
          24 + MediaQuery.paddingOf(context).top + kToolbarHeight,
          24,
          24 + MediaQuery.paddingOf(context).bottom + 76,
        ),
        children: [
          // ---- 导入课表 ----
          Text(
            '导入课表',
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '选择适合你的导入方式。',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          _ImportCard(
            icon: Icons.image_outlined,
            title: '截图导入',
            subtitle: '上传完整课表截图',
            onTap: () => _pickAndParseFile(image: true),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _ImportCard(
                  icon: Icons.account_balance_outlined,
                  title: '扬大教务',
                  subtitle: '从教务系统导入',
                  emphasized: true,
                  onTap: () => context.push('/import/webview'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ImportCard(
                  icon: Icons.description_outlined,
                  title: '表格导入',
                  subtitle: '上传表格文件导入课表',
                  onTap: () => _pickAndParseFile(image: false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _ImportCard(
            icon: Icons.apartment_outlined,
            title: '其他学校教务',
            compact: true,
            onTap: () => context.push('/import/school-select'),
          ),
          const SizedBox(height: 10),
          _ImportCard(
            icon: Icons.people_alt_outlined,
            title: '分享口令',
            compact: true,
            onTap: _showShareCodeDialog,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _showImportHelpDialog,
              icon: const Text('导入帮助'),
              label: const Icon(Icons.chevron_right, size: 18),
              style: TextButton.styleFrom(
                foregroundColor: scheme.primary,
                textStyle: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          // 识别进度 / 错误（文件导入进行中时浮现在入口下方）
          if (_fileImporting) _buildFileProgress(context),
          if (!_fileImporting && _fileImportErrorTitle != null)
            _buildFileError(context),
          Divider(height: 32, color: scheme.outlineVariant),

          // ---- 添加日程 ----
          Row(
            children: [
              Expanded(
                child: Text(
                  '添加日程',
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  showDragHandle: true,
                  builder: (_) => const EventEditorSheet(),
                ),
                icon: const Icon(Icons.add, size: 20),
                label: const Text('手动添加'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.primary,
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          Text(
            '已接入 AI 识别：自然语言说安排，怎么说都能理解。',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          const AiInputCard(),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: scheme.outline),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '点底部「语音」按钮，说话就能记日程。',
                  style: text.bodySmall?.copyWith(color: scheme.outline),
                ),
              ),
            ],
          ),
          Divider(height: 32, color: scheme.outlineVariant),

          // ---- 即将进行 ----
          Text(
            '即将进行',
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const _UpcomingEventsSection(),
        ],
      ),
    );
  }

  Future<void> _showGenericImportDialog() async {
    _genericUrlController.clear();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.apartment_outlined),
        title: const Text('其他学校教务导入'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '输入你学校教务系统网址，在 App 内登录到课表页后抓取；'
              '识别不出结构时由服务器 AI 兜底解析（需你确认后才会上传页面内容）。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _genericUrlController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '例如 https://jwgl.example.edu.cn',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
              onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _genericUrlController.text.trim()),
            child: const Text('打开教务系统'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty || !mounted) return;
    var input = url;
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

  Future<void> _showShareCodeDialog() async {
    _shareCodeController.clear();
    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.people_alt_outlined),
        title: const Text('口令导入（同学分享）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '输入同学分享的 6 位口令，预览确认后创建一份独立课表副本。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _shareCodeController,
              maxLength: 6,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[A-Za-z2-9]')),
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(
                hintText: '例如 K7M2QP',
                counterText: '',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.pin_outlined),
              ),
              onSubmitted: (v) =>
                  Navigator.pop(dialogContext, v.trim().toUpperCase()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext,
                _shareCodeController.text.trim().toUpperCase()),
            child: const Text('查看课表预览'),
          ),
        ],
      ),
    );
    if (code == null || code.length != 6 || !mounted) return;
    _previewShareCode(code);
  }

  void _showImportHelpDialog() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入帮助'),
        content: Text(
          '· 截图导入：上传完整课表截图，AI 识别课程、星期、节次、周次和地点，保存前可预览核对；\n'
          '· 扬大教务：仅适用扬州大学（经 WebVPN 进教务系统），登录过程完全显示在 App 内；校园网环境可直连教务系统，无需 WebVPN；\n'
          '· Excel 导入：支持 XLSX、XLS、CSV 表格，只读提取并脱敏后识别；\n'
          '· 其他学校教务：在学校列表中搜索你的学校，App 内登录后抓取，AI 兜底解析；\n'
          '· 分享口令：同学分享的 6 位口令，创建独立副本互不影响；\n'
          '· 文件只用于本次识别，不保存到服务器；截图建议先裁掉姓名、学号等无关区域。',
          style: Theme.of(dialogContext)
              .textTheme
              .bodySmall
              ?.copyWith(height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _showGenericImportDialog();
            },
            child: const Text('名单外？手动输入网址'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

/// 导入方式入口卡片（设计稿「导入课表」区）。
///
/// emphasized=true 为深绿主卡（扬大教务推荐）；compact=true 为单行紧凑行
/// （其他学校教务 / 分享口令）。圆角 16，白卡描边，右侧 > 箭头。
class _ImportCard extends StatelessWidget {
  const _ImportCard({
    required this.icon,
    required this.title,
    this.subtitle,
    this.emphasized = false,
    this.compact = false,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool emphasized;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final iconColor = emphasized ? scheme.onPrimary : scheme.primary;
    final titleColor = emphasized ? scheme.onPrimary : scheme.onSurface;
    final subtitleColor = emphasized
        ? scheme.onPrimary.withValues(alpha: 0.85)
        : scheme.onSurfaceVariant;
    // 网格卡（非 compact）在 2 列里空间紧张：图标缩小一档，徽章挪到副标题行，
    // 让标题（扬大教务/Excel 导入）与副标题都能完整显示，不被截断
    final iconSize = compact ? 24.0 : 26.0;

    final titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (compact ? text.titleSmall : text.titleMedium)?.copyWith(
              color: titleColor,
              fontWeight: FontWeight.w700,
              // 双列网格卡宽度紧张（小屏「Excel 导入」曾截断），标题收两档
              fontSize: compact ? null : 14,
            ),
          ),
        ),
      ],
    );

    final body = Row(
      children: [
        Icon(icon, size: iconSize, color: iconColor),
        SizedBox(width: compact ? 12 : 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleRow,
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (subtitle != null)
                      Flexible(
                        child: Text(
                          subtitle!,
                          // 网格卡宽度紧张：允许两行 + 小字号，说明文字完整不截断
                          maxLines: compact ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: subtitleColor,
                            fontSize: compact ? null : 11,
                            height: 1.25,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        Icon(
          Icons.chevron_right,
          size: 20,
          color: emphasized
              ? scheme.onPrimary.withValues(alpha: 0.85)
              : scheme.onSurfaceVariant,
        ),
      ],
    );

    return Material(
      color: emphasized ? scheme.primary : scheme.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 16 : 14,
            vertical: compact ? 14 : 16,
          ),
          decoration: emphasized
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                ),
          child: body,
        ),
      ),
    );
  }
}

/// 今天起的一次性日程与长期有效的每周日程。
class _UpcomingEventsSection extends ConsumerWidget {
  const _UpcomingEventsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(upcomingEventsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    if (events.isEmpty) {
      // 设计稿空态：日历图标 + 暂无安排 + 引导语
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            Icon(Icons.calendar_month_outlined,
                size: 56, color: colorScheme.outline.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(
              '暂无安排',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              '导入课表或添加你的第一条日程。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colorScheme.outline),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final event in events.take(12)) _EventListTile(event: event),
      ],
    );
  }
}

class _EventListTile extends ConsumerWidget {
  const _EventListTile({required this.event});

  final LocalEvent event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final config = ref.watch(sectionTimeConfigProvider).valueOrNull ??
        const SectionTimeConfig.defaults();
    final referenceDate = DateTime.tryParse(event.date) ?? DateTime.now();
    final timeLabel = eventTimeLabel(event, referenceDate, config);
    final dateLabel = event.eventType == 'recurring'
        ? '每周${'一二三四五六日'[(event.weekday - 1).clamp(0, 6)]}'
        : event.date;
    final color = Color(eventColorOf(event));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 10,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(5),
        ),
      ),
      title: Text(event.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          dateLabel,
          if (timeLabel.isNotEmpty) timeLabel,
          if (event.location.isNotEmpty) event.location,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colorScheme.outline, fontSize: 12),
      ),
      trailing: Text(
        eventTypeLabel(event.eventType),
        style: TextStyle(color: colorScheme.outline, fontSize: 12),
      ),
      onTap: () => showEventDetailSheet(context, event),
    );
  }
}
