import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/platform/platform_capabilities.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/privacy/data/privacy_consent.dart';
import 'features/privacy/presentation/privacy_gate_view.dart';
import 'features/sync/presentation/sync_controller.dart';

/// 应用根组件：挂载路由与主题（Material 3）
class YzuScheduleApp extends ConsumerWidget {
  const YzuScheduleApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 正式构建若被错误配置为 HTTP，直接阻止认证与同步 Provider 启动。
    if (!PlatformCapabilities.allowsApiBaseUrl(
      defaultTargetPlatform,
      AppConfig.apiBaseUrl,
    )) {
      return const _InsecureApiBlockedApp();
    }

    // 隐私政策门禁（金标联盟/应用商店合规）：未同意前不挂载业务路由，
    // 也就不会触发会话恢复、云端同步与推送初始化。
    final gate = ref.watch(privacyGateProvider);
    return gate.when(
      loading: () => const _PrivacyGateSplash(),
      error: (_, __) => _buildMainApp(ref),
      data: (consented) =>
          consented ? _buildMainApp(ref) : const PrivacyGateView(),
    );
  }

  Widget _buildMainApp(WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeControllerProvider);
    final seed = ref.watch(themeSeedProvider);
    // 阶段 4：数据变化自动联动（重排上课提醒 + 静默云端同步）
    ref.watch(dataChangeEffectsProvider);

    return MaterialApp.router(
      title: '邗上课表',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(seed),
      darkTheme: AppTheme.dark(seed),
      themeMode: themeMode, // 跟随系统 / 浅色 / 深色（「我的」页可切换）
      routerConfig: router,
    );
  }
}

/// 隐私门禁读取本地状态时的过渡页。
class _PrivacyGateSplash extends StatelessWidget {
  const _PrivacyGateSplash();

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '邗上课表',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF158A63),
          useMaterial3: true,
        ),
        home: const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
}

class _InsecureApiBlockedApp extends StatelessWidget {
  const _InsecureApiBlockedApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '邗上课表',
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          appBar: AppBar(title: const Text('邗上课表')),
          body: const SafeArea(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.security, size: 56),
                    SizedBox(height: 16),
                    Text(
                      '安全配置错误',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 12),
                    Text(
                      '当前构建使用了不安全的 API 地址。为避免账号密码、登录令牌和课表数据'
                      '明文传输，应用已停止连接。请使用 HTTPS 的 API_BASE_URL 重新构建。',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
