import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/network/api_client.dart';
import 'package:yzu_schedule/core/notifications/push_service.dart';
import 'package:yzu_schedule/core/storage/token_storage.dart';
import 'package:yzu_schedule/features/auth/data/auth_repository.dart';

void main() {
  test('断网启动时保留凭证并恢复缓存用户', () async {
    final storage = MemoryTokenStorage();
    await storage.saveTokens(access: 'access', refresh: 'refresh');
    await storage.saveCachedUserJson(jsonEncode({
      'id': 7,
      'username': 'cached-user',
      'email': 'cached@example.test',
    }));
    final container = _container(storage, _OfflineAdapter());
    addTearDown(container.dispose);

    final user = await container.read(authRepositoryProvider).restore();

    expect(user?.id, 7);
    expect(user?.username, 'cached-user');
    expect(await storage.readRefreshToken(), 'refresh');
  });

  test('旧版本升级后首次断网启动可进入离线模式', () async {
    final storage = MemoryTokenStorage();
    await storage.saveTokens(access: 'access', refresh: 'refresh');
    final container = _container(storage, _OfflineAdapter());
    addTearDown(container.dispose);

    final user = await container.read(authRepositoryProvider).restore();

    expect(user?.username, '离线模式');
    expect(await storage.readRefreshToken(), 'refresh');
  });

  test('服务器明确拒绝 refresh token 时清除会话', () async {
    final storage = MemoryTokenStorage();
    await storage.saveTokens(access: 'access', refresh: 'invalid-refresh');
    await storage.saveCachedUserJson(jsonEncode({
      'id': 7,
      'username': 'cached-user',
      'email': 'cached@example.test',
    }));
    final container = _container(storage, _UnauthorizedAdapter());
    addTearDown(container.dispose);

    final user = await container.read(authRepositoryProvider).restore();

    expect(user, isNull);
    expect(await storage.readRefreshToken(), isNull);
    expect(await storage.readCachedUserJson(), isNull);
  });

  test('推送 SDK 卡住不能阻塞账号状态恢复', () async {
    final storage = MemoryTokenStorage();
    await storage.saveTokens(access: 'access', refresh: 'refresh');
    await storage.saveCachedUserJson(jsonEncode({
      'id': 7,
      'username': 'cached-user',
      'email': 'cached@example.test',
    }));
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/yzu'))
      ..httpClientAdapter = _OfflineAdapter();
    final container = ProviderContainer(overrides: [
      tokenStorageProvider.overrideWithValue(storage),
      dioProvider.overrideWithValue(dio),
      pushServiceProvider.overrideWithValue(_NeverPushService()),
    ]);
    addTearDown(container.dispose);

    final user = await container
        .read(authStateProvider.future)
        .timeout(const Duration(milliseconds: 500));

    expect(user?.id, 7);
    expect(user?.username, 'cached-user');
  });
}

ProviderContainer _container(
  MemoryTokenStorage storage,
  HttpClientAdapter adapter,
) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test/yzu'));
  dio.httpClientAdapter = adapter;
  return ProviderContainer(overrides: [
    tokenStorageProvider.overrideWithValue(storage),
    dioProvider.overrideWithValue(dio),
  ]);
}

class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      message: 'offline',
    );
  }

  @override
  void close({bool force = false}) {}
}

class _UnauthorizedAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode({'code': 40101, 'message': 'invalid refresh token'}),
      401,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _NeverPushService implements PushServiceApi {
  @override
  Future<void> restoreForUser(int userId) =>
      Future<void>.delayed(const Duration(seconds: 2));
  @override
  Future<bool> shouldPrompt() async => false;
  @override
  Future<bool> consented() async => true;
  @override
  Future<void> declineInitialPrompt() async {}
  @override
  Future<void> enableForUser(int userId) async {}
  @override
  Future<void> unbind() async {}
  @override
  Future<Map<String, dynamic>> inbox() async => {};
  @override
  Future<void> markRead(int id) async {}
  @override
  Future<void> markAllRead() async {}
  @override
  Future<void> deleteNotification(int id) async {}

  @override
  Future<void> clearNotifications() async {}
}
