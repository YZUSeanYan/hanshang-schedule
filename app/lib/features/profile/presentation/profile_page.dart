import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:go_router/go_router.dart';

import '../../../core/notifications/reminder_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_controller.dart';
import '../../sync/data/sync_repository.dart';
import '../../sync/presentation/sync_controller.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/data/device_pair_repository.dart';
import '../../../core/notifications/course_live_service.dart';
import '../../schedule/data/schedule_repository.dart';
import '../../share/data/share_repository.dart';
import '../../watch/data/watch_ble_service.dart';
import '../../update/update_checker.dart';

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
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        children: [
          // ---- 账号卡片 ----
          if (user != null)
            ListTile(
              leading: CircleAvatar(
                child: Text(user.username.characters.first),
              ),
              title: Text(user.username),
              subtitle: Text(user.email),
            )
          else if (authState.isLoading)
            const ListTile(
              leading: CircleAvatar(child: CircularProgressIndicator(strokeWidth: 2)),
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
                            label: selected
                                ? '$colorName，已选择'
                                : '切换为$colorName',
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
          const Divider(),

          // ---- 功能入口 ----
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
                          final summary = await ref
                              .read(syncRepositoryProvider)
                              .sync();
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

class _ReminderSettingsTileState extends State<ReminderSettingsTile> {
  bool? _enabled;
  int? _leadMinutes;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object>([
        widget.service.isEnabled(),
        widget.service.leadMinutes(),
      ]);
      if (!mounted) return;
      setState(() {
        _enabled = values[0] as bool;
        _leadMinutes = values[1] as int;
      });
    } catch (error) {
      if (mounted) _showError(error);
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
              onSelectionChanged: _saving
                  ? null
                  : (values) => _setLeadMinutes(values.first),
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
      if (mounted) setState(() { _enabled = v; _loaded = true; });
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
