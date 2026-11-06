import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/core/utils/week_calculator.dart';
import 'package:yzu_schedule/core/utils/location_formatter.dart';
import 'package:yzu_schedule/features/schedule/data/schedule_repository.dart';
import 'package:yzu_schedule/features/schedule/presentation/week_view.dart';

void main() {
  final now = DateTime(2026, 9, 1);

  CourseEntry entry({
    required int id,
    required String name,
    required WeeksType type,
    String location = '文津楼101',
  }) {
    return CourseEntry(
      course: Course(
        id: id,
        uuid: 'course-$id',
        semesterId: 1,
        name: name,
        teacher: '张老师',
        color: 0xFF4F6BED,
        note: '',
        updatedAt: now,
      ),
      slots: [
        Schedule(
          id: id,
          uuid: 'slot-$id',
          courseId: id,
          dayOfWeek: 1,
          startSection: 1,
          endSection: 2,
          weeksType: type,
          customWeeks: '[]',
          location: location,
          updatedAt: now,
        ),
      ],
    );
  }

  Widget subject(int week, List<CourseEntry> entries, {double width = 800}) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: 700,
          child: WeekView(
            semester: Semester(
              id: 1,
              uuid: 'semester',
              name: '2026 秋',
              startDate: DateTime(2026, 9, 7),
              totalWeeks: 20,
              isCurrent: true,
              updatedAt: now,
            ),
            week: week,
            entries: entries,
            onCourseTap: (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('互斥周次的同时间课程只显示本周课程', (tester) async {
    final odd = entry(id: 1, name: '单周课程', type: WeeksType.odd);
    final even = entry(id: 2, name: '双周课程', type: WeeksType.even);

    await tester.pumpWidget(subject(1, [odd, even]));
    expect(find.text('单周课程'), findsOneWidget);
    expect(find.text('双周课程'), findsNothing);

    await tester.pumpWidget(subject(2, [odd, even]));
    expect(find.text('单周课程'), findsNothing);
    expect(find.text('双周课程'), findsOneWidget);
  });

  testWidgets('同一周真正冲突的课程会横向分栏', (tester) async {
    final semantics = tester.ensureSemantics();
    final first = entry(id: 1, name: '课程甲', type: WeeksType.every);
    final second = entry(id: 2, name: '课程乙', type: WeeksType.every);

    await tester.pumpWidget(subject(1, [first, second]));

    Finder block(String label) => find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == label,
        );
    final firstRect = tester.getRect(block('课程甲，文津楼101，张老师'));
    final secondRect = tester.getRect(block('课程乙，文津楼101，张老师'));
    expect(firstRect.overlaps(secondRect), isFalse);
    expect(firstRect.top, secondRect.top);
    semantics.dispose();
  });

  testWidgets('手机宽度下充分利用卡片高度并显示地点和教师', (tester) async {
    final course = entry(
      id: 1,
      name: '这是一门名称比较长但需要尽量完整显示的课程',
      type: WeeksType.every,
      location: '扬子津东校区文津楼智慧教室101',
    );

    await tester.pumpWidget(subject(1, [course], width: 360));

    final name = tester.widget<Text>(find.text(course.course.name));
    expect(name.maxLines, greaterThan(2));
    final location = tester.widget<Text>(
        find.text(formatCourseLocation(course.slots.single.location)));
    expect(location.maxLines, greaterThanOrEqualTo(4));
    expect(find.text(course.course.teacher), findsOneWidget);
  });
}
