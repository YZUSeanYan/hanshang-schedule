import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/constants/section_times.dart';
import '../../../core/database/app_database.dart';
import '../../../core/utils/week_calculator.dart';
import '../../../core/utils/location_formatter.dart';
import '../data/schedule_repository.dart';

/// 周视图：只绘制当前展示周真正发生的课程。
class WeekView extends StatelessWidget {
  const WeekView({
    super.key,
    required this.semester,
    required this.week,
    required this.entries,
    required this.onCourseTap,
  });

  final Semester semester;
  final int week;
  final List<CourseEntry> entries;
  final void Function(CourseEntry entry) onCourseTap;

  static const double _timeColWidth = 60;
  static const double _sectionHeight = 54;
  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  DateTime get _monday =>
      semester.startDate.add(Duration(days: (week - 1) * 7));

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final isCurrentWeek = weekNumberOf(semester.startDate, today) == week;

    return Column(
      children: [
        _buildHeader(context, today, isCurrentWeek),
        Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
        Expanded(
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTimeColumn(context),
                for (var day = 1; day <= 7; day++)
                  Expanded(child: _buildDayColumn(context, day)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(
      BuildContext context, DateTime today, bool isCurrentWeek) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          const SizedBox(width: _timeColWidth),
          for (var day = 1; day <= 7; day++)
            Expanded(
              child: Builder(builder: (context) {
                final date = _monday.add(Duration(days: day - 1));
                final isToday = isCurrentWeek &&
                    date.year == today.year &&
                    date.month == today.month &&
                    date.day == today.day;
                return Column(
                  children: [
                    Text(
                      _weekdayLabels[day - 1],
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: isToday ? colors.primary : colors.outline,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      width: 26,
                      height: 26,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isToday ? colors.primary : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${date.day}',
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(
                              color:
                                  isToday ? colors.onPrimary : colors.onSurface,
                              fontWeight:
                                  isToday ? FontWeight.w700 : FontWeight.w500,
                            ),
                      ),
                    ),
                  ],
                );
              }),
            ),
        ],
      ),
    );
  }

  Widget _buildTimeColumn(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: _timeColWidth,
      child: Column(
        children: [
          for (var section = 1; section <= SectionTimes.sectionCount; section++)
            SizedBox(
              height: _sectionHeight,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '$section',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  Text(
                    '${SectionTimes.startOf(section)}-${SectionTimes.endOf(section)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontSize: 7,
                          color: colors.outline,
                        ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDayColumn(BuildContext context, int day) {
    final visible = <_VisibleCourse>[];
    for (final entry in entries) {
      for (final slot in entry.slots) {
        if (slot.dayOfWeek == day && slotOccursInWeek(slot, week)) {
          visible.add(_VisibleCourse(entry: entry, slot: slot));
        }
      }
    }
    final placements = _placeOverlappingCourses(visible);

    return SizedBox(
      height: SectionTimes.sectionCount * _sectionHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              Column(
                children: [
                  for (var i = 0; i < SectionTimes.sectionCount; i++)
                    Container(
                      height: _sectionHeight,
                      decoration: BoxDecoration(
                        color: i.isEven
                            ? Theme.of(context)
                                .colorScheme
                                .surfaceContainerLowest
                                .withValues(alpha: 0.35)
                            : null,
                        border: Border(
                          bottom: BorderSide(
                            color: Theme.of(context)
                                .dividerColor
                                .withValues(alpha: 0.32),
                            width: 0.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              for (final placed in placements)
                Builder(builder: (context) {
                  final laneWidth = constraints.maxWidth / placed.laneCount;
                  return Positioned(
                    top: (placed.item.slot.startSection - 1) * _sectionHeight +
                        2,
                    height: (placed.item.slot.endSection -
                                placed.item.slot.startSection +
                                1) *
                            _sectionHeight -
                        4,
                    left: placed.lane * laneWidth + 1,
                    width: math.max(1, laneWidth - 2),
                    child: _CourseBlock(
                      entry: placed.item.entry,
                      slot: placed.item.slot,
                      compact: placed.laneCount > 1,
                      onTap: () => onCourseTap(placed.item.entry),
                    ),
                  );
                }),
            ],
          );
        },
      ),
    );
  }
}

class _VisibleCourse {
  const _VisibleCourse({required this.entry, required this.slot});

  final CourseEntry entry;
  final Schedule slot;
}

class _PlacedCourse {
  const _PlacedCourse({
    required this.item,
    required this.lane,
    required this.laneCount,
  });

  final _VisibleCourse item;
  final int lane;
  final int laneCount;
}

/// 对相交区间做贪心分栏，确保同一周确有冲突的课程也不会互相覆盖。
List<_PlacedCourse> _placeOverlappingCourses(List<_VisibleCourse> source) {
  final sorted = [...source]..sort((a, b) {
      final byStart = a.slot.startSection.compareTo(b.slot.startSection);
      return byStart != 0
          ? byStart
          : a.slot.endSection.compareTo(b.slot.endSection);
    });
  final result = <_PlacedCourse>[];
  var index = 0;
  while (index < sorted.length) {
    final group = <_VisibleCourse>[sorted[index]];
    var groupEnd = sorted[index].slot.endSection;
    var next = index + 1;
    while (next < sorted.length && sorted[next].slot.startSection <= groupEnd) {
      group.add(sorted[next]);
      groupEnd = math.max(groupEnd, sorted[next].slot.endSection);
      next++;
    }

    final laneEnds = <int>[];
    final lanes = <int>[];
    for (final item in group) {
      var lane = laneEnds.indexWhere(
        (endSection) => endSection < item.slot.startSection,
      );
      if (lane == -1) {
        lane = laneEnds.length;
        laneEnds.add(item.slot.endSection);
      } else {
        laneEnds[lane] = item.slot.endSection;
      }
      lanes.add(lane);
    }
    for (var i = 0; i < group.length; i++) {
      result.add(_PlacedCourse(
        item: group[i],
        lane: lanes[i],
        laneCount: laneEnds.length,
      ));
    }
    index = next;
  }
  return result;
}

class _CourseBlock extends StatelessWidget {
  const _CourseBlock({
    required this.entry,
    required this.slot,
    required this.compact,
    required this.onTap,
  });

  final CourseEntry entry;
  final Schedule slot;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final displayLocation = formatCourseLocation(slot.location);
    final baseColor = Color(entry.course.color);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = baseColor.withValues(alpha: isDark ? 0.30 : 0.16);
    final foreground = isDark
        ? Color.alphaBlend(baseColor.withValues(alpha: 0.42), Colors.white)
        : Color.alphaBlend(baseColor.withValues(alpha: 0.70), Colors.black);

    return Semantics(
      button: true,
      label: [
        entry.course.name,
        if (displayLocation.isNotEmpty) displayLocation,
        if (entry.course.teacher.isNotEmpty) entry.course.teacher,
      ].join('，'),
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: baseColor.withValues(alpha: 0.38)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: baseColor, width: 3)),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(compact ? 3 : 5, 4, 3, 3),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showLocation =
                      displayLocation.isNotEmpty && constraints.maxHeight >= 42;
                  final showTeacher = entry.course.teacher.isNotEmpty &&
                      constraints.maxHeight >= 44;
                  final nameLength =
                      entry.course.name.characters.length;
                  final nameStyle = TextStyle(
                    fontSize: nameLength > 16
                        ? 7
                        : nameLength > 12
                            ? 8
                            : compact
                                ? 8.5
                                : 10,
                    height: 1.12,
                    fontWeight: FontWeight.w700,
                    color: foreground,
                  );
                  final locationStyle = TextStyle(
                    fontSize: compact ? 7.5 : 8.5,
                    height: 1.08,
                    color: foreground.withValues(alpha: 0.82),
                  );
                  final teacherStyle = TextStyle(
                    fontSize: 8,
                    height: 1.1,
                    color: foreground.withValues(alpha: 0.72),
                  );
                  final nameLineHeight =
                      nameStyle.fontSize! * nameStyle.height!;
                  final locationLineHeight =
                      locationStyle.fontSize! * locationStyle.height!;
                  final teacherHeight = showTeacher
                      ? teacherStyle.fontSize! * teacherStyle.height! + 2
                      : 0.0;
                  final availableLocationHeight = constraints.maxHeight -
                      nameLineHeight -
                      teacherHeight -
                      (showLocation ? 3 : 0);
                  final maxLocationLines = math.max(
                    1,
                    math.min(6,
                        (availableLocationHeight / locationLineHeight).floor()),
                  );
                  final requiredLocationLines = showLocation
                      ? _measureLineCount(
                          context,
                          displayLocation,
                          locationStyle,
                          constraints.maxWidth,
                        )
                      : 0;
                  final locationLines =
                      math.min(requiredLocationLines, maxLocationLines);
                  final metadataHeight = (showLocation
                          ? locationLines * locationLineHeight + 3
                          : 0) +
                      teacherHeight;
                  final calculatedNameLines =
                      ((constraints.maxHeight - metadataHeight) /
                              nameLineHeight)
                          .floor();
                  final nameLines =
                      math.max(1, math.min(8, calculatedNameLines));
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.course.name,
                        maxLines: nameLines,
                        overflow: TextOverflow.ellipsis,
                        style: nameStyle,
                      ),
                      if (showLocation || showTeacher) const Spacer(),
                      if (showLocation) ...[
                        const SizedBox(height: 3),
                        Text(
                          displayLocation,
                          maxLines: locationLines,
                          overflow: TextOverflow.ellipsis,
                          style: locationStyle,
                        ),
                      ],
                      if (showTeacher) ...[
                        const SizedBox(height: 2),
                        Text(
                          entry.course.teacher,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: teacherStyle,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  int _measureLineCount(
    BuildContext context,
    String text,
    TextStyle style,
    double maxWidth,
  ) {
    if (text.isEmpty || maxWidth <= 0) return 0;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    return math.max(1, painter.computeLineMetrics().length);
  }
}
