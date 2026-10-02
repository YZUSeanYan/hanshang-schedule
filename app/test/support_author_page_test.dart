import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:yzu_schedule/core/network/api_client.dart';
import 'package:yzu_schedule/features/profile/presentation/about_page.dart';
import 'package:yzu_schedule/features/profile/presentation/support_author_page.dart';

class _AboutAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? send,
    Future<void>? cancel,
  ) async {
    final body = jsonEncode({
      'data': {
        'display_name': '测试作者',
        'intro': '测试介绍',
        'website_url': '',
        'avatar_media': '',
        'payment_qr_media': 'qr.png',
        'icp_beian': '',
      }
    });
    return ResponseBody.fromString(body, 200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

GoRouter _testRouter() => GoRouter(
      initialLocation: '/about',
      routes: [
        GoRoute(
          path: '/about',
          builder: (context, state) => const AboutPage(),
        ),
        GoRoute(
          path: '/support-author',
          builder: (context, state) => const SupportAuthorPage(),
        ),
      ],
    );

void main() {
  testWidgets('关于页不再内嵌支持作者入口（已移到「我的」页）', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dioProvider.overrideWithValue(
          Dio(BaseOptions(baseUrl: 'https://example.test'))
            ..httpClientAdapter = _AboutAdapter(),
        ),
      ],
      child: MaterialApp.router(routerConfig: _testRouter()),
    ));
    // 远程清单 provider 里有 600ms 的拉取超时定时器，等它走完再断言
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    // 关于页里不该再有支持作者入口（用户 2026-10-01 决策：移到「我的」页）
    expect(find.text('支持作者'), findsNothing);
    expect(find.text('关于邗上课表'), findsOneWidget);
  });

  testWidgets('支持作者页只展示扫码支持（广告已移除）', (tester) async {
    // 广告代码已整体删除，页面无论构建配置都只应有扫码选项
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dioProvider.overrideWithValue(
          Dio(BaseOptions(baseUrl: 'https://example.test'))
            ..httpClientAdapter = _AboutAdapter(),
        ),
      ],
      child: const MaterialApp(home: SupportAuthorPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('扫码支持'), findsOneWidget);
    expect(find.textContaining('广告'), findsNothing);
  });
}
