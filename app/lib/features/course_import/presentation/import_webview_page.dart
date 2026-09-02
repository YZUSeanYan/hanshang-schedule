import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../import/sniffer_js.dart';
import '../../../import/yzu_parser.dart';
import '../data/school_url_policy.dart';
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

  @override
  ConsumerState<ImportWebViewPage> createState() => _ImportWebViewPageState();
}

class _ImportWebViewPageState extends ConsumerState<ImportWebViewPage> {
  InAppWebViewController? _controller;
  bool _loading = true;
  bool _capturing = false;
  String _currentTitle = '';
  bool _guideCollapsed = false;

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _capturing) {
      return;
    }
    setState(() => _capturing = true);
    try {
      // 抓取前再补一次注入，防止 SPA 路由切换后 hook 丢失
      await controller.evaluateJavascript(source: kYzuSnifferInjectJs);
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
      final result = YzuParser.parseCapture(capture);
      await _clearWebResourceCache();
      if (!mounted) {
        return;
      }
      if (result.isSuccess) {
        context.push('/import/preview', extra: result);
      } else {
        // 本地解析失败时把抓取包一并带到失败页，用户可选择 AI 云端兜底解析
        _goFailed(result.detail, capture);
      }
    } catch (e) {
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
            onPressed: () => _controller?.reload(),
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
                        widget.isGenericMode
                            ? ImportWebViewPage.genericGuideText
                            : ImportWebViewPage.guideText,
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
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(
                  widget.genericStartUrl ?? ImportWebViewPage.webVpnUrl,
                ),
              ),
              // 必须在 document-start 安装。课表页会在 DOM 加载完成前发起
              // AJAX；若等 onLoadStop 才 hook，移动端经常已经错过响应。
              initialUserScripts: UnmodifiableListView([
                UserScript(
                  source: kYzuSnifferInjectJs,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
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
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                if (navigationAction.isForMainFrame != true) {
                  return NavigationActionPolicy.ALLOW;
                }
                final url = navigationAction.request.url;
                // 通用模式面向任意学校教务系统，放行所有 HTTPS 导航；
                // 扬大模式维持 *.yzu.edu.cn 白名单。
                if (widget.isGenericMode) {
                  return (url?.scheme == 'https' || url?.scheme == 'about')
                      ? NavigationActionPolicy.ALLOW
                      : NavigationActionPolicy.CANCEL;
                }
                if (isAllowedSchoolUri(url) || url?.scheme == 'about') {
                  return NavigationActionPolicy.ALLOW;
                }
                return NavigationActionPolicy.CANCEL;
              },
              onLoadStop: (controller, url) async {
                // 兼容不支持 document-start 注入的旧 WebView；脚本可重复执行。
                await controller.evaluateJavascript(
                    source: kYzuSnifferInjectJs);
                final title = await controller.getTitle();
                if (mounted) {
                  setState(() {
                    _loading = false;
                    _currentTitle = title ?? '';
                  });
                }
              },
              onReceivedError: (controller, request, error) {
                if (request.isForMainFrame == true && mounted) {
                  setState(() => _loading = false);
                }
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _capturing ? null : _capture,
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
