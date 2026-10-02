import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/settings/section_time_settings.dart';
import '../../../core/settings/course_card_display.dart';

import '../../../core/constants/section_times.dart';
import '../../../core/database/app_database.dart';
import '../../../core/utils/week_calculator.dart';
import '../../../core/utils/location_formatter.dart';
import '../data/event_repository.dart';
import '../data/override_repository.dart';
import '../data/schedule_repository.dart';
import 'week_day_content.dart';

/// 周视图：只绘制当前展示周真正发生的课程与日程（2.0：日程叠加进同一网格）。
class WeekView extends ConsumerStatefulWidget {
  const WeekView({
    super.key,
    required this.semester,
    required this.week,
    required this.entries,
    required this.onCourseTap,
    this.events = const [],
    this.onEventTap,
    this.showWeekends = true,
    this.trimEmptyEvenings = true,
  });

  final Semester semester;
  final int week;
  final List<CourseEntry> entries;
  final void Function(CourseEntry entry) onCourseTap;

  /// 本周日程（AI 日程 2.0）：与课程共用冲突分栏，样式上用虚线感的
  /// 细描边 + 类型标签区分。
  final List<LocalEvent> events;
  final void Function(LocalEvent event)? onEventTap;
  final bool showWeekends;
  final bool trimEmptyEvenings;

  @override
  ConsumerState<WeekView> createState() => _WeekViewState();
}

class _WeekViewState extends ConsumerState<WeekView> {
  bool _weekendsExpanded = false;
  Semester get semester => widget.semester;
  int get week => widget.week;
  List<CourseEntry> get entries => widget.entries;
  List<LocalEvent> get events => widget.events;
  void Function(CourseEntry) get onCourseTap => widget.onCourseTap;
  void Function(LocalEvent)? get onEventTap => widget.onEventTap;

  static const double _timeColWidth = 60;
  static const double _minSectionHeight = 54;
  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  DateTime get _monday =>
      semester.startDate.add(Duration(days: (week - 1) * 7));

