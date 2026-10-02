import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/core/settings/course_card_display.dart';
import 'package:yzu_schedule/core/settings/schedule_display_settings.dart';
import 'package:yzu_schedule/core/settings/section_time_settings.dart';
import 'package:yzu_schedule/core/utils/week_calculator.dart';
import 'package:yzu_schedule/features/schedule/data/override_repository.dart';
import 'package:yzu_schedule/features/schedule/data/schedule_repository.dart';
import 'package:yzu_schedule/features/schedule/presentation/schedule_display_sheet.dart';
import 'package:yzu_schedule/features/schedule/presentation/week_day_content.dart';
import 'package:yzu_schedule/features/schedule/presentation/week_view.dart';

final _monday = DateTime(2026, 9, 7);
final _semester = Semester(
    id: 1,
    uuid: 'semester',
    name: '秋',
    startDate: _monday,
    totalWeeks: 20,
    isCurrent: true,
    updatedAt: _monday);

CourseEntry _course(
        {int id = 1,
        int day = 1,
        int start = 1,
        int end = 8,
        WeeksType weeks = WeeksType.every,
        String custom = '[]',
        String location = '扬子津校区>>经济管理学院MBA教学楼>>504'}) =>
    CourseEntry(
      course: Course(
          id: id,
          uuid: 'course-$id',
          semesterId: 1,
          name: '课程$id',
          shortName: '',
          teacher: '张老师',
          color: 0xFF4F6BED,
          note: '',
          updatedAt: _monday),
      slots: [
        Schedule(
            id: id,
            uuid: 'slot-$id',
            courseId: id,
            dayOfWeek: day,
            startSection: start,
            endSection: end,
            weeksType: weeks,
            customWeeks: custom,
            location: location,
            updatedAt: _monday)
      ],
    );

LocalEvent _event(
        {String date = '2026-09-12',
        String type = 'event',
        int weekday = 0,
        int start = 0,
        int end = 0,
        String busy = ''}) =>
    LocalEvent(
      id: 1,
      uuid: 'event',
      title: '个人安排',
      shortTitle: '',
      eventType: type,
      date: date,
      weekday: weekday,
      startTime: '',
      endTime: '',
      startSection: start,
      endSection: end,
      busySections: busy,
      location: '',
      note: '',
      color: 0,
      remindMinutes: -1,
      source: 'manual',
      updatedAt: _monday,
    );

ScheduleOverride _override(String date, String kind, {int weekday = 0}) =>
    ScheduleOverride(
        id: 1,
        uuid: 'override',
        date: date,
        kind: kind,
        weekday: weekday,
        note: '',
        updatedAt: _monday);

List<WeekDayContent> _days(List<CourseEntry> courses,
        {int week = 1,
        List<LocalEvent> events = const [],
        List<ScheduleOverride> overrides = const []}) =>
    WeekDayContent.forWeek(
      semester: _semester,
      week: week,
      entries: courses,
      events: events,
      overrides: overrides,
    );

class _TeacherVisible extends CourseCardDisplay {
  @override
  bool build() => true;
}

Widget _subject(
        {List<CourseEntry> courses = const [],
        List<LocalEvent> events = const [],
        List<ScheduleOverride> overrides = const [],
        bool showWeekends = true,
        bool trim = true,
        int week = 1,
        double scale = 1,
        Brightness brightness = Brightness.light}) =>
    ProviderScope(
        overrides: [
          sectionTimeConfigProvider.overrideWith(
              (_) => Stream.value(const SectionTimeConfig.defaults())),
          overridesProvider.overrideWith((_) => Stream.value(overrides)),
          courseCardDisplayProvider.overrideWith(_TeacherVisible.new),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
                body: WeekView(
                    semester: _semester,
                    week: week,
                    entries: courses,
                    events: events,
                    showWeekends: showWeekends,
                    trimEmptyEvenings: trim,
                    onCourseTap: (_) {})),
          ),
        ));

