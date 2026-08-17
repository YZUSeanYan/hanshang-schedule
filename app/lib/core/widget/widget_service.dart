import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../../features/schedule/data/schedule_repository.dart';
import '../constants/course_colors.dart';
import '../constants/section_times.dart';
import '../database/app_database.dart';
import '../utils/location_formatter.dart';
import '../utils/week_calculator.dart';

/// 桌面小组件服务（四种小组件统一数据源）。
///
/// 每次课程数据变化后，把各小组件摘要写入 home_widget 共享存储，
/// 并通知原生 Provider 刷新。数据契约（与原生 Kotlin 一致）：
/// - today_title / today_courses_json    「今日课程」（2x2/4x2）
/// - day_title / day_courses_json        「日视图」（4x2，带节次）
/// - week_title / week_grid_json         「一周课程」（4x2 网格）
/// - twoday_title / twoday_json          「近日课程」（今天/明天两列）
class WidgetService {
  WidgetService(this._db);

  final AppDatabase _db;

  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  static const _weekdayShort = ['一', '二', '三', '四', '五', '六', '日'];

  static const providerName =
      'cn.yzu.schedule.yzu_schedule.TodayWidgetProvider';

  /// 刷新全部小组件（今日/日视图/一周/近日）
  Future<void> refresh() async {
    final today = DateTime.now();

    final semester = await (_db.select(_db.semesters)
          ..where((s) => s.isCurrent.equals(true))
          ..orderBy([
            (s) => OrderingTerm.desc(s.updatedAt),
            (s) => OrderingTerm.desc(s.id),
          ])
          ..limit(1))
        .getSingleOrNull();

    final todayList = await _coursesForDate(today, semester);
    final tomorrowList = await _coursesForDate(
      today.add(const Duration(days: 1)),
      semester,
    );
    final weekColumns = await _weekColumns(today, semester);

    final title = _titleFor(today, semester);
    await HomeWidget.saveWidgetData<String>('today_title', title);
    await HomeWidget.saveWidgetData<String>(
        'today_courses_json', jsonEncode(todayList));

    await HomeWidget.saveWidgetData<String>(
        'day_title', '${_titleFor(today, semester)} · 日视图');
    await HomeWidget.saveWidgetData<String>(
        'day_courses_json', jsonEncode(todayList));

    await HomeWidget.saveWidgetData<String>(
        'week_title', '${_titleFor(today, semester)} · 一周');
    await HomeWidget.saveWidgetData<String>(
        'week_grid_json', jsonEncode(weekColumns));

    await HomeWidget.saveWidgetData<String>(
        'twoday_title', _titleFor(today, semester));
    await HomeWidget.saveWidgetData<String>(
      'twoday_json',
      jsonEncode({
        'left': {
          'head': '今天',
          'courses': todayList,
        },
        'right': {
          'head': '明天',
          'courses': tomorrowList,
        },
      }),
    );

    // 通知四个 Provider 刷新
    await HomeWidget.updateWidget(
      qualifiedAndroidName: providerName,
      androidName: 'TodayWidgetProvider',
    );
    await HomeWidget.updateWidget(
      androidName: 'DayWidgetProvider',
    );
    await HomeWidget.updateWidget(
      androidName: 'WeekWidgetProvider',
    );
    await HomeWidget.updateWidget(
      androidName: 'TwoDayWidgetProvider',
    );
  }

  String _titleFor(DateTime date, Semester? semester) {
    var title =
        '${date.month}月${date.day}日 ${_weekdayLabels[date.weekday - 1]}';
    if (semester == null) return title;
    final week = weekNumberOf(semester.startDate, date);
    if (week >= 1 && week <= semester.totalWeeks) {
      title += ' · 第$week周';
    } else {
      title += ' · 假期中';
    }
    return title;
  }

  /// 某天的课程列表（含颜色），按开始节次排序。
  Future<List<Map<String, String>>> _coursesForDate(
    DateTime date,
    Semester? semester,
  ) async {
    if (semester == null) return [];
    final week = weekNumberOf(semester.startDate, date);
    if (week < 1 || week > semester.totalWeeks) return [];

    final courseRows = await (_db.select(_db.courses)
          ..where((c) => c.semesterId.equals(semester.id)))
        .get();
    final slots = await (_db.select(_db.schedules)
          ..where((s) => s.dayOfWeek.equals(date.weekday)))
        .get();
    final courseById = {for (final c in courseRows) c.id: c};

    final items = <(int, Map<String, String>)>[];
    for (final slot in slots) {
      final course = courseById[slot.courseId];
      if (course == null) continue;
      final weeks = (jsonDecode(slot.customWeeks) as List).cast<int>();
      if (!occursInWeek(slot.weeksType, weeks, week)) continue;
      items.add((
        slot.startSection,
        {
          'time': '${SectionTimes.startOf(slot.startSection)}-${SectionTimes.endOf(slot.endSection)}',
          'name': course.name,
          'loc': formatCourseLocation(slot.location),
          'sec': '${slot.startSection}-${slot.endSection}节',
          'color': _colorHex(course),
          'colorIndex': _colorIndex(course).toString(),
        }
      ));
    }
    items.sort((a, b) => a.$1.compareTo(b.$1));
    return items.map((e) => e.$2).toList();
  }

  /// 本周一~周日的课程列（周网格）。
  Future<List<Map<String, dynamic>>> _weekColumns(
    DateTime today,
    Semester? semester,
  ) async {
    final monday = mondayOf(today);
    final columns = <Map<String, dynamic>>[];
    for (var i = 0; i < 7; i++) {
      final date = monday.add(Duration(days: i));
      final list = await _coursesForDate(date, semester);
      columns.add({
        'head': _weekdayShort[i],
        'courses': list
            .map((c) => {
                  'name': c['name'] ?? '',
                  'color': c['color'] ?? '',
                  'colorIndex': c['colorIndex'] ?? '0',
                })
            .toList(),
      });
    }
    return columns;
  }

  /// 课程颜色转 hex 字符串（ARGB int 去掉 alpha 通道）。
  String _colorHex(Course course) {
    final c = course.color;
    if (c == 0) {
      final fallback = CourseColors.forCourseName(course.name);
      return '#${(fallback.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    }
    return '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  /// 课程颜色索引（ARGB → 马卡龙盘反查；未匹配按课名哈希）。
  int _colorIndex(Course course) {
    final idx = CourseColors.macaron
        .indexWhere((c) => c.toARGB32() == course.color);
    if (idx >= 0) return idx;
    var hash = 0;
    for (final unit in course.name.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash % CourseColors.macaron.length;
  }
}

/// 小组件服务 Provider
final widgetServiceProvider = Provider<WidgetService>(
  (ref) => WidgetService(ref.read(databaseProvider)),
);
