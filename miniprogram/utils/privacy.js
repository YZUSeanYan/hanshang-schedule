/*
 * 小程序隐私授权流程。
 *
 * 微信要求：调用相册/相机、聊天文件等涉及用户信息的接口前，必须在
 * 「公众平台 → 设置 → 服务内容声明 → 用户隐私保护指引」中声明用途，
 * 并在代码里先取得用户同意。本模块把官方回调包装成「弹自己的隐私弹窗 →
 * 用户点同意 → 放行」的流程，与网页版已有的隐私政策弹窗共用同一份文案。
 *
 * 未同意时调用隐私接口，微信会回调 onNeedPrivacyAuthorization；我们在这里
 * 记下 resolve，交给页面上的弹窗按钮（open-type="agreePrivacyAuthorization"）
 * 去解决。低版本基础库没有这套能力，直接放行，不影响老设备使用。
 */
const listeners = [];
let pendingResolve = null;

function install() {
  if (!wx.onNeedPrivacyAuthorization) return;
  wx.onNeedPrivacyAuthorization((resolve, eventInfo) => {
    pendingResolve = resolve;
    if (!listeners.length) {
      // 没有页面接管（异常路径）时不应把用户卡死：直接放行由平台决定
      resolve({ event: "agree" });
      pendingResolve = null;
      return;
    }
    listeners.slice().forEach((handler) => handler(eventInfo || {}));
  });
}

function subscribe(handler) {
  listeners.push(handler);
  return function unsubscribe() {
    const index = listeners.indexOf(handler);
    if (index >= 0) listeners.splice(index, 1);
  };
}

// 由「同意并继续」按钮调用（open-type="agreePrivacyAuthorization" 的回调）
function agree(buttonId) {
  if (!pendingResolve) return;
  const resolve = pendingResolve;
  pendingResolve = null;
  resolve({ buttonId: buttonId || "privacy-agree", event: "agree" });
}

function disagree() {
  if (!pendingResolve) return;
  const resolve = pendingResolve;
  pendingResolve = null;
  resolve({ event: "disagree" });
}

/*
 * 主动查询是否需要授权。返回 true 表示可以直接调用隐私接口。
 * 老基础库没有该接口，一律放行。
 */
function needAuthorization() {
  return new Promise((resolve) => {
    if (!wx.getPrivacySetting) return resolve(false);
    wx.getPrivacySetting({
      success: (res) => resolve(Boolean(res.needAuthorization)),
      fail: () => resolve(false),
    });
  });
}

module.exports = { install, subscribe, agree, disagree, needAuthorization, hasPending: () => Boolean(pendingResolve) };
