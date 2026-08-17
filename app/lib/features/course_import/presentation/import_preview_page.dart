import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/location_formatter.dart';
import '../../../core/utils/week_calculator.dart';
import '../../../import/yzu_parser.dart';
import '../../schedule/data/schedule_repository.dart';
// allSemestersProvider 目前定义在学期设置页底部（与设置页共用）
import '../../schedule/presentation/semester_settings_page.dart';

/// 导入预览页（设计文档 4.1：让用户确认后再写入本地数据库）。
///
/// 流程：列出解析出的课程与时间段 → 选择写入哪个学期
/// （默认当前学期；没有则提示先建学期）→ 确认导入。
class ImportPreviewPage extends ConsumerStatefulWidget {
  const ImportPreviewPage({super.key, required this.result});

  final ParseResult result;

  @override
  ConsumerState<ImportPreviewPage> createState() => _ImportPreviewPageState();
}

class _ImportPreviewPageState extends ConsumerState<ImportPreviewPage> {
  bool _importing = false;
  int? _targetSemesterId;

  static const _weekdayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  String _weeksLabel(ParsedSlot slot) {
    if (slot.weeksText.isNotEmpty) return slot.weeksText;
    switch (slot.weeksType) {
      case WeeksType.every:
        return '每周';
      case WeeksType.odd:
        return '单周';
      case WeeksType.even:
        return '双周';
      case WeeksType.custom:
        if (slot.customWeeks.isEmpty) return '每周';
        return '${slot.customWeeks.first}-${slot.customWeeks.last}周';
    }
  }

  Future<void> _confirmImport() async {
    final semesterId = _targetSemesterId;
    if (semesterId == null || _importing) return;
    setState(() => _importing = true);
    try {
      final repo = ref.read(scheduleRepositoryProvider);
      final count = await repo.createCourses(
        semesterId: semesterId,
        courses: widget.result.courses
            .map(
              (course) => CourseDraft(
                name: course.name,
                teacher: course.teacher,
                slots: course.slots
                    .map(
                      (s) => SlotDraft(
                        dayOfWeek: s.dayOfWeek,
                        startSection: s.startSection,
                        endSection: s.endSection,
                        weeksType: s.weeksType,
                        customWeeks: s.customWeeks,
                        location: s.location,
                      ),
                    )
                    .toList(),
              ),
            )
            .toList(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导入 $count 门课程')));
      // 回到课表页（清掉导入流程的栈）
      context.go('/schedule');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败：$e')));
      setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final semestersAsync = ref.watch(allSemestersProvider);
    final courses = widget.result.courses;

    return Scaffold(
      appBar: AppBar(title: const Text('导入预览')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 来源说明
          Card(
            child: ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: Text('解析出 ${courses.length} 门课程'),
              subtitle: Text(widget.result.detail),
            ),
          ),
          const SizedBox(height: 12),

          // 目标学期选择
          semestersAsync.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text('学期读取失败：$e'),
            data: (semesters) {
              if (semesters.isEmpty) {
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber),
                    title: const Text('还没有学期'),
                    subtitle: const Text('请先在课表页创建一个学期，再回来导入'),
                    trailing: TextButton(
                      onPressed: () => context.push('/settings/semester'),
                      child: const Text('去创建'),
                    ),
                  ),
                );
              }
              _targetSemesterId ??= semesters
                  .where((s) => s.isCurrent)
                  .map((s) => s.id)
                  .firstOrNull;
              return DropdownButtonFormField<int>(
                initialValue: _targetSemesterId,
                decoration: const InputDecoration(
                  labelText: '导入到学期',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final s in semesters)
                    DropdownMenuItem(
                      value: s.id,
                      child: Text('${s.name}${s.isCurrent ? '（当前）' : ''}'),
                    ),
                ],
                onChanged: (v) => setState(() => _targetSemesterId = v),
              );
            },
          ),
          const SizedBox(height: 12),

          // 课程明细
          for (final course in courses)
            Card(
              child: ExpansionTile(
                title: Text(course.name),
                subtitle: Text(
                  '${course.teacher.isEmpty ? '教师未知' : course.teacher} · ${course.slots.length} 个时间段',
                ),
                children: [
                  for (final slot in course.slots)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.schedule, size: 18),
                      title: Text(
                        '${_weekdayNames[slot.dayOfWeek - 1]} '
                        '第${slot.startSection}-${slot.endSection}节',
                      ),
                      subtitle: Text(
                        '${_weeksLabel(slot)}'
                        '${slot.location.isEmpty ? '' : ' · ${formatCourseLocation(slot.location)}'}',
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: (_importing || _targetSemesterId == null)
                ? null
                : _confirmImport,
            icon: _importing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(_importing ? '导入中…' : '确认导入'),
          ),
        ),
      ),
    );
  }
}
