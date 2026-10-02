import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/database/app_database.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/token_storage.dart';
import '../../../core/notifications/push_service.dart';
import '../../schedule/data/schedule_repository.dart';

/// 当前登录用户
class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.email,
    this.avatarMedia = '',
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: json['id'] as int,
        username: json['username'] as String,
        email: json['email'] as String,
        avatarMedia: json['avatar_media'] as String? ?? '',
      );

  factory AuthUser.offlineFallback() => const AuthUser(
        id: 0,
        username: '离线模式',
        email: '联网后将自动恢复账号信息',
      );

  final int id;
  final String username;
  final String email;

  /// 头像文件名（服务端 uploads/avatars/ 下），空=首字母默认头像
  final String avatarMedia;

  AuthUser copyWith({String? username, String? avatarMedia}) => AuthUser(
        id: id,
        username: username ?? this.username,
        email: email,
        avatarMedia: avatarMedia ?? this.avatarMedia,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'email': email,
        'avatar_media': avatarMedia,
      };
}

/// 认证仓库：注册/登录/恢复会话/退出。
class AuthRepository {
  AuthRepository(this._ref);

  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  TokenStorage get _storage => _ref.read(tokenStorageProvider);

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
    await _ensureLocalDataIsolated(user.id);
    await _cacheUser(user);
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
    await _ensureLocalDataIsolated(user.id);
    await _cacheUser(user);
    return user;
  }

  /// 账号数据隔离（同设备切换账号的防串号）。
  ///
  /// 本地数据库是全局单库（按设备不按账号）：若当前登录账号与上次记录的
  /// 账号不同，必须先清空本地全部业务表 + 重置同步游标，再让新账号从
  /// 云端全量 pull。否则旧账号的本地数据会显示给新账号，且新账号的删除
  /// 操作会以墓碑推送到旧账号云端（数据安全 P0）。
  Future<void> _ensureLocalDataIsolated(int newUserId) async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'last_logged_in_user_id';
    final previous = prefs.getInt(key);
    if (previous == newUserId) return;
    await _wipeLocalDataForAccountSwitch();
    await prefs.setInt(key, newUserId);
  }

  /// 清空本地全部业务数据（账号切换时调用，调用方负责先确认账号已变更）。
  ///
  /// 连带删除 pendingDeletions 墓碑队列：旧账号的墓碑绝不能随新账号的
  /// 首次同步推送到云端（那会误删旧账号云端数据）。同步游标清零，让新
  /// 账号从 0 全量拉取自己的数据。
  ///
  /// 同时写入新的 session_epoch（review R01）：所有在途同步在各自提交点
  /// 核对代次，对不上立即放弃——登录清库无法阻止已经挂起的网络响应，
  /// 代次校验才能保证旧账号的迟到数据绝不落进新账号的库。
  Future<void> _wipeLocalDataForAccountSwitch() async {
    final db = _ref.read(databaseProvider);
    await db.transaction(() async {
      await db.delete(db.localEvents).go();
      await db.delete(db.schedules).go();
      await db.delete(db.courses).go();
      await db.delete(db.semesters).go();
      await db.delete(db.pendingDeletions).go();
      await db.delete(db.settingsEntries).go();
      await db.delete(db.syncStates).go();
      await db.delete(db.scheduleOverrides).go(); // v6 新表，切号必须一并清（review R02）
      // 会话代次：旧同步的 _capturedEpoch 与之不同即失效
      await db.into(db.settingsEntries).insert(
            SettingsEntriesCompanion.insert(
              key: 'session_epoch',
              value: DateTime.now().millisecondsSinceEpoch.toString(),
            ),
          );
    });
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
  }

  /// 修改用户名（昵称），返回更新后的用户
  Future<AuthUser> updateUsername(String username) async {
    final resp = await _dio.patch<Map<String, dynamic>>(
      '/api/user/profile',
      data: {'username': username},
    );
    final user = AuthUser.fromJson(resp.data!['data'] as Map<String, dynamic>);
    await _cacheUser(user);
    return user;
  }

  /// 上传头像（图片字节），返回更新后的头像文件名
  Future<String> uploadAvatar(List<int> bytes, String filename) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final resp = await _dio.post<Map<String, dynamic>>(
      '/api/user/avatar',
      data: form,
    );
    final name =
        (resp.data!['data'] as Map<String, dynamic>)['avatar_media'] as String;
    final refreshed = await _fetchProfile();
    await _cacheUser(refreshed);
    return name;
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

  /// 修改用户名（昵称）。返回 null 表示成功，否则为错误提示。
  Future<String?> updateUsername(String username) async {
    try {
      final user =
          await ref.read(authRepositoryProvider).updateUsername(username);
      state = AsyncData(user);
      return null;
    } on DioException catch (e) {
      return apiErrorMessage(e, fallback: '修改失败');
    } catch (_) {
      return '修改失败，请稍后重试';
    }
  }

  /// 上传头像。返回 null 表示成功。
  Future<String?> updateAvatar(List<int> bytes, String filename) async {
    final current = state.valueOrNull;
    try {
      final name =
          await ref.read(authRepositoryProvider).uploadAvatar(bytes, filename);
      if (current != null) {
        state = AsyncData(current.copyWith(avatarMedia: name));
      }
      return null;
    } on DioException catch (e) {
      return apiErrorMessage(e, fallback: '头像上传失败');
    } catch (_) {
      return '头像上传失败，请稍后重试';
    }
  }
}

final authStateProvider =
    AsyncNotifierProvider<AuthState, AuthUser?>(AuthState.new);
