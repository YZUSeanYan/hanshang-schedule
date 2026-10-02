import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/section_times.dart';
import '../../../core/settings/section_time_settings.dart';
import '../../../core/notifications/reminder_service.dart';
import '../../../core/widget/widget_service.dart';

class SectionTimeSettingsPage extends ConsumerStatefulWidget {
  const SectionTimeSettingsPage({super.key});
  @override
  ConsumerState<SectionTimeSettingsPage> createState() =>
      _SectionTimeSettingsPageState();
}

class _SectionTimeSettingsPageState
    extends ConsumerState<SectionTimeSettingsPage> {
  bool _automatic = true, _loading = true, _saving = false, _dirty = false;
  String? _loadError;
  List<(String, String)> _times = [...SectionTimes.current];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final config = await ref.read(sectionTimeSettingsProvider).load();
      if (!mounted) return;
      setState(() {
        _automatic = config.automatic;
        _times = [...config.forDate(DateTime.now())];
        _loading = false;
        _loadError = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '读取失败，请重试';
        });
      }
    }
  }

  Future<void> _pick(int i, bool start) async {
    final value = start ? _times[i].$1 : _times[i].$2;
    final minutes = SectionTimeConfig.minutes(value)!;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
      helpText: '第 ${i + 1} 节${start ? '上课' : '下课'}时间',
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!),
    );
    if (picked == null || !mounted) return;
    final text =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    setState(() {
      _times[i] = start ? (text, _times[i].$2) : (_times[i].$1, text);
      _dirty = true;
    });
  }

  void _message(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _save() async {
    if (!_automatic) {
      final error = SectionTimeConfig.validate(_times);
      if (error != null) {
        _message(error);
        return;
      }
    }
    setState(() => _saving = true);
    try {
      await ref.read(sectionTimeSettingsProvider).save(_automatic
          ? const SectionTimeConfig.defaults()
          : SectionTimeConfig.custom(_times));
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        _message('保存失败，请重试');
      }
      return;
    }
    final failed = <String>[];
    try {
      await ref.read(reminderServiceProvider).reschedule();
    } catch (_) {
      failed.add('提醒');
    }
    try {
      await ref.read(widgetServiceProvider).refresh();
    } catch (_) {
      failed.add('桌面小组件');
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _dirty = false;
    });
    _message(failed.isEmpty
        ? '已保存，课表、提醒和小组件已更新'
        : '时间已保存；${failed.join('、')}刷新失败，请稍后再次保存重试');
  }

  Future<void> _leave() async {
    if (_saving) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('放弃未保存的修改？'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('继续编辑')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('放弃修改'))
                ],
              ));
      if (discard != true || !mounted) return;
    }
    if (mounted) {
      setState(() => _dirty = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _automatic ? SectionTimes.current : _times;
    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('每节课时间'), actions: [
          TextButton(
              onPressed:
                  _loading || _saving || _loadError != null ? null : _save,
              child: Text(_saving ? '保存中…' : '保存'))
        ]),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? Center(
                    child:
                        TextButton(onPressed: _load, child: Text(_loadError!)))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                        SwitchListTile.adaptive(
                          title: const Text('使用扬大默认作息'),
                          subtitle: const Text(
                              '按上课日期自动切换：10 月 1 日起下午首节 14:00；5 月 1 日起 14:30。后续各节相应前移或后移 30 分钟。'),
                          value: _automatic,
                          onChanged: _saving
                              ? null
                              : (value) => setState(() {
                                    _automatic = value;
                                    _dirty = true;
                                  }),
                        ),
                        const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                                '适用于本设备所有课表。关闭默认作息后，可逐节修改上课和下课时间；自定义时间全年固定，不随季节切换。')),
                        if (!_automatic)
                          Wrap(spacing: 8, children: [
                            OutlinedButton(
                                onPressed: _saving
                                    ? null
                                    : () => setState(() {
                                          _times = [
                                            ...SectionTimes.springSummer
                                          ];
                                          _dirty = true;
                                        }),
                                child: const Text('填入春夏时间')),
                            OutlinedButton(
                                onPressed: _saving
                                    ? null
                                    : () => setState(() {
                                          _times = [
                                            ...SectionTimes.autumnWinter
                                          ];
                                          _dirty = true;
                                        }),
                                child: const Text('填入秋冬时间')),
                          ]),
                        if (_automatic) const Text('以下预览今天适用的时间；查看其他日期时会自动切换。'),
                        for (var i = 0; i < SectionTimes.sectionCount; i++)
                          Card(
                              child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  child: Row(children: [
                                    Expanded(child: Text('第 ${i + 1} 节')),
                                    TextButton(
                                        onPressed: _automatic || _saving
                                            ? null
                                            : () => _pick(i, true),
                                        child: Text('上课 ${shown[i].$1}')),
                                    TextButton(
                                        onPressed: _automatic || _saving
                                            ? null
                                            : () => _pick(i, false),
                                        child: Text('下课 ${shown[i].$2}')),
                                  ]))),
                      ]),
      ),
    );
  }
}
