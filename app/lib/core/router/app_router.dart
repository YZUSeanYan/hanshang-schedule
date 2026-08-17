import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/data/auth_repository.dart';
import '../../features/auth/presentation/login_page.dart';
import '../../features/course_import/presentation/import_failed_page.dart';
import '../../features/course_import/presentation/import_page.dart';
import '../../features/course_import/presentation/import_preview_page.dart';
import '../../features/course_import/presentation/import_webview_page.dart';
import '../../import/yzu_parser.dart';
import '../../features/profile/presentation/profile_page.dart';
import '../../features/profile/presentation/about_page.dart';
import '../../features/profile/presentation/notification_inbox_page.dart';
import '../../features/profile/presentation/notification_settings_page.dart';
import '../../features/profile/presentation/background_delivery_guide_page.dart';
import '../notifications/push_service.dart';
import '../../features/schedule/data/schedule_repository.dart';
import '../../features/schedule/presentation/course_edit_page.dart';
import '../../features/schedule/presentation/semester_settings_page.dart';
import '../../features/schedule/presentation/schedule_page.dart';

/// 全局路由配置。
///
/// 设计规范（设计文档 6.2）：底部导航最多 3 个 —— 课表 / 导入 / 我的。
/// 登录页等全屏页面挂在 Shell 之外。
///
/// 路由守卫：未登录一律去 /login；登录后自动回到课表页。
final appRouterProvider = Provider<GoRouter>((ref) {
  // 登录态变化时通知 GoRouter 重新评估 redirect
  final refresh = ValueNotifier<int>(0);
  ref
    ..listen(authStateProvider, (_, __) => refresh.value++)
    ..onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/schedule',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authStateProvider);
      if (auth.isLoading) return null; // 恢复会话中，暂不跳转
      final loggedIn = auth.valueOrNull != null;
      final onLoginPage = state.matchedLocation == '/login';
      if (!loggedIn && !onLoginPage) return '/login';
      if (loggedIn && onLoginPage) return '/schedule';
      return null;
    },
    routes: [
      // 全屏页面：登录/注册
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginPage(),
      ),
      // 全屏页面：课程编辑（编辑时通过 extra 传入 CourseEntry）
      GoRoute(
        path: '/course/edit',
        builder: (context, state) =>
            CourseEditPage(existing: state.extra as CourseEntry?),
      ),
      // 全屏页面：学期设置
      GoRoute(
        path: '/settings/semester',
        builder: (context, state) => const SemesterSettingsPage(),
      ),
      // 全屏页面：教务导入 WebView（WebVPN 引导抓取）
      GoRoute(
        path: '/import/webview',
        builder: (context, state) => const ImportWebViewPage(),
      ),
      // 全屏页面：导入预览（extra 传 ParseResult）
      GoRoute(
        path: '/import/preview',
        builder: (context, state) =>
            ImportPreviewPage(result: state.extra as ParseResult),
      ),
      // 全屏页面：导入失败（extra 传诊断信息）
      GoRoute(
        path: '/import/failed',
        builder: (context, state) =>
            ImportFailedPage(detail: state.extra as String),
      ),
      GoRoute(
        path: '/about',
        builder: (context, state) => const AboutPage(),
      ),
      GoRoute(
        path: '/notifications',
        builder: (context, state) => const NotificationInboxPage(),
      ),
      GoRoute(
        path: '/notifications/settings',
        builder: (context, state) => const NotificationSettingsPage(),
      ),
      GoRoute(
        path: '/notifications/background-guide',
        builder: (context, state) => const BackgroundDeliveryGuidePage(),
      ),
      // 带底部导航的主框架
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          // Tab 1：课表（周视图主页）
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/schedule',
              builder: (context, state) => const SchedulePage(),
            ),
          ]),
          // Tab 2：导入（教务系统导入入口）
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/import',
              builder: (context, state) => const ImportPage(),
            ),
          ]),
          // Tab 3：我的（账号、同步状态、设置、关于）
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/profile',
              builder: (context, state) => const ProfilePage(),
            ),
          ]),
        ],
      ),
    ],
  );
});

/// 带底部导航的外壳页面（IndexedStack 保持各 Tab 状态不丢失）
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  bool _checkingPrompt = false;

  @override
  void initState() {
    super.initState();
    // HomeShell can be constructed while the cached account is still being
    // restored. Listen for the first authenticated value instead of performing
    // a one-shot check that can race authentication and never run again.
    ref.listenManual<AsyncValue<AuthUser?>>(authStateProvider, (_, next) {
      final user = next.valueOrNull;
      if (user == null || user.id <= 0) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 首登通知推荐弹窗已按需求移除（2026-08-15）；
        // 需要恢复时取消下一行注释即可。
        // _promptForNotifications(user);
      });
    }, fireImmediately: true);
  }

  // ignore: unused_element
  Future<void> _promptForNotifications(AuthUser user) async {
    if (_checkingPrompt || !mounted) return;
    _checkingPrompt = true;
    try {
      final push = ref.read(pushServiceProvider);
      if (!await push.shouldPrompt() || !mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.notifications_active_outlined),
          title: const Text('及时接收课程与账户通知'),
          content: const Text('开启后可接收上课提醒、同步异常和管理员发送的重要账户通知。通知权限可随时在“我的”或系统设置中关闭。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('暂不开启')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('允许通知')),
          ],
        ),
      );
      if (accepted != true) {
        await push.declineInitialPrompt();
        return;
      }
      try {
        await push.enableForUser(user.id);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    } finally {
      _checkingPrompt = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _AnimatedShell(shell: widget.navigationShell),
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.navigationShell.currentIndex,
        onDestinationSelected: (index) => widget.navigationShell.goBranch(
          index,
          // 重复点当前 Tab 时回到该分支初始页
          initialLocation: index == widget.navigationShell.currentIndex,
        ),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '课表',
          ),
          NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download),
            label: '导入',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

/// 底部导航切换动画（一镜到底）：Tab 切换时重放淡入+位移入场动画。
/// 包装 StatefulNavigationShell（内部 IndexedStack 保持状态），
/// 仅在 currentIndex 变化时重放动画，不影响分支状态。
class _AnimatedShell extends StatefulWidget {
  const _AnimatedShell({required this.shell});

  final dynamic shell;

  @override
  State<_AnimatedShell> createState() => _AnimatedShellState();
}

class _AnimatedShellState extends State<_AnimatedShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1.0,
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0.035, 0),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
  int _lastIndex = -1;

  @override
  void didUpdateWidget(_AnimatedShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final idx = widget.shell.currentIndex as int;
    if (idx != _lastIndex) {
      _lastIndex = idx;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.shell as Widget),
    );
  }
}
