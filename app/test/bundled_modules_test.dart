import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/remote_features/remote_feature_manifest.dart';
import 'package:yzu_schedule/core/remote_features/remote_feature_providers.dart';

void main() {
  // 背景（2026-10-01 用户反馈）：远程清单冻结在 rev 5 且签名私钥遗失，
  // 本地曾见过更高 revision 的设备会永久拒绝它，远程模块从此不再采纳，
  // 「共同空闲」入口随之消失。兜底 = 全原生模块内置在客户端。
  test('远程清单被拒/为空时，共同空闲入口走内置兜底（profile 位）', () {
    final container = ProviderContainer(overrides: [
      remoteFeatureManifestProvider
          .overrideWith((ref) => Stream.value(RemoteFeatureManifest.bundled)),
      remoteFeatureEligibilityProvider
          .overrideWith((ref) => Future.value(const <String>{})),
    ]);
    addTearDown(container.dispose);

    final modules =
        container.read(remoteModulesAtProvider(RemoteFeaturePlacement.profile));
    expect(
      modules.map((m) => m.id),
      contains('couple_schedule'),
      reason: '共同空闲是全原生页面，入口不能依赖远程清单签发',
    );
    expect(modules.single.title, '共同空闲');
  });

  test('远程清单恢复且包含同 id 模块时，不出现重复入口', () async {
    final remote = RemoteFeatureManifest(
      revision: 9,
      issuedAt: DateTime(2026, 10, 1),
      expiresAt: DateTime(2027, 10, 1),
      privacyPolicy: bundledPrivacyPolicy,
      modules: [
        RemoteFeatureModule(
          id: 'couple_schedule',
          title: '共同空闲（远程版）',
          description: '远程下发的描述',
          entryUrl: Uri.parse('https://hanshang.seanyan.store/web/modules/couple-schedule/'),
          placements: {RemoteFeaturePlacement.profile},
          capabilities: const <RemoteFeatureCapability>{},
          minBuild: 35,
          maxBuild: 99,
          rolloutPercent: 100,
          priority: 10,
        ),
      ],
    );
    final container = ProviderContainer(overrides: [
      remoteFeatureManifestProvider.overrideWith((ref) => Stream.value(remote)),
      remoteFeatureEligibilityProvider
          .overrideWith((ref) => Future.value(const <String>{})),
    ]);
    addTearDown(container.dispose);
    await container.read(remoteFeatureManifestProvider.future);

    final modules =
        container.read(remoteModulesAtProvider(RemoteFeaturePlacement.profile));
    expect(modules.map((m) => m.id), ['couple_schedule'],
        reason: '远程模块优先，内置兜底按 id 去重');
    expect(modules.single.title, '共同空闲（远程版）');
  });
}
