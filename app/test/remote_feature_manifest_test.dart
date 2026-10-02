import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yzu_schedule/core/remote_features/remote_feature_manifest.dart';
import 'package:yzu_schedule/core/remote_features/remote_feature_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 9, 13, 8);

  Map<String, dynamic> payload({
    int revision = 4,
    String entryUrl =
        'https://hanshang.seanyan.store/web/modules/couple-schedule/',
    int minBuild = 35,
    int maxBuild = 80,
    int rollout = 100,
    String? audience,
    DateTime? expiresAt,
  }) =>
      {
        'schema': 1,
        'revision': revision,
        'minBuild': minBuild,
        'maxBuild': maxBuild,
        'issuedAt': now.millisecondsSinceEpoch ~/ 1000,
        'expiresAt': (expiresAt ?? now.add(const Duration(days: 7)))
                .millisecondsSinceEpoch ~/
            1000,
        'privacyPolicy': {
          'id': 'privacy-v7',
          'revision': 7,
          'effectiveDate': '2026-10-01',
          'summary': '新增协作课表的数据处理说明。',
          'body': '第 7 版完整政策正文',
          'requiresReconsent': true,
        },
        'modules': [
          {
            'id': 'couple_schedule',
            'title': '情侣课表',
            'description': '经双方同意后查看空闲时间',
            'badge': '测试中',
            'entryUrl': entryUrl,
            'placements': ['profile', 'feature_hub'],
            'capabilities': ['schedule_read', 'share'],
            'minBuild': minBuild,
            'maxBuild': maxBuild,
            'rolloutPercent': rollout,
            'priority': 50,
            'requiresLogin': true,
            if (audience != null) 'audience': audience,
          },
        ],
      };

  Future<String> sign(
    Map<String, dynamic> value,
    SimpleKeyPair key,
  ) async {
    final bytes = utf8.encode(jsonEncode(value));
    final signature = await Ed25519().sign(bytes, keyPair: key);
    return jsonEncode({
      'payload': base64Encode(bytes),
      'signature': base64Encode(signature.bytes),
    });
  }

  test('accepts a signed compatible manifest and exposes its module', () async {
    final key = await Ed25519().newKeyPair();
    final store = RemoteFeatureStore(
      publicKey: (await key.extractPublicKey()).bytes,
    );
    final manifest = await store.verify(
      await sign(payload(), key),
      build: 35,
      now: now,
    );
    expect(manifest.revision, 4);
    expect(manifest.privacyPolicy.id, 'privacy-v7');
    expect(manifest.modules.single.id, 'couple_schedule');
    expect(manifest.modulesAt(RemoteFeaturePlacement.profile), hasLength(1));
  });

  test('parses targeted account audience and rejects unknown audiences', () {
    final targeted = RemoteFeatureManifest.fromPayload(
      payload(audience: 'targeted'),
      appBuild: 35,
      now: now,
    );
    expect(targeted.modules.single.audience, RemoteFeatureAudience.targeted);
    expect(
      () => RemoteFeatureManifest.fromPayload(
        payload(audience: 'staff-only'),
        appBuild: 35,
        now: now,
      ),
      throwsFormatException,
    );
  });

  test('rejects tampering, arbitrary hosts and unknown native capabilities',
      () async {
    final key = await Ed25519().newKeyPair();
    final store = RemoteFeatureStore(
      publicKey: (await key.extractPublicKey()).bytes,
    );
    final good = await sign(payload(), key);
    final envelope = jsonDecode(good) as Map<String, dynamic>;
    final changed = utf8.encode(jsonEncode({...payload(), 'revision': 99}));
    final tampered =
        jsonEncode({...envelope, 'payload': base64Encode(changed)});
    await expectLater(
      store.verify(tampered, build: 35, now: now),
      throwsFormatException,
    );
    expect(
      () => RemoteFeatureManifest.fromPayload(
        payload(entryUrl: 'https://evil.example/web/modules/a/'),
        appBuild: 35,
        now: now,
      ),
      throwsFormatException,
    );
    final unknownCapability = payload();
    (unknownCapability['modules'] as List).first['capabilities'] = ['camera'];
    expect(
      () => RemoteFeatureManifest.fromPayload(
        unknownCapability,
        appBuild: 35,
        now: now,
      ),
      throwsFormatException,
    );
  });

  test('stable rollout gives the same installation the same result', () {
    expect(stableRolloutBucket('install-a:feature'), inInclusiveRange(0, 99));
    expect(
      stableRolloutBucket('install-a:feature'),
      stableRolloutBucket('install-a:feature'),
    );
    final manifest = RemoteFeatureManifest.fromPayload(
      payload(rollout: 25),
      appBuild: 35,
      now: now,
    );
    expect(
      manifest.forInstallation('install-a').modules.length,
      manifest.forInstallation('install-a').modules.length,
    );
  });

  test('a module for a newer APK is skipped without discarding the policy', () {
    final futureModule = payload();
    (futureModule['modules'] as List).first['minBuild'] = 40;
    final manifest = RemoteFeatureManifest.fromPayload(
      futureModule,
      appBuild: 35,
      now: now,
    );
    expect(manifest.modules, isEmpty);
    expect(manifest.privacyPolicy.id, 'privacy-v7');
  });

  test('rejects a signed privacy policy downgrade or mismatched policy id', () {
    final downgraded = payload();
    downgraded['privacyPolicy'] = {
      ...(downgraded['privacyPolicy'] as Map<String, dynamic>),
      'id': 'privacy-v2',
      'revision': 2,
    };
    expect(
      () => RemoteFeatureManifest.fromPayload(
        downgraded,
        appBuild: 35,
        now: now,
      ),
      throwsFormatException,
    );

    final mismatched = payload();
    mismatched['privacyPolicy'] = {
      ...(mismatched['privacyPolicy'] as Map<String, dynamic>),
      'id': 'privacy-v5',
    };
    expect(
      () => RemoteFeatureManifest.fromPayload(
        mismatched,
        appBuild: 35,
        now: now,
      ),
      throwsFormatException,
    );
  });

  test('last trusted revision survives offline and blocks signed rollback',
      () async {
    SharedPreferences.setMockInitialValues({});
    final key = await Ed25519().newKeyPair();
    final publicKey = (await key.extractPublicKey()).bytes;

    Future<RemoteFeatureManifest> load(String? response) => RemoteFeatureStore(
          publicKey: publicKey,
          endpoint: Uri.parse('https://api.example.test/api/app-manifest'),
          clientFactory: () =>
              Dio()..httpClientAdapter = _ManifestAdapter(response),
        ).load(build: 35);

    final currentNow = DateTime.now().toUtc();
    Map<String, dynamic> livePayload(int revision) => {
          ...payload(revision: revision),
          'issuedAt': currentNow
                  .subtract(const Duration(minutes: 1))
                  .millisecondsSinceEpoch ~/
              1000,
          'expiresAt':
              currentNow.add(const Duration(days: 7)).millisecondsSinceEpoch ~/
                  1000,
        };

    expect((await load(await sign(livePayload(6), key))).revision, 6);
    expect((await load(null)).revision, 6);
    expect((await load(await sign(livePayload(5), key))).revision, 6);
    expect((await load(await sign(livePayload(7), key))).revision, 7);
  });

  test('cold launch verifies cached policy without opening a network client', () async {
    SharedPreferences.setMockInitialValues({});
    final key = await Ed25519().newKeyPair();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(RemoteFeatureStore.cacheKey, await sign(payload(), key));
    final manifest = await RemoteFeatureStore(
      publicKey: (await key.extractPublicKey()).bytes,
      clientFactory: () => throw StateError('Cold launch must stay local'),
    ).loadCached(build: 35);
    expect(manifest.revision, 4);
    expect(manifest.privacyPolicy.id, 'privacy-v7');
  });

  test('expired cache keeps the signed policy but disables hosted modules',
      () async {
    SharedPreferences.setMockInitialValues({});
    final key = await Ed25519().newKeyPair();
    final publicKey = (await key.extractPublicKey()).bytes;
    final old = {
      ...payload(),
      'issuedAt': DateTime.now()
              .subtract(const Duration(days: 8))
              .millisecondsSinceEpoch ~/
          1000,
      'expiresAt': DateTime.now()
              .subtract(const Duration(days: 1))
              .millisecondsSinceEpoch ~/
          1000,
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(RemoteFeatureStore.cacheKey, await sign(old, key));
    final manifest = await RemoteFeatureStore(
      publicKey: publicKey,
      endpoint: Uri.parse('https://api.example.test/api/app-manifest'),
      clientFactory: () => Dio()..httpClientAdapter = _ManifestAdapter(null),
    ).load(build: 35);
    expect(manifest.stale, isTrue);
    expect(manifest.modules, isEmpty);
    expect(manifest.privacyPolicy.id, 'privacy-v7');
  });
}

class _ManifestAdapter implements HttpClientAdapter {
  _ManifestAdapter(this.response);
  final String? response;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (response == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    return ResponseBody.fromString(response!, 200);
  }

  @override
  void close({bool force = false}) {}
}
