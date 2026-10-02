// 确认日程弹层（设计稿 3/3，AI 日程 2.0）。
//
// 语音/文字/图片识别出的单条新建日程在这里核对后落库：
// 原话卡片 + 事项/日期/时间/地点四个可修改字段行 + 重录/确认添加。
// 多操作或调课/取消类结果不走本层（由 app 路由到完整预览页 /ai/preview）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/section_time_settings.dart';
import '../../schedule/data/event_repository.dart';
import '../data/schedule_ai_repository.dart';
import 'voice_record_sheet.dart';

class ConfirmEventSheet extends ConsumerStatefulWidget {
  const ConfirmEventSheet({
    super.key,
    required this.result,
    required this.source,
  });

  final ScheduleAiResult result;

  /// 'voice' / 'text' / 'image'：写入日程的 source 标记
  final String source;

  static Future<void> show(
    BuildContext context, {
    required ScheduleAiResult result,
    required String source,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => ConfirmEventSheet(result: result, source: source),
    );
  }

  @override
  ConsumerState<ConfirmEventSheet> createState() => _ConfirmEventSheetState();
}

class _ConfirmEventSheetState extends ConsumerState<ConfirmEventSheet> {
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late String _eventType;
  DateTime? _date;
  int _weekday = 0; // recurring 专用（1-7）
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;
  bool _saving = false;
  // 用户改过时刻后节次表达作废（review R26）：busySections/入库必须
  // 以时刻为准重新换算，不能继续沿用 AI 给的原节次
  bool _timeEdited = false;

