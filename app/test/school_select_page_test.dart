import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yzu_schedule/core/remote_features/remote_feature_manifest.dart';
import 'package:yzu_schedule/core/remote_features/remote_feature_providers.dart';
import 'package:yzu_schedule/features/course_import/data/import_runtime.dart';
import 'package:yzu_schedule/features/course_import/data/import_runtime_provider.dart';
import 'package:yzu_schedule/features/course_import/data/school_directory.dart';
import 'package:yzu_schedule/features/course_import/presentation/school_select_page.dart';

/// 学校选择页（其他学校教务）的 widget 测试。
///
/// 覆盖：内置种子名单的分组与教务系统标注、搜索过滤、远程下发名单
/// 覆盖内置名单（免发版扩展）、import-runtime 按校目录的优先级/去重/
/// 「已适配」标注，以及 schoolInitial 的首字母映射。
void main() {
  Widget subject({RemoteFeatureManifest? manifest, ImportRuntime? runtime}) {
    return ProviderScope(
      overrides: [
        // 统一 override 掉真实 manifest provider：它内部有 600ms 定时器，
        // 会在测试树销毁后泄漏 pending timer。内置名单测试用空 manifest
        // （schoolDirectory=null → 页面回落内置种子名单）。
        remoteFeatureManifestProvider.overrideWith(
          (ref) => Stream.value(
            manifest ??
                RemoteFeatureManifest(
                  revision: 0,
                  issuedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
                  expiresAt:
                      DateTime.fromMillisecondsSinceEpoch(86400000000, isUtc: true),
                  privacyPolicy: bundledPrivacyPolicy,
                  modules: const [],
                ),
          ),
        ),
        if (runtime != null)
          importRuntimeProvider.overrideWith((ref) async => runtime),
      ],
      child: const MaterialApp(home: SchoolSelectPage()),
    );
  }

  testWidgets('默认展示内置名单：分组字母、学校与教务系统标注', (tester) async {
    await tester.pumpWidget(subject());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('在搜索框输入学校全称以快速定位'), findsOneWidget);
    // 搜索框
    expect(find.widgetWithText(TextField, '搜索学校'), findsOneWidget);
    // 屏内直接断言：A 组第一个学校与教务标注
    expect(find.text('安庆师范大学'), findsOneWidget);
    expect(find.text('新URP'), findsWidgets);
    expect(find.text('安康学院'), findsOneWidget);
    expect(find.text('正方教务'), findsWidgets);
    // 拖到底部 X 组：扬州大学广陵学院与 URP系统
    await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
    await tester.pump();
    await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
    await tester.pump();
    expect(find.text('扬州大学广陵学院'), findsOneWidget);
    expect(find.text('URP系统'), findsOneWidget);
    // 分组字母（安→A、扬/盐/西/徐→X、中/浙→Z）
    expect(find.text('A'), findsWidgets);
    expect(find.text('X'), findsWidgets);
  });

  testWidgets('搜索过滤学校名称', (tester) async {
    await tester.pumpWidget(subject());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(
      find.widgetWithText(TextField, '搜索学校'),
      '扬州',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('扬州大学广陵学院'), findsOneWidget);
    expect(find.text('安康学院'), findsNothing);
  });

  testWidgets('远程下发名单覆盖内置名单（免发版扩展）', (tester) async {
    final manifest = RemoteFeatureManifest(
      revision: 1,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(86400000000, isUtc: true),
      privacyPolicy: bundledPrivacyPolicy,
      modules: const [],
      schoolDirectory: const [
        SchoolDirectoryEntry(
          name: '测试大学',
          url: 'https://jwxt.test.edu.cn',
          system: '新URP',
        ),
      ],
    );
    await tester.pumpWidget(subject(manifest: manifest));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 远程名单生效
    expect(find.text('测试大学'), findsOneWidget);
    expect(find.text('新URP'), findsOneWidget);
    // 内置名单不再显示
    expect(find.text('扬州大学广陵学院'), findsNothing);
  });

  testWidgets('runtime 按校目录优先：已适配标注、legacy 合并、按 host 去重', (tester) async {
    final manifest = RemoteFeatureManifest(
      revision: 1,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(86400000000, isUtc: true),
      privacyPolicy: bundledPrivacyPolicy,
      modules: const [],
      schoolDirectory: const [
        // 与 runtime 中「测试大学」同 host：应被 runtime 覆盖，不得重复出现
        SchoolDirectoryEntry(
            name: '旧目录的测试大学', url: 'https://jwxt.test.edu.cn', system: '旧通道'),
        SchoolDirectoryEntry(
            name: '仅旧目录的学校', url: 'https://legacy-only.edu.cn', system: '正方教务'),
      ],
    );
    const runtime = ImportRuntime(
      revision: 2,
      schools: [
        RuntimeSchool(
            name: '测试大学',
            url: 'https://jwxt.test.edu.cn',
            system: '正方教务',
            guide: '登录后进入课表页'),
        RuntimeSchool(name: '无适配学校', url: 'https://plain.edu.cn', system: 'URP'),
      ],
    );
    await tester.pumpWidget(subject(manifest: manifest, runtime: runtime));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // runtime 目录生效且带「已适配」标注（仅 guide/hints 非空的学校）
    expect(find.text('测试大学'), findsOneWidget);
    expect(find.text('已适配'), findsOneWidget);
    // 同 host 的旧目录条目被去重，host 不同的旧条目被合并进名单
    expect(find.text('旧目录的测试大学'), findsNothing);
    expect(find.text('仅旧目录的学校'), findsOneWidget);
    expect(find.text('无适配学校'), findsOneWidget);
    // 内置名单合并显示（runtime 未覆盖的学校）
    expect(find.text('安庆师范大学'), findsOneWidget);
  });

  testWidgets('runtime 条目自带首字母：生僻校名按 initial 落组而非 #', (tester) async {
    const runtime = ImportRuntime(
      revision: 2,
      schools: [
        // 「重庆」不在客户端内置拼音粗查表的高频组里也能正确落 C 组
        RuntimeSchool(
            name: '重庆城市科技学院',
            url: 'https://jw.cqcst.edu.cn',
            system: '强智',
            initial: 'C',
            guide: '登录后任意页面点运行'),
      ],
    );
    await tester.pumpWidget(subject(runtime: runtime));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('重庆城市科技学院'), findsOneWidget);
    expect(find.text('已适配'), findsOneWidget);
    // C 分组标题存在（若落 # 组则不存在）
    expect(find.text('C'), findsWidgets);
  });

  test('schoolInitial 首字母映射', () {
    expect(schoolInitial('安康学院'), 'A');
    expect(schoolInitial('扬州大学广陵学院'), 'X');
    expect(schoolInitial('南京大学'), 'N');
    expect(schoolInitial('苏州大学'), 'S');
    expect(schoolInitial('中国矿业大学'), 'Z');
    expect(schoolInitial('ABC学院'), 'A');
    expect(schoolInitial(''), '#');
  });

  test('内置名单 URL 均为 https 且学校名非空', () {
    for (final s in kSchoolDirectory) {
      expect(s.name, isNotEmpty);
      expect(s.url.startsWith('https://'), isTrue, reason: s.name);
    }
  });
}
