import '../../../core/constants/section_times.dart';
import '../../../core/database/app_database.dart';
import '../data/event_repository.dart';
import '../data/override_repository.dart';
import '../data/schedule_repository.dart';

/// 网格、节次范围与周末提示使用同一份日期投影，避免隐藏实际发生的安排。
class WeekDayContent {
  WeekDayContent({
    required this.date,
    required this.isOffDay,
    required this.courses,
    required this.timedEvents,
    required this.allDayEvents,
  });

  final DateTime date;
  final bool isOffDay;
  final List<({CourseEntry entry, Schedule slot})> courses;
  final List<({LocalEvent event, int start, int end})> timedEvents;
  final List<LocalEvent> allDayEvents;

  bool get hasActivities =>
      courses.isNotEmpty || timedEvents.isNotEmpty || allDayEvents.isNotEmpty;

  int get lastSection {
    var last = 0;
    for (final course in courses) {
      if (course.slot.endSection > last) last = course.slot.endSection;
    }
    for (final event in timedEvents) {
      if (event.end > last) last = event.end;
    }
    return last.clamp(0, SectionTimes.sectionCount);
  }

  static List<WeekDayContent> forWeek({
    required Semester semester,
    required int week,
    required List<CourseEntry> entries,
    required List<LocalEvent> events,
    required List<ScheduleOverride> overrides,
  }) {
    final monday = semester.startDate.add(Duration(days: (week - 1) * 7));
    return List.generate(7, (index) {
      final date = monday.add(Duration(days: index));
      final effective = effectiveWeekday(overrides, date);
      final courses = <({CourseEntry entry, Schedule slot})>[
        if (effective != null)
          for (final entry in entries)
            for (final slot in entry.slots)
              if (slot.dayOfWeek == effective && slotOccursInWeek(slot, week))
                (entry: entry, slot: slot),
      ];
      final timed = <({LocalEvent event, int start, int end})>[];
      final allDay = <LocalEvent>[];
      for (final event in events) {
        if (!eventOccursOn(event, date)) continue;
        final range = eventSectionRange(event);
        if (range == null) {
          allDay.add(event);
        } else {
          timed.add((event: event, start: range.$1, end: range.$2));
        }
      }
      return WeekDayContent(
        date: date,
        isOffDay: effective == null,
        courses: courses,
        timedEvents: timed,
        allDayEvents: allDay,
      );
    });
  }
}

/// 保留白天 1–8 节；晚间按当前可见日期的最后一项安排展开。
int visibleSectionCount(Iterable<WeekDayContent> days, {required bool trim}) {
  if (!trim) return SectionTimes.sectionCount;
  var last = 8;
  for (final day in days) {
    if (day.lastSection > last) last = day.lastSection;
  }
  return last;
}
