import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'import_runtime.dart';
import 'runtime_defaults.dart';

class SchoolTls {
  static const _channel = MethodChannel('hanshang/school_tls');
  static Future<bool> verify(
      ServerTrustChallenge challenge, ImportRuntime runtime) async {
    final space = challenge.protectionSpace;
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        space.sslError?.code != SslErrorType.UNTRUSTED ||
        (space.protocol != null && space.protocol != 'https') ||
        (space.port != null && space.port != -1 && space.port != 443)) {
      return false;
    }
    final leaf = space.sslCertificate?.x509Certificate?.encoded;
    if (leaf == null) return false;
    try {
      return await _channel.invokeMethod<bool>('verifyCompletedChain', {
            'host': space.host,
            'leaf': leaf,
            'intermediates': [
              ...{bundledIntermediate, ...runtime.intermediates}
            ].take(8).map(base64Decode).toList(),
          }) ==
          true;
    } catch (_) {
      return false;
    }
  }
}
