import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'import_runtime.dart';

/// 全局共享的已签名导入运行时（离线/验签失败回落内置默认）。
/// 导入 WebView 与学校选择页共用同一份，避免重复拉取与状态不一致。
final importRuntimeProvider = FutureProvider<ImportRuntime>((ref) async {
  try {
    final info = await PackageInfo.fromPlatform();
    return await ImportRuntimeStore()
        .load(build: int.tryParse(info.buildNumber) ?? 34);
  } catch (_) {
    return ImportRuntime.bundled;
  }
});
