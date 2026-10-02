import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'remote_feature_manifest.dart';
import 'remote_feature_providers.dart';
import '../../features/sync/data/sync_repository.dart';

class RemoteFeatureSection extends ConsumerWidget {
  const RemoteFeatureSection({
    super.key,
    required this.placement,
    this.cardLayout = false,
  });

  final RemoteFeaturePlacement placement;
  final bool cardLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modules = ref.watch(remoteModulesAtProvider(placement));
    if (modules.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final module in modules)
          if (cardLayout)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Card(child: _RemoteFeatureTile(module: module)),
            )
          else
            _RemoteFeatureTile(module: module),
      ],
    );
  }
}

class RemoteFeatureMenuButton extends ConsumerWidget {
  const RemoteFeatureMenuButton({super.key, required this.placement});

  final RemoteFeaturePlacement placement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modules = ref.watch(remoteModulesAtProvider(placement));
    if (modules.isEmpty) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.extension_outlined),
      tooltip: '更多课表功能',
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Text(
                  '更多课表功能',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              for (final module in modules) _RemoteFeatureTile(module: module),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteFeatureTile extends ConsumerWidget {
  const _RemoteFeatureTile({required this.module});
  final RemoteFeatureModule module;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
        leading: Icon(module.id == 'couple_schedule'
            ? Icons.people_alt_outlined
            : Icons.extension_outlined),
        title: Row(
          children: [
            Expanded(child: Text(module.title)),
            if (module.badge.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  module.badge,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
          ],
        ),
        subtitle: Text(module.description),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await context.push('/features/${module.id}');
          if (module.capabilities
              .contains(RemoteFeatureCapability.scheduleWrite)) {
            try {
              await ref.read(syncRepositoryProvider).sync();
            } catch (_) {
              // The normal sync controller will retry without blocking return.
            }
          }
        },
      );
}
