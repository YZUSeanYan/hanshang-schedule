import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/app_database.dart';
import '../../../core/settings/section_time_settings.dart';
import '../../../core/utils/week_calculator.dart';
import '../../../core/widgets/liquid_glass.dart';
import '../../schedule/data/event_repository.dart';
import '../../schedule/data/schedule_repository.dart';
import '../data/schedule_ai_repository.dart';

/// 跳转预览页的参数（GoRoute extra 的记录类型，见 app_router.dart 与 ai_input_card.dart）。
typedef EventPreviewArgs = ({ScheduleAiResult result, String source});

/// AI 日程预览确认页（AI 日程 2.0）。
///
/// 语音/文字解析结果在这里逐条确认后才落库：
/// - create → 新日程（可编辑标题/日期/时间/地点），自动检测与课程的冲突
///   并给出"请假涉及哪几节课"的提示（仅列节数与时间，不做评估建议）；
/// - reschedule → 匹配已有课程时段后展示"原时间 → 新时间"，确认后原地更新；
/// - cancel → 匹配日程或课程时段，确认后删除。
/// 语音输入额外展示转写文本，听错了可以改文字重新解析。
class EventPreviewPage extends ConsumerStatefulWidget {
  const EventPreviewPage({
    super.key,
    required this.result,
    required this.source,
  });

  final ScheduleAiResult result;

  /// 'voice' / 'text'：写入日程的 source 标记
  final String source;

  @override
  ConsumerState<EventPreviewPage> createState() => _EventPreviewPageState();
}

