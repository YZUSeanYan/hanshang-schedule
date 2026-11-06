import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/storage/credential_vault_key_storage.dart';

class AcademicCredential {
  const AcademicCredential({required this.studentId, required this.password});

  final String studentId;
  final String password;
}

class CredentialRoundTripResult {
  const CredentialRoundTripResult(
      {required this.verified, required this.studentIdHint});

  final bool verified;
  final String studentIdHint;
}

class CredentialVaultRepository {
  CredentialVaultRepository(this._ref);

  static const _aad = 'hanshang-academic-credential-v1';
  static final _cipher = AesGcm.with256bits();

  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  CredentialVaultKeyStorage get _keyStorage =>
      _ref.read(credentialVaultKeyStorageProvider);

  Future<bool> hasLocalKey() async => await _keyStorage.readKey() != null;

  Future<CredentialRoundTripResult> saveAndVerify({
    required String studentId,
    required String password,
  }) async {
    final key = await _requireKey();
    final plain = utf8.encode(jsonEncode({
      'student_id': studentId,
      'password': password,
    }));
    final box = await _cipher.encrypt(
      plain,
      secretKey: SecretKey(key),
      nonce: _cipher.newNonce(),
      aad: utf8.encode(_aad),
    );
    final packed = <int>[...box.cipherText, ...box.mac.bytes];
    final hiddenCount = studentId.length > 4 ? studentId.length - 4 : 0;
    final hidden = List.filled(hiddenCount, '*').join();
    final hint = studentId.length <= 4
        ? List.filled(studentId.length, '*').join()
        : '$hidden${studentId.substring(studentId.length - 4)}';
    await _dio.put<Map<String, dynamic>>(
      '/api/credential-vault',
      data: {
        'ciphertext': base64Encode(packed),
        'nonce': base64Encode(box.nonce),
        'student_id_hint': hint,
        'schema_version': 1,
      },
    );

    final roundTrip = await load();
    final verified =
        roundTrip?.studentId == studentId && roundTrip?.password == password;
    if (!verified) throw StateError('教务凭据往返校验失败');
    await _dio.post<Map<String, dynamic>>('/api/credential-vault/verified');
    return CredentialRoundTripResult(verified: true, studentIdHint: hint);
  }

  Future<AcademicCredential?> load() async {
    final response =
        await _dio.get<Map<String, dynamic>>('/api/credential-vault');
    final data = response.data!['data'] as Map<String, dynamic>;
    if (data['exists'] != true) return null;
    final key = await _requireKey();
    final packed = base64Decode(data['ciphertext'] as String);
    if (packed.length <= 16) throw const FormatException('密文长度异常');
    final nonce = base64Decode(data['nonce'] as String);
    final box = SecretBox(
      packed.sublist(0, packed.length - 16),
      nonce: nonce,
      mac: Mac(packed.sublist(packed.length - 16)),
    );
    final decoded = await _cipher.decrypt(
      box,
      secretKey: SecretKey(key),
      aad: utf8.encode(_aad),
    );
    final payload = jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>;
    return AcademicCredential(
      studentId: payload['student_id'] as String,
      password: payload['password'] as String,
    );
  }

  Future<void> delete() => _dio.delete<void>('/api/credential-vault');

  Future<List<int>> _requireKey() async {
    final key = await _keyStorage.readKey();
    if (key == null) {
      throw StateError('请退出并重新登录一次，以初始化本机加密密钥');
    }
    return key;
  }
}

final credentialVaultRepositoryProvider = Provider<CredentialVaultRepository>(
  (ref) => CredentialVaultRepository(ref),
);