void main() {
  test('白天课程默认到第8节，关闭收起可恢复12节', () {
    final days = _days([_course()]);
    expect(visibleSectionCount(days, trim: true), 8);
    expect(visibleSectionCount(days, trim: false), 12);
    expect(visibleSectionCount(_days([]), trim: true), 8);
  });
  test('按整周实际周次计算，其他日期的晚课不能被截掉', () {
    final courses = [
      _course(),
      _course(id: 2, day: 4, start: 9, end: 12, weeks: WeeksType.even)
    ];
    expect(visibleSectionCount(_days(courses, week: 1), trim: true), 8);
    expect(visibleSectionCount(_days(courses, week: 2), trim: true), 12);
  });
  test('晚间个人日程与busySections延長范围', () {
    final days = _days([_course()],
        events: [_event(date: '2026-09-08', start: 9, end: 10)]);
    expect(visibleSectionCount(days, trim: true), 10);
    expect(
        visibleSectionCount(_days([], events: [_event(busy: '11,12')]),
            trim: true),
        12);
  });
  test('放假移除晚课，补课按目标星期计入周末', () {
    final days = _days([
      _course(day: 1, start: 9, end: 12)
    ], overrides: [
      _override('2026-09-07', 'off'),
      _override('2026-09-12', 'makeup', weekday: 1),
    ]);
    expect(days.first.hasActivities, isFalse);
    expect(days[5].hasActivities, isTrue);
    expect(visibleSectionCount(days.take(5), trim: true), 8);
    expect(visibleSectionCount(days, trim: true), 12);
  });
  test('周末提示覆盖全天DDL和周期日程，但不把放假本身当安排', () {
    expect(_days([], events: [_event(type: 'ddl')])[5].hasActivities, isTrue);
    expect(
        _days([], events: [_event(type: 'recurring', date: '', weekday: 7)])[6]
            .hasActivities,
        isTrue);
    expect(
        _days([], overrides: [_override('2026-09-12', 'off')])[5].hasActivities,
        isFalse);
  });
  test('显示偏好持久保存且账号清库后恢复默认', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final settings = ScheduleDisplaySettings(db);
    await settings.save(const ScheduleDisplayOptions(
        showWeekends: false, trimEmptyEvenings: false));
    final reloaded = await ScheduleDisplaySettings(db).watch().first;
    expect(reloaded.showWeekends, isFalse);
    expect(reloaded.trimEmptyEvenings, isFalse);
    await db.delete(db.settingsEntries).go();
    final reset = await settings.watch().first;
    expect(reset.showWeekends, isTrue);
    expect(reset.trimEmptyEvenings, isTrue);
  });
  test('损坏或旧版偏好使用安全默认值', () {
    for (final raw in [null, '', 'broken', '{"show_weekends":1}', '[]']) {
      final options = ScheduleDisplayOptions.decode(raw);
      expect(options.showWeekends, isTrue);
      expect(options.trimEmptyEvenings, isTrue);
    }
  });
  testWidgets('8节填满网格，不渲染9至12节空行', (tester) async {
    await tester.pumpWidget(_subject(courses: [_course()]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('section-label-8')), findsOneWidget);
    expect(find.byKey(const ValueKey('section-label-9')), findsNothing);
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.padding, EdgeInsets.zero);
    expect(
        tester.getBottomLeft(find.byKey(const ValueKey('section-label-8'))).dy,
        closeTo(600, 1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('有晚课时仍可显示12节', (tester) async {
    await tester.pumpWidget(_subject(courses: [_course(start: 11, end: 12)]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('section-label-12')), findsOneWidget);
    expect(find.text('课程1'), findsOneWidget);
  });
  testWidgets('隐藏空闲周末只显示五列且不制造提示', (tester) async {
    await tester
        .pumpWidget(_subject(courses: [_course()], showWeekends: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weekday-header-5')), findsOneWidget);
    expect(find.byKey(const ValueKey('weekday-header-6')), findsNothing);
    expect(find.byKey(const ValueKey('weekend-activity-toggle')), findsNothing);
  });
  testWidgets('周末有安排可临时展开并收起，换周不继承展开状态', (tester) async {
    final courses = [_course(day: 6, start: 11, end: 12)];
    await tester.pumpWidget(_subject(courses: courses, showWeekends: false));
    await tester.pumpAndSettle();
    expect(find.text('课程1'), findsNothing);
    expect(find.byKey(const ValueKey('section-label-12')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('weekend-activity-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('课程1'), findsOneWidget);
    expect(find.byKey(const ValueKey('weekday-header-7')), findsOneWidget);
    expect(find.byKey(const ValueKey('section-label-12')), findsOneWidget);
    await tester.tap(find.text('收起周末'));
    await tester.pumpAndSettle();
    expect(find.text('课程1'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('weekend-activity-toggle')));
    await tester.pumpAndSettle();
    await tester
        .pumpWidget(_subject(courses: courses, showWeekends: false, week: 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weekday-header-6')), findsNothing);
  });
  testWidgets('周末全天安排展开后可见，时间轴与其他列对齐', (tester) async {
    await tester.pumpWidget(_subject(
        courses: [_course(day: 6)],
        events: [_event(type: 'ddl')],
        showWeekends: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weekend-activity-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('个人安排'), findsOneWidget);
    final courseTop =
        tester.getTopLeft(find.bySemanticsLabel(RegExp('课程1，'))).dy;
    final timeTop =
        tester.getTopLeft(find.byKey(const ValueKey('section-label-1'))).dy;
    expect(courseTop - timeTop, closeTo(2, 1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('显示设置两个开关保存到数据库', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(ProviderScope(overrides: [
      databaseProvider.overrideWithValue(db)
    ], child: const MaterialApp(home: Scaffold(body: ScheduleDisplaySheet()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示周六、周日'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起晚间空白'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
        tester.element(find.byType(ScheduleDisplaySheet)));
    final saved = container.read(scheduleDisplayOptionsProvider).requireValue;
    expect(saved.showWeekends, isFalse);
    expect(saved.trimEmptyEvenings, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('长课名不因楼宇换行被省略，单节卡片仍不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const name = '国际会计审计准则前沿（全英文授课）';
    final source = _course(end: 1);
    final course = CourseEntry(
        course: source.course.copyWith(name: name), slots: source.slots);
    await tester
        .pumpWidget(_subject(courses: [course], trim: false, scale: 1.3));
    await tester.pumpAndSettle();
    final label = tester.widget<Text>(find.text(name));
    expect(label.maxLines, isNull);
    expect(label.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.takeException(), isNull);
  });
  for (final width in [320.0, 390.0]) {
    for (final dark in [false, true]) {
      testWidgets('长楼名先换行，窄屏无溢出 $width dark=$dark', (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_subject(
            courses: [_course(end: 2)],
            scale: 1.3,
            brightness: dark ? Brightness.dark : Brightness.light));
        await tester.pumpAndSettle();
        final building = find.text('经济管理学院MBA教学楼');
        expect(building, findsOneWidget);
        final text = tester.widget<Text>(building);
        expect(text.softWrap, isTrue);
        expect(text.maxLines, isNull);
        final paragraph = tester.renderObject<RenderParagraph>(building);
        expect(paragraph.size.height, greaterThan(15));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