class _EventPreviewPageState extends ConsumerState<EventPreviewPage> {
  late List<_OpDraft> _drafts;
  late String? _transcript = widget.result.transcript;
  bool _applying = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _drafts = [for (final op in widget.result.operations) _OpDraft.fromOp(op)];
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(courseEntriesProvider).valueOrNull ?? const [];
    final events = ref.watch(eventsProvider).valueOrNull ?? const [];
    final config = ref.watch(sectionTimeConfigProvider).valueOrNull ??
        const SectionTimeConfig.defaults();
    final semester = ref.watch(currentSemesterProvider).valueOrNull;
    final currentWeek = ref.watch(currentWeekProvider);
    for (final draft in _drafts) {
      draft.resolveMatches(entries, events);
      draft.computeConflicts(entries, semester, currentWeek, config);
    }
    final readyCount = _drafts.where((d) => d.ready).length;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: buildGlassAppBar(context: context, title: const Text('确认日程')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          16 + MediaQuery.paddingOf(context).top + kToolbarHeight,
          20,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          if (_transcript != null) _buildTranscriptCard(),
          for (var i = 0; i < _drafts.length; i++) _buildOpCard(_drafts[i], config),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _applying || readyCount == 0 ? null : _applyAll,
            icon: _applying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text('确认执行（$readyCount 项）'),
          ),
          const SizedBox(height: 8),
          Text(
            '确认前请核对时间与地点；低置信度的条目已用橙色标出。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ),
    );
  }

  // ---------------- 转写卡片 ----------------

  Widget _buildTranscriptCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.graphic_eq,
                    size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text('听到的是',
                    style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(_transcript!, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _retrying ? null : _retryWithEditedText,
              icon: _retrying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.edit_outlined, size: 18),
              label: const Text('听错了？改文字重新理解'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _retryWithEditedText() async {
    final controller = TextEditingController(text: _transcript);
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('修改后重新理解'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('重新理解'),
          ),
        ],
      ),
    );
    if (edited == null || edited.isEmpty || !mounted) return;
    setState(() => _retrying = true);
    try {
      final result =
          await ref.read(scheduleAiRepositoryProvider).parseText(edited);
      if (!mounted) return;
      setState(() {
        _transcript = edited;
        _drafts = [for (final op in result.operations) _OpDraft.fromOp(op)];
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重新理解失败：$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  // ---------------- 操作卡片 ----------------

  Widget _buildOpCard(_OpDraft draft, SectionTimeConfig config) {
    final scheme = Theme.of(context).colorScheme;
    final lowConfidence = draft.op.confidence < 0.7;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _actionChip(draft.op.action),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    draft.headline,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (draft.op.action == 'create')
                  IconButton(
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _editCreateDraft(draft),
                  ),
              ],
            ),
            if (lowConfidence)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '这条把握不大，请仔细核对',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.tertiary),
                ),
              ),
            const SizedBox(height: 8),
            Text(draft.detail(config),
                style: Theme.of(context).textTheme.bodyMedium),
            if (draft.op.action != 'create') _buildMatchPicker(draft),
            if (draft.unresolvedReason != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  draft.unresolvedReason!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ),
            if (draft.conflicts.isNotEmpty) _buildConflictPanel(draft, config),
          ],
        ),
      ),
    );
  }

  Widget _actionChip(String action) {
    final (label, icon) = switch (action) {
      'reschedule' => ('调课', Icons.swap_horiz),
      'cancel' => ('取消', Icons.cancel_outlined),
      _ => ('新日程', Icons.add_circle_outline),
    };
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildMatchPicker(_OpDraft draft) {
    if (draft.candidates.length <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DropdownButtonFormField<int>(
        initialValue: draft.selectedCandidate,
        decoration: const InputDecoration(
          labelText: '要操作的对象',
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        items: [
          for (var i = 0; i < draft.candidates.length; i++)
            DropdownMenuItem(value: i, child: Text(draft.candidates[i].label)),
        ],
        onChanged: (value) => setState(() => draft.selectedCandidate = value),
      ),
    );
  }

  /// 冲突请假提示：只列冲突课程的节数与时间，不做任何评估建议。
  Widget _buildConflictPanel(_OpDraft draft, SectionTimeConfig config) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_busy, size: 18, color: scheme.error),
              const SizedBox(width: 6),
              Text('与课程冲突',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(color: scheme.error)),
            ],
          ),
          const SizedBox(height: 6),
          for (final conflict in draft.conflicts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '· ${conflict.courseName} 第${conflict.startSection}-${conflict.endSection}节'
                '（${conflict.startTime}-${conflict.endTime}）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 4),
          Text(
            '如需请假，涉及以上 ${draft.conflicts.length} 节课。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // ---------------- 编辑新建条目 ----------------

  Future<void> _editCreateDraft(_OpDraft draft) async {
    final titleController = TextEditingController(text: draft.title);
    final locationController = TextEditingController(text: draft.location);
    final result = await showModalBottomSheet<_CreateEditResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => _CreateDraftEditor(
        draft: draft,
        titleController: titleController,
        locationController: locationController,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      draft.title = result.title;
      draft.type = result.type;
      draft.date = result.date;
      draft.weekday = result.weekday;
      draft.startTime = result.startTime;
      draft.endTime = result.endTime;
      // 编辑器只产时刻表达：清掉 AI 给的节次，避免旧节次盖过新时刻
      draft.startSection = 0;
      draft.endSection = 0;
      draft.location = result.location;
    });
  }

  // ---------------- 应用 ----------------

  Future<void> _applyAll() async {
    setState(() => _applying = true);
    var applied = 0;
    final failures = <String>[];
    final events = ref.read(eventRepositoryProvider);
    final schedules = ref.read(scheduleRepositoryProvider);
    final db = ref.read(databaseProvider);
    final config = ref.read(sectionTimeConfigProvider).valueOrNull ??
        const SectionTimeConfig.defaults();
    for (final draft in _drafts) {
      if (!draft.ready) continue;
      try {
        switch (draft.op.action) {
          case 'create':
            final referenceDate = draft.referenceDate();
            await events.createEvent(
              EventDraft(
                title: draft.title,
                shortTitle:
                    draft.title == (draft.op.title ?? '') ? (draft.op.shortTitle ?? '') : '',
                eventType: draft.type,
                date: draft.type == 'recurring' ? '' : draft.date,
                weekday: draft.type == 'recurring' ? draft.weekday : 0,
                startTime: draft.startTime,
                endTime: draft.endTime,
                startSection: draft.startSection,
                endSection: draft.endSection,
                busySections: draft
                    .effectiveSections(config, referenceDate)
                    .join(','),
                location: draft.location,
                source: widget.source,
              ),
            );
            applied++;
          case 'reschedule':
            final sections = draft.effectiveSections(config, draft.referenceDate());
            final slot = draft.selectedSlot;
            if (slot != null) {
              final singleWeek = await _singleOccurrenceWeek(db, draft.date, slot);
              final newDay = draft.weekday > 0
                  ? draft.weekday
                  : (draft.date.isNotEmpty
                      ? DateTime.parse(draft.date).weekday
                      : slot.dayOfWeek);
              if (singleWeek != null) {
                // 单次调课（review R24）：原时段只摘掉这一周，另建一条
                // 单周时段承载新时间——绝不能整学期循环一起挪。
                await schedules.createSlot(
                  courseId: slot.courseId,
                  draft: SlotDraft(
                    dayOfWeek: newDay,
                    startSection: sections.isNotEmpty ? sections.first : slot.startSection,
                    endSection: sections.isNotEmpty ? sections.last : slot.endSection,
                    weeksType: WeeksType.custom,
                    customWeeks: [singleWeek],
                    location: draft.location.isNotEmpty ? draft.location : slot.location,
                  ),
                );
                await _removeWeekFromSlot(schedules, db, slot, singleWeek);
              } else {
                // 整组调课（确认页已明示"整个学期该时段"）
                await schedules.updateSlot(
                  slot.copyWith(
                    dayOfWeek: newDay,
                    startSection: sections.isNotEmpty ? sections.first : slot.startSection,
                    endSection: sections.isNotEmpty ? sections.last : slot.endSection,
                    location:
                        draft.location.isNotEmpty ? draft.location : slot.location,
                  ),
                );
              }
            } else if (draft.selectedEvent != null) {
              // 日程目标（review R25）：按日程字段更新，而不是走课程时段分支
              final event = draft.selectedEvent!;
              final recurring = draft.type == 'recurring';
              final newSections = sections;
              await events.updateEvent(event.copyWith(
                date: recurring ? '' : (draft.date.isNotEmpty ? draft.date : event.date),
                weekday: recurring
                    ? (draft.weekday > 0 ? draft.weekday : event.weekday)
                    : 0,
                startTime: draft.startTime.isNotEmpty ? draft.startTime : event.startTime,
                endTime: draft.endTime.isNotEmpty ? draft.endTime : event.endTime,
                startSection: newSections.isNotEmpty ? newSections.first : 0,
                endSection: newSections.isNotEmpty ? newSections.last : 0,
                busySections: newSections.join(','),
                location: draft.location.isNotEmpty ? draft.location : event.location,
              ));
            } else {
              throw StateError('reschedule 目标已失效');
            }
            applied++;
          case 'cancel':
            final event = draft.selectedEvent;
            if (event != null) {
              await events.deleteEvent(event.id);
            } else if (draft.selectedSlot != null) {
              final slot = draft.selectedSlot!;
              final singleWeek =
                  await _singleOccurrenceWeek(db, draft.date, slot);
              if (singleWeek != null) {
                // 单次取消（review R24）：只从周次列表摘掉这一周
                await _removeWeekFromSlot(schedules, db, slot, singleWeek);
              } else {
                await schedules.deleteSlot(slot);
              }
            }
            applied++;
        }
      } catch (_) {
        failures.add(draft.headline);
      }
    }
    if (!mounted) return;
    if (failures.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已执行 $applied 项日程操作')),
      );
      context.pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('完成 $applied 项，失败 ${failures.length} 项：${failures.join('、')}')),
      );
      context.pop();
    }
  }

  /// 操作日期对应课程时段的第几周；日期为空或不在学期内返回 null
  /// （null = 按整组语义执行）。
  Future<int?> _singleOccurrenceWeek(
    AppDatabase db,
    String date,
    Schedule slot,
  ) async {
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return null;
    final course = await (db.select(db.courses)
          ..where((c) => c.id.equals(slot.courseId)))
        .getSingleOrNull();
    if (course == null) return null;
    final semester = await (db.select(db.semesters)
          ..where((s) => s.id.equals(course.semesterId)))
        .getSingleOrNull();
    if (semester == null) return null;
    final week = weekNumberOf(semester.startDate, parsed);
    if (week < 1 || week > semester.totalWeeks) return null;
    return week;
  }

  /// 把时段的指定周次摘掉（review R24）：custom 直接减；every/odd/even
  /// 按学期周数展开成 custom 后减。摘完为空则整条删除。
  Future<void> _removeWeekFromSlot(
    ScheduleRepository schedules,
    AppDatabase db,
    Schedule slot,
    int week,
  ) async {
    final course = await (db.select(db.courses)
          ..where((c) => c.id.equals(slot.courseId)))
        .getSingleOrNull();
    final semester = course == null
        ? null
        : await (db.select(db.semesters)
              ..where((s) => s.id.equals(course.semesterId)))
            .getSingleOrNull();
    final totalWeeks = semester?.totalWeeks ?? 20;
    final weeks = switch (slot.weeksType) {
      WeeksType.custom => (jsonDecode(slot.customWeeks) as List).cast<int>(),
      WeeksType.every => [for (var i = 1; i <= totalWeeks; i++) i],
      WeeksType.odd => [for (var i = 1; i <= totalWeeks; i++) if (i.isOdd) i],
      WeeksType.even => [for (var i = 1; i <= totalWeeks; i++) if (i.isEven) i],
    }.where((w) => w != week).toList();
    if (weeks.isEmpty) {
      await schedules.deleteSlot(slot);
      return;
    }
    await schedules.updateSlot(slot.copyWith(
      weeksType: WeeksType.custom,
      customWeeks: jsonEncode(weeks),
    ));
  }
}

