import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'remote_feature_manifest.dart';
import 'remote_feature_providers.dart';

class RemoteFeaturePage extends ConsumerStatefulWidget {
  const RemoteFeaturePage({super.key, required this.moduleId});
  final String moduleId;

  @override
  ConsumerState<RemoteFeaturePage> createState() => _RemoteFeaturePageState();
}

class _RemoteFeaturePageState extends ConsumerState<RemoteFeaturePage> {
  Uri? _launchUrl;
  String? _error;
  double _progress = 0;

  @override
  void dispose() {
    final url = _launchUrl;
    if (url != null) {
      unawaited(CookieManager.instance().deleteCookie(
        url: WebUri(url.toString()),
        name: '__Host-hanshang_module',
        path: '/',
      ));
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    final manifest = ref.read(remoteFeatureManifestProvider).valueOrNull;
    final module = manifest?.moduleById(widget.moduleId);
    if (manifest == null || module == null) {
      setState(() => _error = '该功能当前不可用，请返回后重试。');
      return;
    }
    try {
      final launch = await ref
          .read(remoteModuleSessionRepositoryProvider)
          .createLaunch(module: module, manifestRevision: manifest.revision);
      final cookie = launch.sessionCookie;
      if (cookie != null) {
        await CookieManager.instance().setCookie(
          url: WebUri(launch.uri.toString()),
          name: '__Host-hanshang_module',
          value: cookie,
          path: '/',
          maxAge: 15 * 60,
          isSecure: true,
          isHttpOnly: true,
          sameSite: HTTPCookieSameSitePolicy.STRICT,
        );
      }
      if (mounted) setState(() => _launchUrl = launch.uri);
    } catch (_) {
      if (mounted) setState(() => _error = '功能页面连接失败，请稍后重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = ref.watch(remoteFeatureManifestProvider).valueOrNull;
    final module = manifest?.moduleById(widget.moduleId);
    return Scaffold(
      appBar: AppBar(title: Text(module?.title ?? '扩展功能')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 48),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () {
                        setState(() => _error = null);
                        _prepare();
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          : _launchUrl == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    InAppWebView(
                      initialUrlRequest:
                          URLRequest(url: WebUri(_launchUrl.toString())),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        useShouldOverrideUrlLoading: true,
                        cacheEnabled: false,
                        cacheMode: CacheMode.LOAD_NO_CACHE,
                        mixedContentMode:
                            MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                        allowFileAccessFromFileURLs: false,
                        allowUniversalAccessFromFileURLs: false,
                        thirdPartyCookiesEnabled: false,
                      ),
                      shouldOverrideUrlLoading: (controller, action) async {
                        final uri = action.request.url;
                        if (uri?.scheme == 'about') {
                          return NavigationActionPolicy.ALLOW;
                        }
                        final parsed =
                            uri == null ? null : Uri.tryParse(uri.toString());
                        return parsed != null && isTrustedRemotePage(parsed)
                            ? NavigationActionPolicy.ALLOW
                            : NavigationActionPolicy.CANCEL;
                      },
                      onProgressChanged: (_, progress) {
                        if (mounted) setState(() => _progress = progress / 100);
                      },
                      onReceivedHttpError: (_, request, response) {
                        if (request.isForMainFrame == true && mounted) {
                          setState(() => _error =
                              '功能页面暂时不可用（HTTP ${response.statusCode}）。');
                        }
                      },
                      onReceivedError: (_, request, __) {
                        if (request.isForMainFrame == true && mounted) {
                          setState(() => _error = '功能页面加载失败，请检查网络。');
                        }
                      },
                    ),
                    if (_progress < 1)
                      LinearProgressIndicator(value: _progress),
                  ],
                ),
    );
  }
}
