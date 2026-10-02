import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import 'remote_feature_manifest.dart';

class RemoteFeatureStore {
  RemoteFeatureStore({
    List<int>? publicKey,
    this.endpoint,
    this.clientFactory,
  }) : publicKey = publicKey ?? _configuredPublicKey();

  static const cacheKey = 'remote_feature_manifest_signed_v1';
  static const highestRevisionKey = 'remote_feature_manifest_highest_v1';
  static const installationIdKey = 'remote_feature_installation_id_v1';
  static const maximumBytes = 131072;

  final List<int> publicKey;
  final Uri? endpoint;
  final Dio Function()? clientFactory;

  static List<int> _configuredPublicKey() {
    if (AppConfig.remoteFeaturePublicKey.isEmpty) return const [];
    try {
      final bytes = base64Decode(AppConfig.remoteFeaturePublicKey);
      return bytes.length == 32 ? bytes : const [];
    } on FormatException {
      return const [];
    }
  }

  Future<RemoteFeatureManifest> verify(
    String envelope, {
    required int build,
    DateTime? now,
    bool allowExpired = false,
  }) async {
    if (publicKey.length != 32 || utf8.encode(envelope).length > maximumBytes) {
      throw const FormatException('Manifest verification unavailable');
    }
    final decoded = jsonDecode(envelope);
    if (decoded is! Map<String, dynamic> ||
        decoded['payload'] is! String ||
        decoded['signature'] is! String) {
      throw const FormatException('Invalid manifest envelope');
    }
    final payload = base64Decode(decoded['payload'] as String);
    final signature = base64Decode(decoded['signature'] as String);
    if (payload.length > maximumBytes || signature.length != 64) {
      throw const FormatException('Invalid manifest envelope');
    }
    final valid = await Ed25519().verify(
      payload,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) throw const FormatException('Manifest signature mismatch');
    final json = jsonDecode(utf8.decode(payload));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid manifest payload');
    }
    return RemoteFeatureManifest.fromPayload(
      json,
      appBuild: build,
      now: now ?? DateTime.now(),
      allowExpired: allowExpired,
    );
  }

  /// Verify the installed policy locally without waiting for the network.
  /// Expired signed policies remain enforceable; their modules stay disabled.
  Future<RemoteFeatureManifest> loadCached({required int build}) async {
    final prefs = await SharedPreferences.getInstance();
    final installationId = await _installationId(prefs);
    final cached = prefs.getString(cacheKey);
    if (cached != null) {
      try {
        final manifest = await verify(cached, build: build, allowExpired: true);
        if (manifest.revision >= (prefs.getInt(highestRevisionKey) ?? 0)) {
          return manifest.forInstallation(installationId);
        }
      } catch (_) {
        // A corrupt cache cannot supply either policy text or feature entries.
      }
    }
    return RemoteFeatureManifest.bundled;
  }

  Future<RemoteFeatureManifest> load({required int build}) async {
    final prefs = await SharedPreferences.getInstance();
    final installationId = await _installationId(prefs);
    var active = RemoteFeatureManifest.bundled;
    final cached = prefs.getString(cacheKey);
    if (cached != null) {
      try {
        active = await verify(cached, build: build, allowExpired: true);
      } catch (_) {
        // Corrupt or incompatible cached data never reaches the UI.
      }
    }

    if (publicKey.length != 32) return active.forInstallation(installationId);
    final uri = endpoint ??
        Uri.tryParse(
          '${AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '')}/api/app-manifest',
        );
    if (uri == null || uri.scheme != 'https') {
      return active.forInstallation(installationId);
    }

    final dio = clientFactory?.call() ??
        Dio(BaseOptions(
          connectTimeout: const Duration(milliseconds: 900),
          receiveTimeout: const Duration(milliseconds: 1200),
          followRedirects: false,
          maxRedirects: 0,
        ));
    final cancel = CancelToken();
    final deadline = Timer(
      const Duration(milliseconds: 1500),
      () => cancel.cancel('Manifest deadline'),
    );
    try {
      final response = await dio.get<ResponseBody>(
        uri.toString(),
        cancelToken: cancel,
        options: Options(responseType: ResponseType.stream),
      );
      final bytes = BytesBuilder(copy: false);
      await for (final part in response.data!.stream.timeout(
        const Duration(milliseconds: 1200),
      )) {
        if (bytes.length + part.length > maximumBytes) {
          throw const FormatException('Oversized manifest');
        }
        bytes.add(part);
      }
      final envelope = utf8.decode(bytes.takeBytes());
      final next = await verify(envelope, build: build);
      final highest = prefs.getInt(highestRevisionKey) ?? 0;
      if (next.revision >= active.revision && next.revision >= highest) {
        await prefs.setString(cacheKey, envelope);
        await prefs.setInt(highestRevisionKey, next.revision);
        active = next;
      }
    } catch (_) {
      // Offline, timeout, rollback, bad signature: keep last known good.
    } finally {
      deadline.cancel();
      dio.close(force: true);
    }
    return active.forInstallation(installationId);
  }

  Future<String> _installationId(SharedPreferences prefs) async {
    final existing = prefs.getString(installationIdKey);
    if (existing != null && RegExp(r'^[a-f0-9-]{36}$').hasMatch(existing)) {
      return existing;
    }
    final created = const Uuid().v4();
    await prefs.setString(installationIdKey, created);
    return created;
  }
}
