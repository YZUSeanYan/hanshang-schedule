import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/features/sync/data/sync_repository.dart';

void main() {
  test('同步请求使用服务端实际的 /api 路由', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/yzu'));
    final adapter = _RecordingAdapter();
    dio.httpClientAdapter = adapter;

    await SyncRepository(db, dio).sync();

    expect(adapter.paths, ['/yzu/api/sync/push', '/yzu/api/sync/pull']);
    await db.close();
  });

  test('拉取到两个当前学期时立即本地自愈并回传云端', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/yzu'));
    final adapter = _RecordingAdapter(pullSemesters: [
      {
        'uuid': 'sem-old',
        'name': '2026春',
        'start_date': '2026-02-23',
        'total_weeks': 20,
        'is_current': true,
        'updated_at': 1000,
        'deleted': false,
      },
      {
        'uuid': 'sem-new',
        'name': '2026秋',
        'start_date': '2026-08-31',
        'total_weeks': 20,
        'is_current': true,
        'updated_at': 2000,
        'deleted': false,
      },
    ]);
    dio.httpClientAdapter = adapter;

    await SyncRepository(db, dio).sync();

    final semesters = await db.select(db.semesters).get();
    expect(semesters, hasLength(2));
    expect(semesters.where((row) => row.isCurrent).single.uuid, 'sem-new');
    expect(adapter.paths,
        ['/yzu/api/sync/push', '/yzu/api/sync/pull', '/yzu/api/sync/push']);
    final repaired = adapter.pushPayloads.last['semesters'] as List;
    expect(repaired.where((item) => item['is_current'] == true), hasLength(1));
    expect(
      repaired.singleWhere((item) => item['uuid'] == 'sem-old')['is_current'],
      isFalse,
    );
    await db.close();
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.pullSemesters = const []});

  final List<Map<String, dynamic>> pullSemesters;
  final paths = <String>[];
  final pushPayloads = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    if (options.uri.path.endsWith('/push')) {
      pushPayloads.add(Map<String, dynamic>.from(options.data as Map));
    }
    final data = options.uri.path.endsWith('/push')
        ? {
            'code': 0,
            'message': 'ok',
            'data': {
              'applied': {'semesters': 0, 'courses': 0, 'schedules': 0},
            },
          }
        : {
            'code': 0,
            'message': 'ok',
            'data': {
              'semesters': pullSemesters,
              'courses': [],
              'schedules': [],
              'cursor': 0,
            },
          };
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
