import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yzu_schedule/core/settings/section_time_settings.dart';
import 'package:yzu_schedule/features/course_import/presentation/import_page.dart';

/// 「添加」页（设计稿 1/3）的纯布局 widget 测试。
///
/// 只断言不触发 drift 流的静态 UI：四区块标题、五个导入入口、
/// 添加日程输入卡（拍照/图片/识别）、网格卡文字不被截断。
/// 「即将进行」的日程渲染由数据层测试 event_db_test 覆盖，不在此
/// 触发 drift 查询流（provider dispose 的 markAsClosed 定时器与
/// FakeAsync 沙箱冲突，会让 widget 测试不稳定）。
void main() {
  Widget subject() {
    return ProviderScope(
      overrides: [
        sectionTimeConfigProvider.overrideWith(
          (ref) => Stream.value(const SectionTimeConfig.defaults()),
        ),
      ],
      child: const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(412, 900),
            padding: EdgeInsets.only(bottom: 24),
          ),
          child: ImportPage(),
        ),
      ),
    );
  }

  /// 让目标文本滚动进视口后再断言存在（页面是 ListView，下方区块默认屏外）。
  Future<void> expectVisible(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(
      find.text(text),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text(text), findsOneWidget);
  }

  testWidgets('添加页四区块与五个导入入口齐全', (tester) async {
    await tester.pumpWidget(subject());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 顶栏（与其他页面一致的玻璃顶栏：大标题 + 副标题）
    expect(find.text('添加'), findsWidgets);
    expect(find.text('课程与日程，轻松安排。'), findsOneWidget);

    // 导入课表
    expect(find.text('导入课表'), findsOneWidget);
    expect(find.text('选择适合你的导入方式。'), findsOneWidget);
    expect(find.text('截图导入'), findsOneWidget);
    expect(find.text('上传完整课表截图'), findsOneWidget);
    expect(find.text('扬大教务'), findsOneWidget);
    expect(find.text('从教务系统导入'), findsOneWidget);
    expect(find.text('表格导入'), findsOneWidget);
    expect(find.text('上传表格文件导入课表'), findsOneWidget);
    expect(find.text('其他学校教务'), findsOneWidget);
    expect(find.text('分享口令'), findsOneWidget);
    expect(find.text('导入帮助'), findsOneWidget);

    // 添加日程
    await expectVisible(tester, '添加日程');
    await expectVisible(tester, '已接入 AI 识别：自然语言说安排，怎么说都能理解。');
    expect(find.text('手动添加'), findsOneWidget);
    expect(find.text('拍照'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('识别'), findsOneWidget);
    expect(find.text('点底部「语音」按钮，说话就能记日程。'), findsOneWidget);
  });

  testWidgets('识别按钮在输入文字后可点击', (tester) async {
    await tester.pumpWidget(subject());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await expectVisible(tester, '识别');
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('识别'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull); // 无文字时禁用

    await tester.enterText(
      find.widgetWithText(TextField, '例如：明天下午三点，小组讨论。'),
      '明天下午三点图书馆自习',
    );
    await tester.pump();
    final enabled = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('识别'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(enabled.onPressed, isNotNull);
  });

  testWidgets('网格卡文字不被截断（扬大教务/表格导入完整显示）', (tester) async {
    await tester.pumpWidget(subject());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 标题完整可见（不被省略号裁切）
    expect(find.text('扬大教务'), findsOneWidget);
    expect(find.text('表格导入'), findsOneWidget);
    // 扬大卡副标题完整（「推荐」徽章已按产品要求移除）
    expect(find.text('从教务系统导入'), findsOneWidget);
    expect(find.text('推荐'), findsNothing);
    // Excel 副标题完整
    expect(find.text('上传表格文件导入课表'), findsOneWidget);
  });
}
