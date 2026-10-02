import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/settings/section_time_settings.dart';
import '../../schedule/data/event_repository.dart';

/// 日程详情弹层：日视图/AI 页「即将进行」点击日程后弹出。
/// 支持编辑（标题/类型/日期/时间/地点/提醒）与删除（带墓碑同步）。
Future<void> showEventDetailSheet(BuildContext context, LocalEvent event) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) =>
        _EventDetailSheet(event: event, parentContext: context),
  );
}

class _EventDetailSheet extends ConsumerWidget {
  const _EventDetailSheet({required this.event, required this.parentContext});

  final LocalEvent event;

  /// 调用方的存活 context：本弹层 pop 后自身 context 即销毁，
  /// 编辑流程必须挂在父级 context 上（否则保存动作随弹层一起被销毁，
  /// 改动全部丢失——已踩过的坑）
  final BuildContext parentContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final config = ref.watch(sectionTimeConfigProvider).valueOrNull ??
        const SectionTimeConfig.defaults();
    final referenceDate = DateTime.tryParse(event.date) ?? DateTime.now();
    final timeLabel = eventTimeLabel(event, referenceDate, config);
    final dateLabel = event.eventType == 'recurring'
        ? '每周${'一二三四五六日'[(event.weekday - 1).clamp(0, 6)]}'
        : event.date;