// ==================== 草稿与匹配模型 ====================

class _SlotCandidate {
  const _SlotCandidate({required this.label, this.slot, this.event});
  final String label;
  final Schedule? slot;
  final LocalEvent? event;
}

class _Conflict {
  const _Conflict({
    required this.courseName,
    required this.startSection,
    required this.endSection,
    required this.startTime,
    required this.endTime,
  });
  final String courseName;
  final int startSection;
  final int endSection;
  final String startTime;
  final String endTime;
}

class _OpDraft {
  _OpDraft.fromOp(this.op)
      : title = op.title ?? '',
        type = op.type,
        date = op.date ?? '',
        weekday = op.weekday ?? 0,
        startTime = op.startTime ?? '',
        endTime = op.endTime ?? '',
        startSection = op.startSection ?? 0,
        endSection = op.endSection ?? 0,
        location = op.location ?? '';

  final AiOperation op;
  String title;
  String type;
  String date;
  int weekday;
  String startTime;
  String endTime;
  int startSection;
  int endSection;
  String location;

  List<_SlotCandidate> candidates = const [];
  int? selectedCandidate;
  String? unresolvedReason;
  List<_Conflict> conflicts = const [];

  bool get ready =>
      unresolvedReason == null &&
      (op.action == 'create' ? title.isNotEmpty : selected != null);