  AiOperation get _op => widget.result.operations.single;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: _op.title ?? '');
    _locationController = TextEditingController(text: _op.location ?? '');
    _eventType = _op.type;
    _date = DateTime.tryParse(_op.date ?? '');
    _weekday = _op.weekday ?? 0;
    _startTime = _parseTime(_op.startTime);
    _endTime = _parseTime(_op.endTime);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  static TimeOfDay? _parseTime(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  static String _fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String get _dateLabel {
    if (_eventType == 'recurring') {
      return '每周${'一二三四五六日'[(_weekday - 1).clamp(0, 6)]}';
    }
    final d = _date;
    if (d == null) return '待选择';
    return '${d.year}年${d.month}月${d.day}日 '
        '周${'一二三四五六日'[d.weekday - 1]}';
  }

  String get _timeLabel {
    if (_startTime == null) return '待选择';
    if (_endTime == null) return _fmtTime(_startTime!);
    return '${_fmtTime(_startTime!)}-${_fmtTime(_endTime!)}';
  }

  Future<void> _editText(TextEditingController controller, String label) async {
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('修改$label'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: label == '事项' ? 40 : 60,
          decoration: InputDecoration(hintText: '请输入$label'),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (edited != null) setState(() {});
  }

  Future<void> _pickDate() async {
    if (_eventType == 'recurring') return;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final start = await showTimePicker(
      context: context,
      initialTime: _startTime ?? const TimeOfDay(hour: 15, minute: 0),
      helpText: '开始时间',
    );
    if (start == null || !mounted) return;
    setState(() {
      _startTime = start;
      _timeEdited = true;
    });
    // 已有结束时间且早于新开始时间时清掉，交由用户补充
    if (_endTime != null &&
        (_endTime!.hour * 60 + _endTime!.minute) <=
            (start.hour * 60 + start.minute)) {
      setState(() => _endTime = null);
    }
  }

  Future<void> _pickEndTime() async {
    final base = _startTime ?? const TimeOfDay(hour: 15, minute: 0);
    final end = await showTimePicker(
      context: context,
      initialTime:
          TimeOfDay(hour: (base.hour + 1) % 24, minute: base.minute),
      helpText: '结束时间',
    );
    if (end == null || !mounted) return;
    if ((end.hour * 60 + end.minute) <= (base.hour * 60 + base.minute)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('结束时间要晚于开始时间')),
      );
      return;
    }
    setState(() {
      _endTime = end;
      _timeEdited = true;
    });
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写事项名称')),
      );
      return;
    }
    if (_eventType != 'recurring' && _date == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择日期')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final config = ref.read(sectionTimeConfigProvider).valueOrNull ??
          const SectionTimeConfig.defaults();
      final dateStr = _date == null
          ? ''
          : '${_date!.year.toString().padLeft(4, '0')}-'
              '${_date!.month.toString().padLeft(2, '0')}-'
              '${_date!.day.toString().padLeft(2, '0')}';
      final referenceDate = _date ??
          () {
            // recurring：用下一次发生日作作息参照
            final now = DateTime.now();
            final days = (_weekday - now.weekday) % 7;
            return now.add(Duration(days: days));
          }();
      // 时刻被用户改过就不再沿用 AI 的节次表达（review R26），让
      // computeBusySections 走"按时刻换算节次"分支
      final startSection = _timeEdited ? 0 : (_op.startSection ?? 0);
      final endSection = _timeEdited ? 0 : (_op.endSection ?? 0);
      final busy = computeBusySections(
        startSection: startSection,
        endSection: endSection,
        startTime: _startTime == null ? '' : _fmtTime(_startTime!),
        endTime: _endTime == null ? '' : _fmtTime(_endTime!),
        config: config,
        referenceDate: referenceDate,
      );
      await ref.read(eventRepositoryProvider).createEvent(
            EventDraft(
              title: title,
              // 用户改过标题后 AI 简写不再代表内容，置空回退展示全称
              shortTitle: title == (_op.title ?? '') ? (_op.shortTitle ?? '') : '',
              eventType: _eventType,
              date: _eventType == 'recurring' ? '' : dateStr,
              weekday: _eventType == 'recurring' ? _weekday : 0,
              startTime: _startTime == null ? '' : _fmtTime(_startTime!),
              endTime: _endTime == null ? '' : _fmtTime(_endTime!),
              startSection: startSection,
              endSection: endSection,
              busySections: busy.join(','),
              location: _locationController.text.trim(),
              source: widget.source,
            ),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已添加，可在课表中查看')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存失败，请稍后重试')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final transcript = widget.result.transcript;
    return Padding(
      // 让出悬浮导航高度（76）+ 安全区（规范 §三.6）
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewPaddingOf(context).bottom + 76,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- 标题行 ----
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '确认日程',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              '请核对识别结果，点击字段可修改。',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          // ---- 原话 ----
          if (transcript != null && transcript.isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '原话：$transcript',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
              ),
            ),
          // ---- 字段行 ----
          _FieldRow(
            icon: Icons.notes_outlined,
            label: '事项',
            value: _titleController.text.isEmpty ? '待填写' : _titleController.text,
            trailing: Icon(Icons.edit_outlined,
                size: 18, color: scheme.onSurfaceVariant),
            onTap: () => _editText(_titleController, '事项'),
          ),
          _FieldRow(
            icon: Icons.calendar_month_outlined,
            label: '日期',
            value: _dateLabel,
            onTap: _eventType == 'recurring' ? null : _pickDate,
          ),
          _FieldRow(
            icon: Icons.schedule_outlined,
            label: '时间',
            value: _timeLabel,
            onTap: _pickTime,
          ),
          _FieldRow(
            icon: Icons.place_outlined,
            label: '地点',
            value: _locationController.text.isEmpty
                ? '待填写'
                : _locationController.text,
            trailing: Icon(Icons.edit_outlined,
                size: 18, color: scheme.onSurfaceVariant),
            onTap: () => _editText(_locationController, '地点'),
          ),
          // ---- 结束时间补充 ----
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: _endTime == null
                ? GestureDetector(
                    onTap: _startTime == null ? null : _pickEndTime,
                    child: Text(
                      _startTime == null ? '未设置时间，点击上方时间行选择。' : '结束时间未指定，可补充。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: _startTime == null
                                ? scheme.outline
                                : scheme.primary,
                          ),
                    ),
                  )
                : GestureDetector(
                    onTap: () => setState(() => _endTime = null),
                    child: Text(
                      '结束时间 ${_fmtTime(_endTime!)}（点击移除）',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.outline),
                    ),
                  ),
          ),
          // ---- 操作按钮 ----
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: Row(
              children: [
                if (widget.source == 'voice') ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () {
                              Navigator.of(context).pop();
                              VoiceRecordSheet.show(context);
                            },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: const Text('重录'),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    child: Text(_saving ? '保存中…' : '确认添加'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '确认后显示在课表中。',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// 单条字段行：图标 + 字段名 + 值 + 尾部（编辑图标或 > 箭头）。
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 22, color: scheme.primary),
            const SizedBox(width: 14),
            SizedBox(
              width: 52,
              child: Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: Theme.of(context).textTheme.bodyLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            trailing ??
                Icon(Icons.chevron_right,
                    size: 20, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
