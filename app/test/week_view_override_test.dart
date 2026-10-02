import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/core/utils/week_calculator.dart';
import 'package:yzu_schedule/features/schedule/data/schedule_repository.dart';
import 'package:yzu_schedule/features/schedule/data/override_repository.dart';
import 'package:yzu_schedule/features/schedule/presentation/week_view.dart';

/// 周视图调休渲染回归（修复：放假当天课程仍显示）。
///
/// 真实渲染路径：WeekView._buildDayColumn 必须按 effectiveWeekday 跳过
/// 放假日（off → null）的全部课程块；补课日（makeup）按指定星期渲染。
void main() {
  final semester = Semester(
    id: 1,
    uuid: 'sem-1',
    name: '测试学期',
    startDate: DateTime(2026, 9, 7), // 周一
    totalWeeks: 20,
    isCurrent: true,
    updatedAt: DateTime(2026, 9, 20),
  );

  final course = Course(
    id: 1,
    uuid: 'course-math',
    semesterId: 1,
    name: '高等数学',
    shortName: '',
    teacher: '王老师',
    color: 0xFF158A63,
    note: '',
    updatedAt: DateTime(2026, 9, 20),
  );

  // 周三第 1-2 节的课（每周都上）
  final wednesdaySlot = Schedule(
    id: 1,
    uuid: 'sched-wed',
    courseId: 1,
    dayOfWeek: 3,
    startSection: 1,
    endSection: 2,
    weeksType: WeeksType.every,
    customWeeks: '[]',
    location: '文津楼201',
    updatedAt: DateTime(2026, 9, 20),
  );

  List<ScheduleOverride> overrides(String date, String kind, {int weekday = 0}) =>
      [ScheduleOverride(
        id: 1,
        uuid: 'ov-1',
        date: date,
        kind: kind,
        weekday: weekday,
        note: '',
        updatedAt: DateTime(2026, 9, 20),
      )];

  Widget buildWeekView(List<ScheduleOverride> overrides) => ProviderScope(
        overrides: [overridesProvider.overrideWith((_) => Stream.value(overrides))],
        child: MaterialApp(
          home: Scaffold(
            body: WeekView(
              semester: semester,
              week: 2, // 2026-09-14 ~ 09-20
              entries: [CourseEntry(course: course, slots: [wednesdaySlot])],
              onCourseTap: (_) {},
            ),
          ),
        ),
      );

  testWidgets('调休放假（off）：当天课程块从周视图消失', (tester) async {
    // 放假日 = 2026-09-16（周三），覆盖课表周三
    await tester.pumpWidget(buildWeekView(overrides('2026-09-16', 'off')));
    await tester.pumpAndSettle();
    // 周视图里不应出现课程名文本（放假当天不渲染）
    expect(find.text('高等数学'), findsNothing);
    // 应显示「放假」标签
    expect(find.text('放假'), findsOneWidget);
  });

  testWidgets('无覆盖：周三正常显示课程', (tester) async {
    await tester.pumpWidget(buildWeekView(const []));
    await tester.pumpAndSettle();
    expect(find.text('高等数学'), findsOneWidget);
  });
}
