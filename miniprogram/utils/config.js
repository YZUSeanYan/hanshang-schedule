/*
 * 接口基址与全局常量。
 *
 * 微信要求小程序 request 合法域名必须是「已完成 ICP 备案的 HTTPS 域名」，
 * 不支持 IP、不支持非 443 端口。本项目沿用网页版同源反代 /web-api，
 * 因此只需在「微信公众平台 → 开发管理 → 服务器域名」把
 *   https://hanshang.seanyan.store
 * 同时加入 request 与 uploadFile 两个白名单即可（备案号 苏ICP备2026057230号）。
 *
 * 若要直连后端（api.seanyan.store），改成 https://api.seanyan.store/yzu 亦可，
 * 但需把该域名另行加入白名单。
 */
const API_BASE = "https://hanshang.seanyan.store/web-api";

// 与网页版一致的本地存储键，便于日后排查与跨端对照
const KEYS = {
  refreshToken: "hanshang-mp-refresh-token-v1",
  sessionHistory: "hanshang-session-established-v1",
  signedOut: "hanshang-explicit-signout-v1",
  scheduleCache: "hanshang-mp-offline-schedule-v1",
  sectionTimes: "hanshang-section-times-v1",
  themeMode: "hanshang-theme-mode-v1",
  cardDetail: "hanshang-card-detail-v1",
  guideSeen: "hanshang-mp-guide-seen-v1",
  notificationPrompt: "hanshang-mp-notification-consent-v1",
  subscribeQuota: "hanshang-mp-subscribe-quota-v1",
  guestSchedule: "hanshang-mp-guest-schedule-v1",
};

const DAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];

/*
 * 课前提醒用的微信订阅消息模板 ID。
 * 需要在「微信公众平台 → 功能 → 订阅消息」按小程序的类目申请一次性订阅模板，
 * 把返回的模板 ID 填到这里；留空时「课程提醒」入口会如实显示未配置，
 * 而不是给出一个点了没反应的按钮（见 utils/subscribe.js 顶部说明）。
 */
const SUBSCRIBE_TEMPLATE_ID = "";

module.exports = { API_BASE, KEYS, DAYS, SUBSCRIBE_TEMPLATE_ID };
