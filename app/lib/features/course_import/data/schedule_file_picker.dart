import 'package:flutter/services.dart';

class PickedScheduleFile {
  const PickedScheduleFile({
    required this.name,
    required this.bytes,
    required this.mimeType,
  });

  final String name;
  final Uint8List bytes;
  final String mimeType;

  int get size => bytes.length;
}

class ScheduleFilePicker {
  static const _channel = MethodChannel('hanshang/schedule_file_picker');

  static Future<PickedScheduleFile?> pick({required bool image}) async {
    final result = await _channel.invokeMapMethod<String, dynamic>('pick', {
      'kind': image ? 'image' : 'table',
    });
    return _fromResult(result, image: image);
  }

  /// 拍照识别：原生侧用相机 Intent（FileProvider 取全尺寸图，不申请相机权限）。
  /// 无相机应用时原生自动回退到系统图片选择器。
  static Future<PickedScheduleFile?> capture() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('pick', {
      'kind': 'capture',
    });
    return _fromResult(result, image: true);
  }

  static PickedScheduleFile? _fromResult(
    Map<String, dynamic>? result, {
    required bool image,
  }) {
    if (result == null) return null;
    final bytes = result['bytes'];
    if (bytes is! Uint8List) {
      throw PlatformException(
        code: 'invalid_file',
        message: '系统未能读取所选文件',
      );
    }
    return PickedScheduleFile(
      name: result['name'] as String? ?? (image ? '课表.png' : '课表.xlsx'),
      bytes: bytes,
      mimeType: result['mimeType'] as String? ?? 'application/octet-stream',
    );
  }
}
