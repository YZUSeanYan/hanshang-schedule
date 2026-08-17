import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/core/utils/week_calculator.dart';
import 'package:yzu_schedule/features/schedule/data/schedule_repository.dart';
import 'package:yzu_schedule/features/schedule/presentation/course_detail_sheet.dart';

void main() {
  CourseEntry longCourse() {
    final now = DateTime(2026, 8, 12);
    return CourseEntry(
      course: Course(
        id: 1,
        uuid: 'fluid-thermodynamics',
        semesterId: 1,
        name: '流体热力学',
        teacher: '张老师',
        color: 0xFF087B58,
        note: '这是一段较长的课程备注，用于验证小屏幕与大字体下详情区可滚动。长备注末尾标记。',
        updatedAt: now,
      ),
      slots: List.generate(
        10,
        (index) => Schedule(
          id: index + 1,
          uuid: 'slot-$index',
          courseId: 1,
          dayOfWeek: index % 7 + 1,
          startSection: index % 8 + 1,
          endSection: index % 8 + 2,
          weeksType: WeeksType.every,
          customWeeks: '[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18]',
          location: '扬子津东校区文津楼${101 + index}',
          updatedAt: now,
        ),
      ),
    );
  }

  Widget subject({
    double textScale = 1,
    bool disableAnimations = false,
    required VoidCallback onDelete,
    required VoidCallback onEdit,
  }) {
    return MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                showDragHandle: true,
                builder: (_) => CourseDetailSheet(
                  entry: longCourse(),
                  onDelete: onDelete,
                  onEdit: onEdit,
                ),
              ),
              child: const Text('打开详情'),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('小屏幕长详情可滚动且编辑删除始终可达', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var editCount = 0;
    var deleteCount = 0;
    await tester.pumpWidget(
      subject(
        textScale: 2,
        onDelete: () => deleteCount++,
        onEdit: () => editCount++,
      ),
    );

    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('流体热力学'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '删除').hitTestable(), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, '编辑').hitTestable(),
      findsOneWidget,
    );

    final list = tester.widget<ListView>(
      find.byKey(CourseDetailSheet.detailsListKey),
    );
    expect(list.controller, isNotNull);
    expect(list.controller!.offset, 0);

    await tester.drag(
      find.byKey(CourseDetailSheet.detailsListKey),
      const Offset(0, -320),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(CourseDetailSheet.detailsListKey),
      const Offset(0, -320),
    );
    await tester.pumpAndSettle();
    expect(list.controller!.offset, greaterThan(0));
    expect(find.widgetWithText(TextButton, '删除').hitTestable(), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, '编辑').hitTestable(),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, '编辑'));
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    expect(editCount, 1);
    expect(deleteCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('横屏超大字体下标题可滚动且操作按钮不溢出', (tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      subject(textScale: 2, onDelete: () {}, onEdit: () {}),
    );
    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(TextButton, '删除').hitTestable(), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, '编辑').hitTestable(),
      findsOneWidget,
    );

    final listFinder = find.byKey(CourseDetailSheet.detailsListKey);
    final list = tester.widget<ListView>(listFinder);
    await tester.drag(listFinder, const Offset(0, -220));
    await tester.pumpAndSettle();
    await tester.drag(listFinder, const Offset(0, -220));
    await tester.pumpAndSettle();

    expect(list.controller!.offset, greaterThan(0));
    expect(find.widgetWithText(TextButton, '删除').hitTestable(), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, '编辑').hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动态效果时关闭详情弹层吸附动画', (tester) async {
    await tester.pumpWidget(
      subject(disableAnimations: true, onDelete: () {}, onEdit: () {}),
    );
    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();

    final sheet = tester.widget<DraggableScrollableSheet>(
      find.byType(DraggableScrollableSheet),
    );
    expect(sheet.snap, isFalse);
    expect(tester.takeException(), isNull);
  });
}