    return Padding(
      // 底部让出悬浮导航高度（76）+ 安全区，避免按钮被胶囊底栏遮挡（规范 §三.6）
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: 20 + MediaQuery.viewPaddingOf(context).bottom + 76,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Chip(
                label: Text(eventTypeLabel(event.eventType)),
                visualDensity: VisualDensity.compact,
              ),
              if (event.source != 'manual') ...[
                const SizedBox(width: 8),
                Chip(
                  avatar: Icon(
                    event.source == 'voice' ? Icons.mic : Icons.keyboard,
                    size: 14,
                  ),
                  label: Text(event.source == 'voice' ? '语音录入' : '文字录入'),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // 全角括号前主动换行，避免「（补面）」这类后缀被拆到两行
          Text(event.title.replaceAll('（', '\n（'),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          _InfoRow(icon: Icons.event_outlined, text: dateLabel),
          if (timeLabel.isNotEmpty)
            _InfoRow(icon: Icons.schedule, text: timeLabel),
          if (event.location.isNotEmpty)
            _InfoRow(icon: Icons.place_outlined, text: event.location),
          if (event.note.isNotEmpty)
            _InfoRow(icon: Icons.notes, text: event.note),
          _InfoRow(
            icon: Icons.notifications_outlined,
            text: event.remindMinutes == 0
                ? '不提醒'
                : event.remindMinutes > 0
                    ? '提前 ${event.remindMinutes} 分钟提醒'
                    : '跟随默认提醒设置',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    // 先拿 repo（ref 随本层销毁），再 pop，再开编辑器
                    final repo = ref.read(eventRepositoryProvider);
                    Navigator.of(context).pop();
                    await _editEvent(parentContext, repo, event);
                  },
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.errorContainer,
                    foregroundColor: scheme.onErrorContainer,
                  ),
                  onPressed: () => _confirmDelete(context, ref),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除日程'),
        content: Text('确定删除「${event.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(eventRepositoryProvider).deleteEvent(event.id);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _editEvent(
      BuildContext context, EventRepository repo, LocalEvent event) async {
    final updated = await showModalBottomSheet<LocalEvent>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => EventEditorSheet(event: event),
    );
    if (updated == null) return;
    await repo.updateEvent(updated);
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

/// 日程编辑弹层（详情页「编辑」与手动新建共用；event 为 null 时是新建）。
class EventEditorSheet extends ConsumerStatefulWidget {
  const EventEditorSheet({super.key, this.event});

  final LocalEvent? event;

  @override
  ConsumerState<EventEditorSheet> createState() => _EventEditorSheetState();
}

class _EventEditorSheetState extends ConsumerState<EventEditorSheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.event?.title ?? '');
  late final TextEditingController _location =
      TextEditingController(text: widget.event?.location ?? '');
  late String _type = widget.event?.eventType ?? 'event';
  late String _date = widget.event?.date ?? '';
  late int _weekday = (widget.event?.weekday ?? 0) >= 1
      ? widget.event!.weekday
      : DateTime.now().weekday;
  late String _startTime = widget.event?.startTime ?? '';
  late String _endTime = widget.event?.endTime ?? '';
  late int _remindMinutes = widget.event?.remindMinutes ?? -1;

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        // 底部让出悬浮导航高度（76）+ 安全区（规范 §三.6）+ 键盘
        bottom: 20 +
            MediaQuery.viewPaddingOf(context).bottom +
            76 +
            MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.event == null ? '新建日程' : '编辑日程',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              decoration: const InputDecoration(
                labelText: '标题',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'event', label: Text('日程')),
                ButtonSegment(value: 'ddl', label: Text('待办')),
                ButtonSegment(value: 'exam', label: Text('考试')),
                ButtonSegment(value: 'recurring', label: Text('每周')),
              ],
              selected: {_type},
              onSelectionChanged: (value) =>
                  setState(() => _type = value.first),
            ),
            const SizedBox(height: 12),
            if (_type == 'recurring')
              OutlinedButton.icon(
                onPressed: _pickWeekday,
                icon: const Icon(Icons.repeat),
                label: Text('每周${'一二三四五六日'[_weekday - 1]}'),
              )
            else
              OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.event_outlined),
                label: Text(_date.isEmpty ? '选择日期' : _date),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickTime(true),
                    icon: const Icon(Icons.schedule),
                    label: Text(_startTime.isEmpty ? '开始时间' : _startTime),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickTime(false),
                    icon: const Icon(Icons.schedule_outlined),
                    label: Text(_endTime.isEmpty ? '结束时间' : _endTime),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _location,
              decoration: const InputDecoration(
                labelText: '地点（可选）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('不提醒'),
              value: _remindMinutes == 0,
              onChanged: (value) =>
                  setState(() => _remindMinutes = value ? 0 : -1),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _save,
              child: Text(widget.event == null ? '创建' : '保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickWeekday() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('每周几'),
        children: [
          for (var i = 1; i <= 7; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(i),
              child: Text('周${'一二三四五六日'[i - 1]}'),
            ),
        ],
      ),
    );
    if (picked != null) setState(() => _weekday = picked);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_date) ?? now,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 370)),
    );
    if (picked != null) {
      setState(() => _date =
          '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _pickTime(bool isStart) async {
    final current = isStart ? _startTime : _endTime;
    final initial = current.isNotEmpty
        ? TimeOfDay(
            hour: int.parse(current.split(':')[0]),
            minute: int.parse(current.split(':')[1]),
          )
        : TimeOfDay.now();
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      final formatted =
          '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      setState(() => isStart ? _startTime = formatted : _endTime = formatted);
    }
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('先起个标题吧')));
      return;
    }
    if (_type != 'recurring' && _date.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('选个日期吧')));
      return;
    }
    final config = ref.read(sectionTimeConfigProvider).valueOrNull ??
        const SectionTimeConfig.defaults();
    final referenceDate = DateTime.tryParse(_date) ??
        () {
          final today = DateTime.now();
          final days = (_weekday - today.weekday) % 7;
          return DateTime(today.year, today.month, today.day)
              .add(Duration(days: days));
        }();
    final busy = computeBusySections(
      startSection: 0,
      endSection: 0,
      startTime: _startTime,
      endTime: _endTime,
      config: config,
      referenceDate: referenceDate,
    );
    final existing = widget.event;
    if (existing == null) {
      final repo = ref.read(eventRepositoryProvider);
      await repo.createEvent(
        EventDraft(
          title: title,
          eventType: _type,
          date: _type == 'recurring' ? '' : _date,
          weekday: _type == 'recurring' ? _weekday : 0,
          startTime: _startTime,
          endTime: _endTime,
          busySections: busy.join(','),
          location: _location.text.trim(),
          remindMinutes: _remindMinutes,
          source: 'manual',
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } else {
      Navigator.of(context).pop(
        existing.copyWith(
          title: title,
          eventType: _type,
          date: _type == 'recurring' ? '' : _date,
          weekday: _type == 'recurring' ? _weekday : 0,
          startTime: _startTime,
          endTime: _endTime,
          startSection: 0,
          endSection: 0,
          busySections: busy.join(','),
          location: _location.text.trim(),
          remindMinutes: _remindMinutes,
        ),
      );
    }
  }
}
