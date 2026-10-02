import 'dart:convert';
import '../../schedule/presentation/section_time_settings_page.dart';
import '../../schedule/presentation/schedule_display_sheet.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/notifications/reminder_service.dart';
import '../../course_import/data/schedule_file_picker.dart';
import '../../../core/settings/course_card_display.dart';
import '../../../core/settings/haptics_settings.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/widgets/liquid_glass.dart';
import '../../sync/data/sync_repository.dart';
import '../../sync/presentation/sync_controller.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/data/device_pair_repository.dart';
import '../../../core/notifications/course_live_service.dart';
import '../../schedule/data/schedule_repository.dart';
import '../../share/data/share_repository.dart';
import '../../watch/data/watch_ble_service.dart';
import '../../update/update_checker.dart';
import '../../../core/remote_features/remote_feature_manifest.dart';
import '../../../core/remote_features/remote_feature_widgets.dart';

/// 「我的」页面：账号信息、外观设置、检查更新、关于。
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  static String _fmtTime(DateTime t) =>
      '${t.month}-${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// 发送课表到手表：服务端快照 → BLE 广播 → 等待手表读取。
  /// （入口已隐藏，BLE 联调完成后恢复）
  // ignore: unused_element
  static Future<void> _sendToWatch(BuildContext context, WidgetRef ref) async {
    final semester = ref.read(currentSemesterProvider).valueOrNull;
    if (semester == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在课表页创建课表')),
      );
      return;
    }
    final share = ref.read(shareRepositoryProvider);
    final ble = ref.read(watchBleServiceProvider);
    try {
      // 1) 服务端生成课表快照（手机有网即可）
      final codeInfo = await share.create(semester.uuid);
      final payload = await share.previewRaw(codeInfo.code);
      final json = jsonEncode(payload);
      // 2) 开启 BLE 广播 + GATT Server
      final granted = await ble.startTransfer(json);
      if (!granted) {
        if (context.mounted) {
          await showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('需要蓝牙权限'),
              content: const Text('请在系统弹窗中允许蓝牙权限后，重新点击「发送课表到手表」。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('知道了'),
                ),
              ],
            ),
          );
        }
        return;
      }
      // 3) 发送状态对话框（手表读取分片时实时更新）
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _BleSendingDialog(
          ble: ble,
          semesterName: semester.name,
          sizeKb: (json.length / 1024).toStringAsFixed(1),
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败：$error')),
        );
      }
    }
  }

  /// 手表配对码对话框：大号展示 6 位码，支持复制与重新生成。
  /// （入口已隐藏，BLE 联调完成后恢复）
  // ignore: unused_element
  static Future<void> _showPairCodeDialog(
    BuildContext context,
    WidgetRef ref,
    DevicePairCode initial,
  ) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          Future<void> regenerate() async {
            try {
              final pair =
                  await ref.read(devicePairRepositoryProvider).create();
              if (dialogContext.mounted) {
                setState(() {
                  initial = pair;
                });
              }
            } catch (error) {
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('生成失败：$error')),
                );
              }
            }
          }

          return AlertDialog(
            title: const Text('手表配对'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('在手表「邗上课表」登录页选择「配对码」，输入下方 6 位数字完成登录：'),
                const SizedBox(height: 16),
                Text(
                  initial.code,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 44,
                    letterSpacing: 10,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(dialogContext).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${initial.expiresMinutes} 分钟内有效，仅可领取一次',
                  textAlign: TextAlign.center,
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: initial.code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('配对码已复制')),
                  );
                },
                child: const Text('复制'),
              ),
              TextButton(
                onPressed: regenerate,
                child: const Text('重新生成'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  static const _modeLabels = {
    ThemeMode.system: '跟随系统',
    ThemeMode.light: '浅色',
    ThemeMode.dark: '深色',
  };

  static const _seedLabels = [
    '邗上绿',
    '清爽蓝',
    '竹青绿',
    '葡萄紫',
    '枫叶红',
    '蜜柑橙',
    '湖水青',
    '靛蓝',
    '樱粉',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeControllerProvider);
    final authState = ref.watch(authStateProvider);
    final user = authState.valueOrNull;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: buildGlassAppBar(
        context: context,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('我的',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            Text(
              '账户、外观与提醒设置。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: ListView(
        // 穿透式顶栏：视口延伸到玻璃 AppBar 后方，列表滚动穿过时实时模糊
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + kToolbarHeight,
          bottom: MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          // ---- 账号卡片 ----
          if (user != null)
            _AccountCard(user: user)
          else if (authState.isLoading)
            const ListTile(
              leading: CircleAvatar(
                  child: CircularProgressIndicator(strokeWidth: 2)),
              title: Text('正在恢复账号'),
              subtitle: Text('本地课表可继续使用，请稍候'),
            )
          else
            const ListTile(
              leading: CircleAvatar(child: Icon(Icons.person_outline)),
              title: Text('未登录'),
            ),

          const Divider(),

          // ---- 外观设置 ----
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('外观', style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('跟随系统'),
                  icon: Icon(Icons.brightness_auto_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('浅色'),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('深色'),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
              ],
              selected: {themeMode},
              onSelectionChanged: (modes) => ref
                  .read(themeControllerProvider.notifier)
                  .setMode(modes.first),
            ),
          ),

          const SizedBox(height: 12),
          // 主题色板（阶段 5）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Consumer(
              builder: (context, ref, _) {
                final current = ref.watch(themeSeedProvider);
                return Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final (index, color) in AppTheme.presetSeeds.indexed)
                      Builder(
                        builder: (context) {
                          final selected =
                              current.toARGB32() == color.toARGB32();
                          final colorName = _seedLabels[index];
                          final reduceMotion =
                              MediaQuery.maybeOf(context)?.disableAnimations ??
                                  false;
                          final duration = reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 180);
                          return Semantics(
                            button: true,
                            selected: selected,
                            label:
                                selected ? '$colorName，已选择' : '切换为$colorName',
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => ref
                                  .read(themeControllerProvider.notifier)
                                  .setSeed(color),
                              child: SizedBox.square(
                                dimension: 48,
                                child: Center(
                                  child: AnimatedScale(
                                    scale: selected ? 1.08 : 1,
                                    duration: duration,
                                    curve: Curves.easeOutBack,
                                    child: AnimatedContainer(
                                      duration: duration,
                                      curve: Curves.easeOut,
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        color: color,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: selected
                                              ? Theme.of(
                                                  context,
                                                ).colorScheme.onSurface
                                              : Colors.transparent,
                                          width: 2.5,
                                        ),
                                        boxShadow: selected
                                            ? [
                                                BoxShadow(
                                                  color: color.withValues(
                                                    alpha: 0.28,
                                                  ),
                                                  blurRadius: 10,
                                                  spreadRadius: 1,
                                                ),
                                              ]
                                            : const [],
                                      ),
                                      child: AnimatedSwitcher(
                                        duration: duration,
                                        child: selected
                                            ? const Icon(
                                                Icons.check,
                                                key: ValueKey('selected'),
                                                color: Colors.white,
                                                size: 18,
                                              )
                                            : const SizedBox(
                                                key: ValueKey('unselected'),
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.view_week_outlined),
            title: const Text('课表显示'),
            subtitle: const Text('晚间空白、周末显示'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showScheduleDisplaySheet(context),
          ),
          // 课程卡片信息密度：默认名称/教室/楼名三级，教师与校区收起进详情
          Consumer(
            builder: (context, ref, _) {
              final show = ref.watch(courseCardDisplayProvider);
              return SwitchListTile(
                secondary: const Icon(Icons.badge_outlined),
                title: const Text('卡片显示教师'),
                subtitle: const Text('校区等完整信息在课程详情里查看'),
                value: show,
                onChanged: (value) => ref
                    .read(courseCardDisplayProvider.notifier)
                    .setShow(value),
              );
            },
          ),
          // 触感反馈：长按「添加」语音录入等交互震动（默认开启，重震感）
          Consumer(
            builder: (context, ref, _) {
              final enabled = ref.watch(hapticsEnabledProvider);
              return SwitchListTile(
                secondary: const Icon(Icons.vibration_outlined),
                title: const Text('触感反馈'),
                subtitle: const Text('长按添加等操作时的震动提示'),
                value: enabled,
                onChanged: (value) => ref
                    .read(hapticsEnabledProvider.notifier)
                    .setEnabled(value),
              );
            },
          ),
          const Divider(),

          // ---- 功能入口 ----
          const RemoteFeatureSection(
            placement: RemoteFeaturePlacement.profile,
          ),
          // 云端同步：状态 + 手动触发
          Consumer(
            builder: (context, ref, _) {
              final status = ref.watch(syncStatusProvider);
              final subtitle = status.error != null
                  ? '同步失败：${status.error}'
                  : status.lastSyncAt != null
                      ? '上次同步 ${_fmtTime(status.lastSyncAt!)}'
                      : '编辑课程后自动同步，也可手动触发';
              return ListTile(
                leading: const Icon(Icons.cloud_sync_outlined),
                title: const Text('云端同步'),
                subtitle: Text(subtitle),
                trailing: status.syncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: user == null
                    ? null
                    : () async {
                        ref.read(syncStatusProvider.notifier).markSyncing();
                        try {
                          final summary =
                              await ref.read(syncRepositoryProvider).sync();
                          ref.read(syncStatusProvider.notifier).markSuccess();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('同步完成：$summary')),
                            );
                          }
                        } catch (e) {
                          ref.read(syncStatusProvider.notifier).markFailed(e);
                        }
                      },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.event_repeat_outlined),
            title: const Text('调休课表'),
            subtitle: const Text('放假与补课安排 · 可上传通知自动识别'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/holiday-overrides'),
          ),
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: const Text('每节课时间'),
            subtitle: const Text('扬大默认作息 · 自定义上下课时间'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const SectionTimeSettingsPage())),
          ),
          // 上课提醒：开关 + 提前量
          Consumer(
            builder: (context, ref, _) {
              return ReminderSettingsTile(
                service: ref.watch(reminderServiceProvider),
              );
            },
          ),
          // 通知设置（实时通知/账户通知/开启系统通知 合并二级菜单）
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('通知设置'),
            subtitle: const Text('实时通知 · 账户通知 · 系统通知'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/notifications/settings'),
          ),
          ListTile(
            leading: const Icon(Icons.phonelink_lock_outlined),
            title: const Text('通知保活与后台锁定教程'),
            subtitle: const Text('华为、荣耀、小米、OPPO、vivo、三星等品牌设置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/notifications/background-guide'),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_alt_outlined),
            title: const Text('检查更新'),
            subtitle: FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) =>
                  Text('当前版本 ${snapshot.data?.version ?? '-'}'),
            ),
            onTap: () => ref.read(updateServiceProvider).checkManually(context),
          ),

          // 手表相关入口已按需求隐藏（2026-08-15，BLE 联调完成后恢复）：
          // if (false)
          // ListTile(
          //   leading: const Icon(Icons.watch_outlined),
          //   title: const Text('手表配对'),
          //   subtitle: const Text('给 Vela 手表生成 6 位登录配对码'),
          //   trailing: const Icon(Icons.chevron_right),
          //   onTap: user == null ? null : () async {
          //     try {
          //       final pair =
          //           await ref.read(devicePairRepositoryProvider).create();
          //       if (context.mounted) {
          //         await _showPairCodeDialog(context, ref, pair);
          //       }
          //     } catch (error) {
          //       if (context.mounted) {
          //         ScaffoldMessenger.of(context).showSnackBar(
          //           SnackBar(content: Text('生成配对码失败：$error')),
          //         );
          //       }
          //     }
          //   },
          // ),
          // if (false)
          // ListTile(
          //   leading: const Icon(Icons.bluetooth),
          //   title: const Text('发送课表到手表'),
          //   subtitle: const Text('蓝牙直传当前课表给 Vela 手表（无需网络）'),
          //   trailing: const Icon(Icons.chevron_right),
          //   onTap: user == null ? null : () => _sendToWatch(context, ref),
          // ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于邗上课表'),
            subtitle: Text('当前主题模式：${_modeLabels[themeMode]}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/about'),
          ),
          ListTile(
            leading: const Icon(Icons.favorite_outline_rounded),
            title: const Text('支持作者'),
            subtitle: const Text('扫码支持一下，免费无广告'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/support-author'),
          ),

          // ---- 退出登录 ----
          if (user != null) ...[
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.logout),
                label: const Text('退出登录'),
                onPressed: () => ref.read(authStateProvider.notifier).logout(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 提醒设置需要在原生通知重排完成前立即更新界面，避免点击后看似无响应。
class ReminderSettingsTile extends StatefulWidget {
  const ReminderSettingsTile({super.key, required this.service});

  final ReminderServiceApi service;

  @override
  State<ReminderSettingsTile> createState() => _ReminderSettingsTileState();
}

class _ReminderSettingsTileState extends State<ReminderSettingsTile>
    with WidgetsBindingObserver {
  bool? _enabled;
  int? _leadMinutes;
  bool? _exactAllowed;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户可能刚去系统设置页授权了「闹钟和提醒」,回前台时刷新状态
    if (state == AppLifecycleState.resumed) _refreshExactAllowed();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object>([
        widget.service.isEnabled(),
        widget.service.leadMinutes(),
        widget.service.canExactSchedule(),
      ]);
      if (!mounted) return;
      setState(() {
        _enabled = values[0] as bool;
        _leadMinutes = values[1] as int;
        _exactAllowed = values[2] as bool;
      });
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _refreshExactAllowed() async {
    try {
      final allowed = await widget.service.canExactSchedule();
      if (mounted && allowed != _exactAllowed) {
        setState(() => _exactAllowed = allowed);
      }
    } catch (_) {
      // 状态刷新失败不影响现有展示
    }
  }

  Future<void> _setEnabled(bool value) async {
    final previous = _enabled;
    setState(() {
      _enabled = value;
      _saving = true;
    });
    try {
      await widget.service.setEnabled(value);
      await _refreshExactAllowed();
    } catch (error) {
      if (!mounted) return;
      setState(() => _enabled = previous);
      _showError(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setLeadMinutes(int value) async {
    final previous = _leadMinutes;
    setState(() {
      _leadMinutes = value;
      _saving = true;
    });
    try {
      await widget.service.setLeadMinutes(value);
    } catch (error) {
      if (!mounted) return;
      setState(() => _leadMinutes = previous);
      _showError(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _sendTestNotification() async {
    setState(() => _saving = true);
    try {
      await widget.service.sendTestNotification();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('测试通知已发送，请检查通知栏')));
      }
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('提醒设置保存失败，请稍后重试：$error')));
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    final leadMinutes = _leadMinutes;
    if (enabled == null || leadMinutes == null) {
      return const ListTile(
        leading: Icon(Icons.notifications_outlined),
        title: Text('上课提醒'),
        trailing: SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.notifications_outlined),
          title: const Text('上课提醒'),
          subtitle: Text(
            enabled
                ? '提前 $leadMinutes 分钟通知${_saving ? ' · 正在保存' : ''}'
                : '已关闭${_saving ? ' · 正在保存' : ''}',
          ),
          value: enabled,
          onChanged: _saving ? null : _setEnabled,
        ),
        if (enabled && _exactAllowed == false)
          ListTile(
            dense: true,
            leading: Icon(
              Icons.alarm_off_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              '提醒可能不准时',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: const Text('系统未授权「闹钟和提醒」，点此去开启，开启后提醒将按点送达'),
            onTap: _saving
                ? null
                : () async {
                    await widget.service.requestExactAlarmPermission();
                    await _refreshExactAllowed();
                  },
          ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 5, label: Text('5分钟')),
                ButtonSegment(value: 10, label: Text('10分钟')),
                ButtonSegment(value: 15, label: Text('15分钟')),
                ButtonSegment(value: 30, label: Text('30分钟')),
              ],
              selected: {leadMinutes},
              onSelectionChanged:
                  _saving ? null : (values) => _setLeadMinutes(values.first),
            ),
          ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _sendTestNotification,
                icon: const Icon(Icons.notification_add_outlined),
                label: const Text('发送测试通知'),
              ),
            ),
          ),
      ],
    );
  }
}

