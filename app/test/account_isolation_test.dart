import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/core/network/api_client.dart';
import 'package:yzu_schedule/core/storage/token_storage.dart';
import 'package:yzu_schedule/features/auth/data/auth_repository.dart';
import 'package:yzu_schedule/features/schedule/data/schedule_repository.dart';

/// 账号数据隔离（同设备切换账号防串号）的数据层测试。
///
/// 场景：账号 A 在本机存有课表/日程/墓碑 → 同设备登录全新账号 B，
/// 本地必须被清空（含墓碑队列），B 从云端全量拉取自己的数据；
/// 且 A 的墓碑绝不能随 B 的首次同步推送到 A 云端。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  /// 构造一个在登录时注入内存数据库的 AuthRepository。
  /// Dio 用假登录响应；AuthRepository 通过 ref.read 拿 provider，
  /// 而 ProviderContainer.read 与 Ref.read 函数签名一致，直接传入。
  AuthRepository buildRepo({required String responseUserJson}) {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/yzu'))
      ..httpClientAdapter = _FakeAuthAdapter(responseUserJson);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      dioProvider.overrideWithValue(dio),
      // 用内存 token 存储，避免 flutter_secure_storage 无插件实现报错
      tokenStorageProvider.overrideWithValue(MemoryTokenStorage()),
    ]);
    addTearDown(container.dispose);
    // container.read 的类型 Result Function(ProviderListenable<Result>)
    // 与 Ref 的 read 方法签名一致，AuthRepository 只用到 _ref.read。
    return AuthRepository(_ContainerRef(container));
  }

  test('切换账号登录后本地数据被清空（含墓碑队列）', () async {
    // 账号 A 在本机留下课表、日程和一条待推送墓碑
    final repo = ScheduleRepository(db);
    final semId = await repo.createSemester(
      name: '2026秋',
      startMonday: DateTime(2026, 9, 7),
    );
    await repo.createCourse(
      semesterId: semId,
      name: '大学物理',
      slots: const [],
    );
    await db.into(db.localEvents).insert(
          LocalEventsCompanion.insert(
            title: 'A 的日程',
            updatedAt: DateTime.now(),
          ),
        );
    await db.into(db.pendingDeletions).insert(
          PendingDeletionsCompanion.insert(
            entity: 'course',
            uuid: 'a-tombstone',
            parentUuid: const Value(''),
            deletedAt: DateTime.now(),
          ),
        );

    // 账号 A 曾登录过（last_logged_in_user_id = 1）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('last_logged_in_user_id', 1);

    // 账号 B（id=2）登录：本地必须被清空
    final auth = buildRepo(
      responseUserJson:
          '{"id":2,"username":"b","email":"b@example.test"}',
    );
    await auth.login('b', 'password');

    expect(await db.select(db.semesters).get(), isEmpty);
    expect(await db.select(db.courses).get(), isEmpty);
    expect(await db.select(db.schedules).get(), isEmpty);
    expect(await db.select(db.localEvents).get(), isEmpty);
    // A 的墓碑被丢弃，不会随 B 的同步推送到 A 云端
    expect(await db.select(db.pendingDeletions).get(), isEmpty);
    expect(await prefs.getInt('last_logged_in_user_id'), 2);
  });

  test('同一账号重复登录不清空本地数据', () async {
    final repo = ScheduleRepository(db);
    await repo.createSemester(
      name: '2026秋',
      startMonday: DateTime(2026, 9, 7),
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('last_logged_in_user_id', 1);

    // 账号 A（id=1）再次登录：本地数据保留
    final auth = buildRepo(
      responseUserJson:
          '{"id":1,"username":"a","email":"a@example.test"}',
    );
    await auth.login('a', 'password');

    expect(await db.select(db.semesters).get(), hasLength(1));
    expect(await prefs.getInt('last_logged_in_user_id'), 1);
  });
}

/// 只响应 /api/auth/login 的假适配器。
class _FakeAuthAdapter implements HttpClientAdapter {
  _FakeAuthAdapter(this.userJson);

  final String userJson;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/api/auth/login')) {
      return ResponseBody.fromString(
        '{"code":0,"message":"ok","data":{"access_token":"at",'
        '"refresh_token":"rt","user":$userJson}}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      '{"code":40400,"message":"not mocked"}',
      404,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 把 ProviderContainer 适配成 Ref：AuthRepository 只用到 _ref.read，
/// riverpod 2.x 中 ProviderContainer.read 与 Ref.read 的函数签名一致。
class _ContainerRef implements Ref {
  _ContainerRef(this._container);

  final ProviderContainer _container;

  @override
  T read<T>(ProviderListenable<T> provider) => _container.read(provider);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
