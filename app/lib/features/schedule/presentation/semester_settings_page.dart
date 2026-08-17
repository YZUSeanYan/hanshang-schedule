import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utils/week_calculator.dart';
import '../data/schedule_repository.dart';

/// 学期设置页：开学第一周的周一 + 总周数，自动计算"今天是第几周"。
class SemesterSettingsPage extends ConsumerStatefulWidget {
  const SemesterSettingsPage({super.key});

  @override
  ConsumerState<SemesterSettingsPage> createState() =>
      _SemesterSettingsPageState();
}

class _SemesterSettingsPageState extends ConsumerState<SemesterSettingsPage> {
  final _nameController = TextEditingController();
  DateTime _startMonday = mondayOf(DateTime.now());
  int _totalWeeks = 20;
  Semester? _editing; // null = 新建

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _loadSemester(Semester? semester) {
    setState(() {
      _editing = semester;
      if (semester != null) {
        _nameController.text = semester.name;
        _startMonday = semester.startDate;
        _totalWeeks = semester.totalWeeks;
      } else {
        _nameController.text = _suggestName();
        _startMonday = mondayOf(DateTime.now());
        _totalWeeks = 20;
      }
    });
  }

  /// 按当前月份猜测学期名：2-7 月 → 春，其余 → 秋
  String _suggestName() {
    final now = DateTime.now();
    final term = (now.month >= 2 && now.month <= 7) ? '春' : '秋';
    return '${now.year}$term';
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startMonday,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      helpText: '选择开学第一周的任意一天（自动对齐到周一）',
    );
    if (picked != null) {
      setState(() => _startMonday = mondayOf(picked));
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入学期名称')));
      return;
    }
    final repo = ref.read(scheduleRepositoryProvider);
    final editing = _editing;
    if (editing == null) {
      await repo.createSemester(
          name: name, startMonday: _startMonday, totalWeeks: _totalWeeks);
    } else {
      await repo.updateSemester(editing.copyWith(
        name: name,
        startDate: _startMonday,
        totalWeeks: _totalWeeks,
      ));
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final semestersAsync = ref.watch(allSemestersProvider);
    final currentWeek = ref.watch(currentWeekProvider);

    // 首次进入且未选择编辑对象时，自动载入当前学期
    if (_editing == null && _nameController.text.isEmpty) {
      final current =
          semestersAsync.valueOrNull?.where((s) => s.isCurrent).firstOrNull;
      if (current != null) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _loadSemester(current));
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('学期设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- 当前周提示 ----
          if (currentWeek != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.today_outlined),
                title: Text('今天是第 $currentWeek 周'),
                subtitle: Text('开学周一：${_fmtDate(_startMonday)}'),
              ),
            )
          else
            const Card(
              child: ListTile(
                leading: Icon(Icons.beach_access_outlined),
                title: Text('当前不在学期内'),
                subtitle: Text('开学前或已放假，保存正确的开学日期后自动计算周数'),
              ),
            ),
          const SizedBox(height: 16),

          TextFormField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '学期名称',
              hintText: '如 2026秋',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.calendar_today_outlined),
            label: Text('开学第一周周一：${_fmtDate(_startMonday)}'),
            onPressed: _pickStartDate,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('总周数'),
              Expanded(
                child: Slider(
                  value: _totalWeeks.toDouble(),
                  min: 16,
                  max: 25,
                  divisions: 9,
                  label: '$_totalWeeks 周',
                  onChanged: (v) => setState(() => _totalWeeks = v.round()),
                ),
              ),
              Text('$_totalWeeks 周'),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.save_outlined),
            label: Text(_editing == null ? '创建学期' : '保存修改'),
            onPressed: _save,
          ),

          // ---- 学期列表（多学期时切换/删除）----
          const SizedBox(height: 24),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('全部学期', style: Theme.of(context).textTheme.titleSmall),
          ),
          ...?semestersAsync.valueOrNull?.map((s) => ListTile(
                leading: Icon(s.isCurrent
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off),
                title: Text(s.name),
                subtitle:
                    Text('${_fmtDate(s.startDate)} 开学 · 共 ${s.totalWeeks} 周'),
                onTap: () => _loadSemester(s),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!s.isCurrent)
                      TextButton(
                        onPressed: () => ref
                            .read(scheduleRepositoryProvider)
                            .setCurrentSemester(s.id),
                        child: const Text('设为当前'),
                      ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '删除学期（课程将一并删除）',
                      onPressed: () => _confirmDeleteSemester(s),
                    ),
                  ],
                ),
              )),
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('新建学期'),
            onPressed: () => _loadSemester(null),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteSemester(Semester semester) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除学期'),
        content: Text('确定删除「${semester.name}」吗？该学期下的所有课程会一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(scheduleRepositoryProvider).deleteSemester(semester.id);
      if (mounted) _loadSemester(null);
    }
  }

  String _fmtDate(DateTime d) => '${d.year}-${d.month}-${d.day}';
}

/// 全部学期列表
final allSemestersProvider = StreamProvider<List<Semester>>(
  (ref) => ref.read(scheduleRepositoryProvider).watchAllSemesters(),
);
