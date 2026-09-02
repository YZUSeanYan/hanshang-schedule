import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_client.dart';
import '../data/llm_import_repository.dart';

/// 传给导入失败页的负载：诊断信息 + 原始抓取包（用于 AI 兜底解析）。
class ImportFailedPayload {
  const ImportFailedPayload({required this.detail, this.capture});

  /// 解析器返回的诊断信息
  final String detail;

  /// WebView 抓取包；为 null 时（例如页面数据读取失败）不提供 AI 兜底入口
  final Map<String, dynamic>? capture;
}

/// 导入失败页（设计文档 4.2 要求：解析失败时给用户明确反馈和自救路径）。
///
/// 展示解析器返回的诊断信息，并给出排查建议；
/// 引导用户把课表页面样本（截图/网页另存）反馈给开发者，
/// 以便按真实教务结构迭代解析器。
class ImportFailedPage extends ConsumerStatefulWidget {
  const ImportFailedPage({super.key, required this.payload});

  final ImportFailedPayload payload;

  @override
  ConsumerState<ImportFailedPage> createState() => _ImportFailedPageState();
}

class _ImportFailedPageState extends ConsumerState<ImportFailedPage> {
  bool _llmParsing = false;

  Future<void> _runLlmImport() async {
    final capture = widget.payload.capture;
    if (capture == null || _llmParsing) return;

    // 隐私披露：页面内容需上传服务器并交由第三方大模型解析一次，
    // 明确告知脱敏规则并获得用户确认后再发起。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('AI 智能解析'),
        content: const Text(
          '将把当前课表页面的内容上传到服务器，由 AI 大模型（小米 MiMo）解析一次。\n\n'
          '上传前会在你的设备上自动抹除姓名、学号等身份信息，服务器收到后会再次脱敏检查；'
          '清洗后的内容仅用于本次解析，不保存原文、不写日志，也不接收任何教务密码。'
          '解析过程约需 30 秒。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始解析'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _llmParsing = true);
    try {
      final result =
          await ref.read(llmImportRepositoryProvider).parseCapture(capture);
      if (!mounted) return;
      // 替换失败页，避免预览确认后返回到失败页
      context.pushReplacement('/import/preview', extra: result);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is LlmImportException
                ? error.message
                : apiErrorMessage(error, fallback: '智能解析失败，请稍后重试'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _llmParsing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final detail = widget.payload.detail;
    final canLlmImport =
        widget.payload.capture != null && !_llmParsing;
    return Scaffold(
      appBar: AppBar(title: const Text('未能识别课表')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(Icons.search_off, size: 64, color: colorScheme.outline),
          const SizedBox(height: 16),
          Text('这个页面的课表结构暂时认不出来',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          if (widget.payload.capture != null) ...[
            FilledButton.icon(
              onPressed: canLlmImport ? _runLlmImport : null,
              icon: _llmParsing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(_llmParsing ? 'AI 解析中（约 30 秒）…' : '试试 AI 智能解析'),
            ),
            const SizedBox(height: 8),
            Text(
              '适用于非扬大教务系统或页面结构改版；上传前自动抹除姓名学号，服务器不保存页面原文',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('诊断信息：$detail',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          const SizedBox(height: 16),
          Text('可以试试：', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          const Text('1. 确认已进到「我的课表 / 学生课表」页面，'
              '并且课表格子已经显示出来；\n'
              '2. 如果课表是按周切换的，先切到第 1 周再抓取；\n'
              '3. 返回上一页重新加载后再试一次；\n'
              '4. 仍失败：点下方「复制诊断信息」并发给开发者。'
              '诊断只包含页面结构与字段类型，不包含密码和字段值。'),
          const SizedBox(height: 24),
          FilledButton.tonalIcon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: detail));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('诊断信息已复制')),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('复制诊断信息'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back),
            label: const Text('返回重试'),
          ),
        ],
      ),
    );
  }
}
