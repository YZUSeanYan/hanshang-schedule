import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_client.dart';
import '../../course_import/data/schedule_file_picker.dart';
import '../data/schedule_ai_repository.dart';
import 'confirm_event_sheet.dart';

/// AI 日程输入卡（添加页主体，设计稿 1/3）。
///
/// 卡片结构：上方多行文本框（例如：明天下午三点，小组讨论。），
/// 下方 [拍照] [图片] … [识别 →]。拍照/图片识别活动海报或通知截图，
/// 文字直接理解；识别结果单条新建进「确认日程」弹层，其余走完整预览页。
/// 语音入口不在本卡：长按底部导航「添加」唤起（见 voice_record_sheet.dart）。
class AiInputCard extends ConsumerStatefulWidget {
  const AiInputCard({super.key});

  @override
  ConsumerState<AiInputCard> createState() => _AiInputCardState();
}

class _AiInputCardState extends ConsumerState<AiInputCard> {
  final _textController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  bool get _textReady => _textController.text.trim().isNotEmpty && !_busy;

  void _fail(Object error) {
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content:
              Text(apiErrorMessage(error, fallback: '识别失败，请稍后重试'))),
    );
  }

  Future<void> _handleResult(ScheduleAiResult result, String source) async {
    if (!mounted) return;
    setState(() => _busy = false);
    // 单条新建 → 设计稿的「确认日程」弹层；其余（多操作/调课/取消）走完整预览页
    if (result.operations.length == 1 &&
        result.operations.single.action == 'create') {
      await ConfirmEventSheet.show(context, result: result, source: source);
    } else {
      await context.push('/ai/preview',
          extra: (result: result, source: source));
    }
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final result =
          await ref.read(scheduleAiRepositoryProvider).parseText(text);
      _textController.clear();
      await _handleResult(result, 'text');
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _pickImage({required bool camera}) async {
    if (_busy) return;
    final file = camera
        ? await ScheduleFilePicker.capture()
        : await ScheduleFilePicker.pick(image: true);
    if (file == null || !mounted) return;
    if (file.size > 8 * 1024 * 1024) {
      _fail(StateError('图片不能超过 8 MB'));
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(scheduleAiRepositoryProvider)
          .parseImage(file.bytes);
      await _handleResult(result, 'image');
    } catch (error) {
      _fail(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _textController,
            minLines: 1,
            maxLines: 3,
            enabled: !_busy,
            style: text.bodyMedium,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_textReady) _sendText();
            },
            decoration: InputDecoration(
              // 示例语小一号且单行，不与用户输入的正文字号抢视觉
              hintText: '例如：明天下午三点，小组讨论。',
              hintStyle: text.bodySmall?.copyWith(
                color: scheme.outline,
              ),
              hintMaxLines: 1,
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
          Row(
            children: [
              TextButton.icon(
                onPressed: _busy ? null : () => _pickImage(camera: true),
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: const Text('拍照'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.primary,
                  textStyle: const TextStyle(fontSize: 13),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                  minimumSize: const Size(0, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              TextButton.icon(
                onPressed: _busy ? null : () => _pickImage(camera: false),
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('图片'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.primary,
                  textStyle: const TextStyle(fontSize: 13),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                  minimumSize: const Size(0, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _textReady ? _sendText : null,
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward, size: 16),
                label: Text(_busy ? '识别中' : '识别'),
                style: FilledButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 13),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  minimumSize: const Size(0, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