/// BLE 发送课表状态对话框：广播中 → 手表连接 → 发送完成。
// ignore: unused_element
class _BleSendingDialog extends StatefulWidget {
  const _BleSendingDialog({
    required this.ble,
    required this.semesterName,
    required this.sizeKb,
  });

  final WatchBleService ble;
  final String semesterName;
  final String sizeKb;

  @override
  State<_BleSendingDialog> createState() => _BleSendingDialogState();
}

class _BleSendingDialogState extends State<_BleSendingDialog> {
  String _status = '准备中…';
  bool _done = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.ble.stateStream.listen((event) {
      if (!mounted) return;
      final state = event['state'] as String?;
      setState(() {
        switch (state) {
          case 'advertising':
            _status = '正在广播，请在手表的「蓝牙导入课表」页点开始接收…';
            break;
          case 'connected':
            _status = '手表已连接，正在发送课表…';
            break;
          case 'done':
            _status = '已发送完成，手表会自动显示课表';
            _done = true;
            break;
          case 'advertise_failed':
            _status = '广播启动失败，请检查蓝牙是否开启';
            _failed = true;
            break;
          case 'disconnected':
            if (!_done) _status = '手表已断开，可在手表上重新点「开始接收」';
            break;
        }
      });
    });
  }

  @override
  void dispose() {
    widget.ble.stopTransfer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('发送课表到手表'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('课表：${widget.semesterName}（${widget.sizeKb} KB）'),
          const SizedBox(height: 12),
          Text(
            _status,
            style: TextStyle(
              color: _failed
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_done ? '完成' : '取消'),
        ),
      ],
    );
  }
}