  @override
  void didUpdateWidget(covariant WeekView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.week != week ||
        oldWidget.semester.id != semester.id ||
        oldWidget.showWeekends != widget.showWeekends) {
      _weekendsExpanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(sectionTimeConfigProvider).valueOrNull ??
        const SectionTimeConfig.defaults();
    final overrides =
        ref.watch(overridesProvider).valueOrNull ?? const <ScheduleOverride>[];
    final today = DateTime.now();
    final isCurrentWeek = weekNumberOf(semester.startDate, today) == week;
    final days = WeekDayContent.forWeek(
      semester: semester,
      week: week,
      entries: entries,
      events: events,
      overrides: overrides,
    );
    final showWeekends = widget.showWeekends || _weekendsExpanded;
    final dayCount = showWeekends ? 7 : 5;
    final visibleDays = days.take(dayCount).toList();
    final sectionCount = visibleSectionCount(
      visibleDays,
      trim: widget.trimEmptyEvenings,
    );
    final hasWeekendActivities = days.skip(5).any((day) => day.hasActivities);

    return Column(
      children: [
        if (!widget.showWeekends && (hasWeekendActivities || _weekendsExpanded))
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('weekend-activity-toggle'),
              onPressed: () =>
                  setState(() => _weekendsExpanded = !_weekendsExpanded),
              icon: Icon(
                  _weekendsExpanded ? Icons.unfold_less : Icons.event_outlined,
                  size: 18),
              label: Text(_weekendsExpanded ? '收起周末' : '周末有安排 · 展开'),
            ),
          ),
        _buildHeader(context, today, isCurrentWeek, dayCount),
        if (config.automatic &&
            SectionTimes.forDate(_monday) !=
                SectionTimes.forDate(_monday.add(Duration(days: dayCount - 1))))
          const Padding(
              padding: EdgeInsets.all(4),
              child: Text('本周作息切换：时间栏上行为切换前，下行为切换后',
                  style: TextStyle(fontSize: 11))),
        Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            final bottom = MediaQuery.paddingOf(context).bottom;
            final sectionHeight = math.max(_minSectionHeight,
                (constraints.maxHeight - bottom) / sectionCount);
            return SingleChildScrollView(
              // 底栏悬浮胶囊高度（HomeShell extendBody 注入），滚动到底不压最后一节课
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(children: [
                // 全天标记独立成一行，不再把某天的第 1 节推到时间轴下方。
                if (visibleDays
                    .any((day) => day.isOffDay || day.allDayEvents.isNotEmpty))
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const SizedBox(width: _timeColWidth),
                    for (final day in visibleDays)
                      Expanded(child: _buildDayNotes(context, day)),
                  ]),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTimeColumn(
                        context, config, sectionCount, sectionHeight, dayCount),
                    for (final day in visibleDays)
                      Expanded(
                          child: _buildDayColumn(
                              context, day, sectionCount, sectionHeight)),
                  ],
                ),
              ]),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildHeader(
      BuildContext context, DateTime today, bool isCurrentWeek, int dayCount) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          const SizedBox(width: _timeColWidth),
          for (var day = 1; day <= dayCount; day++)
            Expanded(
              child: Builder(builder: (context) {
                final date = _monday.add(Duration(days: day - 1));
                final isToday = isCurrentWeek &&
                    date.year == today.year &&
                    date.month == today.month &&
                    date.day == today.day;
                return Column(
                  key: ValueKey('weekday-header-$day'),
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

  Widget _buildTimeColumn(BuildContext context, SectionTimeConfig config,
      int sectionCount, double sectionHeight, int dayCount) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: _timeColWidth,
      child: Column(
        children: [
          for (var section = 1; section <= sectionCount; section++)
            SizedBox(
              key: ValueKey('section-label-$section'),
              height: sectionHeight,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '$section',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  // 跨作息切换的周（如 9/28-10/4 换季）时间串有两行，
                  // FittedBox 缩字保证 54px 格内不溢出（真实触发过的渲染错误）
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        {
                          for (var d = 0; d < dayCount; d++)
                            '${config.startOf(section, _monday.add(Duration(days: d)))}-${config.endOf(section, _monday.add(Duration(days: d)))}'
                        }.join('\n'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontSize: 7,
                              color: colors.outline,
                            ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDayNotes(BuildContext context, WeekDayContent day) {
    return Column(
      children: [
        if (day.isOffDay)
          Padding(
            padding: const EdgeInsets.fromLTRB(1, 3, 1, 0),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(6),
              ),
              child: _fitLine(
                '放假',
                TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        if (day.allDayEvents.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(1, 2, 1, 2),
            child: Column(
              children: [
                for (final event in day.allDayEvents)
                  _AllDayChip(
                    event: event,
                    onTap: onEventTap == null ? null : () => onEventTap!(event),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDayColumn(BuildContext context, WeekDayContent day,
      int sectionCount, double sectionHeight) {
    final dayDate = day.date;
    final placements = _placeOverlapping([
      for (final course in day.courses)
        _GridItem.course(course.entry, course.slot),
      for (final event in day.timedEvents)
        _GridItem.event(event.event, event.start, event.end),
    ]);
    return SizedBox(
      height: sectionCount * sectionHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              Column(
                children: [
                  for (var i = 0; i < sectionCount; i++)
                    Container(
                      height: sectionHeight,
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
                    top: (placed.item.startSection - 1) * sectionHeight + 2,
                    height: (placed.item.endSection -
                                placed.item.startSection +
                                1) *
                            sectionHeight -
                        4,
                    left: placed.lane * laneWidth + 1,
                    width: math.max(1, laneWidth - 2),
                    child: placed.item.conflictItems != null
                        ? _ConflictBlock(
                            items: placed.item.conflictItems!,
                            dayDate: dayDate,
                            onCourseTap: onCourseTap,
                            onEventTap: onEventTap,
                          )
                        : placed.item.event != null
                            ? _EventBlock(
                                event: placed.item.event!,
                                dayDate: dayDate,
                                compact: placed.laneCount > 1,
                                onTap: onEventTap == null
                                    ? null
                                    : () => onEventTap!(placed.item.event!),
                              )
                            : _CourseBlock(
                                entry: placed.item.entry!,
                                slot: placed.item.slot!,
                                compact: placed.laneCount > 1,
                                onTap: () => onCourseTap(placed.item.entry!),
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

/// 全天/DDL 日程条：当日列顶部横条，类型图标 + 简写标题，点按看详情。
class _AllDayChip extends StatelessWidget {
  const _AllDayChip({required this.event, this.onTap});

  final LocalEvent event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final baseColor = Color(eventColorOf(event));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = baseColor.withValues(alpha: isDark ? 0.26 : 0.14);
    final foreground = isDark
        ? Color.alphaBlend(baseColor.withValues(alpha: 0.30), Colors.white)
        : Color.alphaBlend(baseColor.withValues(alpha: 0.55), Colors.black);
    final title = event.shortTitle.isNotEmpty ? event.shortTitle : event.title;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: baseColor.withValues(alpha: 0.4)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            child: Row(
              children: [
                Icon(
                  switch (event.eventType) {
                    'ddl' => Icons.flag_outlined,
                    'exam' => Icons.assignment_late_outlined,
                    'recurring' => Icons.repeat,
                    _ => Icons.event_note,
                  },
                  size: 9,
                  color: foreground.withValues(alpha: 0.85),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: _fitLine(
                    title,
                    TextStyle(
                      fontSize: 8.5,
                      height: 1.1,
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 网格项：课程时段或日程（2.0），对放置算法只暴露节次区间。
class _GridItem {
  _GridItem.course(CourseEntry this.entry, Schedule this.slot)
      : event = null,
        conflictItems = null,
        startSection = slot.startSection,
        endSection = slot.endSection;

  _GridItem.event(LocalEvent this.event, this.startSection, this.endSection)
      : entry = null,
        slot = null,
        conflictItems = null;

  _GridItem.conflict(this.conflictItems, this.startSection, this.endSection)
      : entry = null,
        slot = null,
        event = null;

  final CourseEntry? entry;
  final Schedule? slot;
  final LocalEvent? event;

  /// 冲突占位：同组重叠的课程/日程（≥2），非 null 时渲染为合并块
  final List<_GridItem>? conflictItems;
  final int startSection;
  final int endSection;
}

class _PlacedItem {
  const _PlacedItem({
    required this.item,
    required this.lane,
    required this.laneCount,
  });

  final _GridItem item;
  final int lane;
  final int laneCount;
}

/// 对相交区间做贪心分栏，确保同一周确有冲突的课程/日程也不会互相覆盖。
List<_PlacedItem> _placeOverlapping(List<_GridItem> source) {
  final sorted = [...source]..sort((a, b) {
      final byStart = a.startSection.compareTo(b.startSection);
      return byStart != 0 ? byStart : a.endSection.compareTo(b.endSection);
    });
  final result = <_PlacedItem>[];
  var index = 0;
  while (index < sorted.length) {
    final group = <_GridItem>[sorted[index]];
    var groupEnd = sorted[index].endSection;
    var next = index + 1;
    while (next < sorted.length && sorted[next].startSection <= groupEnd) {
      group.add(sorted[next]);
      groupEnd = math.max(groupEnd, sorted[next].endSection);
      next++;
    }

    if (group.length == 1) {
      result.add(_PlacedItem(item: group[0], lane: 0, laneCount: 1));
    } else {
      // 同组 ≥2 项重叠：不再并排细条（哪条都看不清），合并为一个
      // 冲突占位块，独特颜色 + 「N 个活动」，点按展开看原始卡片。
      final start = group.map((e) => e.startSection).reduce(math.min);
      final end = group.map((e) => e.endSection).reduce(math.max);
      result.add(_PlacedItem(
        item: _GridItem.conflict(group, start, end),
        lane: 0,
        laneCount: 1,
      ));
    }
    index = next;
  }
  return result;
}

class _CourseBlock extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final showTeacherCampus = ref.watch(courseCardDisplayProvider);
    final location = parseCourseLocation(slot.location);
    final baseColor = Color(entry.course.color);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = baseColor.withValues(alpha: isDark ? 0.30 : 0.16);
    // 对比度优先：文字在底色上压得更实，课名再单独加重
    final foreground = isDark
        ? Color.alphaBlend(baseColor.withValues(alpha: 0.30), Colors.white)
        : Color.alphaBlend(baseColor.withValues(alpha: 0.55), Colors.black);

    // 用户自定义简称优先（课程卡片显示名）
    final displayName = entry.course.shortName.isNotEmpty
        ? entry.course.shortName
        : entry.course.name;
    // 分级后的地点行：教室独占醒目行，楼名次要行，校区仅在设置开启时展示
    final room = location.room;
    final building = location.building;
    final fallbackLocation =
        (room.isEmpty && building.isEmpty) ? location.formatted : '';
    final teacher = showTeacherCampus ? entry.course.teacher : '';

    return Semantics(
      button: true,
      label: [
        entry.course.name,
        if (location.formatted.isNotEmpty) location.formatted,
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
              // 窄卡（冲突分栏）内边距收紧，给文字多留 3-4dp
              padding:
                  EdgeInsets.fromLTRB(compact ? 2 : 5, 4, compact ? 1 : 3, 3),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 固定紧凑字阶（用户定稿：加粗排密、信息完整优先于自适应缩放——
                  // 高度/宽度缩放会让高卡的教室号涨大到截断，已弃用）。
                  // 楼名先换行再在极端高度下缩放，避免长楼名缩成一条细线。
                  final nameStyle = TextStyle(
                    fontSize: compact ? 9.5 : 10.5,
                    height: 1.16,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  );
                  final roomStyle = TextStyle(
                    fontSize: compact ? 9.5 : 10.5,
                    height: 1.12,
                    fontWeight: FontWeight.w700,
                    color: foreground,
                  );
                  final buildingStyle = TextStyle(
                    fontSize: 9.5,
                    height: 1.12,
                    fontWeight: FontWeight.w500,
                    color: foreground.withValues(alpha: 0.8),
                  );
                  final metaStyle = TextStyle(
                    fontSize: 8.5,
                    height: 1.1,
                    fontWeight: FontWeight.w500,
                    color: foreground.withValues(alpha: 0.8),
                  );

                  // 按优先级逐级放行：课名 > 教室 > 楼名 > 教师/校区
                  final scaler = MediaQuery.textScalerOf(context);
                  final nameLineHeight =
                      scaler.scale(nameStyle.fontSize!) * nameStyle.height!;
                  final roomLineHeight =
                      scaler.scale(roomStyle.fontSize!) * roomStyle.height! + 3;
                  final metaLineHeight =
                      scaler.scale(metaStyle.fontSize!) * metaStyle.height! + 2;

                  var remaining = constraints.maxHeight;
                  final showRoom =
                      room.isNotEmpty && remaining - nameLineHeight >= 16;
                  if (showRoom) remaining -= roomLineHeight;
                  final showFallback = room.isEmpty &&
                      fallbackLocation.isNotEmpty &&
                      remaining - nameLineHeight >= 16;
                  if (showFallback) remaining -= roomLineHeight;
                  final showBuilding =
                      building.isNotEmpty && remaining - nameLineHeight >= 9;
                  final buildingTextHeight = showBuilding
                      ? math.min(
                          _wrappedTextHeight(context, building, buildingStyle,
                              constraints.maxWidth),
                          math.max(
                              9.0,
                              remaining -
                                  nameLineHeight * 2 -
                                  (teacher.isNotEmpty ? metaLineHeight : 0) -
                                  2),
                        )
                      : 0.0;
                  final buildingLineHeight = buildingTextHeight + 2;
                  if (showBuilding) remaining -= buildingLineHeight;
                  // 卡片上只放教师（校区信息量低且挤，留给详情页）；
                  // 加粗排密原则下 8.5sp 是窄卡可读下限
                  final metaText = teacher;
                  final showMeta =
                      metaText.isNotEmpty && remaining - nameLineHeight >= 8;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            width: constraints.maxWidth,
                            child: Text(displayName,
                                softWrap: true, style: nameStyle),
                          ),
                        ),
                      ),
                      if (showRoom) ...[
                        const SizedBox(height: 3),
                        _fitLine(room, roomStyle),
                      ],
                      if (showFallback) ...[
                        const SizedBox(height: 3),
                        _fitLine(fallbackLocation, roomStyle),
                      ],
                      if (showBuilding) ...[
                        const SizedBox(height: 2),
                        SizedBox(
                          height: buildingTextHeight,
                          width: double.infinity,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: constraints.maxWidth,
                              child: Text(building,
                                  softWrap: true, style: buildingStyle),
                            ),
                          ),
                        ),
                      ],
                      if (showMeta) ...[
                        const SizedBox(height: 2),
                        _fitLine(metaText, metaStyle),
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
}

/// 冲突合并块：同一时段有 ≥2 个重叠课程/日程时，不再并排细条，
/// 用与其他卡片都不同的中性色提示「N 个活动」，点按展开看原始卡片。
class _ConflictBlock extends StatelessWidget {
  const _ConflictBlock({
    required this.items,
    required this.dayDate,
    required this.onCourseTap,
    required this.onEventTap,
  });

  final List<_GridItem> items;

  /// 冲突块所在列的日期（review R33）：弹层里换算上课时刻必须用它，
  /// 不能隐式读"今天"——跨作息季节的周会算错时间。
  final DateTime dayDate;
  final void Function(CourseEntry entry) onCourseTap;
  final void Function(LocalEvent event)? onEventTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '同一时段有 ${items.length} 个活动，点按查看',
      child: Material(
        // 中性底 + 标准卡片 chrome（与其他卡片同圆角/同描边宽度），
        // 颜色差异交给内部小方块，块本身保持 App 统一的表面语言
        color: colors.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: colors.outlineVariant, width: 1.2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _showConflictSheet(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(5, 4, 3, 3),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final titleStyle = TextStyle(
                  fontSize: 10.5,
                  height: 1.14,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                );
                // 说明「同一时段」的性质，与其他次要信息同色
                final subStyle = TextStyle(
                  fontSize: 9.5,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                );
                // 每个活动一个彩色小方块（用回它自己的颜色），
                // 均分剩余高度占满块内空间；字号随活动数自适应
                const headHeight = 14.0;
                final availH =
                    math.max(0.0, constraints.maxHeight - headHeight);
                final maxChips = math.max(0, (availH / 15).floor());
                final shown = items.take(math.min(4, maxChips)).toList();
                final itemFontSize = shown.length <= 2
                    ? 10.5
                    : shown.length == 3
                        ? 10.0
                        : 9.5;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.dynamic_feed_outlined,
                            size: 11, color: colors.onSurfaceVariant),
                        const SizedBox(width: 3),
                        Expanded(
                          child: _fitLine('${items.length} 个活动', titleStyle),
                        ),
                      ],
                    ),
                    for (final item in shown)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2.5),
                          child: _ConflictMiniChip(
                            item: item,
                            fontSize: itemFontSize,
                          ),
                        ),
                      ),
                    if (items.length > shown.length)
                      _fitLine(
                        '还有 ${items.length - shown.length} 个…',
                        subStyle,
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _showConflictSheet(BuildContext context) {
    // 与课表同规则排列：按开始节次排序；时间重叠的并排（分栏），
    // 不重叠的顺次往下——展开后仍能读出时间先后的结构。
    // 分组用"当前组最大 endSection"做连通分量（review R32）：只和上一项
    // 比较会漏掉嵌套区间，[1,8][2,3][5,6] 会被错误拆成两组。
    final sorted = [...items]..sort((a, b) => a.startSection != b.startSection
        ? a.startSection.compareTo(b.startSection)
        : a.endSection.compareTo(b.endSection));
    final clusters = <List<_GridItem>>[];
    var clusterMaxEnd = 0;
    for (final item in sorted) {
      if (clusters.isEmpty || clusterMaxEnd < item.startSection) {
        clusters.add([item]);
        clusterMaxEnd = item.endSection;
      } else {
        clusters.last.add(item);
        if (item.endSection > clusterMaxEnd) clusterMaxEnd = item.endSection;
      }
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: 16 + MediaQuery.viewPaddingOf(sheetContext).bottom + 76,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: Text(
                  '同一时段有 ${items.length} 个活动',
                  style: Theme.of(sheetContext)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Flexible(
                child: Consumer(builder: (context, ref, _) {
                  final config =
                      ref.watch(sectionTimeConfigProvider).valueOrNull ??
                          const SectionTimeConfig.defaults();
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: clusters.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final cluster = clusters[index];
                      if (cluster.length == 1) {
                        return _conflictSheetItem(
                            sheetContext, config, cluster.first);
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < cluster.length; i++) ...[
                            if (i > 0) const SizedBox(width: 8),
                            Expanded(
                              child: _conflictSheetItem(
                                  sheetContext, config, cluster[i]),
                            ),
                          ],
                        ],
                      );
                    },
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 弹层里的一项：小时间说明 + 原始卡片（与课表里同款）
  Widget _conflictSheetItem(
      BuildContext sheetContext, SectionTimeConfig config, _GridItem item) {
    // 用冲突块所在列的日期换算时刻（review R33），冬夏作息随目标日期走
    final dayDate = this.dayDate;
    late final String caption;
    if (item.event != null) {
      final label = eventTimeLabel(item.event!, dayDate, config);
      caption =
          label.isEmpty ? '第${item.startSection}-${item.endSection}节' : label;
    } else {
      final slot = item.slot!;
      caption =
          '第${slot.startSection}-${slot.endSection}节 ${config.startOf(slot.startSection, dayDate)}-${config.endOf(slot.endSection, dayDate)}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 3),
          child: Text(
            caption,
            style: Theme.of(sheetContext).textTheme.labelSmall?.copyWith(
                  color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        SizedBox(
          height: 78,
          child: item.event != null
              ? _EventBlock(
                  event: item.event!,
                  dayDate: dayDate,
                  compact: false,
                  onTap: onEventTap == null
                      ? null
                      : () {
                          Navigator.of(sheetContext).pop();
                          onEventTap!(item.event!);
                        },
                )
              : _CourseBlock(
                  entry: item.entry!,
                  slot: item.slot!,
                  compact: false,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    onCourseTap(item.entry!);
                  },
                ),
        ),
      ],
    );
  }
}

/// 冲突块内的单个活动小方块：用回活动自己的颜色，加粗名称缩字适配。
class _ConflictMiniChip extends StatelessWidget {
  const _ConflictMiniChip({required this.item, required this.fontSize});

  final _GridItem item;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final isEvent = item.event != null;
    final baseColor = isEvent
        ? Color(eventColorOf(item.event!))
        : Color(item.entry!.course.color);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = baseColor.withValues(alpha: isDark ? 0.30 : 0.18);
    final foreground = isDark
        ? Color.alphaBlend(baseColor.withValues(alpha: 0.30), Colors.white)
        : Color.alphaBlend(baseColor.withValues(alpha: 0.50), Colors.black);
    final name = isEvent
        ? (item.event!.shortTitle.isNotEmpty
            ? item.event!.shortTitle
            : item.event!.title)
        : (item.entry!.course.shortName.isNotEmpty
            ? item.entry!.course.shortName
            : item.entry!.course.name);
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: baseColor.withValues(alpha: 0.45)),
      ),
      child: _fitLine(
        name,
        TextStyle(
          fontSize: fontSize,
          height: 1.1,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}

/// 单行内容缩小适配：宽度不够时整体缩字，保证信息完整不截断
/// （教室号/楼名等关键信息宁可小也不省略号）。
Widget _fitLine(String text, TextStyle style) {
  return SizedBox(
    width: double.infinity,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(text, softWrap: false, maxLines: 1, style: style),
    ),
  );
}

double _wrappedTextHeight(
    BuildContext context, String text, TextStyle style, double width) {
  final painter = TextPainter(
    text: TextSpan(
        text: text, style: DefaultTextStyle.of(context).style.merge(style)),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: math.max(1, width));
  final height = painter.height;
  painter.dispose();
  return height;
}

/// 日程块（AI 日程 2.0）：与课程块同一网格坐标系，视觉上用更透明的底色 +
/// 虚线感细描边 + 类型小标签区分；点击弹出日程详情。
class _EventBlock extends ConsumerWidget {
  const _EventBlock({
    required this.event,
    required this.dayDate,
    required this.compact,
    required this.onTap,
  });

  final LocalEvent event;
  final DateTime dayDate;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(sectionTimeConfigProvider).valueOrNull ??
        const SectionTimeConfig.defaults();
    final baseColor = Color(eventColorOf(event));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = baseColor.withValues(alpha: isDark ? 0.22 : 0.10);
    final foreground = isDark
        ? Color.alphaBlend(baseColor.withValues(alpha: 0.42), Colors.white)
        : Color.alphaBlend(baseColor.withValues(alpha: 0.70), Colors.black);
    // 课表小格子优先展示 AI 简写，完整标题在详情里
    final displayTitle =
        event.shortTitle.isNotEmpty ? event.shortTitle : event.title;
    final timeLabel = eventTimeLabel(event, dayDate, config);

    return Semantics(
      button: true,
      label: '日程：${event.title}',
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: baseColor.withValues(alpha: 0.55),
            width: 1.2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.fromLTRB(compact ? 3 : 5, 4, 3, 3),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showTime =
                    timeLabel.isNotEmpty && constraints.maxHeight >= 40;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          switch (event.eventType) {
                            'exam' => Icons.assignment_late_outlined,
                            'recurring' => Icons.repeat,
                            _ => Icons.event_note,
                          },
                          size: 10,
                          color: foreground.withValues(alpha: 0.8),
                        ),
                        const SizedBox(width: 2),
                        Expanded(
                          child: Text(
                            displayTitle,
                            maxLines: math.max(
                              1,
                              math.min(
                                4,
                                ((constraints.maxHeight - (showTime ? 14 : 0)) /
                                        11)
                                    .floor(),
                              ),
                            ),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: compact ? 8.5 : 9.5,
                              height: 1.12,
                              fontWeight: FontWeight.w700,
                              color: foreground,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (showTime) ...[
                      const Spacer(),
                      _fitLine(
                        timeLabel,
                        TextStyle(
                          fontSize: 8.5,
                          height: 1.1,
                          fontWeight: FontWeight.w600,
                          color: foreground.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                    if (event.location.isNotEmpty &&
                        constraints.maxHeight >= 54) ...[
                      const SizedBox(height: 2),
                      Builder(builder: (context) {
                        final loc = parseCourseLocation(event.location);
                        // 与课程块同策略：优先「教室 楼名」结构，缩小适配不截断
                        final text = loc.room.isNotEmpty
                            ? (loc.building.isNotEmpty
                                ? '${loc.room} ${loc.building}'
                                : loc.room)
                            : loc.formatted;
                        return _fitLine(
                          text,
                          TextStyle(
                            fontSize: 8,
                            height: 1.1,
                            color: foreground.withValues(alpha: 0.78),
                          ),
                        );
                      }),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
