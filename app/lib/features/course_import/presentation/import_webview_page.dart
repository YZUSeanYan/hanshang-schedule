import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:package_info_plus/package_info_plus.dart';
import '../data/import_runtime.dart';
import '../data/school_tls.dart';
import '../../../import/yzu_parser.dart';
import '../../../import/sniffer_js.dart' show kYzuSnifferCollectJs;
import '../data/school_url_policy.dart';
import '../data/import_telemetry.dart';
import 'import_failed_page.dart';

/// 教务导入 WebView 页（设计文档 4.1 核心差异化功能）。
///
/// 用户路径：
/// 1. App 内打开扬大 WebVPN（用户亲自登录统一身份认证）；
/// 2. 进校内资源 → 教务系统（学生端）；
/// 3. 常用服务 → 班级课表 → 选择班级 → 课表信息；
/// 4. 点底部"抓取课表"→ 注入嗅探脚本 → 解析 → 导入预览。
///
/// 合规红线（2026-09-02）：教务账号密码只存在于本设备与学校系统之间——
/// 不读取密码框、不上传、不同步（原实验性凭据同步已彻底移除，服务端接口已下线）；
/// 嗅探脚本只缓存"疑似课表"的响应体，抓取结果仅用于本地解析，完成后即丢弃。
class ImportWebViewPage extends ConsumerStatefulWidget {
  const ImportWebViewPage({super.key})
      : genericStartUrl = null,
        isGenericMode = false;

  /// 通用模式（AI 通用教务导入）：任意学校教务系统。
  ///
  /// 与扬大模式的差异仅在于：起始页由用户输入、导航白名单放宽到任意 HTTPS 站点。
  const ImportWebViewPage.generic({super.key, required String startUrl})
      : genericStartUrl = startUrl,
        isGenericMode = true;

  final String? genericStartUrl;
  final bool isGenericMode;

  /// 扬大 WebVPN 入口（深信服）
  static const String webVpnUrl = 'https://webvpn.yzu.edu.cn/';

  static const String guideText = '① 登录 WebVPN（统一身份认证）\n'
      '② 进入 校内资源 → 教务系统（学生端）\n'
      '③ 在「常用服务」点「班级课表」，选择对应班级后点「课表信息」\n'
      '④ 课表完整显示后，点底部「抓取课表」\n'
      '你的账号密码只保存在本机与学校系统之间，邗上课表不读取、不上传';

  static const String genericGuideText = '① 在下方页面登录你学校的教务系统\n'
      '② 进入「课表查询 / 我的课表」页面\n'
      '③ 课表完整显示后，点底部「抓取课表」\n'
      '本地识别不出时会提供 AI 云端解析（自动抹除姓名学号，经你确认后才上传）';

  /// 引导文案选择：通用模式优先展示 runtime 命中学校的专属引导，
  /// 扬大模式优先用签名 runtime 下发的引导，都没有再回落内置文案。
  static String guideFor(
      {required bool genericMode,
      RuntimeSchool? school,
      required String runtimeGuide}) {
    if (genericMode) {
      return (school?.guide.isNotEmpty ?? false)
          ? school!.guide
          : genericGuideText;
    }
    return runtimeGuide.isEmpty ? guideText : runtimeGuide;
  }

  @override
  ConsumerState<ImportWebViewPage> createState() => _ImportWebViewPageState();
}

class _ImportWebViewPageState extends ConsumerState<ImportWebViewPage> {
  InAppWebViewController? _controller;
  bool _loading = true;
  bool _capturing = false;
  String _currentTitle = '';
  bool _guideCollapsed = false;
  bool _runtimeReady = false, _pageReady = false;
  ImportRuntime _runtime = ImportRuntime.bundled;

  /// 通用模式下按入口 URL 命中的学校适配配置（runtime schools）。
  RuntimeSchool? _school;

  /// 生效运行时：学校配置并入全局槽位（嗅探词/字段别名/中间证书）。
  ImportRuntime get _effective => _runtime.effectiveForSchool(_school);

