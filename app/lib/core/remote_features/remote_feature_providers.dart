import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../network/api_client.dart';
import '../../features/auth/data/auth_repository.dart';
import 'remote_feature_manifest.dart';
import 'remote_feature_store.dart';

final remoteFeatureStoreProvider = Provider<RemoteFeatureStore>(
  (ref) => RemoteFeatureStore(),
);

/// Enforce the last verified local policy first, then refresh it in the background.
/// A newly received major policy still closes the gate until consent is given.
final remoteFeatureManifestProvider = StreamProvider<RemoteFeatureManifest>(
  (ref) async* {
    int build;
    try {
      final package = await PackageInfo.fromPlatform().timeout(
        const Duration(milliseconds: 600),
      );
      build = int.tryParse(package.buildNumber) ?? 0;
    } catch (_) {
      yield RemoteFeatureManifest.bundled;
      return;
    }
    if (build < 1) {
      yield RemoteFeatureManifest.bundled;
      return;
    }
    final store = ref.read(remoteFeatureStoreProvider);
    yield await store.loadCached(build: build);
    yield await store.load(build: build);
  },
);

final remoteModulesAtProvider =
    Provider.family<List<RemoteFeatureModule>, RemoteFeaturePlacement>(
        (ref, placement) {
  final manifest = ref.watch(remoteFeatureManifestProvider).valueOrNull;
  final eligibility = ref.watch(remoteFeatureEligibilityProvider).valueOrNull;
  final remote = manifest
          ?.modulesAt(placement)
          .where((module) {
            return module.audience == RemoteFeatureAudience.all ||
                (eligibility?.contains(module.id) ?? false);
          })
          .toList(growable: false) ??
      const <RemoteFeatureModule>[];
  // 内置兜底（2026-10-01）：远程清单签名私钥遗失后清单冻结在 rev 5，而
  // 内置 revision 已升到其上（刻意屏蔽旧远程清单），远程模块从此不再被
  // 采纳——「共同空闲」这类**全原生页面**的入口随之从 2.0.1 起消失。
  // 这里把纯原生模块作为本地兜底：远程清单将来若换新钥匙重签并包含同
  // id 模块，按 id 去重以远程为准，不会出现重复入口。
  final remoteIds = remote.map((module) => module.id).toSet();
  final fallback = _bundledNativeModules
      .where((module) =>
          module.placements.contains(placement) &&
          !remoteIds.contains(module.id))
      .toList(growable: false);
  if (fallback.isEmpty) return remote;
  final merged = [...remote, ...fallback]
    ..sort((a, b) => b.priority.compareTo(a.priority));
  return List.unmodifiable(merged);
});

/// 全原生的内置模块（entryUrl 不会被使用：app_router 对其 id 有原生路由
/// 特判）。字段与 2026-09-13 签发的远程清单 rev 5 保持一致。
final _bundledNativeModules = <RemoteFeatureModule>[
  RemoteFeatureModule(
    id: 'couple_schedule',
    title: '共同空闲',
    description: '连接同学或朋友的课表，快速找到双方都没课的节次',
    badge: '新功能',
    entryUrl:
        Uri.parse('https://hanshang.seanyan.store/web/modules/couple-schedule/'),
    placements: {
      RemoteFeaturePlacement.profile,
      RemoteFeaturePlacement.featureHub,
    },
    capabilities: {
      RemoteFeatureCapability.scheduleRead,
      RemoteFeatureCapability.share,
      RemoteFeatureCapability.notifications,
    },
    minBuild: 35,
    maxBuild: 80,
    rolloutPercent: 100,
    priority: 60,
    requiresLogin: true,
  ),
];

final remoteFeatureEligibilityProvider =
    FutureProvider<Set<String>>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null || user.id <= 0) return const {};
  try {
    final response = await ref.read(dioProvider).get<Map<String, dynamic>>(
          '/api/app-modules/eligibility',
        );
    final values = response.data?['data']?['feature_ids'];
    if (values is! List) return const {};
    return values.whereType<String>().toSet();
  } catch (_) {
    return const {};
  }
});

class RemoteModuleSessionRepository {
  RemoteModuleSessionRepository(this._dio);
  final Dio _dio;

  Future<RemoteModuleLaunch> createLaunch({
    required RemoteFeatureModule module,
    required int manifestRevision,
  }) async {
    if (!module.requiresLogin) return RemoteModuleLaunch(uri: module.entryUrl);
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/app-modules/session',
      data: {
        'module_id': module.id,
        'manifest_revision': manifestRevision,
      },
    );
    final root = response.data;
    final data = root?['data'];
    final raw = data is Map<String, dynamic> ? data['launch_url'] : null;
    final cookie = data is Map<String, dynamic> ? data['session_cookie'] : null;
    final uri = raw is String ? Uri.tryParse(raw) : null;
    if (uri == null || !isTrustedRemotePage(uri)) {
      throw const FormatException('服务器返回了不受信任的功能地址');
    }
    if (cookie is! String || cookie.length < 40 || cookie.length > 4096) {
      throw const FormatException('服务器返回了无效的功能会话');
    }
    return RemoteModuleLaunch(uri: uri, sessionCookie: cookie);
  }
}

class RemoteModuleLaunch {
  const RemoteModuleLaunch({required this.uri, this.sessionCookie});

  final Uri uri;
  final String? sessionCookie;
}

final remoteModuleSessionRepositoryProvider =
    Provider<RemoteModuleSessionRepository>(
  (ref) => RemoteModuleSessionRepository(ref.read(dioProvider)),
);
