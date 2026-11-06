/*
 * 「我的」页：账号、同步、外观、作息、通知与关于。
 *
 * 与网页版逐项对齐，但有四处必须按平台改写：
 *
 * 1. 账号区不再是「登录页 → 应用」的两段式。小程序首屏就是课表（游客可用），
 *    所以这里是「已登录 / 本机课表」两种状态，而不是登出按钮的开关。
 * 2. 「课程通知」换成微信订阅消息。小程序没有 Web Push，也不能后台定时；
 *    订阅消息必须由用户点击触发、一次授权换一条额度，故文案与交互都按此改写，
 *    并且模板 ID 未配置时不假装能用（见 utils/subscribe.js）。
 * 3. 「iPhone 使用指南」整块删除：那是为 PWA 加到主屏写的，小程序本身就是
 *    可从微信直达的入口，没有等价需求；同一位置换成订阅提醒说明。
 * 4. 官网链接不跳转（个人主体不能用 web-view），改为复制链接。
 */
const store = require("../../utils/store");
const sync = require("../../utils/sync");
const api = require("../../utils/api");
const ui = require("../../utils/ui");
const subscribe = require("../../utils/subscribe");
const { currentSemesterOf, normalizeCourses } = require("../../utils/schedule");

Page({
  data: {
    themeClass: "theme-light",
    statusBarHeight: 20,
    tabBarHeight: 56,
    guest: true,
    userName: "未登录",
    userDesc: "本机课表 · 登录后可跨设备同步",
    avatarChar: "邗",
    themeMode: "system",
    cardDetail: false,
    notifySummary: "登录后查看邀请与系统消息",
    subscribeStatus: "尚未配置订阅消息模板",
    subscribeReady: false,
    aboutSummary: "开发者介绍与支持信息",
    busy: false,
    showSectionTime: false,
    showInbox: false,
    showAbout: false,
    showPrivacy: false,
    showShare: false,
    showSubscribe: false,
    shareCode: "------",
  },

  onLoad() {
    const layout = store.state.layout;
    this.setData({ statusBarHeight: layout.statusBarHeight, tabBarHeight: 56 + (layout.safeBottom || 0) });
    this.unsubscribe = store.subscribe(() => this.render());
    getApp().ready().then(() => {
      this.render();
      this.refreshNotifySummary();
    });
  },

  onShow() {
    if (this.getTabBar) this.getTabBar().setData({ selected: 2 });
    this.render();
    this.refreshNotifySummary();
  },

  onUnload() {
    if (this.unsubscribe) this.unsubscribe();
  },

  render() {
    const user = store.state.user;
    const guest = !user;
    this.setData({
      themeClass: store.themeClass(),
      guest,
      userName: guest ? "未登录" : user.username,
      userDesc: guest ? "本机课表 · 登录后可跨设备同步" : "邗上课表账号 · 数据与 Android / 网页版共享",
      avatarChar: guest ? "邗" : (String(user.username || "邗").trim().charAt(0) || "邗"),
      themeMode: store.state.themeMode,
      cardDetail: store.state.cardDetail,
      subscribeReady: subscribe.isConfigured(),
      subscribeStatus: subscribe.statusText(),
    });
  },

  async refreshNotifySummary() {
    if (store.isGuest()) {
      this.setData({ notifySummary: "登录后查看邀请与系统消息" });
      return;
    }
    try {
      const data = await api.request("/api/notifications?limit=1");
      this.setData({ notifySummary: data.unread ? `${data.unread} 条未读通知` : "暂无未读通知" });
    } catch (error) {
      this.setData({ notifySummary: "查看邀请与系统消息" });
    }
  },

  // ---- 账号 ----

  goLogin() {
    wx.navigateTo({ url: "/pages/login/index" });
  },

  async logout() {
    const ok = await ui.confirm("退出登录", "退出后将清除本机课表缓存，本机不会保留你的课表。", "退出");
    if (!ok) return;
    getApp().logout();
    ui.showMessage("已退出，本机课表缓存已清除");
    this.render();
  },

  // ---- 同步 ----

  async refreshNow() {
    if (store.isGuest()) {
      ui.showMessage("登录后才能从云端同步");
      return wx.navigateTo({ url: "/pages/login/index" });
    }
    if (this.data.busy) return;
    this.setData({ busy: true });
    try {
      await sync.pull(true);
      ui.showMessage("已读取云端最新课表");
    } catch (error) {
      ui.showMessage(`课表读取失败：${error.message}`, true);
    } finally {
      this.setData({ busy: false });
    }
  },

  // ---- 外观与信息密度 ----

  setTheme(event) {
    store.setThemeMode(event.currentTarget.dataset.mode);
    this.render();
  },

  toggleCardDetail() {
    store.setCardDetail(!store.state.cardDetail);
    this.render();
  },

  // ---- 需要账号的入口 ----

  requireLogin() {
    ui.showMessage("该功能需要登录后才能使用");
    setTimeout(() => wx.navigateTo({ url: "/pages/login/index" }), 600);
  },

  openShare() {
    if (store.isGuest()) return this.requireLogin();
    const snapshot = store.activeSnapshot();
    const semester = currentSemesterOf(snapshot);
    if (!semester) return ui.showMessage("请先创建或导入课表", true);
    const courses = normalizeCourses(snapshot, semester);
    if (!courses.length) return ui.showMessage("当前课表还没有课程，先添加课程再分享", true);
    api.request("/api/share/create", { method: "POST", body: { semester_uuid: semester.uuid } })
      .then((data) => {
        this.setData({ shareCode: data.code, showShare: true });
        // 打开分享入口，「发给同学」按钮才可用（默认是关的）
        if (wx.showShareMenu) {
          wx.showShareMenu({ menus: ["shareAppMessage", "shareTimeline"] });
        }
      })
      .catch((error) => ui.showMessage(error.message, true));
  },

  copyShareCode() {
    wx.setClipboardData({ data: this.data.shareCode });
  },

  /*
   * 分享口令做成深链：把口令放进 path，同学点开卡片直接落到导入页并自动填好，
   * 不必再手输 6 位口令。这是小程序相对网页版「复制口令再发」的主要体验升级。
   *
   * 仅在分享弹层打开且口令有效时才带口令；否则退化成分享小程序本身。
   * （onShareAppMessage 必须同步返回，不能在这里发请求现生成口令。）
   */
  onShareAppMessage() {
    const code = this.data.shareCode;
    if (this.data.showShare && /^[A-Z2-9]{6}$/.test(code)) {
      return {
        title: `我分享了一份邗上课表给你 · 口令 ${code}`,
        path: `/pages/import/index?code=${code}`,
      };
    }
    return { title: "邗上课表 — 扬大同学的课表工具", path: "/pages/schedule/index" };
  },

  onShareTimeline() {
    return {
      title: this.onShareAppMessage().title,
      path: this.onShareAppMessage().path,
    };
  },

  openCouple() {
    if (store.isGuest()) return this.requireLogin();
    wx.navigateTo({ url: "/pages/couple/index" });
  },

  openInbox() {
    if (store.isGuest()) return this.requireLogin();
    this.setData({ showInbox: true });
    this.selectComponent("#inbox").open();
  },

  onUnread(event) {
    const unread = event.detail.unread;
    this.setData({ notifySummary: unread ? `${unread} 条未读通知` : "暂无未读通知" });
  },

  // 关于页拿到服务端配置的展示名后，同步到设置行的摘要文案（与网页版一致）
  onAboutName(event) {
    this.setData({ aboutSummary: event.detail.name || "开发者介绍与支持信息" });
  },

  // ---- 作息 / 关于 / 隐私 ----

  openSectionTime() {
    this.setData({ showSectionTime: true });
    this.selectComponent("#sectionTime").open();
  },

  // 调休（放假/补课）：手动添加对游客开放，AI 识别需要账号
  openHoliday() {
    this.setData({ showHoliday: true });
    this.selectComponent("#holiday").open();
  },

  onHolidaySaved() {
    // 调休会影响课表显示（放假当天不排课、补课按指定星期），广播一次让课表页重绘
    store.emit();
  },

  openAbout() {
    this.setData({ showAbout: true });
    this.selectComponent("#about").open();
  },

  openPrivacy() {
    this.setData({ showPrivacy: true });
  },

  setSubscribeStatus() {
    this.setData({ subscribeStatus: subscribe.statusText() });
  },

  /*
   * 课程提醒：走微信订阅消息。必须在用户点击的同步调用链里发起
   * （微信要求 requestSubscribeMessage 由点击触发），授权成功即记一条发送额度。
   */
  requestSubscribe() {
    if (store.isGuest()) return this.requireLogin();
    if (!subscribe.isConfigured()) {
      this.setData({ showSubscribe: true });
      return;
    }
    subscribe.request(this)
      .then((result) => {
        this.setData({ showSubscribe: true });
        if (result === "accept") ui.showMessage("已获得一次课前提醒额度");
      })
      .catch(() => {
        this.setData({ showSubscribe: true });
      });
  },

  closeSheet(event) {
    const key = event.currentTarget.dataset.key;
    this.setData({ [key]: false });
  },

  noop() {},
});
