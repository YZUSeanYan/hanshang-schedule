import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/course_colors.dart';
import '../../../core/constants/section_times.dart';
import '../../../core/utils/week_calculator.dart';
import '../data/schedule_repository.dart';

/// 课程编辑页：新增 / 编辑课程（同课程多时间段、单双周/自定义周次）。
class CourseEditPage extends ConsumerStatefulWidget {
  const CourseEditPage({super.key, this.existing});

  /// 编辑已有课程时传入；新增时为 null
  final CourseEntry? existing;

  @override
  ConsumerState<CourseEditPage> createState() => _CourseEditPageState();
}

class _SlotForm {
  int dayOfWeek = 1;
  int startSection = 1;
  int endSection = 2;
  WeeksType weeksType = WeeksType.every;
  final customWeeksController = TextEditingController();
  final locationController = TextEditingController();

  void dispose() {
    customWeeksController.dispose();
    locationController.dispose();
  }
}

class _CourseEditPageState extends ConsumerState<CourseEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _teacherController = TextEditingController();
  final _noteController = TextEditingController();
  final List<_SlotForm> _slots = [_SlotForm()];
  int? _color;
  bool _saving = false;

  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  static const _weeksTypeLabels = {
    WeeksType.every: '每周',
    WeeksType.odd: '单周',
    WeeksType.even: '双周',
    WeeksType.custom: '自定义',
  };

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _nameController.text = existing.course.name;
      _teacherController.text = existing.course.teacher;
      _noteController.text = existing.course.note;
      _color = existing.course.color;
      _slots
        ..clear()
        ..addAll(
          existing.slots.map((s) {
            final form = _SlotForm()
              ..dayOfWeek = s.dayOfWeek
              ..startSection = s.startSection
              ..endSection = s.endSection
              ..weeksType = s.weeksType
              ..locationController.text = s.location;
            final weeks = (jsonDecode(s.customWeeks) as List).cast<int>();
            form.customWeeksController.text = weeks.join(',');
            return form;
          }),
        );
      if (_slots.isEmpty) _slots.add(_SlotForm());
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _teacherController.dispose();
    _noteController.dispose();
    for (final slot in _slots) {
      slot.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_slots.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('至少需要一个上课时间段')));
      return;
    }
    // 校验时间段
    for (final slot in _slots) {
      if (slot.startSection > slot.endSection) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('存在开始节次大于结束节次的时间段，请检查')));
        return;
      }
      if (slot.weeksType == WeeksType.custom &&
          parseCustomWeeks(slot.customWeeksController.text).isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('自定义周次不能为空，例如：1,3,5-8')));
        return;
      }
    }

    setState(() => _saving = true);
    final semester = ref.read(currentSemesterProvider).valueOrNull;
    if (semester == null) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先设置学期')));
      return;
    }

    final drafts = _slots
        .map(
          (s) => SlotDraft(
            dayOfWeek: s.dayOfWeek,
            startSection: s.startSection,
            endSection: s.endSection,
            weeksType: s.weeksType,
            customWeeks: parseCustomWeeks(s.customWeeksController.text),
            location: s.locationController.text.trim(),
          ),
        )
        .toList();

    try {
      final repo = ref.read(scheduleRepositoryProvider);
      final existing = widget.existing;
      if (existing == null) {
        await repo.createCourse(
          semesterId: semester.id,
          name: _nameController.text.trim(),
          teacher: _teacherController.text.trim(),
          color: _color,
          note: _noteController.text.trim(),
          slots: drafts,
        );
      } else {
        await repo.updateCourse(
          courseId: existing.course.id,
          name: _nameController.text.trim(),
          teacher: _teacherController.text.trim(),
          color: _color,
          note: _noteController.text.trim(),
          slots: drafts,
        );
      }
      if (mounted) context.pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? '添加课程' : '编辑课程'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ---- 基本信息 ----
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '课程名称',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入课程名称' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _teacherController,
              decoration: const InputDecoration(
                labelText: '教师（选填）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),

            // ---- 颜色选择 ----
            Text('课程颜色', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final color in CourseColors.macaron)
                  GestureDetector(
                    onTap: () => setState(() => _color = color.toARGB32()),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: color,
                      child: _color == color.toARGB32()
                          ? Icon(
                              Icons.check,
                              size: 16,
                              color: CourseColors.textOn(color),
                            )
                          : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // ---- 时间段 ----
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('上课时间段', style: Theme.of(context).textTheme.titleSmall),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('加一段'),
                  onPressed: () => setState(() => _slots.add(_SlotForm())),
                ),
              ],
            ),
            for (var i = 0; i < _slots.length; i++) _buildSlotCard(i),
            const SizedBox(height: 12),

            TextFormField(
              controller: _noteController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '备注（选填）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlotCard(int index) {
    final slot = _slots[index];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: slot.dayOfWeek,
                    decoration: const InputDecoration(labelText: '星期'),
                    items: [
                      for (var d = 1; d <= 7; d++)
                        DropdownMenuItem(
                          value: d,
                          child: Text(_weekdayLabels[d - 1]),
                        ),
                    ],
                    onChanged: (v) => setState(() => slot.dayOfWeek = v ?? 1),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: slot.startSection,
                    decoration: const InputDecoration(labelText: '开始节'),
                    items: _sectionItems(),
                    onChanged: (v) =>
                        setState(() => slot.startSection = v ?? 1),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: slot.endSection,
                    decoration: const InputDecoration(labelText: '结束节'),
                    items: _sectionItems(),
                    onChanged: (v) => setState(() => slot.endSection = v ?? 2),
                  ),
                ),
                if (_slots.length > 1)
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: '删除该时间段',
                    onPressed: () => setState(() {
                      _slots.removeAt(index).dispose();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<WeeksType>(
                    initialValue: slot.weeksType,
                    decoration: const InputDecoration(labelText: '周次'),
                    items: [
                      for (final e in _weeksTypeLabels.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) =>
                        setState(() => slot.weeksType = v ?? WeeksType.every),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: slot.weeksType == WeeksType.custom
                      ? TextFormField(
                          controller: slot.customWeeksController,
                          decoration: const InputDecoration(
                            labelText: '自定义周次，如 1,3,5-8',
                          ),
                        )
                      : TextFormField(
                          controller: slot.locationController,
                          decoration: const InputDecoration(
                            labelText: '教室（选填）',
                          ),
                        ),
                ),
              ],
            ),
            // 自定义周次时教室换行展示
            if (slot.weeksType == WeeksType.custom) ...[
              const SizedBox(height: 8),
              TextFormField(
                controller: slot.locationController,
                decoration: const InputDecoration(labelText: '教室（选填）'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<DropdownMenuItem<int>> _sectionItems() => [
    for (var s = 1; s <= SectionTimes.sectionCount; s++)
      DropdownMenuItem(value: s, child: Text('$s')),
  ];
}
