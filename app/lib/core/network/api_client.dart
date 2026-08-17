import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../storage/token_storage.dart';

/// 全局 Dio 实例：统一 baseUrl、超时、JWT 拦截器。
final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );
  dio.interceptors.add(AuthInterceptor(ref));
  return dio;
});

/// JWT 拦截器：自动附带 access token；401 时用 refresh token 换新并重试。
///
/// 继承 QueuedInterceptor：并发请求同时遇到 401 时串行处理，避免重复刷新。
class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor(this._ref);

  final Ref _ref;

  /// 无拦截器的裸客户端：专门用于刷新 token，防止拦截器套娃
  final Dio _rawDio = Dio(
    BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  bool _isAuthFree(String path) =>
      path.startsWith('/api/auth/login') ||
      path.startsWith('/api/auth/register') ||
      path.startsWith('/api/auth/refresh') ||
      path.startsWith('/api/auth/forgot-password') ||
      path.startsWith('/api/auth/reset-password');

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!_isAuthFree(options.path)) {
      final token = await _ref.read(tokenStorageProvider).readAccessToken();
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // 只处理业务接口的 401；认证接口自身的 401 直接抛给调用方
    if (err.response?.statusCode != 401 ||
        _isAuthFree(err.requestOptions.path)) {
      handler.next(err);
      return;
    }

    final storage = _ref.read(tokenStorageProvider);
    final refreshToken = await storage.readRefreshToken();
    if (refreshToken == null) {
      handler.next(err);
      return;
    }

    try {
      // 用 refresh token 换新 token 对
      final resp = await _rawDio.post<Map<String, dynamic>>(
        '/api/auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      final data = resp.data?['data'] as Map<String, dynamic>;
      await storage.saveTokens(
        access: data['access_token'] as String,
        refresh: data['refresh_token'] as String,
      );

      // 带上新 token 重放原请求
      final options = err.requestOptions;
      options.headers['Authorization'] = 'Bearer ${data['access_token']}';
      final retryResp = await _rawDio.fetch<dynamic>(options);
      handler.resolve(retryResp);
    } on DioException catch (refreshError) {
      // 只有服务器明确拒绝 refresh token 时才注销。断网或服务器暂时
      // 不可用时保留本地凭证，让已登录用户继续使用离线课表。
      final status = refreshError.response?.statusCode;
      if (status == 400 || status == 401 || status == 403) {
        await storage.clear();
      }
      handler.next(err);
    }
  }
}

/// 从 DioException 提取服务端统一错误信息 {code, message}
String apiErrorMessage(Object error, {String fallback = '网络异常，请稍后重试'}) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map<String, dynamic> && data['message'] is String) {
      return data['message'] as String;
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError) {
      return '无法连接服务器，请检查网络';
    }
  }
  return fallback;
}
