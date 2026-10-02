import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/features/course_import/data/import_runtime.dart';

/// 发布前端到端关卡：用真实签名私钥产出的信封（tools/import-runtime-v1.json，
/// 由 publish_runtime.py 在签名时写出）走一遍客户端 verify + 解析。
///
/// 文件不存在（本机以外环境）时整组跳过，不影响常规测试。
void main() {
  final envelopeFile = File('../tools/import-runtime-v1.json');
  final envelope = envelopeFile.existsSync() ? envelopeFile.readAsStringSync() : null;

  test('真实待发布 payload 通过客户端验签与 schema 2 解析', () async {
    final store = ImportRuntimeStore(); // 使用 App 内置公钥
    final runtime = await store.verify(
      envelope!,
      build: 68,
      now: DateTime.now().add(const Duration(days: 1)),
    );
    // build 窗口内的正式包（≥minBuild）都能接受
    expect(runtime.revision, greaterThan(0));
    for (final school in runtime.schools) {
      expect(school.url.startsWith('https://'), isTrue, reason: school.name);
      expect(school.host, isNotEmpty, reason: school.name);
    }
  }, skip: envelope == null ? 'tools/import-runtime-v1.json 不存在（尚未签名）' : null);
}
