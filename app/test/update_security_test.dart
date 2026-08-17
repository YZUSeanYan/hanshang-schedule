import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/features/update/update_checker.dart';

void main() {
  const hash =
      'c39ec044f36e51dd969e560a27168fc5f684c71a61552bd1b9548379fac17dcc';

  Map<String, dynamic> metadata(String url, {String sha256 = hash}) => {
        'apk_url': url,
        'sha256': sha256,
        'version_code': 13,
      };

  test('只接受与 HTTPS API 同源的固定 APK 下载目录', () {
    final result = trustedApkUri(
      metadata('https://schedule.example.com/yzu-apk/hanshang-schedule-v1.0.11.apk'),
      apiBaseUrl: 'https://schedule.example.com/yzu',
    );
    expect(
      result,
      Uri.parse(
          'https://schedule.example.com/yzu-apk/hanshang-schedule-v1.0.11.apk'),
    );
  });

  test('拒绝 HTTP、异源、目录逃逸与无效哈希', () {
    const base = 'https://schedule.example.com/yzu';
    expect(
      trustedApkUri(
        metadata('http://schedule.example.com/yzu-apk/app.apk'),
        apiBaseUrl: base,
      ),
      isNull,
    );
    expect(
      trustedApkUri(
        metadata('https://evil.example/yzu-apk/app.apk'),
        apiBaseUrl: base,
      ),
      isNull,
    );
    expect(
      trustedApkUri(
        metadata('https://schedule.example.com/download/app.apk'),
        apiBaseUrl: base,
      ),
      isNull,
    );
    expect(
      trustedApkUri(
        metadata(
          'https://schedule.example.com/yzu-apk/app.apk',
          sha256: 'not-a-hash',
        ),
        apiBaseUrl: base,
      ),
      isNull,
    );
  });
}
