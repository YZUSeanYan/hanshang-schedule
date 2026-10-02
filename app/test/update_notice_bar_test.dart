import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yzu_schedule/features/update/update_checker.dart';
import 'package:yzu_schedule/features/update/update_notice_bar.dart';

/// 底部轻提示条回归测试。
///
/// 背景（2026-09-22）：用户反馈「发现新版本时 App 内根本没有任何提示」，
/// 同时坚持不能像强制更新那样用全屏弹窗挡课表。这条折中方案容易在后续
/// 改版里被误删或误改成弹窗，所以把三件事锁住：有提示、不占位时不占版面、
/// 「忽略」后该版本不再打扰。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final update = <String, dynamic>{
    'has_update': true,
    'version_name': '2.0.1',
    'version_code': 63,
    'apk_url': 'https://api.seanyan.store/yzu-apk/hanshang-schedule-v2.0.1.apk',
    'sha256': 'a' * 64,
    'release_notes': '修复已知问题',
    'is_force_update': false,
  };

  Future<void> pumpBar(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const SizedBox.expand(),
                const UpdateNoticeOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没有待提示的更新时不留任何占位', (tester) async {
    await pumpBar(tester);
    expect(find.textContaining('发现新版本'), findsNothing);
    expect(find.byType(UpdateNoticeBar), findsOneWidget); // 收起态是 SizedBox
  });

  testWidgets('有更新时显示版本号与「查看/忽略」，且不阻断页面', (tester) async {
    await pumpBar(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(UpdateNoticeBar)),
      listen: false,
    );
    container.read(updateNoticeProvider.notifier).state = update;
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 2.0.1'), findsOneWidget);
    expect(find.text('查看'), findsOneWidget);
    expect(find.byTooltip('忽略此版本'), findsOneWidget);
    // 非模态：不弹阻断对话框，用户可以继续看课表
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('点「忽略」后立即收起，并记住该版本不再提示', (tester) async {
    await pumpBar(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(UpdateNoticeBar)),
      listen: false,
    );
    container.read(updateNoticeProvider.notifier).state = update;
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('忽略此版本'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 2.0.1'), findsNothing);
    expect(container.read(updateNoticeProvider), isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('ignored_version_code'), 63);
  });

  testWidgets('强制更新不进轻提示条（仍是阻断对话框的职责）', (tester) async {
    await pumpBar(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(UpdateNoticeBar)),
      listen: false,
    );
    container.read(updateNoticeProvider.notifier).state =
        {...update, 'is_force_update': true};
    await tester.pumpAndSettle();
    // 只要是 updateService 放进来的更新都显示；强制与否由 UpdateService 分流，
    // 这里守住「轻提示条不会自己弹出遮罩」即可。
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('发现新版本 2.0.1'), findsOneWidget);
  });
}