/// 实时通知（灵动岛）设置行：开关 + 支持版本说明。
class CourseLiveTile extends StatefulWidget {
  const CourseLiveTile({super.key, required this.service});

  final CourseLiveService service;

  @override
  State<CourseLiveTile> createState() => _CourseLiveTileState();
}

class _CourseLiveTileState extends State<CourseLiveTile> {
  bool _enabled = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    widget.service.isEnabled().then((v) {
      if (mounted) {
        setState(() {
          _enabled = v;
          _loaded = true;
        });
      }
    });
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    await widget.service.setEnabled(value);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(value ? '实时通知已开启' : '实时通知已关闭')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.live_tv_outlined),
      title: const Text('实时通知（灵动岛）'),
      subtitle: const Text(
        '适配系统：原生 Android 16、ColorOS 16、小米 HyperOS 3.0.300、荣耀 MagicOS 10 及以上',
        style: TextStyle(fontSize: 12),
      ),
      isThreeLine: true,
      value: _enabled,
      onChanged: _loaded ? _toggle : null,
    );
  }
}

/// 账号卡片：头像（点按更换）+ 用户名（可改昵称）+ 邮箱。
class _AccountCard extends ConsumerStatefulWidget {
  const _AccountCard({required this.user});

  final AuthUser user;

