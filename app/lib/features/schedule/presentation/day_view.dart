import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/settings/section_time_settings.dart';
import '../../../core/settings/course_card_display.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utils/location_formatter.dart';
import '../../../core/utils/week_calculator.dart';
import '../data/event_repository.dart';
import '../data/override_repository.dart';
import '../data/schedule_repository.dart';

/// 日视图（阶段 5）：按时间轴展示某一天的课程与日程（2.0：日程并入时间线）。
///
/// 与周视图共用数据，左右滑动切日期；顶部由外层 SchedulePage 显示日期。
class DayView extends ConsumerWidget {
  const DayView({
    super.key,
    required this.semester,
    required this.date,
    required this.entries,
    required this.onCourseTap,
    this.events = const [],
    this.onEventTap,
  });

  final Semester semester;
  final DateTime date;
  final List<CourseEntry> entries;
  final void Function(CourseEntry) onCourseTap;
  final List<LocalEvent> events;
  final void Function(LocalEvent)? onEventTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(sectionTimeConfigProvider).valueOrNull ??
        const SectionTimeConfig.defaults();
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

    // 调休生效：放假当天不排课；补课按指定星期排课
    final overrides =
        ref.watch(overridesProvider).valueOrNull ?? const <ScheduleOverride>[];
    final effective = effectiveWeekday(overrides, date);
    if (effective == null) {
      // 放假：只展示当天日程
    }
    // 当天课程展开为 (课程, 时间段)，与当天日程一起按开始时刻排序
    final items = <_DayItem>[];
    for (final entry in entries) {
      if (effective == null) break;
      for (final slot in entry.slots) {
        if (slot.dayOfWeek != effective) continue;
        final weeks = (jsonDecode(slot.customWeeks) as List).cast<int>();
        if (!occursInWeek(slot.weeksType, weeks, week)) continue;
        final minutes =
            SectionTimeConfig.minutes(config.startOf(slot.startSection, date)) ??
                0;
        items.add(_DayItem.course(entry, slot, minutes));
      }
    }
    for (final event in events) {
      if (!eventOccursOn(event, date)) continue;
      // DDL 等无时间的日程排在当天最后
      final minutes = eventStartMinutes(event, date, config) ?? 9999;
      items.add(_DayItem.event(event, minutes));
    }
    items.sort((a, b) => a.startMinutes.compareTo(b.startMinutes));

    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.coffee_outlined, size: 56, color: colorScheme.outline),
            const SizedBox(height: 12),
            Text('今天没课也没安排',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: colorScheme.outline)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        if (item.event != null) {
          return _buildEventCard(context, item.event!, config);
        }
        final entry = item.entry!;
        final slot = item.slot!;
        final start = config.startOf(slot.startSection, date);
        final end = config.endOf(slot.endSection, date);
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
                          Text(
                              entry.course.shortName.isNotEmpty
                                  ? entry.course.shortName
                                  : entry.course.name,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Builder(builder: (context) {
                            final location =
                                parseCourseLocation(slot.location);
                            final showTeacherCampus =
                                ref.watch(courseCardDisplayProvider);
                            final secondary =
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    );
                            final roomStyle = secondary?.copyWith(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            );
                            return Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text:
                                        '第${slot.startSection}-${slot.endSection}节',
                                    style: secondary,
                                  ),
                                  if (location.building.isNotEmpty)
                                    TextSpan(
                                      text: ' · ${location.building}',
                                      style: secondary,
                                    ),
                                  if (location.room.isNotEmpty)
                                    TextSpan(
                                      text: ' ${location.room}',
                                      style: roomStyle,
                                    )
                                  else if (location.building.isEmpty &&
                                      location.formatted.isNotEmpty)
                                    TextSpan(
                                      text: ' · ${location.formatted}',
                                      style: roomStyle,
                                    ),
                                  if (showTeacherCampus &&
                                      entry.course.teacher.isNotEmpty)
                                    TextSpan(
                                      text: ' · ${entry.course.teacher}',
                                      style: secondary,
                                    ),
                                  if (showTeacherCampus &&
                                      location.campus.isNotEmpty)
                                    TextSpan(
                                      text: ' · ${location.campus}',
                                      style: secondary,
                                    ),
                                ],
                              ),
                            );
                          }),
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

  /// 日程卡片：色条 + 时间 + 标题 + 类型标签；DDL 显示"当天截止"。
  Widget _buildEventCard(
      BuildContext context, LocalEvent event, SectionTimeConfig config) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = Color(eventColorOf(event));
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEventTap == null ? null : () => onEventTap!(event),
        child: IntrinsicHeight(
          child: Row(
            children: [
              Container(
                width: 4,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.startTime.isNotEmpty
                          ? event.startTime
                          : event.startSection >= 1
                              ? config.startOf(event.startSection, date)
                              : '全天',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      event.endTime.isNotEmpty
                          ? event.endTime
                          : event.endSection >= 1
                              ? config.endOf(event.endSection, date)
                              : eventTypeLabel(event.eventType),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: colorScheme.outline),
                    ),
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
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                                event.shortTitle.isNotEmpty
                                    ? event.shortTitle
                                    : event.title,
                                style:
                                    Theme.of(context).textTheme.titleMedium),
                          ),
                          Text(
                            eventTypeLabel(event.eventType),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: colorScheme.primary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (event.startSection >= 1)
                            '第${event.startSection}-${event.endSection}节',
                          if (event.location.isNotEmpty)
                            formatCourseLocation(event.location),
                          if (event.source == 'voice') '语音录入',
                        ].join(' · '),
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
  }
}

/// 日视图时间线条目：课程时段或日程。
class _DayItem {
  _DayItem.course(this.entry, this.slot, this.startMinutes) : event = null;
  _DayItem.event(this.event, this.startMinutes)
      : entry = null,
        slot = null;

  final CourseEntry? entry;
  final Schedule? slot;
  final LocalEvent? event;
  final int startMinutes;
}
