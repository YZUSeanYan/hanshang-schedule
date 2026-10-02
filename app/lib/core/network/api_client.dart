import 'dart:typed_data';

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
  /// [baseUrl] 仅供测试注入：裸客户端（refresh 用）默认跟随生产 baseUrl，
  /// 测试里主 Dio 与裸 Dio 必须指向同一个回环服务。
  AuthInterceptor(this._ref, {String? baseUrl}) : _baseUrl = baseUrl {
    _rawDio = Dio(
      BaseOptions(
        baseUrl: _baseUrl ?? AppConfig.apiBaseUrl,
        connectTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
  }

  final Ref _ref;
  final String? _baseUrl;

  /// 无拦截器的裸客户端：专门用于刷新 token，防止拦截器套娃
  late final Dio _rawDio;

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
    // multipart 重放快照（review R18）：FormData 的文件流是一次性的，
    // 401 刷新后直接重放会失败。这里在首次发送前把文件字节读进内存，
    // 存成可重建的工厂，重放时生成全新的 FormData。只对 10MB 以内的
    // 小文件做快照（现有调用是头像/截图），超大文件退化为不重放。
    if (options.data is FormData) {
      final snapshot = await _snapshotFormData(options.data as FormData);
      if (snapshot != null) {
        options.extra['__rebuildable_form'] = snapshot;
        // 快照消费了原始文件流，发送必须用重建出的新 FormData
        options.data = snapshot.rebuild();
      }
    }
    handler.next(options);
  }

  /// 把 FormData 的字段与文件字节快照成可重建的工厂；超出大小上限返回
  /// null（该请求放弃 401 重放能力）。文件流在快照时被消费，发送用的
  /// FormData 会在快照成功后被替换成新建实例。
  static Future<_FormDataSnapshot?> _snapshotFormData(FormData form) async {
    try {
      final fields = [for (final f in form.fields) MapEntry(f.key, f.value)];
      final files = <_FilePart>[];
      var totalBytes = 0;
      for (final entry in form.files) {
        final file = entry.value;
        final builder = BytesBuilder(copy: false);
        await for (final chunk in file.finalize()) {
          builder.add(chunk);
          totalBytes += chunk.length;
          if (totalBytes > _maxReplayableFormBytes) return null;
        }
        final bytes = builder.takeBytes();
        files.add(_FilePart(
          field: entry.key,
          bytes: bytes,
          // 延迟重建：contentType/headers 等元信息由原文件对象携带，
          // 这里不重复声明类型，交由闭包捕获
          makeFile: () => MultipartFile.fromBytes(
            bytes,
            filename: file.filename,
            contentType: file.contentType,
            headers: file.headers,
          ),
        ));
      }
      return _FormDataSnapshot(fields: fields, files: files);
    } on Object {
      // 流读取失败就按原样发送，只是失去重放能力
      return null;
    }
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

    String accessToken;
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
      accessToken = data['access_token'] as String;
    } on DioException catch (refreshError) {
      // 只有服务器明确拒绝 refresh token 时才注销。断网或服务器暂时
      // 不可用时保留本地凭证，让已登录用户继续使用离线课表。
      final status = refreshError.response?.statusCode;
      if (status == 400 || status == 401 || status == 403) {
        await storage.clear();
      }
      handler.next(err);
      return;
    }

    // 刷新成功后重放原请求（review R17）：重放的错误必须与刷新分开
    // 处理——重放返回的业务 400/403 是真实的业务校验失败，既不能把它
    // 当成"refresh 被拒"清掉刚换来的有效 token，也不能把它伪装成 401。
    final options = err.requestOptions;
    options.headers['Authorization'] = 'Bearer $accessToken';
    final snapshot = options.extra['__rebuildable_form'];
    if (snapshot is _FormDataSnapshot) {
      options.data = snapshot.rebuild();
    }
    try {
      final retryResp = await _rawDio.fetch<dynamic>(options);
      handler.resolve(retryResp);
    } on DioException catch (replayError) {
      handler.next(replayError);
    }
  }
}

/// FormData 的内存快照（review R18）：401 刷新成功后用 [rebuild]
/// 生成全新 FormData 重放，绕开文件流只能消费一次的限制。
class _FormDataSnapshot {
  _FormDataSnapshot({required this.fields, required this.files});

  final List<MapEntry<String, String>> fields;
  final List<_FilePart> files;

  FormData rebuild() => FormData()
    ..fields.addAll(fields)
    ..files.addAll([for (final f in files) MapEntry(f.field, f.makeFile())]);
}

class _FilePart {
  _FilePart({
    required this.field,
    required this.bytes,
    required this.makeFile,
  });

  final String field;
  final Uint8List bytes;
  final MultipartFile Function() makeFile;
}

const _maxReplayableFormBytes = 10 * 1024 * 1024;

/// 从 DioException 提取服务端统一错误信息 {code, message}
String apiErrorMessage(Object error, {String fallback = '网络异常，请稍后重试'}) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map<String, dynamic> && data['message'] is String) {
      return data['message'] as String;
    }
    if (data is Map &&
        data['detail'] is Map &&
        (data['detail'] as Map)['message'] is String) {
      return (data['detail'] as Map)['message'] as String;
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError) {
      return '无法连接服务器，请检查网络';
    }
    if (error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      // 明确告知是超时而非"识别失败"，用户知道该重试还是换网络
      return '服务器响应超时了，请重试一次';
    }
    final status = error.response?.statusCode;
    if (status == 502 || status == 503) {
      return '识别服务暂时不可用，请稍后重试';
    }
    if (status == 504) {
      return '服务器处理超时，请重试一次';
    }
    if (status == 413) {
      return '文件或内容太大了，请精简后重试';
    }
  }
  return fallback;
}
