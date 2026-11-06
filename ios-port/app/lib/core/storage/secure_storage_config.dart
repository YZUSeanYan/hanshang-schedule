import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 敏感数据只在设备首次解锁后可用，且不通过 iCloud Keychain 同步到其他设备。
/// Android 仍使用插件默认的 Keystore 配置。
const appSecureStorage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
  ),
);
