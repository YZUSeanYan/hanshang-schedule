import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/storage/token_storage.dart';
import '../../../core/storage/credential_vault_key_storage.dart';
import '../../../core/notifications/push_service.dart';

/// 当前登录用户
class AuthUser {
  const AuthUser(
      {required this.id, required this.username, required this.email});

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: json['id'] as int,
        username: json['username'] as String,
        email: json['email'] as String,
      );

  factory AuthUser.offlineFallback() => const AuthUser(
        id: 0,
        username: '离线模式',
        email: '联网后将自动恢复账号信息',
      );

  final int id;
  final String username;
  final String email;

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'email': email,
      };
}

/// 认证仓库：注册/登录/恢复会话/退出。
class AuthRepository {
  AuthRepository(this._ref);

  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  TokenStorage get _storage => _ref.read(tokenStorageProvider);
  CredentialVaultKeyStorage get _vaultKeyStorage =>
      _ref.read(credentialVaultKeyStorageProvider);

  /// 启动时恢复会话：有 refresh token 则换新并拉取个人信息，否则视为未登录。
  Future<AuthUser?> restore() async {
    final refresh = await _storage.readRefreshToken();
    if (refresh == null) return null;
    final cachedUser = await _readCachedUser();
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/api/auth/refresh',
        data: {'refresh_token': refresh},
      );
      await _saveTokens(resp.data!['data'] as Map<String, dynamic>);
      final user = await _fetchProfile();
      await _cacheUser(user);
      return user;
    } on DioException catch (error) {
      if (_isDefinitiveAuthFailure(error)) {
        await _storage.clear();
        return null;
      }
      if (_canUseOfflineSession(error)) {
        return cachedUser ?? AuthUser.offlineFallback();
      }
      return null;
    }
  }

  Future<AuthUser> login(String account, String password) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '/api/auth/login',
      data: {'account': account, 'password': password},
    );
    final data = resp.data!['data'] as Map<String, dynamic>;
    await _saveTokens(data);
    final user = AuthUser.fromJson(data['user'] as Map<String, dynamic>);
    await _cacheUser(user);
    await _vaultKeyStorage.deriveAndSave(password: password, userId: user.id);
    return user;
  }

  Future<AuthUser> register(
      String username, String email, String password) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '/api/auth/register',
      data: {'username': username, 'email': email, 'password': password},
    );
    final data = resp.data!['data'] as Map<String, dynamic>;
    await _saveTokens(data);
    final user = AuthUser.fromJson(data['user'] as Map<String, dynamic>);
    await _cacheUser(user);
    await _vaultKeyStorage.deriveAndSave(password: password, userId: user.id);
    return user;
  }

  /// 发送重置密码验证码
  Future<void> sendResetCode(String email) async {
    await _dio.post<void>('/api/auth/forgot-password', data: {'email': email});
  }

  /// 凭验证码重置密码
  Future<void> resetPassword(
      String email, String code, String newPassword) async {
    await _dio.post<void>('/api/auth/reset-password', data: {
      'email': email,
      'code': code,
      'new_password': newPassword,
    });
  }

  Future<void> logout() async {
    await _storage.clear();
    await _vaultKeyStorage.clear();
  }

  Future<AuthUser> _fetchProfile() async {
    final resp = await _dio.get<Map<String, dynamic>>('/api/user/profile');
    return AuthUser.fromJson(resp.data!['data'] as Map<String, dynamic>);
  }

  Future<void> _saveTokens(Map<String, dynamic> data) => _storage.saveTokens(
        access: data['access_token'] as String,
        refresh: data['refresh_token'] as String,
      );

  Future<void> _cacheUser(AuthUser user) =>
      _storage.saveCachedUserJson(jsonEncode(user.toJson()));

  Future<AuthUser?> _readCachedUser() async {
    final raw = await _storage.readCachedUserJson();
    if (raw == null) return null;
    try {
      return AuthUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  bool _isDefinitiveAuthFailure(DioException error) {
    final status = error.response?.statusCode;
    return status == 400 || status == 401 || status == 403;
  }

  bool _canUseOfflineSession(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return status == 408 || status == 429 || status >= 500;
    }
    return error.type != DioExceptionType.cancel;
  }
}

final authRepositoryProvider =
    Provider<AuthRepository>((ref) => AuthRepository(ref));

/// 认证状态：null = 未登录；非 null = 已登录用户。
/// 路由守卫监听本状态自动在 登录页/主页 间切换。
class AuthState extends AsyncNotifier<AuthUser?> {
  @override
  Future<AuthUser?> build() async {
    final user = await ref.read(authRepositoryProvider).restore();
    if (user != null && user.id > 0) {
      // 账号恢复是 T0 主链路，绝不能等待第三方推送 SDK。推送失败或卡住
      // 只影响系统通知，不影响用户登录态、课表和“我的”页面。
      unawaited(ref.read(pushServiceProvider).restoreForUser(user.id).catchError((_) {}));
    }
    return user;
  }

  /// 登录。返回 null 表示成功，否则为错误提示文案。
  Future<String?> login(String account, String password) async {
    try {
      final user = await ref.read(authRepositoryProvider).login(account, password);
      state = AsyncData(user);
      unawaited(ref.read(pushServiceProvider).restoreForUser(user.id).catchError((_) {}));
      return null;
    } on DioException catch (e) {
      return apiErrorMessage(e, fallback: '登录失败');
    }
  }

  /// 注册（成功后自动登录）。返回 null 表示成功。
  Future<String?> register(
      String username, String email, String password) async {
    try {
      final user = await ref
          .read(authRepositoryProvider)
          .register(username, email, password);
      state = AsyncData(user);
      unawaited(ref.read(pushServiceProvider).restoreForUser(user.id).catchError((_) {}));
      return null;
    } on DioException catch (e) {
      return apiErrorMessage(e, fallback: '注册失败');
    }
  }

  Future<void> logout() async {
    try {
      await ref.read(pushServiceProvider).unbind();
    } catch (_) {
      // 第三方推送解绑失败不能阻止本地账号安全退出。
    } finally {
      await ref.read(authRepositoryProvider).logout();
      state = const AsyncData(null);
    }
  }
}

final authStateProvider =
    AsyncNotifierProvider<AuthState, AuthUser?>(AuthState.new);
