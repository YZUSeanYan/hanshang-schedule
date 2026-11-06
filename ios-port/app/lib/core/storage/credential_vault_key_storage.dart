import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'secure_storage_config.dart';

abstract class CredentialVaultKeyStorage {
  Future<List<int>?> readKey();
  Future<void> deriveAndSave({required String password, required int userId});
  Future<void> clear();
}

class SecureCredentialVaultKeyStorage implements CredentialVaultKeyStorage {
  static const _storage = appSecureStorage;
  static const _keyName = 'academic_credential_vault_key_v1';
  static final _deriver = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 210000,
    bits: 256,
  );

  @override
  Future<List<int>?> readKey() async {
    final encoded = await _storage.read(key: _keyName);
    if (encoded == null) return null;
    try {
      final value = base64Decode(encoded);
      return value.length == 32 ? value : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> deriveAndSave(
      {required String password, required int userId}) async {
    final key = await _deriver.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: utf8.encode('hanshang-vault-v1-user-$userId'),
    );
    await _storage.write(
        key: _keyName, value: base64Encode(await key.extractBytes()));
  }

  @override
  Future<void> clear() => _storage.delete(key: _keyName);
}

class MemoryCredentialVaultKeyStorage implements CredentialVaultKeyStorage {
  MemoryCredentialVaultKeyStorage([List<int>? initialKey]) : key = initialKey;

  List<int>? key;

  @override
  Future<List<int>?> readKey() async => key;

  @override
  Future<void> deriveAndSave(
      {required String password, required int userId}) async {
    key = List<int>.generate(
        32, (index) => (index + password.length + userId) % 256);
  }

  @override
  Future<void> clear() async => key = null;
}

final credentialVaultKeyStorageProvider = Provider<CredentialVaultKeyStorage>(
  (ref) => SecureCredentialVaultKeyStorage(),
);
