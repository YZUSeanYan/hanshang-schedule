import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 手表 BLE 课表传输（封装原生 GATT Server）。
///
/// 手机端开启广播（Service 8F2A0001 + 可读 Characteristic 8F2A0002），
/// 手表 GATT Client 每 read 一次，原生端返回下一分片（协议见 WatchBleTransfer.kt）。
class WatchBleService {
  static const _channel = MethodChannel('hanshang/ble');
  static const _stateChannel = EventChannel('hanshang/ble/state');

  /// 开启广播与 GATT Server；返回 true = 已开始，false = 刚请求了权限需重试。
  Future<bool> startTransfer(String json) async {
    final result = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('startTransfer', {'json': json});
    return result?['permission'] == 'granted';
  }

  Future<void> stopTransfer() => _channel.invokeMethod('stopTransfer');

  /// 状态流：advertising / connected / done / advertise_failed / disconnected
  Stream<Map<dynamic, dynamic>> get stateStream =>
      _stateChannel.receiveBroadcastStream().cast<Map<dynamic, dynamic>>();
}

final watchBleServiceProvider = Provider<WatchBleService>(
  (ref) => WatchBleService(),
);
