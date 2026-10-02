import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/app_database.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/image_downscale.dart';
import '../../ai_schedule/data/schedule_ai_repository.dart';
import '../../course_import/data/schedule_file_picker.dart';
import '../data/override_repository.dart';

/// 调休课表页：放假（当天不上课）与补课（某天按指定星期上课）设置。
///
/// 两种录入方式：手动选择日期/星期，或上传调休通知（截图/文字）由 AI 识别后确认。
class HolidayOverridePage extends ConsumerStatefulWidget {
  const HolidayOverridePage({super.key});

  @override
  ConsumerState<HolidayOverridePage> createState() =>
      _HolidayOverridePageState();
}

class _HolidayOverridePageState extends ConsumerState<HolidayOverridePage> {
  bool _parsing = false;
  Timer? _etaTimer;
  int _etaSeconds = 0;

  @override
  void dispose() {
    _etaTimer?.cancel();
    super.dispose();
  }

  /// 解析中：显示预计剩余时长（实测文本 ~19s / 截图 ~20s，从 25s 起倒数）
  void _startEta({bool image = false}) {
    _etaTimer?.cancel();
    setState(() => _etaSeconds = image ? 25 : 22);
    _etaTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_etaSeconds > 1) _etaSeconds -= 1;
      });
    });
  }

  void _stopEta() {
    _etaTimer?.cancel();
    _etaTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    final overrides =
        ref.watch(overridesProvider).valueOrNull ?? const <ScheduleOverride>[];
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('调休课表')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            '放假当天不显示课程；补课时段按你选择的星期显示课表（如周六补周三的课）。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _parsing ? null : _importFromNotice,
                  icon: _parsing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: Text(_parsing ? '识别中…' : '上传调休通知'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _parsing ? null : () => _editOverride(null),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('手动添加'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_parsing)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              color: scheme.primaryContainer.withValues(alpha: 0.35),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '正在识别调休通知…',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _etaSeconds > 1
                                ? '预计还需 $_etaSeconds 秒左右，请不要退出'
                                : '马上就好，正在整理结果…',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (overrides.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  '还没有调休安排',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          else
            for (final row in overrides)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: Icon(
                    row.kind == 'off' ? Icons.beach_access_outlined
                                      : Icons.swap_horiz,
                    color: scheme.primary,
                  ),
                  title: Text('${row.date}  ${overrideLabel(row)}'),
                  subtitle: Text(
                    row.kind == 'off' ? '放假：当天不上课' : '补课：按所选星期的课表上课',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '编辑',
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: _parsing ? null : () => _editOverride(row),
                      ),
                      IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: _parsing
                            ? null
                            : () => ref
                                .read(overrideRepositoryProvider)
                                .remove(row.id),
                      ),
                    ],
                  ),
                  onTap: _parsing ? null : () => _editOverride(row),
                ),
              ),
        ],
      ),
    );
  }

  /// 上传调休通知：截图或文字 → AI 识别 → 确认后批量保存
  Future<void> _importFromNotice() async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('上传调休通知截图'),
              subtitle: const Text('通知/公告截图，AI 自动提取放假与补课安排'),
              onTap: () => Navigator.pop(sheetContext, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('粘贴通知文字'),
              subtitle: const Text('例如：10月1日至7日放假，10月11日补周三的课'),
              onTap: () => Navigator.pop(sheetContext, 'text'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (mode == null || !mounted) return;

    List<int>? imageBytes;
    String? text;
    if (mode == 'image') {
      final picked = await ScheduleFilePicker.pick(image: true);
      if (picked == null) return;
      if (picked.bytes.length > 12 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('图片不能超过 12 MB，请裁剪后重试')),
          );
        }
        return;
      }
      // 手机截图动辄 3-8MB，base64 后超网关上限会 413：先降采样到 1600px
      imageBytes = await downscaleImage(picked.bytes, maxWidth: 1600);
    } else {
      final controller = TextEditingController();
      text = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('粘贴调休通知'),
          content: TextField(
            controller: controller,
            maxLines: 6,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '例如：10月1日至7日放假，10月11日（周六）补周三的课',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('识别'),
            ),
          ],
        ),
      );
      if (text == null || text.isEmpty) return;
    }

    setState(() => _parsing = true);
    _startEta(image: imageBytes != null);
    try {
      final adjustments = await ref
          .read(scheduleAiRepositoryProvider)
          .parseHoliday(text: text, imageBytes: imageBytes);
      _stopEta();
      if (!mounted) return;
      setState(() => _parsing = false);
      if (adjustments.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有识别到调休安排，可换张更清晰的截图或手动添加')),
        );
        return;
      }
      await _confirmAdjustments(adjustments);
    } catch (error) {
      _stopEta();
      if (!mounted) return;
      setState(() => _parsing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(apiErrorMessage(error, fallback: '识别失败，请稍后重试'))),
      );
    }
  }

  Future<void> _confirmAdjustments(List<HolidayAdjustment> adjustments) async {
    final selected = <int>{for (var i = 0; i < adjustments.length; i++) i};
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: 16 + MediaQuery.viewPaddingOf(sheetContext).bottom + 76,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '识别到 ${adjustments.length} 条调休安排',
                style: Theme.of(sheetContext)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '勾选要保存的条目；同一天已有安排会被覆盖。',
                style: Theme.of(sheetContext)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(sheetContext).colorScheme.outline),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < adjustments.length; i++)
                      CheckboxListTile(
                        value: selected.contains(i),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                            '${adjustments[i].date}  ${_describe(adjustments[i])}'),
                        onChanged: (v) => setSheetState(() {
                          if (v == true) {
                            selected.add(i);
                          } else {
                            selected.remove(i);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(sheetContext, true),
                  child: Text('保存 ${selected.length} 条'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true) return;
    final repo = ref.read(overrideRepositoryProvider);
    for (var i = 0; i < adjustments.length; i++) {
      if (!selected.contains(i)) continue;
      final item = adjustments[i];
      await repo.upsert(
        date: item.date,
        kind: item.kind,
        weekday: item.weekday,
        note: item.note,
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存 ${selected.length} 条调休安排')),
    );
  }

  String _describe(HolidayAdjustment item) {
    if (item.kind == 'off') {
      return item.note.isNotEmpty ? '放假 · ${item.note}' : '放假';
    }
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final base = '补周${names[(item.weekday - 1).clamp(0, 6)]}的课';
    return item.note.isNotEmpty ? '$base · ${item.note}' : base;
  }

  /// 手动添加/编辑：日期 + 放假或（补课 + 星期）
  Future<void> _editOverride(ScheduleOverride? existing) async {
    var date = existing?.date ?? '';
    var kind = existing?.kind ?? 'off';
    var weekday = existing?.weekday ?? 1;
    final noteController =
        TextEditingController(text: existing?.note ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          const names = ['一', '二', '三', '四', '五', '六', '日'];
          return AlertDialog(
            title: Text(existing == null ? '添加调休安排' : '编辑调休安排'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: dialogContext,
                      initialDate: DateTime.tryParse(date) ?? now,
                      firstDate: DateTime(now.year - 1),
                      lastDate: DateTime(now.year + 2),
                    );
                    if (picked == null) return;
                    setDialogState(() => date =
                        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
                  },
                  icon: const Icon(Icons.event_outlined),
                  label: Text(date.isEmpty ? '选择日期' : date),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'off', label: Text('放假')),
                    ButtonSegment(value: 'makeup', label: Text('补课')),
                  ],
                  selected: {kind},
                  onSelectionChanged: (v) => setDialogState(() {
                    kind = v.first;
                    // 从放假行（weekday=0）切到补课时，按所选日期的自然
                    // 星期预选，绝不落库 weekday=0 的补课（review R28）
                    if (kind == 'makeup' && (weekday < 1 || weekday > 7)) {
                      final parsed = DateTime.tryParse(date);
                      weekday = parsed == null ? 1 : parsed.weekday;
                    }
                  }),
                ),
                if (kind == 'makeup') ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (var i = 1; i <= 7; i++)
                        ChoiceChip(
                          label: Text('周${names[i - 1]}'),
                          selected: weekday == i,
                          onSelected: (_) =>
                              setDialogState(() => weekday = i),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: noteController,
                  maxLength: 30,
                  decoration: const InputDecoration(
                    labelText: '备注（选填）',
                    hintText: '如：国庆假期',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: date.isEmpty
                    ? null
                    : () => Navigator.pop(dialogContext, true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    if (saved != true) return;
    final repo = ref.read(overrideRepositoryProvider);
    final payload = (
      date: date,
      kind: kind,
      weekday: kind == 'makeup' ? weekday : 0,
      note: noteController.text.trim(),
    );
    if (existing == null) {
      await repo.upsert(
        date: payload.date,
        kind: payload.kind,
        weekday: payload.weekday,
        note: payload.note,
      );
    } else {
      // 编辑必须按原记录 ID 更新（review R27）：改日期时清掉旧日期，
      // 不能"新增一条、旧日期还留着"。
      await repo.updateRecord(
        id: existing.id,
        date: payload.date,
        kind: payload.kind,
        weekday: payload.weekday,
        note: payload.note,
      );
    }
  }
}

/// 调休页路由入口（go_router 用）。
Future<void> openHolidayOverridePage(BuildContext context) =>
    context.push('/holiday-overrides');
