import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/network/api_client.dart';

/// 导入漏斗埋点（指标 1/2 的客户端一半）。
///
/// 与服务端埋点严格分工，避免重复计数：服务端已埋 `parse` 与
/// `sharecode/preview|apply`，客户端只补「请求发出之前」和「请求返回之后的
/// 确认环节」——`pick` / `preview` / `save` / `sharecode/input` /
/// `manual/edit|save` / 教务链路的 `webview|login|sniff`。
///
/// 隐私红线：只上报枚举、错误码与 size/ms 档位等元数据，绝不包含课程名、
/// 教师、文件内容或页面原文。
class ImportTelemetry {
  ImportTelemetry(this._dio);

  final Dio _dio;

  /// 与服务端 ENTRY_STAGES 保持一致；用于本地先挡住非法组合，避免白白发请求。
  static const Map<String, Set<String>> _stages = {
    'screenshot': {'pick', 'upload', 'parse', 'preview', 'save'},
    'excel': {'pick', 'upload', 'parse', 'preview', 'save'},
    'school': {'webview', 'login', 'sniff', 'parse', 'preview', 'save'},
    'sharecode': {'input', 'preview', 'apply'},
    'manual': {'edit', 'save'},
  };

  static const Set<String> _outcomes = {'success', 'fail', 'abandon'};

  String? _version;
  String _versionRequested = '';

  Future<String> _clientVersion() async {
    if (_version != null) return _version!;
    if (_versionRequested.isNotEmpty) return _versionRequested;
    try {
      final info = await PackageInfo.fromPlatform()
          .timeout(const Duration(seconds: 2));
      _version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      _version = '';
    }
    return _version!;
  }

  /// 尽力上报：任何失败都静默吞掉，绝不影响导入主流程。
  Future<void> record(
    String entry,
    String stage,
    String outcome, {
    String errorCode = '',
    String detail = '',
  }) async {
    // 用 ?. 而不是 !：entry 不在白名单时要静默忽略，不能抛出——调用点是
    // unawaited(...)，抛出会变成未捕获异步错误（曾会直接崩到 Zone）。
    if (_stages[entry]?.contains(stage) != true) return;
    if (!_outcomes.contains(outcome)) return;
    try {
      final version = await _clientVersion();
      _versionRequested = version;
      await _dio.post<Map<String, dynamic>>(
        '/api/telemetry/import-event',
        data: {
          'entry': entry,
          'stage': stage,
          'outcome': outcome,
          'error_code': errorCode.length > 16 ? errorCode.substring(0, 16) : errorCode,
          'detail': detail.length > 190 ? detail.substring(0, 190) : detail,
          'client_version': version.length > 16
              ? version.substring(0, 16)
              : version,
        },
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
    } catch (_) {
      // 埋点静默失败：网络异常、被限流、枚举被拒都不要打断用户。
    }
  }
}

/// 服务端 LlmImportResult.source → 埋点入口名。
///
/// 预览页只拿到 source，拿不到「用户是从哪个入口进来的」，用这个映射把
/// 保存事件归到正确的 entry 上（service 端已埋 parse，这里只补 preview/save）。
String importEntryOfSource(String source) {
  if (source == 'image_llm') return 'screenshot';
  if (source == 'spreadsheet_llm') return 'excel';
  return 'school';
}

final importTelemetryProvider = Provider<ImportTelemetry>(
  (ref) => ImportTelemetry(ref.read(dioProvider)),
);
