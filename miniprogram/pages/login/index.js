/*
 * 登录 / 注册。
 *
 * 与网页版同一套接口（/api/auth/login、/api/auth/register）和同一套字段校验，
 * 但入口形态不同：网页版是「先登录才能看到课表」，小程序把登录做成二级页，
 * 因为首屏必须能用（游客可查看与手动建课），只有云同步、AI 导入、共同空闲
 * 这些确实依赖账号的功能才引导到这里——微信审核不接受强制登录。
 *
 * 令牌处理：登录响应里带 refresh_token，存进本地存储供下次启动静默恢复。
 * 后端 refresh 不轮换令牌，因此不存在多端互相顶掉的问题。
 */
const store = require("../../utils/store");
const api = require("../../utils/api");
const ui = require("../../utils/ui");

Page({
  data: {
    themeClass: "theme-light",
    statusBarHeight: 20,
    mode: "login",
    account: "",
    password: "",
    username: "",
    email: "",
    registerPassword: "",
    error: "",
    busy: false,
  },

  onLoad() {
    this.unsubscribe = store.subscribe(() => this.setData({ themeClass: store.themeClass() }));
    this.setData({
      statusBarHeight: store.state.layout.statusBarHeight,
      themeClass: store.themeClass(),
    });
  },

  onUnload() {
    if (this.unsubscribe) this.unsubscribe();
  },

  switchMode(event) {
    this.setData({ mode: event.currentTarget.dataset.mode, error: "" });
  },

  onInput(event) {
    this.setData({ [event.currentTarget.dataset.field]: event.detail.value });
  },

  async submitLogin() {
    const account = this.data.account.trim();
    const password = this.data.password;
    if (!account || !password) return this.setData({ error: "请填写账号与密码" });
    await this.authenticate("/api/auth/login", { account, password });
  },

  async submitRegister() {
    const username = this.data.username.trim();
    const email = this.data.email.trim();
    const password = this.data.registerPassword;
    if (username.length < 3 || username.length > 32) return this.setData({ error: "用户名需为 3-32 个字符" });
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return this.setData({ error: "请填写有效的邮箱" });
    if (password.length < 8) return this.setData({ error: "密码至少 8 位" });
    await this.authenticate("/api/auth/register", { username, email, password });
  },

  async authenticate(path, payload) {
    if (this.data.busy) return;
    this.setData({ busy: true, error: "" });
    try {
      const data = await api.request(path, { method: "POST", body: payload, auth: false });
      api.applySession(data);
      // 先用登录响应里的 user 建会话，再拉一次课表；ready() 会在拉完后兑现
      await getApp().resetSession(data.user, require("../../utils/sync").pull(true).catch(() => {}));
      this.setData({ password: "", registerPassword: "", busy: false });
      ui.showMessage(`欢迎回来，${data.user.username}`);
      // 登录页是二级页，返回后由课表页的订阅回调重绘
      setTimeout(() => wx.navigateBack({ delta: 1, fail: () => wx.switchTab({ url: "/pages/schedule/index" }) }), 700);
    } catch (error) {
      this.setData({ busy: false, error: error.message || "登录失败，请稍后再试", password: "", registerPassword: "" });
    }
  },

  continueAsGuest() {
    wx.navigateBack({ delta: 1, fail: () => wx.switchTab({ url: "/pages/schedule/index" }) });
  },
});
