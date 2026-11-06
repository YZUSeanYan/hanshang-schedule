import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/reminder_service.dart';
import '../../../core/notifications/course_live_service.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widget/widget_service.dart';
import '../../auth/data/auth_repository.dart';
import '../../schedule/data/schedule_repository.dart';
import '../data/sync_repository.dart';

/// 数据变化联动器（阶段 4）。
///
/// 在 App 根部 keep-alive 监听：课程数据每次变化（手动编辑 / 教务导入 / 同步拉取）
/// 2 秒防抖后自动做两件事：
/// 1. 重排上课提醒（reminderService.reschedule）
/// 2. 后台静默推送同步（syncRepository.sync，失败不打扰用户）
///
/// 防循环：push 不写本地库，pull 只有真的改了本地数据才会再次触发流，
/// 而拉回来的记录 updated_at 与云端一致，再推上去会被服务端判为"不更新"，
/// 因此收敛，不会死循环。
final dataChangeEffectsProvider = Provider<void>((ref) {
  Timer? debounce;
  Timer? liveTimer;

  // 实时通知（灵动岛）进度刷新：App 存活期间每 60 秒更新一次
  liveTimer = Timer.periodic(const Duration(seconds: 60), (_) {
    ref.read(courseLiveServiceProvider).refresh().catchError((_) {});
  });

  ref.listen<AsyncValue>(
    courseEntriesProvider,
    (previous, next) {
      // 只关心"有数据的变化"，跳过加载态
      if (next is! AsyncData) return;
      debounce?.cancel();
      debounce = Timer(const Duration(seconds: 2), () async {
        try {
          await ref.read(reminderServiceProvider).reschedule();
        } catch (_) {
          // 提醒重排失败不影响主流程（如模拟器无通知服务）
        }
        try {
          await ref.read(widgetServiceProvider).refresh();
        } catch (_) {
          // 小组件刷新失败不影响主流程
        }
        try {
          await ref.read(courseLiveServiceProvider).refresh();
        } catch (_) {
          // 实时通知刷新失败不影响主流程
        }
        // 未登录时跳过同步
        final auth = ref.read(authStateProvider).valueOrNull;
        if (auth == null) return;
        try {
          await ref.read(syncRepositoryProvider).sync();
          ref.read(syncStatusProvider.notifier).markSuccess();
        } catch (e) {
          ref.read(syncStatusProvider.notifier).markFailed(e);
        }
      });
    },
  );

  ref.onDispose(() {
    debounce?.cancel();
    liveTimer?.cancel();
  });
});

/// 同步状态（"我的"页展示：最后同步时间 / 失败原因）
class SyncStatus {
  const SyncStatus({this.lastSyncAt, this.syncing = false, this.error});

  final DateTime? lastSyncAt;
  final bool syncing;
  final String? error;
}

class SyncStatusNotifier extends Notifier<SyncStatus> {
  @override
  SyncStatus build() => const SyncStatus();

  void markSyncing() =>
      state = SyncStatus(lastSyncAt: state.lastSyncAt, syncing: true);

  void markSuccess() => state = SyncStatus(lastSyncAt: DateTime.now());

  void markFailed(Object error) => state = SyncStatus(
        lastSyncAt: state.lastSyncAt,
        error: apiErrorMessage(error, fallback: '同步失败，请稍后重试'),
      );
}

final syncStatusProvider =
    NotifierProvider<SyncStatusNotifier, SyncStatus>(SyncStatusNotifier.new);
