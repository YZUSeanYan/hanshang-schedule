import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';

import '../../../core/database/app_database.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/week_calculator.dart';
import '../../update/update_checker.dart';
import '../../share/data/share_repository.dart';
import '../../sync/data/sync_repository.dart';
import '../data/schedule_repository.dart';
import 'course_detail_sheet.dart';
import 'day_view.dart';
import 'week_view.dart';

/// 周视图主页：横向滑动切周，顶部显示"第X周"+日期范围。
class SchedulePage extends ConsumerStatefulWidget {
  const SchedulePage({super.key});

  @override
  ConsumerState<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends ConsumerState<SchedulePage> {
  PageController? _pageController;
  int _displayedWeek = 1;

  // ---- 日视图状态（阶段 5）----
  bool _isDayView = false;
  PageController? _dayController;
  DateTime _displayedDate = DateTime.now();
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    // 启动后自动检查版本更新（每次冷启动一次，静默失败）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(updateServiceProvider).checkOnLaunch(context);
    });
  }

  @override
  void dispose() {
    _pageController?.dispose();
    _dayController?.dispose();
    super.dispose();
  }

  /// 日视图控制器：初始定位到今天（距开学周一的天数）
  void _ensureDayController(Semester semester) {
    if (_dayController == null) {
      final today = DateTime.now();
      _displayedDate = today;
      final offset = today
          .difference(semester.startDate)
          .inDays
          .clamp(0, semester.totalWeeks * 7 - 1);
      _dayController = PageController(initialPage: offset);
    }
  }

  /// 学期就绪后初始化 PageController（只在学期/当前周变化时重建）
  void _ensurePageController(Semester semester) {
    final currentWeek = ref.read(currentWeekProvider) ?? 1;
    if (_pageController == null) {
      _displayedWeek = currentWeek;
      _pageController = PageController(initialPage: currentWeek - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final semesterAsync = ref.watch(currentSemesterProvider);

    return semesterAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('加载失败：$e'))),
      data: (semester) {
        if (semester == null) return _buildNoSemester(context);
        _ensurePageController(semester);
        _ensureDayController(semester);
        return _buildScheduleScaffold(context, semester);
      },
    );
  }

  /// 空状态：还没有学期 → 引导设置（设计规范：不许空白死页）
  Widget _buildNoSemester(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('邗上课表')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_month_outlined,
              size: 72,
              color: colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text('先设置一下学期吧', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '设置开学日期后，就能自动计算今天是第几周',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colorScheme.outline),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.settings_outlined),
              label: const Text('设置学期'),
              onPressed: () => context.push('/settings/semester'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScheduleScaffold(BuildContext context, Semester semester) {
    final currentWeek = ref.watch(currentWeekProvider);
    final entries = ref.watch(courseEntriesProvider).valueOrNull ?? [];
    final motionDuration = _motionDuration(
      context,
      const Duration(milliseconds: 220),
    );

    return Scaffold(
      appBar: AppBar(
        title: _isDayView
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSwitcher(
                    duration: motionDuration,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.3),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: Text(
                      '${_displayedDate.month}月${_displayedDate.day}日 '
                      '${_weekdayLabel(_displayedDate)}',
                      key: ValueKey(_displayedDate),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    _daySubtitle(semester, _displayedDate),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSwitcher(
                    duration: motionDuration,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.3),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: Text(
                      '第 $_displayedWeek 周',
                      key: ValueKey(_displayedWeek),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    _weekRangeText(semester, _displayedWeek),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
        actions: [
          // 周/日视图切换
          IconButton(
            icon: AnimatedSwitcher(
              duration: _motionDuration(
                context,
                const Duration(milliseconds: 180),
              ),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: Icon(
                _isDayView
                    ? Icons.calendar_view_week_outlined
                    : Icons.view_day_outlined,
                key: ValueKey(_isDayView),
              ),
            ),
            tooltip: _isDayView ? '切到周视图' : '切到日视图',
            onPressed: () => setState(() => _isDayView = !_isDayView),
          ),
          // 回本周按钮（周视图且不在本周时显示）
          if (!_isDayView &&
              currentWeek != null &&
              currentWeek != _displayedWeek)
            TextButton(
              onPressed: () => _pageController?.animateToPage(
                currentWeek - 1,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              ),
              child: const Text('回本周'),
            ),
          IconButton(
            icon: _sharing
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.share_outlined),
            tooltip: '分享给同学',
            onPressed: _sharing ? null : () => _shareSemester(semester),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加课程',
            onPressed: () => context.push('/course/edit'),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '学期设置',
            onPressed: () => context.push('/settings/semester'),
          ),
        ],
      ),
      body: entries.isEmpty
          ? _buildNoCourse(context)
          : AnimatedSwitcher(
              duration: _motionDuration(
                context,
                const Duration(milliseconds: 250),
              ),
              child: _isDayView
                  ? PageView.builder(
                      key: const ValueKey('day-view'),
                      controller: _dayController,
                      itemCount: semester.totalWeeks * 7,
                      onPageChanged: (index) => setState(
                        () => _displayedDate = semester.startDate.add(
                          Duration(days: index),
                        ),
                      ),
                      itemBuilder: (context, index) => DayView(
                        semester: semester,
                        date: semester.startDate.add(Duration(days: index)),
                        entries: entries,
                        onCourseTap: (entry) =>
                            _showCourseDetail(context, entry),
                      ),
                    )
                  : PageView.builder(
                      key: const ValueKey('week-view'),
                      controller: _pageController,
                      itemCount: semester.totalWeeks,
                      onPageChanged: (index) =>
                          setState(() => _displayedWeek = index + 1),
                      itemBuilder: (context, index) => WeekView(
                        semester: semester,
                        week: index + 1,
                        entries: entries,
                        onCourseTap: (entry) =>
                            _showCourseDetail(context, entry),
                      ),
                    ),
            ),
    );
  }

  Future<void> _shareSemester(Semester semester) async {
    if (semester.uuid.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('课表正在准备同步标识，请稍后再试')));
      return;
    }
    final courseCount = await ref
        .read(courseEntriesProvider.future)
        .then((entries) => entries.length)
        .catchError((_) => 0);
    if (!mounted) return;
    if (courseCount == 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前课表还没有课程，先添加课程再分享')));
      return;
    }
    setState(() => _sharing = true);
    try {
      // Snapshotting from the server deliberately happens only after the
      // latest local edits have gone through the existing authenticated sync.
      await ref.read(syncRepositoryProvider).sync();
      final code = await ref
          .read(shareRepositoryProvider)
          .create(semester.uuid);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('分享给同学'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('同学登录邗上课表网页版后输入这个口令，即可领取一份可独立编辑的课表。'),
              const SizedBox(height: 16),
              SelectableText(
                code.code,
                style: Theme.of(dialogContext).textTheme.headlineMedium
                    ?.copyWith(letterSpacing: 4, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('有效期至 ${code.expiresAt.toLocal()}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code.code));
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(
                    dialogContext,
                  ).showSnackBar(const SnackBar(content: Text('口令已复制')));
                }
              },
              icon: const Icon(Icons.copy_outlined),
              label: const Text('复制口令'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '生成口令失败：${apiErrorMessage(error, fallback: '请稍后重试')}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  String _weekdayLabel(DateTime date) => _weekdayLabels[date.weekday - 1];

  String _daySubtitle(Semester semester, DateTime date) {
    final week = weekNumberOf(semester.startDate, date);
    if (week < 1) return '开学前 · ${semester.name}';
    if (week > semester.totalWeeks) return '学期已结束 · ${semester.name}';
    return '第 $week 周 · ${semester.name}';
  }

  /// 空状态：有学期没课程 → 引导导入/手动添加
  Widget _buildNoCourse(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.playlist_add_outlined,
            size: 72,
            color: colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text('还没有课程', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '从教务系统一键导入，或先手动添加一门课',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colorScheme.outline),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('手动添加课程'),
            onPressed: () => context.push('/course/edit'),
          ),
        ],
      ),
    );
  }

  String _weekRangeText(Semester semester, int week) {
    final monday = semester.startDate.add(Duration(days: (week - 1) * 7));
    final sunday = monday.add(const Duration(days: 6));
    return '${monday.month}月${monday.day}日 - ${sunday.month}月${sunday.day}日 · ${semester.name}';
  }

  /// 课程详情弹层
  void _showCourseDetail(BuildContext context, CourseEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => CourseDetailSheet(
        entry: entry,
        onDelete: () async {
          Navigator.of(sheetContext).pop();
          await _confirmDelete(context, entry);
        },
        onEdit: () {
          Navigator.of(sheetContext).pop();
          context.push('/course/edit', extra: entry);
        },
      ),
    );
  }

  Duration _motionDuration(BuildContext context, Duration duration) =>
      (MediaQuery.maybeOf(context)?.disableAnimations ?? false)
      ? Duration.zero
      : duration;

  Future<void> _confirmDelete(BuildContext context, CourseEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除课程'),
        content: Text('确定删除「${entry.course.name}」吗？该课程的所有时间安排会一并删除。'),
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
      try {
        await ref
            .read(scheduleRepositoryProvider)
            .deleteCourse(entry.course.id);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('删除失败：$error')));
        }
      }
    }
  }
}
