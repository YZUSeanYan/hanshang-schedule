/// 应用级配置。
///
/// API 地址通过 --dart-define 注入，例如：
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
/// 说明：
/// - 安卓模拟器访问宿主机用 http://10.0.2.2:8000；
/// - 真机调试填电脑的局域网 IP；
/// - 正式版只允许 HTTPS；HTTP 仅用于 debug 构建的本机/局域网联调；
/// - 正式构建必须显式注入线上地址，例如：
///   flutter build apk --dart-define=API_BASE_URL=https://your-api-host/yzu
class AppConfig {
  AppConfig._();

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    // 默认仅用于本地开发（本机/模拟器）。正式版禁止使用 HTTP，
    // 请通过 --dart-define 注入带 HTTPS 的线上地址。
    defaultValue: 'http://localhost:8000',
  );

  /// iOS 手动“检查更新”跳转地址。App Store 条目创建后由构建参数注入。
  static const String iosAppStoreUrl = String.fromEnvironment(
    'IOS_APP_STORE_URL',
    defaultValue: '',
  );

  static const String aliyunPushAppKey = String.fromEnvironment(
    'ALIYUN_PUSH_APP_KEY',
    defaultValue: '',
  );

  static const String aliyunPushAppSecret = String.fromEnvironment(
    'ALIYUN_PUSH_APP_SECRET',
    defaultValue: '',
  );

  static Uri? trustedIosAppStoreUri([String value = iosAppStoreUrl]) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != 'apps.apple.com') {
      return null;
    }
    return uri;
  }
}
