import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/settings/schedule_display_settings.dart';

Future<void> showScheduleDisplaySheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const ScheduleDisplaySheet(),
    );

class ScheduleDisplaySheet extends ConsumerStatefulWidget {
  const ScheduleDisplaySheet({super.key});

  @override
  ConsumerState<ScheduleDisplaySheet> createState() =>
      _ScheduleDisplaySheetState();
}

class _ScheduleDisplaySheetState extends ConsumerState<ScheduleDisplaySheet> {
  bool _saving = false;

  Future<void> _save(ScheduleDisplayOptions value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(scheduleDisplaySettingsProvider).save(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('显示设置未保存，请重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncOptions = ref.watch(scheduleDisplayOptionsProvider);
    final options = asyncOptions.valueOrNull ?? const ScheduleDisplayOptions();
    final enabled = asyncOptions.hasValue && !_saving;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('课表显示', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('收起晚间空白'),
            subtitle: const Text('周视图至少显示 1–8 节；有晚课或日程时自动延长'),
            value: options.trimEmptyEvenings,
            onChanged: enabled
                ? (value) => _save(options.copyWith(trimEmptyEvenings: value))
                : null,
          ),
          SwitchListTile(
            title: const Text('显示周六、周日'),
            subtitle: const Text('关闭后显示周一至周五；周末有安排时保留展开入口'),
            value: options.showWeekends,
            onChanged: enabled
                ? (value) => _save(options.copyWith(showWeekends: value))
                : null,
          ),
          if (asyncOptions.hasError)
            TextButton(
              onPressed: () => ref.invalidate(scheduleDisplayOptionsProvider),
              child: const Text('显示设置加载失败，点击重试'),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('学期设置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final router = GoRouter.of(context);
              Navigator.of(context).pop();
              router.push('/settings/semester');
            },
          ),
        ]),
      ),
    );
  }
}
