/*
 * 后端接口封装。三处与网页版不同，都是小程序平台特性决定的：
 *
 * 1. fetch → wx.request：小程序没有 fetch，但也没有 CORS，不必再处理凭据模式。
 * 2. 刷新令牌从 HttpOnly Cookie 改为本地存储：小程序没有可用 Cookie 的可靠语义。
 *    后端 refresh 接口本就支持 body 传 refresh_token，且「不轮换、有效期固定」，
 *    因此只需存一次、长期复用，不必处理轮换竞态。
 * 3. access token 仍然只放内存，不落盘——与网页版同一安全边界。
 */
const { API_BASE, KEYS } = require("./config");

let accessToken = "";
let refreshInFlight = null;
let onSessionLost = null;

function setSessionLostHandler(handler) {
  onSessionLost = handler;
}

function getAccessToken() {
  return accessToken;
}

function readRefreshToken() {
  try {
    return wx.getStorageSync(KEYS.refreshToken) || "";
  } catch (error) {
    return "";
  }
}

function writeRefreshToken(token) {
  try {
    if (token) wx.setStorageSync(KEYS.refreshToken, token);
    else wx.removeStorageSync(KEYS.refreshToken);
  } catch (error) {
    // 存储写入失败不应中断登录流程，本次会话仍可用
  }
}

function applySession(data) {
  if (data && data.access_token) accessToken = data.access_token;
  if (data && data.refresh_token) writeRefreshToken(data.refresh_token);
}

function clearSession() {
  accessToken = "";
  writeRefreshToken("");
}

function hasRefreshToken() {
  return Boolean(readRefreshToken());
}

// 把后端 {code,message,data} 信封拆开；错误统一带上 status 与 code
function unwrap(response) {
  const body = response.data || {};
  const status = response.statusCode;
  if (status >= 200 && status < 300) return body.data;
  const detail = body.detail && body.detail.message;
  const error = new Error(detail || body.message || "请求失败，请稍后再试");
  error.status = status;
  error.code = (body.detail && body.detail.code != null ? body.detail.code : body.code) || null;
  throw error;
}

function raw(path, options) {
  const opts = options || {};
  const header = Object.assign({}, opts.header || {});
  if (opts.body !== undefined) header["Content-Type"] = "application/json";
  if (opts.auth !== false && accessToken) header.Authorization = `Bearer ${accessToken}`;
  return new Promise((resolve, reject) => {
    wx.request({
      url: API_BASE + path,
      method: (opts.method || "GET").toUpperCase(),
      data: opts.body,
      header,
      timeout: opts.timeout || 20000,
      success: (response) => {
        try {
          resolve(unwrap(response));
        } catch (error) {
          reject(error);
        }
      },
      fail: (error) => {
        // 小程序网络失败的 errMsg 形如 "request:fail timeout"，转成用户能看懂的话
        const failure = new Error(/timeout/i.test(error.errMsg || "") ? "网络超时，请重试" : "网络连接失败，请检查网络后重试");
        failure.status = 0;
        reject(failure);
      },
    });
  });
}

/*
 * 恢复会话：refresh 接口一次往返就把 user 带回来（后端为非 Cookie 凭据也返回 user），
 * 所以启动时不必再串行请求 /api/user/profile。
 */
function refreshSession() {
  const token = readRefreshToken();
  if (!token) return Promise.reject(Object.assign(new Error("没有可用的登录凭据"), { status: 401 }));
  if (refreshInFlight) return refreshInFlight;
  refreshInFlight = raw("/api/auth/refresh", { method: "POST", body: { refresh_token: token }, auth: false })
    .then((data) => {
      applySession(data);
      return data;
    })
    .catch((error) => {
      // 401/403 是明确被拒（令牌过期或已撤销），其余情况保留令牌等下次再试
      if (error.status === 401 || error.status === 403) clearSession();
      throw error;
    })
    .then(
      (value) => { refreshInFlight = null; return value; },
      (error) => { refreshInFlight = null; throw error; }
    );
  return refreshInFlight;
}

/*
 * 业务请求：401 时自动刷新一次并重放（refresh 不轮换令牌，重放是安全的）。
 * 刷新仍失败才判定会话失效，交给上层退回登录页——绝不把网络故障说成「请登录」。
 */
function request(path, options) {
  return raw(path, options).catch((error) => {
    const opts = options || {};
    if (error.status !== 401 || opts.auth === false || opts.__retried) throw error;
    return refreshSession().then(
      () => raw(path, Object.assign({}, opts, { __retried: true })),
      () => {
        if (onSessionLost) onSessionLost();
        throw error;
      }
    );
  });
}

// 上传文件（AI 识别课表截图 / Excel）——uploadFile 的域名白名单与 request 分开配置
function upload(path, filePath, formData, onProgress) {
  return new Promise((resolve, reject) => {
    const task = wx.uploadFile({
      url: API_BASE + path,
      filePath,
      name: "file",
      formData: formData || {},
      header: accessToken ? { Authorization: `Bearer ${accessToken}` } : {},
      timeout: 90000,
      success: (response) => {
        try {
          // uploadFile 的 data 是字符串，需自行解析
          const parsed = Object.assign({}, response, { data: JSON.parse(response.data || "{}") });
          resolve(unwrap(parsed));
        } catch (error) {
          reject(error);
        }
      },
      fail: () => {
        const failure = new Error("文件上传失败，请检查网络后重试");
        failure.status = 0;
        reject(failure);
      },
    });
    if (task && onProgress && task.onProgressUpdate) task.onProgressUpdate(onProgress);
  });
}

module.exports = {
  request,
  raw,
  upload,
  refreshSession,
  applySession,
  clearSession,
  hasRefreshToken,
  getAccessToken,
  setSessionLostHandler,
};
