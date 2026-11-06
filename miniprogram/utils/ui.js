/*
 * 消息提示与确认框。
 *
 * 网页版是自绘的底部浮层 toast；小程序里 wx.showToast 是原生提示，
 * 位置和动效都已由平台保证，比自绘更省事也更符合用户预期，故直接用原生。
 * 唯一例外是「关闭通知弹窗」这类错误文案较长，用 icon:"none" 保证完整显示。
 */
function showMessage(text, isError) {
  if (!text) return;
  wx.showToast({
    title: String(text),
    icon: isError ? "error" : "none",
    duration: isError ? 2600 : 1800,
  });
}

// wx.showModal 的 Promise 包装：确认返回 true，取消返回 false
function confirm(title, content, confirmText) {
  return new Promise((resolve) => {
    wx.showModal({
      title: title || "确认",
      content: content || "",
      confirmText: confirmText || "确定",
      confirmColor: "#BA1A1A",
      cancelText: "取消",
      success: (res) => resolve(Boolean(res.confirm)),
      fail: () => resolve(false),
    });
  });
}

function toastLoading(title) {
  wx.showLoading({ title: title || "处理中", mask: true });
}

function hideLoading() {
  wx.hideLoading();
}

module.exports = { showMessage, confirm, toastLoading, hideLoading };
