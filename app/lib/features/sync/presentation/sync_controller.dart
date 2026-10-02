import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/reminder_service.dart';
import '../../../core/notifications/course_live_service.dart';
import '../../../core/network/api_client.dart';
import '../../../core/settings/section_time_settings.dart';
import '../../../core/widget/widget_service.dart';
import '../../auth/data/auth_repository.dart';
import '../../schedule/data/event_repository.dart';
import '../../schedule/data/override_repository.dart';
import '../../schedule/data/schedule_repository.dart';
import '../data/sync_repository.dart';

/// 数据变化联动器（阶段 4）。
///
/// 在 App 根部 keep-alive 监听：课程/日程/调休/作息任一变化（手动编辑 /
/// 教务导入 / 同步拉取）2 秒防抖后自动做两件事：
/// 1. 重排上课提醒（reminderService.reschedule）
/// 2. 后台静默推送同步（syncRepository.sync，失败不打扰用户）
///
/// 防循环：push 不写本地库，pull 只有真的改了本地数据才会再次触发流，
/// 而拉回来的记录 updated_at 与云端一致，再推上去会被服务端判为"不更新"，
/// 因此收敛，不会死循环。
final dataChangeEffectsProvider = Provider<void>((ref) {
  Timer? debounce;
  Timer? liveTimer;
  Timer? retryTimer;
  var retryAttempt = 0;

  /// 深度链路（防抖后执行）：重排提醒 → 刷小组件 → 刷实时通知 → 同步。
  Future<void> runEffects() async {
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
      retryAttempt = 0;
      retryTimer?.cancel();
    } catch (e) {
      ref.read(syncStatusProvider.notifier).markFailed(e);
      // 同步失败安排退避重试（review R10）：离线编辑后恢复联网、或启动时
      // 网络未就绪，都不该永远滞留到"下次编辑"。1→2→4→8 分钟，封顶 15。
      retryAttempt = (retryAttempt + 1).clamp(0, 4);
      retryTimer?.cancel();
      retryTimer = Timer(Duration(minutes: 1 << (retryAttempt - 1)), () {
        runEffects();
      });
    }
  }

  void onDataChanged(AsyncValue<dynamic> next) {
    // 只关心"有数据的变化"，跳过加载态
    if (next is! AsyncData) return;
    debounce?.cancel();
    debounce = Timer(const Duration(seconds: 2), runEffects);
  }

  // 课程与日程（AI 日程 2.0）共用一个联动器：任何一边变化都触发同一套
  // 防抖 → 重排提醒 → 刷小组件 → 静默同步流程。
  ref.listen<AsyncValue>(courseEntriesProvider, (_, next) => onDataChanged(next));
  ref.listen<AsyncValue>(eventsProvider, (_, next) => onDataChanged(next));
  // 调休覆盖也影响课程投影/提醒/其他设备（review R09）：调休页只写
  // scheduleOverrides 表，不经过上面两个流，必须单独挂进联动器。
  ref.listen<AsyncValue>(overridesProvider, (_, next) => onDataChanged(next));
  // 作息时间（冬夏/自定义）影响时间显示与提醒绝对时刻
  ref.listen<AsyncValue>(sectionTimeConfigProvider, (_, next) {
    if (next is AsyncData) onDataChanged(next);
  });

  // 登录态就绪后立即做一次初始同步（review R10）：启动时认证恢复可能
  // 晚于首次数据流触发，只靠防抖会错过开机的首轮同步。
  ref.listen<AsyncValue<AuthUser?>>(authStateProvider, (previous, next) {
    final user = next.valueOrNull;
    if (user == null) {
      retryTimer?.cancel();
      retryAttempt = 0;
      return;
    }
    final previousUser = previous?.valueOrNull;
    if (previousUser?.id == user.id) return;
    debounce?.cancel();
    debounce = Timer(const Duration(seconds: 3), runEffects);
  });

  // 实时通知（灵动岛）进度刷新：App 存活期间每 60 秒更新一次；
  // 同一定时器顺带做跨午夜检测（review R23）——日期翻转后重刷小组件
  // 并重排提醒，让"今天"在午夜后自动翻页。
  liveTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
    ref.read(courseLiveServiceProvider).refresh().catchError((_) {});
    try {
      final rolled = await ref.read(widgetServiceProvider).refreshIfDayChanged();
      if (rolled) await ref.read(reminderServiceProvider).reschedule();
    } catch (_) {}
  });

  ref.onDispose(() {
    debounce?.cancel();
    liveTimer?.cancel();
    retryTimer?.cancel();
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
