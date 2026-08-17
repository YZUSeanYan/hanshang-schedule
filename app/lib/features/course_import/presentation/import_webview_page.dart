import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../import/sniffer_js.dart';
import '../../../import/yzu_parser.dart';
import '../data/credential_vault_repository.dart';
import '../data/school_url_policy.dart';

/// 教务导入 WebView 页（设计文档 4.1 核心差异化功能）。
///
/// 用户路径：
/// 1. App 内打开扬大 WebVPN（用户亲自登录统一身份认证）；
/// 2. 进校内资源 → 教务系统（学生端）；
/// 3. 常用服务 → 班级课表 → 选择班级 → 课表信息；
/// 4. 点底部"抓取课表"→ 注入嗅探脚本 → 解析 → 导入预览。
///
/// 凭据同步仅在用户主动开启后生效：
/// - 只在识别到教务登录页并提交时读取一次，立即在本机加密；
/// - 服务端只保存 AES-GCM 密文，自动填入前在本机解密且绝不自动提交；
/// - 嗅探脚本只缓存"疑似课表"的响应体，不碰密码输入框；
/// - 抓取结果仅用于本地解析，解析完成后即丢弃原始 HTML。
class ImportWebViewPage extends ConsumerStatefulWidget {
  const ImportWebViewPage({super.key});

  /// 扬大 WebVPN 入口（深信服）
  static const String webVpnUrl = 'https://webvpn.yzu.edu.cn/';

  static const String guideText = '① 登录 WebVPN（统一身份认证）\n'
      '② 进入 校内资源 → 教务系统（学生端）\n'
      '③ 在「常用服务」点「班级课表」，选择对应班级后点「课表信息」\n'
      '④ 课表完整显示后，点底部「抓取课表」\n'
      '如已主动开启实验性凭据同步，登录信息会先在本机加密，再以密文同步并做往返校验';

  @override
  ConsumerState<ImportWebViewPage> createState() => _ImportWebViewPageState();
}

class _ImportWebViewPageState extends ConsumerState<ImportWebViewPage> {
  static const _preferenceKey = 'academic_credential_sync_enabled';
  InAppWebViewController? _controller;
  bool _loading = true;
  bool _capturing = false;
  String _currentTitle = '';
  bool _guideCollapsed = false;
  bool _credentialSyncEnabled = false;
  bool _autofillNotified = false;
  String _lastCredentialFingerprint = '';

  @override
  void initState() {
    super.initState();
    _loadCredentialPreference();
  }

  Future<void> _loadCredentialPreference() async {
    final preferences = await SharedPreferences.getInstance();
    _credentialSyncEnabled = preferences.getBool(_preferenceKey) ?? false;
    final controller = _controller;
    if (_credentialSyncEnabled && controller != null) {
      final url = await controller.getUrl();
      await _installCredentialCapture(controller, url);
      await _autofillCredential(controller, url);
    }
  }

