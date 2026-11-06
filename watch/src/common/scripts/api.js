/**
 * 邗上课表 Watch - 后端 API 封装
 * 服务器: https://hanshang.seanyan.store/yzu/api（FastAPI，nginx 反代）
 * 会话模型: access_token（Bearer）+ refresh_token（JSON body 携带，
 *           滑动续期 365 天、不轮换；401 时刷新一次并重试请求）
 * 单域名直连：旧 IP api.seanyan.store 已停机（2026-09-26），
 * http 明文逃生通道按安全要求移除。
 */
import storage from "@system.storage";
import fetch from "@system.fetch";

const BASE = "https://hanshang.seanyan.store/yzu/api";

export const KEYS = {
  ACCESS: "hs_access_token",
  REFRESH: "hs_refresh_token",
  USER: "hs_user",
  CACHE: "hs_schedule_cache",
  REMINDER: "hs_reminder_enabled",
};

let _def = null;

export function init(def) {
  _def = def;
}

export function storageGet(key) {
  return new Promise((resolve) => {
    storage.get({
      key,
      success: (v) => resolve(v == null ? null : v),
      fail: () => resolve(null),
    });
  });
}

export function storageSet(key, value) {
  return new Promise((resolve) => {
    storage.set({
      key,
      value,
      success: () => resolve(true),
      fail: () => resolve(false),
    });
  });
}

export function storageDelete(key) {
  return new Promise((resolve) => {
    storage.delete({
      key,
      success: () => resolve(true),
      fail: () => resolve(false),
    });
  });
}

function rawFetch(url, { method = "GET", data = null, token = "", timeout = 15000 } = {}) {
  return new Promise((resolve, reject) => {
    let done = false;
    const timer = setTimeout(() => {
      if (!done) { done = true; reject({ status: 0, message: "网络超时" }); }
    }, timeout);
    const header = { "Content-Type": "application/json" };
    if (token) header["Authorization"] = "Bearer " + token;
    // Vela @system.fetch：默认导出是对象，方法名是 fetch.fetch()；
    // 且 data 为对象时需自行 JSON 序列化（框架只对 form 类型做 url encode）。
    const body = data != null && typeof data !== "string" ? JSON.stringify(data) : data;
    fetch.fetch({
      url,
      method,
      data: body,
      header,
      responseType: "json",
      success: (res) => {
        if (!done) { done = true; clearTimeout(timer); resolve(res); }
      },
      fail: (errData, code) => {
        if (!done) { done = true; clearTimeout(timer); reject({ status: code, data: errData }); }
      },
    });
  });
}

export function parseBody(res) {
  let body = res && res.data;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch (e) { body = {}; }
  }
  return body || {};
}

/** 统一错误消息提取（服务端 HTTPException.detail 结构 / 本地超时） */
export function errMsg(e) {
  if (!e) return "网络错误";
  let body = e.data || {};
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch (_) { body = {}; }
  }
  const detail = body.detail || body;
  if (detail && detail.message) return detail.message;
  if (e.message) return e.message;
  return "网络错误，请稍后重试";
}

export function isAuthError(e) {
  return !!(e && e.status === 401);
}

function saveSessionData(body) {
  const def = _def || {};
  const data = body.data || {};
  if (data.access_token) {
    def.accessToken = data.access_token;
    storageSet(KEYS.ACCESS, data.access_token);
  }
  if (data.refresh_token) {
    def.refreshToken = data.refresh_token;
    storageSet(KEYS.REFRESH, data.refresh_token);
  }
  if (data.user) {
    def.user = data.user;
    storageSet(KEYS.USER, JSON.stringify(data.user));
  }
}

/** 刷新 access token（refresh 不轮换，原样返回同一 refresh token） */
export function refresh() {
  const def = _def || {};
  return new Promise((resolve, reject) => {
    if (!def.refreshToken) {
      reject({ status: 401, message: "登录已过期，请重新登录" });
      return;
    }
    rawFetch(BASE + "/auth/refresh", { method: "POST", data: { refresh_token: def.refreshToken } })
      .then((res) => {
        if (res.code >= 200 && res.code < 300) {
          const body = parseBody(res);
          saveSessionData(body);
          resolve(body);
        } else {
          reject({ status: res.code, message: "登录已过期，请重新登录" });
        }
      })
      .catch((e) => reject({ status: e.status || 401, message: "登录已过期，请重新登录" }));
  });
}

/** 带鉴权请求：401 时自动刷新一次并重试 */
export function apiRequest({ path, method = "GET", data = null, auth = true, timeout = 15000 }) {
  return new Promise((resolve, reject) => {
    const def = _def || {};
    const attempt = (token, retried) => {
      rawFetch(BASE + path, { method, data, token, timeout })
        .then((res) => {
          if (res.code >= 200 && res.code < 300) {
            resolve(parseBody(res));
            return;
          }
          if (auth && res.code === 401 && !retried) {
            refresh().then(() => attempt(def.accessToken, true)).catch(reject);
            return;
          }
          const body = parseBody(res);
          const detail = body.detail || body;
          reject({ status: res.code, message: (detail && detail.message) || ("请求失败(" + res.code + ")") });
        })
        .catch((e) => {
          if (auth && e.status === 401 && !retried) {
            refresh().then(() => attempt(def.accessToken, true)).catch(reject);
            return;
          }
          reject(e);
        });
    };
    attempt(def.accessToken || "", false);
  });
}

/**
 * 配对码登录：手机端「邗上课表」生成 6 位码绑定账号，
 * 手表输码换 token（后端 /auth/device-pair/claim）。
 */
export function pairClaim(code) {
  return new Promise((resolve, reject) => {
    apiRequest({ path: "/auth/device-pair/claim", method: "POST", data: { code }, auth: false })
      .then((body) => { saveSessionData(body); resolve(body); })
      .catch(reject);
  });
}

export function sharePreview(code) {
  return apiRequest({ path: "/share/" + encodeURIComponent(code), method: "GET" });
}

export function shareClaim(code, replace) {
  return apiRequest({
    path: "/share/" + encodeURIComponent(code) + "/claim",
    method: "POST",
    data: { replace_existing: !!replace },
  });
}

export function pullSchedule() {
  return apiRequest({ path: "/sync/pull?since=0", method: "GET", timeout: 20000 });
}

export function logout() {
  const def = _def || {};
  if (def.refreshToken) {
    apiRequest({
      path: "/auth/logout",
      method: "POST",
      data: { refresh_token: def.refreshToken },
      auth: false,
    }).catch(() => {});
  }
  def.accessToken = "";
  def.refreshToken = "";
  def.user = null;
  def.semesters = [];
  def.courses = [];
  def.schedules = [];
  def.courseMap = {};
  def.currentSemester = null;
  storageDelete(KEYS.ACCESS);
  storageDelete(KEYS.REFRESH);
  storageDelete(KEYS.USER);
  storageDelete(KEYS.CACHE);
}
