import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yzu_schedule/app.dart';
import 'package:yzu_schedule/core/network/api_client.dart';
import 'package:yzu_schedule/core/notifications/push_service.dart';
import 'package:yzu_schedule/core/storage/credential_vault_key_storage.dart';
import 'package:yzu_schedule/core/storage/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // 隐私门禁：所有 widget 测试预置“已同意”，直接进入业务路由
  setUpAll(() {
    SharedPreferences.setMockInitialValues({'privacy_consented_at': 1});
  });

  /// 未登录时（空 token 存储），路由守卫应把用户带到登录页
  testWidgets('未登录启动进入登录页', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStorageProvider.overrideWithValue(MemoryTokenStorage())
        ],
        child: const YzuScheduleApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 登录页元素
    expect(find.text('邗上课表'), findsOneWidget);
    expect(find.text('用户名或邮箱'), findsOneWidget);
    expect(find.text('登录'), findsWidgets);
    expect(find.text('没有账号？去注册'), findsOneWidget);
    expect(find.text('忘记密码'), findsOneWidget);
  });

  testWidgets('登录页可切换到注册模式', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStorageProvider.overrideWithValue(MemoryTokenStorage())
        ],
        child: const YzuScheduleApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('没有账号？去注册'));
    await tester.pumpAndSettle();

    // 注册模式多出 用户名 / 邮箱 字段
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('注册并登录'), findsOneWidget);
  });

  testWidgets('首次登录后不再弹通知推荐（已按需求移除）', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/yzu'))
      ..httpClientAdapter = _LoginAdapter();
    final push = _PromptPushService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStorageProvider.overrideWithValue(MemoryTokenStorage()),
          credentialVaultKeyStorageProvider.overrideWithValue(
            MemoryCredentialVaultKeyStorage(),
          ),
          dioProvider.overrideWithValue(dio),
          pushServiceProvider.overrideWithValue(push),
        ],
        child: const YzuScheduleApp(),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'prompt-user');
    await tester.enterText(fields.at(1), 'password123');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('及时接收课程与账户通知').evaluate().isNotEmpty) break;
    }

    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('及时接收课程与账户通知'), findsNothing);
    expect(push.enabledUserId, isNull);
  });
}

class _LoginAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/api/auth/login')) {
      return ResponseBody.fromString(
        jsonEncode({
          'code': 0,
          'message': 'ok',
          'data': {
            'access_token': 'access',
            'refresh_token': 'refresh',
            'user': {
              'id': 7,
              'username': 'prompt-user',
              'email': 'prompt@example.test',
            },
          },
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({'code': 50300, 'message': 'offline in widget test'}),
      503,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _PromptPushService implements PushServiceApi {
  int? enabledUserId;

  @override
  Future<bool> shouldPrompt() async => true;

  @override
  Future<bool> consented() async => false;

  @override
  Future<void> declineInitialPrompt() async {}

  @override
  Future<void> enableForUser(int userId) async => enabledUserId = userId;

  @override
  Future<void> restoreForUser(int userId) async {}

  @override
  Future<void> unbind() async {}

  @override
  Future<Map<String, dynamic>> inbox() async => const {};

  @override
  Future<void> markRead(int id) async {}

  @override
  Future<void> markAllRead() async {}
  @override
  Future<void> deleteNotification(int id) async {}

  @override
  Future<void> clearNotifications() async {}
}
