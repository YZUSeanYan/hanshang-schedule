import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utils/location_formatter.dart';
import '../../../core/utils/week_calculator.dart';
import '../data/schedule_repository.dart';

/// A course detail sheet whose actions remain reachable on small screens.
///
/// The heading and details share one scroll view while edit/delete actions stay
/// fixed, so long courses remain operable in landscape and at large text scales.
class CourseDetailSheet extends StatelessWidget {
  const CourseDetailSheet({
    super.key,
    required this.entry,
    required this.onDelete,
    required this.onEdit,
  });

  final CourseEntry entry;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  static const detailsListKey = ValueKey('course-detail-list');
  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final courseColor = Color(entry.course.color);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.68,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      snap: !reduceMotion,
      snapSizes: const [0.68],
      builder: (context, scrollController) => Column(
        children: [
          Expanded(
            child: ListView(
              key: detailsListKey,
              controller: scrollController,
              padding: EdgeInsets.zero,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 16),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: courseColor.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.menu_book_rounded,
                          color: courseColor,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.course.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${entry.slots.length} 个上课安排',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.outline),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: colors.outlineVariant),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (entry.course.teacher.isNotEmpty)
                        _DetailRow(
                          icon: Icons.person_outline,
                          text: entry.course.teacher,
                        ),
                      for (final slot in entry.slots)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: _DetailRow(
                                icon: Icons.schedule_outlined,
                                text: _slotDescription(slot),
                              ),
                            ),
                          ),
                        ),
                      if (entry.course.note.isNotEmpty)
                        _DetailRow(
                          icon: Icons.notes_outlined,
                          text: entry.course.note,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.outlineVariant),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                  onPressed: onDelete,
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑'),
                  onPressed: onEdit,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _slotDescription(Schedule slot) {
    final weeks = (jsonDecode(slot.customWeeks) as List).cast<int>();
    return '${_weekdayLabels[slot.dayOfWeek - 1]} '
        '${slot.startSection}-${slot.endSection} 节 · '
        '${describeWeeks(slot.weeksType, weeks)}'
        '${slot.location.isEmpty ? '' : ' · ${formatCourseLocation(slot.location)}'}';
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 9),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
