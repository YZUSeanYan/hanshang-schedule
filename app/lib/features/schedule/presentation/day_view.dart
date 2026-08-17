import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/constants/section_times.dart';
import '../../../core/database/app_database.dart';
import '../../../core/utils/location_formatter.dart';
import '../../../core/utils/week_calculator.dart';
import '../data/schedule_repository.dart';

/// 日视图（阶段 5）：按时间轴展示某一天的课程。
///
/// 与周视图共用数据，左右滑动切日期；顶部由外层 SchedulePage 显示日期。
class DayView extends StatelessWidget {
  const DayView({
    super.key,
    required this.semester,
    required this.date,
    required this.entries,
    required this.onCourseTap,
  });

  final Semester semester;
  final DateTime date;
  final List<CourseEntry> entries;
  final void Function(CourseEntry) onCourseTap;

  @override
  Widget build(BuildContext context) {
    final week = weekNumberOf(semester.startDate, date);
    final colorScheme = Theme.of(context).colorScheme;

    // 假期中
    if (week < 1 || week > semester.totalWeeks) {
      return Center(
        child: Text(
          week < 1 ? '还没开学' : '学期已结束',
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(color: colorScheme.outline),
        ),
      );
    }

    // 当天课程展开为 (课程, 时间段) 列表，按开始节次排序
    final today = <(CourseEntry, Schedule)>[];
    for (final entry in entries) {
      for (final slot in entry.slots) {
        if (slot.dayOfWeek != date.weekday) continue;
        final weeks = (jsonDecode(slot.customWeeks) as List).cast<int>();
        if (!occursInWeek(slot.weeksType, weeks, week)) continue;
        today.add((entry, slot));
      }
    }
    today.sort((a, b) => a.$2.startSection.compareTo(b.$2.startSection));

    if (today.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.coffee_outlined, size: 56, color: colorScheme.outline),
            const SizedBox(height: 12),
            Text('今天没课',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: colorScheme.outline)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: today.length,
      itemBuilder: (context, index) {
        final (entry, slot) = today[index];
        final start = SectionTimes.startOf(slot.startSection);
        final end = SectionTimes.endOf(slot.endSection);
        final color = Color(entry.course.color);
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onCourseTap(entry),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  // 左侧时间轴色条 + 起止时间
                  Container(width: 4, color: color),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(start,
                            style: Theme.of(context).textTheme.titleSmall),
                        Text(end,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: colorScheme.outline)),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(entry.course.name,
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Text(
                            '第${slot.startSection}-${slot.endSection}节'
                            '${slot.location.isEmpty ? '' : ' · ${formatCourseLocation(slot.location)}'}'
                            '${entry.course.teacher.isEmpty ? '' : ' · ${entry.course.teacher}'}',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
