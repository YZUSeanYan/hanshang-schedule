import 'dart:typed_data';
import 'dart:ui' as ui;

/// 图片降采样：把最长边压到 [maxWidth]（保持比例），返回 PNG 字节。
///
/// 用于上传前的体积控制——手机截图动辄 3-8MB，base64 后超过服务端与
/// 网关上限（nginx 4m）会直接 413。降采样后视觉信息足够识别，体积减半以上。
Future<Uint8List> downscaleImage(Uint8List bytes, {int maxWidth = 1600}) async {
  // 先解码看原始尺寸：比目标小就不上采样，原样返回
  final probe = await ui.instantiateImageCodec(bytes);
  final probeFrame = await probe.getNextFrame();
  final originalWidth = probeFrame.image.width;
  probeFrame.image.dispose();
  probe.dispose();
  if (originalWidth <= maxWidth) return bytes;

  final codec = await ui.instantiateImageCodec(bytes, targetWidth: maxWidth);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  if (data == null) return bytes;
  final scaled = data.buffer.asUint8List();
  // 极端情况下 PNG 重编码反而更大（噪声图）：取小者
  return scaled.length < bytes.length ? scaled : bytes;
}
