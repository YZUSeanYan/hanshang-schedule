import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'secure_storage_config.dart';

/// Token 存储抽象：便于测试时替换为内存实现。
abstract class TokenStorage {
  Future<String?> readAccessToken();
  Future<String?> readRefreshToken();
  Future<String?> readCachedUserJson();
  Future<void> saveTokens({required String access, required String refresh});
  Future<void> saveCachedUserJson(String value);
  Future<void> clear();
}

/// 生产实现：系统安全存储（Android Keystore / iOS Keychain）。
class SecureTokenStorage implements TokenStorage {
  static const _storage = appSecureStorage;
  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';
  static const _kCachedUser = 'cached_auth_user_v1';

  @override
  Future<String?> readAccessToken() => _storage.read(key: _kAccess);

  @override
  Future<String?> readRefreshToken() => _storage.read(key: _kRefresh);

  @override
  Future<String?> readCachedUserJson() => _storage.read(key: _kCachedUser);

  @override
  Future<void> saveTokens(
      {required String access, required String refresh}) async {
    await _storage.write(key: _kAccess, value: access);
    await _storage.write(key: _kRefresh, value: refresh);
  }

  @override
  Future<void> saveCachedUserJson(String value) =>
      _storage.write(key: _kCachedUser, value: value);

  @override
  Future<void> clear() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kCachedUser);
  }
}

/// 测试实现：内存存储。
class MemoryTokenStorage implements TokenStorage {
  String? access;
  String? refresh;
  String? cachedUserJson;

  @override
  Future<String?> readAccessToken() async => access;

  @override
  Future<String?> readRefreshToken() async => refresh;

  @override
  Future<String?> readCachedUserJson() async => cachedUserJson;

  @override
  Future<void> saveTokens(
      {required String access, required String refresh}) async {
    this.access = access;
    this.refresh = refresh;
  }

  @override
  Future<void> saveCachedUserJson(String value) async {
    cachedUserJson = value;
  }

  @override
  Future<void> clear() async {
    access = null;
    refresh = null;
    cachedUserJson = null;
  }
}

final tokenStorageProvider =
    Provider<TokenStorage>((ref) => SecureTokenStorage());
