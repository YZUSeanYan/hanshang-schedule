import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/network/api_client.dart';
import 'package:yzu_schedule/core/storage/credential_vault_key_storage.dart';
import 'package:yzu_schedule/features/course_import/data/credential_vault_repository.dart';

void main() {
  test(
      'client encrypts, uploads, downloads, decrypts and verifies exact values',
      () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/yzu'));
    final adapter = _VaultAdapter();
    dio.httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      dioProvider.overrideWithValue(dio),
      credentialVaultKeyStorageProvider.overrideWithValue(
        MemoryCredentialVaultKeyStorage(List<int>.generate(32, (i) => i)),
      ),
    ]);
    addTearDown(container.dispose);

    final repository = container.read(credentialVaultRepositoryProvider);
    final result = await repository.saveAndVerify(
      studentId: '2026123456',
      password: 'real-format-test-password',
    );

    expect(result.verified, isTrue);
    expect(result.studentIdHint, '******3456');
    expect(adapter.saved!['student_id_hint'], '******3456');
    final packed = utf8.decode(
        base64Decode(adapter.saved!['ciphertext'] as String),
        allowMalformed: true);
    expect(packed, isNot(contains('2026123456')));
    expect(packed, isNot(contains('real-format-test-password')));
    final loaded = await repository.load();
    expect(loaded!.studentId, '2026123456');
    expect(loaded.password, 'real-format-test-password');
  });
}

class _VaultAdapter implements HttpClientAdapter {
  Map<String, dynamic>? saved;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Map<String, dynamic> data;
    if (options.method == 'PUT') {
      saved = Map<String, dynamic>.from(options.data as Map);
      data = {
        'code': 0,
        'message': 'ok',
        'data': {'saved': true}
      };
    } else {
      data = {
        'code': 0,
        'message': 'ok',
        'data': {'exists': saved != null, ...?saved},
      };
    }
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
