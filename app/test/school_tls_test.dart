import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/features/course_import/data/import_runtime.dart';
import 'package:yzu_schedule/features/course_import/data/school_tls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hanshang/school_tls');
  final cert = X509Certificate.fromData(data: File('android/app/src/androidTest/assets/school-leaf.der').readAsBytesSync());
  ServerTrustChallenge challenge(int port, {SslErrorType? error}) => ServerTrustChallenge(
    protectionSpace: URLProtectionSpace(host: 'webvpn.yzu.edu.cn', protocol: 'https', port: port,
      sslCertificate: SslCertificate(x509Certificate: cert), sslError: SslError(code: error ?? SslErrorType.UNTRUSTED)));
  setUp(() { debugDefaultTargetPlatformOverride = TargetPlatform.android; });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });
  test('Android unspecified HTTPS port -1 reaches full chain verification', () async {
    var called = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      called++;
      expect(call.method, 'verifyCompletedChain');
      expect(call.arguments['leaf'], cert.encoded);
      return true;
    });
    expect(await SchoolTls.verify(challenge(-1), ImportRuntime.bundled), isTrue);
    expect(await SchoolTls.verify(challenge(443), ImportRuntime.bundled), isTrue);
    expect(await SchoolTls.verify(challenge(80), ImportRuntime.bundled), isFalse);
    expect(await SchoolTls.verify(challenge(-1, error: SslErrorType.EXPIRED), ImportRuntime.bundled), isFalse);
    expect(called, 2);
  });
  test('native rejection and missing native bridge fail closed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => false);
    expect(await SchoolTls.verify(challenge(-1), ImportRuntime.bundled), isFalse);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    expect(await SchoolTls.verify(challenge(-1), ImportRuntime.bundled), isFalse);
  });
}
