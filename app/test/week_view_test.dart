import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/core/settings/course_card_display.dart';
import 'package:yzu_schedule/core/settings/section_time_settings.dart';
import 'package:yzu_schedule/core/utils/week_calculator.dart';
import 'package:yzu_schedule/features/schedule/data/schedule_repository.dart';
import 'package:yzu_schedule/features/schedule/data/override_repository.dart';
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
      course: Course(shortName: '', 
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

  Widget subject(int week, List<CourseEntry> entries,
      {double width = 800, List<LocalEvent> events = const []}) {
    // 2.0 起 WeekView 通过 sectionTimeConfigProvider 读作息配置，测试给默认表
    return ProviderScope(
      overrides: [
        sectionTimeConfigProvider.overrideWith(
          (ref) => Stream.value(const SectionTimeConfig.defaults()),
        ),
        // 默认收起教师/校区；stub 掉持久化恢复，避免测试里开真实数据库
        courseCardDisplayProvider.overrideWith(_HiddenAll.new),
        // 调休覆盖：测试里给空流，避免触发真实数据库与 pending timer
        overridesProvider.overrideWith(
          (ref) => Stream.value(const <ScheduleOverride>[]),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: 700,
            child: WeekView(
            events: events,
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

  testWidgets('同一周真正冲突的课程合并为「N 个活动」块，点按展开原始卡片',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final first = entry(id: 1, name: '课程甲', type: WeeksType.every);
    final second = entry(id: 2, name: '课程乙', type: WeeksType.every);

    await tester.pumpWidget(subject(1, [first, second]));

    // 合并块：独特提示，不再并排两条细卡
    final merged = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == '同一时段有 2 个活动，点按查看',
    );
    expect(merged, findsOneWidget);
    expect(find.text('2 个活动'), findsWidgets);

    // 点按展开：两张原始课程卡片都在
    await tester.tap(merged);
    await tester.pumpAndSettle();
    expect(find.text('同一时段有 2 个活动'), findsOneWidget);
    expect(find.text('课程甲'), findsWidgets);
    expect(find.text('课程乙'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('手机宽度下优先显示课名与教室，教师默认收起', (tester) async {
    final course = entry(
      id: 1,
      name: '这是一门名称比较长但需要尽量完整显示的课程',
      type: WeeksType.every,
      location: '扬子津东校区文津楼智慧教室101',
    );

    await tester.pumpWidget(subject(1, [course], width: 360));

    final name = tester.widget<Text>(find.text(course.course.name));
    // 课名现在完整换行后按可用空间适配，不再依赖固定行数截断。
    expect(name.maxLines, isNull);
    expect(name.softWrap, isTrue);
    expect(name.overflow, isNot(TextOverflow.ellipsis));
    // 新层级：教室独占醒目行，楼名次要行，教师/校区默认收起到详情
    expect(find.text('101'), findsOneWidget);
    expect(find.text('文津楼智慧教室'), findsOneWidget);
    expect(find.text(course.course.teacher), findsNothing);
  });

  testWidgets('开启「卡片显示教师与校区」后显示教师', (tester) async {
    final course = entry(
      id: 1,
      name: '课程甲',
      type: WeeksType.every,
      location: '扬子津东校区文津楼101',
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sectionTimeConfigProvider.overrideWith(
          (ref) => Stream.value(const SectionTimeConfig.defaults()),
        ),
        courseCardDisplayProvider.overrideWith(_ShowAll.new),
        overridesProvider.overrideWith(
          (ref) => Stream.value(const <ScheduleOverride>[]),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
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
              week: 1,
              entries: [course],
              onCourseTap: (_) {},
            ),
          ),
        ),
      ),
    ));
    expect(find.textContaining('张老师'), findsWidgets);
  });

  testWidgets('全天日程在所属周的周视图中显示为顶部条，其他周不显示', (tester) async {
    final allDay = LocalEvent(
      id: 1,
      uuid: 'evt-allday',
      title: '赛前面试（补）',
      shortTitle: '赛前面试',
      eventType: 'event',
      date: '2026-09-23', // 学期 2026-09-07 开学，第 3 周周三
      weekday: 0,
      startTime: '',
      endTime: '',
      startSection: 0,
      endSection: 0,
      busySections: '',
      location: '',
      note: '',
      color: 0,
      remindMinutes: -1,
      source: 'text',
      updatedAt: now,
    );

    final dummy = entry(id: 99, name: '占位课程', type: WeeksType.every);
    await tester.pumpWidget(subject(3, [dummy], width: 800, events: [allDay]));
    expect(find.text('赛前面试'), findsWidgets);

    await tester.pumpWidget(subject(4, [dummy], width: 800, events: [allDay]));
    expect(find.text('赛前面试'), findsNothing);
  });
}

class _ShowAll extends CourseCardDisplay {
  @override
  bool build() => true;
}

class _HiddenAll extends CourseCardDisplay {
  @override
  bool build() => false;

}