  _SlotCandidate? get selected =>
      selectedCandidate == null ? null : candidates[selectedCandidate!];
  Schedule? get selectedSlot => selected?.slot;
  LocalEvent? get selectedEvent => selected?.event;

  String get headline => switch (op.action) {
        'reschedule' => '调课：${op.target ?? title}',
        'cancel' => '取消：${op.target ?? title}',
        _ => (title.isEmpty ? '（未命名日程）' : title),
      };

  /// 卡片正文：把时间/地点/类型翻译成一行人类可读描述。
  String detail(SectionTimeConfig config) {
    final parts = <String>[];
    parts.add(switch (type) {
      'ddl' => '待办',
      'exam' => '考试',
      'recurring' => '每周周期',
      _ => '一次性日程',
    });
    if (type == 'recurring' && weekday >= 1) {
      parts.add('每周${_weekdayLabel(weekday)}');
    } else if (date.isNotEmpty) {
      final parsed = DateTime.tryParse(date);
      if (parsed != null) {
        parts.add('${parsed.month}月${parsed.day}日 周${_weekdayLabel(parsed.weekday)}');
      }
    }
    if (startTime.isNotEmpty) {
      parts.add(endTime.isNotEmpty ? '$startTime - $endTime' : startTime);
    } else if (startSection >= 1 && endSection >= startSection) {
      parts.add('第$startSection-$endSection节');
    }
    if (location.isNotEmpty) parts.add(location);
    if (op.action == 'reschedule' && selectedSlot != null) {
      final slot = selectedSlot!;
      parts.insert(
        0,
        '原：周${_weekdayLabel(slot.dayOfWeek)} 第${slot.startSection}-${slot.endSection}节 →',
      );
    }
    // 操作范围必须明示（review R24/R25）：单次与整组是两种不同语义
    if ((op.action == 'reschedule' || op.action == 'cancel') &&
        selected != null) {
      final event = selectedEvent;
      if (event != null) {
        parts.add(event.eventType == 'recurring' ? '整个周期' : '该日程');
      } else {
        final parsed = DateTime.tryParse(date);
        parts.add(parsed == null ? '整个学期该时段' : '仅${parsed.month}月${parsed.day}日这一节');
      }
    }
    return parts.join(' · ');
  }

  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];
  static String _weekdayLabel(int weekday) => _weekdayLabels[weekday - 1];

  /// 一次性日程的参考日期（周期日程取下一次发生日）：冲突检测与作息模板用。
  DateTime referenceDate() {
    final parsed = DateTime.tryParse(date);
    if (parsed != null) return parsed;
    if (weekday >= 1) {
      final today = DateTime.now();
      final days = (weekday - today.weekday) % 7;
      return DateTime(today.year, today.month, today.day).add(Duration(days: days));
    }
    return DateTime.now();
  }

  /// 生效节次：优先节次表达；时刻表达按作息表换算。
  List<int> effectiveSections(SectionTimeConfig config, DateTime referenceDate) {
    return computeBusySections(
      startSection: startSection,
      endSection: endSection,
      startTime: startTime,
      endTime: endTime,
      config: config,
      referenceDate: referenceDate,
    );
  }

  /// reschedule/cancel 的候选匹配：先按标题匹配日程，再按课名匹配课程时段。
  void resolveMatches(List<CourseEntry> entries, List<LocalEvent> events) {
    if (op.action == 'create') return;
    final target = (op.target ?? title).trim();
    if (target.isEmpty) {
      unresolvedReason = '没有听清要操作哪门课或哪个日程';
      return;
    }
    final found = <_SlotCandidate>[];
    for (final event in events) {
      if (event.title.contains(target) || target.contains(event.title)) {
        found.add(_SlotCandidate(
          label: '日程：${event.title}'
              '${event.date.isNotEmpty ? '（${event.date}）' : '（每周${event.weekday >= 1 ? _weekdayLabel(event.weekday) : ''}）'}',
          event: event,
        ));
      }
    }
    for (final entry in entries) {
      final name = entry.course.name;
      if (!name.contains(target) && !target.contains(name)) continue;
      for (final slot in entry.slots) {
        if (op.fromWeekday != null && slot.dayOfWeek != op.fromWeekday) {
          continue;
        }
        if (op.fromStartSection != null &&
            slot.startSection != op.fromStartSection) {
          continue;
        }
        found.add(_SlotCandidate(
          label: '课程：$name 周${_weekdayLabel(slot.dayOfWeek)} '
              '第${slot.startSection}-${slot.endSection}节'
              '${slot.location.isEmpty ? '' : '（${slot.location}）'}',
          slot: slot,
        ));
      }
    }
    candidates = found;
    if (found.isEmpty) {
      unresolvedReason = '没找到「$target」对应的课程或日程，可在课表页手动调整';
      selectedCandidate = null;
    } else {
      unresolvedReason = null;
      if (selectedCandidate == null || selectedCandidate! >= found.length) {
        selectedCandidate = found.length == 1 ? 0 : selectedCandidate;
      }
    }
  }

  /// 冲突检测：新建日程的生效节次与当天课程求交集。
  void computeConflicts(
    List<CourseEntry> entries,
    Semester? semester,
    int? currentWeek,
    SectionTimeConfig config,
  ) {
    conflicts = const [];
    if (op.action != 'create' || type == 'ddl' || semester == null) return;
    final sections = effectiveSections(config, referenceDate());
    if (sections.isEmpty) return;
    final refDate = referenceDate();
    final day = type == 'recurring' ? weekday : refDate.weekday;
    final week = type == 'recurring'
        ? (currentWeek ?? 1)
        : weekNumberOf(semester.startDate, refDate);
    if (week < 1 || week > semester.totalWeeks) return;
    final found = <_Conflict>[];
    for (final entry in entries) {
      for (final slot in entry.slots) {
        if (slot.dayOfWeek != day) continue;
        final customWeeks =
            (jsonDecode(slot.customWeeks) as List).cast<int>();
        if (!occursInWeek(slot.weeksType, customWeeks, week)) continue;
        if (slot.endSection < sections.first || slot.startSection > sections.last) {
          continue;
        }
        found.add(_Conflict(
          courseName: entry.course.name,
          startSection: slot.startSection,
          endSection: slot.endSection,
          startTime: config.startOf(slot.startSection, refDate),
          endTime: config.endOf(slot.endSection, refDate),
        ));
      }
    }
    conflicts = found;
  }
}

