import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/features/share/data/share_repository.dart';

void main() {
  test('分享口令请求使用生产 API 的 /api/share/create 路由', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/yzu'));
    final adapter = _RecordingAdapter();
    dio.httpClientAdapter = adapter;

    final code = await ShareRepository(dio).create('semester-uuid');

    expect(adapter.path, '/yzu/api/share/create');
    expect(adapter.body, contains('semester-uuid'));
    expect(code.code, 'K7M2QP');
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  String? path;
  String? body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    path = options.uri.path;
    body = jsonEncode(options.data);
    return ResponseBody.fromString(
      jsonEncode({
        'code': 0,
        'message': 'ok',
        'data': {'code': 'K7M2QP', 'expires_at': '2026-08-17T00:00:00'},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
