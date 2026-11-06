/**
 * 应用级配置。移植自 Flutter 版 core/config/app_config.dart。
 *
 * 生产 API 地址：Nginx /yzu/ 反代到后端容器，IP 证书公开受信并自动续期。
 * ⚠️ 禁止改回 HTTP，否则账号、令牌和同步数据会暴露在明文链路上。
 */
export class AppConfig {
  static readonly API_BASE_URL: string = 'https://api.seanyan.store/yzu';

  // M8 可执行准备版本，不代表已签名、上架或生产发布。
  static readonly VERSION_NAME: string = '0.8.0';
  static readonly VERSION_CODE: number = 8;
}