  Future<void> _handleCredentialCapture(List<dynamic> arguments) async {
    if (!_credentialSyncEnabled ||
        arguments.isEmpty ||
        arguments.first is! Map) {
      return;
    }
    final controller = _controller;
    if (controller == null || !isAllowedSchoolUri(await controller.getUrl())) {
      return;
    }
    final payload = Map<String, dynamic>.from(arguments.first as Map);
    final frameOrigin = Uri.tryParse(payload['origin'] as String? ?? '');
    if (!isAllowedSchoolUri(frameOrigin)) return;
    final studentId = (payload['studentId'] as String? ?? '').trim();
    final password = payload['password'] as String? ?? '';
    if (studentId.length < 4 ||
        studentId.length > 32 ||
        password.isEmpty ||
        password.length > 128) {
      return;
    }
    final fingerprint = '$studentId\u0000$password';
    if (fingerprint == _lastCredentialFingerprint) {
      return;
    }
    _lastCredentialFingerprint = fingerprint;
    try {
      final result =
          await ref.read(credentialVaultRepositoryProvider).saveAndVerify(
                studentId: studentId,
                password: password,
              );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('教务凭据已加密同步，服务器往返校验通过（${result.studentIdHint}）')),
        );
      }
    } catch (error) {
      _lastCredentialFingerprint = '';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('教务凭据同步失败：$error')),
        );
      }
    }
  }

  Future<void> _installCredentialCapture(
      InAppWebViewController controller, WebUri? url) async {
    if (!_credentialSyncEnabled || !isAllowedSchoolUri(url)) {
      return;
    }
    await controller.evaluateJavascript(source: r'''
(() => {
  if (window.__hanshangCredentialCaptureInstalled) return;
  const host = location.hostname.toLowerCase();
  if (!(host === 'yzu.edu.cn' || host.endsWith('.yzu.edu.cn'))) return;
  const marker = `${location.href} ${document.title}`.toLowerCase();
  if (!/(教务|jwgl|jwc|urp|jsxsd|student)/i.test(marker)) return;
  if (/(统一身份|authserver)/i.test(marker)) return;
  window.__hanshangCredentialCaptureInstalled = true;
  const capture = () => {
    const passwordInput = document.querySelector('input[type="password"]');
    if (!passwordInput || !passwordInput.value) return;
    const usernameInput = document.querySelector(
      'input[autocomplete="username"],input[name*="user" i],input[id*="user" i],input[name*="account" i],input[id*="account" i],input[name*="xh" i],input[id*="xh" i],input[type="text"]'
    );
    const studentId = (usernameInput?.value || '').trim();
    if (!studentId) return;
    window.flutter_inappwebview.callHandler('credentialCapture', {
      studentId,
      password: passwordInput.value,
      origin: location.origin,
    });
  };
  document.addEventListener('submit', capture, true);
  document.addEventListener('click', (event) => {
    if (event.target?.closest?.('button,input[type="submit"]')) setTimeout(capture, 0);
  }, true);
})();
''');
  }

  Future<void> _autofillCredential(
      InAppWebViewController controller, WebUri? url) async {
    if (!_credentialSyncEnabled || !isAllowedSchoolUri(url)) {
      return;
    }
    try {
      final credential =
          await ref.read(credentialVaultRepositoryProvider).load();
      if (credential == null) {
        return;
      }
      final result = await controller.evaluateJavascript(source: '''
(() => {
  const host = location.hostname.toLowerCase();
  if (!(host === 'yzu.edu.cn' || host.endsWith('.yzu.edu.cn'))) return false;
  const marker = `\${location.href} \${document.title}`.toLowerCase();
  if (!/(教务|jwgl|jwc|urp|jsxsd|student)/i.test(marker) || /(统一身份|authserver)/i.test(marker)) return false;
  const passwordInput = document.querySelector('input[type="password"]');
  const usernameInput = document.querySelector('input[autocomplete="username"],input[name*="user" i],input[id*="user" i],input[name*="account" i],input[id*="account" i],input[name*="xh" i],input[id*="xh" i],input[type="text"]');
  if (!passwordInput || !usernameInput) return false;
  const setValue = (input, value) => {
    input.value = value;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  };
  if (!usernameInput.value) setValue(usernameInput, ${jsonEncode(credential.studentId)});
  if (!passwordInput.value) setValue(passwordInput, ${jsonEncode(credential.password)});
  return true;
})();
''');
      if (result == true && !_autofillNotified && mounted) {
        _autofillNotified = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已从云端密文解密并自动填入，请确认后手动登录')),
        );
      }
    } catch (error) {
      if (mounted && !_autofillNotified) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('教务凭据自动填入失败：$error')),
        );
      }
    }
  }

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
        _goFailed(result.detail);
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

  void _goFailed(String detail) {
    if (!mounted) {
      return;
    }
    context.push('/import/failed', extra: detail);
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
                        ImportWebViewPage.guideText,
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
              initialUrlRequest:
                  URLRequest(url: WebUri(ImportWebViewPage.webVpnUrl)),
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
                controller.addJavaScriptHandler(
                  handlerName: 'credentialCapture',
                  callback: _handleCredentialCapture,
                );
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                if (navigationAction.isForMainFrame != true) {
                  return NavigationActionPolicy.ALLOW;
                }
                final url = navigationAction.request.url;
                if (isAllowedSchoolUri(url) || url?.scheme == 'about') {
                  return NavigationActionPolicy.ALLOW;
                }
                return NavigationActionPolicy.CANCEL;
              },
              onLoadStop: (controller, url) async {
                // 兼容不支持 document-start 注入的旧 WebView；脚本可重复执行。
                await controller.evaluateJavascript(
                    source: kYzuSnifferInjectJs);
                await _installCredentialCapture(controller, url);
                await _autofillCredential(controller, url);
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
