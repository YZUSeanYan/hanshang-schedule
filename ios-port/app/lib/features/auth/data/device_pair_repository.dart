import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// 服务端生成的 6 位设备配对码（Vela 手表登录用）。
class DevicePairCode {
  const DevicePairCode({required this.code, required this.expiresMinutes});

  final String code;
  final int expiresMinutes;

  factory DevicePairCode.fromJson(Map<String, dynamic> json) => DevicePairCode(
        code: json['code'] as String,
        expiresMinutes: (json['expires_minutes'] as num?)?.toInt() ?? 10,
      );
}

/// 手表配对码：手机端登录后生成 6 位数字码，手表端输码换取令牌。
/// 码 10 分钟有效、一次性；重复生成会使旧码立即失效。
class DevicePairRepository {
  DevicePairRepository(this._dio);

  final Dio _dio;

  Future<DevicePairCode> create() async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/auth/device-pair',
    );
    return DevicePairCode.fromJson(
      response.data!['data'] as Map<String, dynamic>,
    );
  }
}

final devicePairRepositoryProvider = Provider<DevicePairRepository>(
  (ref) => DevicePairRepository(ref.read(dioProvider)),
);
