/*
 * 小程序入口。
 *
 * 启动顺序与网页版一致：先量好版面 → 决定主题 → 恢复登录态（有刷新令牌就一次
 * refresh 换回 user）→ 拉课表；没有令牌时进入游客模式，用本机课表即可查看与建课，
 * 不强制登录（微信审核明确不允许强制登录）。
 */
const store = require("./utils/store");
const api = require("./utils/api");
const sync = require("./utils/sync");
const privacy = require("./utils/privacy");

// 自绘顶栏必须自己对避让状态栏与右上角胶囊：胶囊高度 + 上下间距决定导航栏高度
function measureLayout() {
  let info = {};
  try {
    info = wx.getWindowInfo ? wx.getWindowInfo() : wx.getSystemInfoSync();
  } catch (error) {
    info = {};
  }
  const statusBarHeight = info.statusBarHeight || 20;
  let navBarHeight = 44;
  try {
    const menu = wx.getMenuButtonBoundingClientRect();
    if (menu && menu.height) navBarHeight = (menu.top - statusBarHeight) * 2 + menu.height;
  } catch (error) {
    // 部分环境（如开发者工具早期版本）拿不到胶囊位置，用 44 兜底
  }
  const windowHeight = info.windowHeight || 640;
  const safeBottom = info.safeArea && info.safeArea.bottom
    ? Math.max(0, windowHeight - info.safeArea.bottom)
    : 0;
  store.state.layout = {
    statusBarHeight,
    navBarHeight,
    windowHeight,
    windowWidth: info.windowWidth || 375,
    safeBottom,
  };
  if (info.theme) store.setSystemTheme(info.theme);
}

App({
  onLaunch() {
    measureLayout();
    privacy.install();
    /*
     * 刷新令牌被服务器明确拒绝（过期/被撤销/账号异常）时，api 层会回调这里。
     * 处理方式是退回游客态而不是停在报错页：小程序首屏本来就能用（本机课表），
     * 退成游客不会让用户看到一片空白，他把课表建在本地照样能用。
     */
    api.setSessionLostHandler(() => {
      store.forgetSessionHistory();
      store.clearScheduleCache();
      store.setSnapshot({ semesters: [], courses: [], schedules: [], cursor: 0 });
      store.setUser(null);
      wx.showToast({ title: "登录已过期，请重新登录", icon: "none", duration: 2600 });
    });
    if (wx.onThemeChange) {
      wx.onThemeChange(({ theme }) => store.setSystemTheme(theme));
    }
    store.loadGuestSchedule();
    this.sessionPromise = this.restoreSession();
  },

  /*
   * 恢复登录态。返回 user 或 null（null = 游客）。
   * 只有服务器明确拒绝（401/403）才判定未登录；网络故障时保留令牌，
   * 本次以游客身份可用，下次启动再试——绝不因为网络抖动把用户踢到登录页。
   */
  restoreSession() {
    if (!api.hasRefreshToken()) return Promise.resolve(null);
    return api.refreshSession()
      .then((data) => {
        store.clearSignedOut();
        store.rememberSessionHistory();
        store.setUser(data.user || null);
        return sync.pull(true).then(
          () => store.state.user,
          () => store.state.user
        );
      })
      .catch(() => null);
  },

  // 页面用它等待启动流程结束，避免首屏抢跑在会话恢复之前
  ready() {
    if (!this.sessionPromise) this.sessionPromise = Promise.resolve(null);
    return this.sessionPromise;
  },

  // 登录成功或退出后重置，让下一次 ready() 反映最新状态
  resetSession(user, snapshotReady) {
    store.setUser(user);
    if (user) {
      store.clearSignedOut();
      store.rememberSessionHistory();
      this.sessionPromise = (snapshotReady || sync.pull(true)).then(() => user, () => user);
    } else {
      store.rememberSessionHistory();
      this.sessionPromise = Promise.resolve(null);
    }
    return this.sessionPromise;
  },

  logout() {
    api.request("/api/auth/logout", { method: "POST", body: { refresh_token: store.read(store.KEYS.refreshToken, "") }, auth: false })
      .catch(() => {});
    api.clearSession();
    store.markSignedOut();
    store.forgetSessionHistory();
    store.clearScheduleCache();
    store.setSnapshot({ semesters: [], courses: [], schedules: [], cursor: 0 });
    this.resetSession(null, Promise.resolve(null));
  },
});