  String? _loadError, _lastMainUrl;
  Timer? _loadTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_prepareRuntime());
  }

  Future<void> _prepareRuntime() async {
    var runtime = ImportRuntime.bundled;
    try {
      final info = await PackageInfo.fromPlatform();
      runtime = await ImportRuntimeStore()
          .load(build: int.tryParse(info.buildNumber) ?? 34);
    } catch (_) {/* Compiled defaults keep import available. */}
    if (mounted) {
      setState(() {
        _runtime = runtime;
        _school = widget.isGenericMode && widget.genericStartUrl != null
            ? runtime
                .schoolForHost(Uri.tryParse(widget.genericStartUrl!)?.host)
            : null;
        _runtimeReady = true;
      });
    }
  }

  void _failLoading(String message) {
    unawaited(ref
        .read(importTelemetryProvider)
        .record('school', 'webview', 'fail', detail: 'load'));
    _loadTimer?.cancel();
    if (mounted) {
      setState(() {
        _loading = false;
        _pageReady = false;
        _loadError = message;
      });
    }
  }

  void _watchLoading() {
    _loadTimer?.cancel();
    _loadTimer = Timer(
        const Duration(seconds: 25), () => _failLoading('学校页面加载超时，请检查网络后重试。'));
  }

  Future<void> _retry() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _loading = true;
      _pageReady = false;
      _loadError = null;
    });
    _watchLoading();
    try {
      await controller.loadUrl(
          urlRequest: URLRequest(
              url: WebUri(_lastMainUrl ??
                  widget.genericStartUrl ??
                  _runtime.entryUrl)));
    } catch (_) {
      _failLoading('页面未能打开，请返回后重试。');
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _capturing || _loading || !_pageReady) {
      return;
    }
    setState(() => _capturing = true);
    try {
      final url = await controller.getUrl();
      if (url == null || url.scheme != 'https') {
        _failLoading('学校页面尚未打开，请重新加载后再抓取。');
        return;
      }
      // 抓取前再补一次注入，防止 SPA 路由切换后 hook 丢失
      await controller.evaluateJavascript(source: _effective.snifferScript);
      final raw =
          await controller.evaluateJavascript(source: kYzuSnifferCollectJs);
      if (raw is! String || raw.isEmpty) {
        _goFailed('页面数据读取失败，请确认课表页面已加载完成后再抓取');
        return;
      }
      final capture = jsonDecode(raw);
      if (capture is! Map<String, dynamic>) {
        _goFailed('页面数据格式异常');
        return;
      }
      final result =
          YzuParser.parseCapture(capture, fieldAliases: _effective.fieldAliases);
      await _clearWebResourceCache();
      if (!mounted) {
        return;
      }
      unawaited(ref.read(importTelemetryProvider).record(
        'school', 'sniff', result.isSuccess ? 'success' : 'fail',
        errorCode: result.isSuccess ? '' : 'parse'));
      if (result.isSuccess) {
        context.push('/import/preview', extra: result);
      } else {
        // 本地解析失败时把抓取包一并带到失败页，用户可选择 AI 云端兜底解析
        _goFailed(result.detail, capture);
      }
    } catch (e) {
      unawaited(ref
          .read(importTelemetryProvider)
          .record('school', 'sniff', 'fail', detail: 'exception'));
      _goFailed('抓取异常：$e');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _clearWebResourceCache() async {
    try {
      // 仅清理 WebView 的内存/磁盘资源缓存；Cookie 与站点存储保留，
      // 因而不会让用户退出 WebVPN 或教务系统登录。
      await InAppWebViewController.clearAllCache(includeDiskFiles: true);
    } catch (_) {
      // 缓存清理属于空间优化，失败不能影响课表导入主流程。
    }
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    unawaited(_clearWebResourceCache());
    super.dispose();
  }

  void _goFailed(String detail, [Map<String, dynamic>? capture]) {
    if (!mounted) {
      return;
    }
    context.push('/import/failed',
        extra: ImportFailedPayload(detail: detail, capture: capture));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentTitle.isEmpty ? '教务导入' : _currentTitle,
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '重新加载',
            icon: const Icon(Icons.refresh),
            onPressed: _runtimeReady ? _retry : null,
          ),
        ],
      ),
      body: Column(
        children: [
          // 引导条：三步路径说明，可折叠
          if (!_guideCollapsed)
            Material(
              color: colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        ImportWebViewPage.guideFor(
                          genericMode: widget.isGenericMode,
                          school: _school,
                          runtimeGuide: _runtime.guide,
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    IconButton(
                      tooltip: '收起引导',
                      icon: const Icon(Icons.expand_less),
                      onPressed: () => setState(() => _guideCollapsed = true),
                    ),
                  ],
                ),
              ),
            ),
          if (_loading && _runtime.enabled) const LinearProgressIndicator(),
          Expanded(
            child: !_runtimeReady
                ? const Center(child: Text('正在准备导入…'))
                : !_runtime.enabled
                    ? const Center(child: Text('教务导入正在维护，请稍后再试。'))
                    : Stack(children: [
                        InAppWebView(
                          initialUrlRequest: URLRequest(
                            url: WebUri(
                              widget.genericStartUrl ?? _runtime.entryUrl,
                            ),
                          ),
                          // 必须在 document-start 安装。课表页会在 DOM 加载完成前发起
                          // AJAX；若等 onLoadStop 才 hook，移动端经常已经错过响应。
                          initialUserScripts: UnmodifiableListView([
                            UserScript(
                              source: _effective.snifferScript,
                              injectionTime:
                                  UserScriptInjectionTime.AT_DOCUMENT_START,
                              // 移动版/WebVPN 可能把教务系统放在 iframe 中。
                              forMainFrameOnly: false,
                            ),
                          ]),
                          initialSettings: InAppWebViewSettings(
                            javaScriptEnabled: true,
                            useShouldOverrideUrlLoading: true,
                            // 教务导入是低频、强时效页面，不复用 Chromium 磁盘缓存。
                            // 登录 Cookie/DOM Storage 不受影响，仍可保持登录态。
                            cacheEnabled: false,
                            cacheMode: CacheMode.LOAD_NO_CACHE,
                            // 教务系统多为桌面布局，允许缩放兜底
                            builtInZoomControls: true,
                            displayZoomControls: false,
                          ),
                          onWebViewCreated: (controller) {
                            _controller = controller;
                            _watchLoading();
                          },
                          onLoadStart: (controller, url) {
                            if (!mounted) return;
                            setState(() {
                              _loading = true;
                              _pageReady = false;
                              _loadError = null;
                            });
                            if (url?.scheme == 'https') {
                              _lastMainUrl = url.toString();
                            }
                            _watchLoading();
                          },
                          onReceivedServerTrustAuthRequest:
                              (controller, challenge) async {
                            final verified =
                                await SchoolTls.verify(challenge, _effective);
                            if (!verified && (_loading || !_pageReady)) {
                              _failLoading('学校网站的安全证书未能通过验证，请稍后重试。');
                            }
                            return ServerTrustAuthResponse(
                                action: verified
                                    ? ServerTrustAuthResponseAction.PROCEED
                                    : ServerTrustAuthResponseAction.CANCEL);
                          },
                          onReceivedHttpError: (controller, request, response) {
                            if (request.isForMainFrame == true) {
                              _failLoading(
                                  '学校网站暂时无法访问（HTTP ${response.statusCode}），请稍后重试。');
                            }
                          },
                          shouldOverrideUrlLoading:
                              (controller, navigationAction) async {
                            if (navigationAction.isForMainFrame != true) {
                              return NavigationActionPolicy.ALLOW;
                            }
                            final url = navigationAction.request.url;
                            // 通用模式面向任意学校教务系统，放行所有 HTTPS 导航；
                            // 扬大模式维持 *.yzu.edu.cn 白名单。
                            if (widget.isGenericMode) {
                              return (url?.scheme == 'https' ||
                                      url?.scheme == 'about')
                                  ? NavigationActionPolicy.ALLOW
                                  : NavigationActionPolicy.CANCEL;
                            }
                            if (isAllowedSchoolUri(url) ||
                                url?.scheme == 'about') {
                              return NavigationActionPolicy.ALLOW;
                            }
                            _failLoading('学校页面跳转到了暂不支持的地址，请联系开发者。');
                            return NavigationActionPolicy.CANCEL;
                          },
                          onLoadStop: (controller, url) async {
                            if (_loadError != null) return;
                            if (url == null || url.scheme != 'https') {
                              _failLoading('学校页面没有加载成功，请点击重新加载。');
                              return;
                            }
                            try {
                              await controller.evaluateJavascript(
                                  source: _effective.snifferScript);
                              final title = await controller.getTitle();
                              _loadTimer?.cancel();
                              if (mounted && _loadError == null) {
                                setState(() {
                                  _loading = false;
                                  _pageReady = true;
                                  unawaited(ref
                                      .read(importTelemetryProvider)
                                      .record('school', 'webview', 'success'));
                                  _currentTitle = title ?? '';
                                });
                              }
                            } catch (_) {
                              _failLoading('读取学校页面失败，请重新加载。');
                            }
                          },
                          onReceivedError: (controller, request, error) {
                            if (request.isForMainFrame == true) {
                              _failLoading('网页加载失败（${error.type}），请检查网络或稍后重试。');
                            }
                          },
                        ),
                        if (_loadError != null)
                          Positioned.fill(
                              child: ColoredBox(
                            color: colorScheme.surface,
                            child: Center(
                                child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.cloud_off, size: 40),
                                    const SizedBox(height: 16),
                                    Text(_loadError!,
                                        textAlign: TextAlign.center),
                                    const SizedBox(height: 16),
                                    FilledButton.icon(
                                        onPressed: _retry,
                                        icon: const Icon(Icons.refresh),
                                        label: const Text('重新加载学校页面')),
                                  ]),
                            )),
                          )),
                      ]),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed:
                _capturing || _loading || !_pageReady || !_runtime.enabled
                    ? null
                    : _capture,
            icon: _capturing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download),
            label: Text(_capturing ? '抓取中…' : '抓取课表'),
          ),
        ),
      ),
    );
  }
}