class _CreateEditResult {
  const _CreateEditResult({
    required this.title,
    required this.type,
    required this.date,
    required this.weekday,
    required this.startTime,
    required this.endTime,
    required this.location,
  });
  final String title;
  final String type;
  final String date;
  final int weekday;
  final String startTime;
  final String endTime;
  final String location;
}

/// 新建日程的编辑弹层（预览页内改错用）。
class _CreateDraftEditor extends StatefulWidget {
  const _CreateDraftEditor({
    required this.draft,
    required this.titleController,
    required this.locationController,
  });

  final _OpDraft draft;
  final TextEditingController titleController;
  final TextEditingController locationController;

  @override
  State<_CreateDraftEditor> createState() => _CreateDraftEditorState();
}

class _CreateDraftEditorState extends State<_CreateDraftEditor> {
  late String _type = widget.draft.type;
  late String _date = widget.draft.date;
  late int _weekday = widget.draft.weekday >= 1 ? widget.draft.weekday : 3;
  late String _startTime = widget.draft.startTime;
  late String _endTime = widget.draft.endTime;

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: widget.titleController,
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
            onSelectionChanged: (value) => setState(() => _type = value.first),
          ),
          const SizedBox(height: 12),
          if (_type == 'recurring')
            OutlinedButton.icon(
              onPressed: () async {
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
              },
              icon: const Icon(Icons.repeat),
              label: Text('每周${'一二三四五六日'[_weekday - 1]}'),
            )
          else
            OutlinedButton.icon(
              onPressed: () async {
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
              },
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
            controller: widget.locationController,
            decoration: const InputDecoration(
              labelText: '地点（可选）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              _CreateEditResult(
                title: widget.titleController.text.trim(),
                type: _type,
                date: _date,
                weekday: _type == 'recurring' ? _weekday : 0,
                startTime: _startTime,
                endTime: _endTime,
                location: widget.locationController.text.trim(),
              ),
            ),
            child: const Text('保存修改'),
          ),
        ],
      ),
    );
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
}