  @override
  ConsumerState<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends ConsumerState<_AccountCard> {
  bool _busy = false;

  Future<void> _changeAvatar() async {
    if (_busy) return;
    final file = await ScheduleFilePicker.pick(image: true);
    if (file == null || !mounted) return;
    if (file.bytes.length > 2 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('头像图片不能超过 2 MB')),
      );
      return;
    }
    setState(() => _busy = true);
    final error =
        await ref.read(authStateProvider.notifier).updateAvatar(file.bytes, file.name);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? '头像已更新')),
    );
  }

  Future<void> _editUsername() async {
    final controller = TextEditingController(text: widget.user.username);
    final confirmed = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改用户名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(
            hintText: '2-32 位，中英文、数字、_、-',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (confirmed == null || confirmed.isEmpty || !mounted) return;
    if (confirmed == widget.user.username) return;
    setState(() => _busy = true);
    final error =
        await ref.read(authStateProvider.notifier).updateUsername(confirmed);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? '用户名已更新')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatarUrl = widget.user.avatarMedia.isEmpty
        ? null
        : '${AppConfig.apiBaseUrl}/api/user/avatar/${widget.user.avatarMedia}';
    return ListTile(
      leading: InkWell(
        customBorder: const CircleBorder(),
        onTap: _busy ? null : _changeAvatar,
        child: Stack(
          alignment: Alignment.bottomRight,
          children: [
            CircleAvatar(
              backgroundImage:
                  avatarUrl == null ? null : NetworkImage(avatarUrl),
              child: avatarUrl == null
                  ? Text(widget.user.username.characters.first)
                  : null,
            ),
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.edit, size: 10, color: scheme.onPrimary),
            ),
          ],
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              widget.user.username,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            customBorder: const CircleBorder(),
            onTap: _busy ? null : _editUsername,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.edit_outlined,
                  size: 16, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
      subtitle: Text(widget.user.email),
    );
  }
}
