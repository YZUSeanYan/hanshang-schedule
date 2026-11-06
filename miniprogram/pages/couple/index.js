/*
 * 共同空闲（与同学/朋友比对哪些节次双方都没课）。
 *
 * 数据来源与网页版一致：/api/couple-schedule/*（需带 X-App-Module 头），
 * 服务器只按账号隔离地回传忙/闲状态，看不到对方的课程名、教师、教室。
 *
 * 与网页版的两处差异：
 * 1. 网页版把模块放在 iframe 里（用 postMessage 与宿主共享会话），小程序没有
 *    iframe，也没有 web-view（个人主体不支持），所以直接做成一个普通页面，
 *    反而更简单——少了那层 /api/app-manifest + /api/app-modules/session 的
 *    模块启动握手，因为小程序里这段代码本身就是受控的。
 * 2. 邀请码的临时保存从 sessionStorage 换成内存 + 本地存储，因为小程序关掉后
 *    sessionStorage 不保证留存，而邀请码 15 分钟内有效，用户很可能中途退出。
 */
const store = require("../../utils/store");
const api = require("../../utils/api");
const ui = require("../../utils/ui");
const { isoDate } = require("../../utils/format");

const MODULE_HEADER = { "X-App-Module": "couple_schedule" };
const CODE_KEY = "hanshang-mp-avail-code-v1";

const STATE_LABELS = {
  both_free: "双方都空闲",
  me_busy: "我有课",
  partner_busy: "对方有课",
  both_busy: "双方都有课",
};

function request(path, options) {
  const opts = options || {};
  return api.request(`/api/couple-schedule${path}`, Object.assign({}, opts, {
    header: Object.assign({}, MODULE_HEADER, opts.header || {}),
  }));
}

// 与安卓 _freeRanges 一致：把连续 both_free 合并成「第1-2节、第5节」
function freeRanges(states) {
  const result = [];
  let start = -1;
  for (let index = 0; index <= states.length; index += 1) {
    const free = index < states.length && states[index] === "both_free";
    if (free && start < 0) start = index + 1;
    if (!free && start > 0) {
      result.push(start === index ? `第${start}节` : `${start}-${index}节`);
      start = -1;
    }
  }
  return result;
}

function startOfWeek(value) {
  const date = new Date(value);
  date.setHours(12, 0, 0, 0);
  const day = date.getDay() || 7;
  date.setDate(date.getDate() - day + 1);
  return date;
}

Page({
  data: {
    themeClass: "theme-light",
    statusBarHeight: 20,
    view: "loading",          // loading | disconnected | waiting | connected
    waitingKind: "",          // username | code | missing
    message: "",
    messageError: false,
    partnerName: "",
    partnerChar: "?",
    outgoingName: "",
    inviteCode: "",
    codeExpiry: "",
    claimCode: "",
    inviteUsername: "",
    searchResults: [],
    searchEmpty: false,
    invitations: [],
    days: [],
    weekRange: "",
    legend: [
      { state: "both_free", text: "双方都空闲" },
      { state: "me_busy", text: "我有课" },
      { state: "partner_busy", text: "对方有课" },
      { state: "both_busy", text: "双方都有课" },
    ],
  },

  onLoad(options) {
    this.monday = startOfWeek(new Date());
    this.setData({
      themeClass: store.themeClass(),
      statusBarHeight: store.state.layout.statusBarHeight,
    });
    this.unsubscribe = store.subscribe(() => this.setData({ themeClass: store.themeClass() }));

    // 分享卡片深链：?code=邀请码（见 onShareAppMessage），落地就填好，免手输 8 位
    const code = String((options && options.code) || "")
      .toUpperCase().replace(/[^2-9A-HJ-NP-Z]/g, "").slice(0, 8);
    if (code.length === 8) this.setData({ claimCode: code });

    getApp().ready().then(() => {
      if (store.isGuest()) {
        this.setData({ view: "disconnected" });
        this.setMessage("共同空闲需要登录后使用");
        return;
      }
      this.refresh();
    });
  },

  /*
   * 分享邀请码做成深链（同 profile 页的口令分享）：卡片里带 code，
   * 对方点开就填好、点「连接」即可，省掉手动输入 8 位邀请码。
   */
  onShareAppMessage() {
    const code = this.data.inviteCode;
    if (this.data.waitingKind === "code" && /^[2-9A-HJ-NP-Z]{8}$/.test(code)) {
      return {
        title: `我的邗上课表共同空闲邀请码：${code}（15 分钟内有效）`,
        path: `/pages/couple/index?code=${code}`,
      };
    }
    return { title: "邗上课表 · 共同空闲：一起找都有空的节次", path: "/pages/couple/index" };
  },

  onShareTimeline() {
    const share = this.onShareAppMessage();
    return { title: share.title, path: share.path };
  },

  onUnload() {
    if (this.unsubscribe) this.unsubscribe();
    if (this.searchTimer) clearTimeout(this.searchTimer);
  },

  setMessage(text, error) {
    this.setData({ message: text || "", messageError: Boolean(error) });
  },

  storedCode() {
    const item = store.read(CODE_KEY, null);
    if (item && item.code && Date.parse(item.expires_at) > Date.now()) return item;
    store.remove(CODE_KEY);
    return null;
  },

  async refresh() {
    this.setData({ view: "loading" });
    this.setMessage("");
    try {
      const data = await request("/status");
      if (data.state === "connected") {
        store.remove(CODE_KEY);
        this.setData({
          view: "connected",
          partnerName: data.partner.username,
          partnerChar: (String(data.partner.username || "?").trim().charAt(0)) || "?",
        });
        await this.loadWeek();
      } else if (data.state === "waiting" && data.invite_type === "username" && data.outgoing) {
        this.outgoingInvitationId = data.outgoing.invitation_id;
        this.setData({ view: "waiting", waitingKind: "username", outgoingName: data.outgoing.username || "对方" });
      } else if (data.state === "waiting" && data.invite_type === "code") {
        const item = this.storedCode();
        if (item) this.showCodeWaiting(item);
        else this.setData({ view: "waiting", waitingKind: "missing" });
      } else {
        store.remove(CODE_KEY);
        this.setData({
          view: "disconnected",
          invitations: (data.invitations || []).map((invite) => ({
            id: invite.invitation_id,
            label: `${invite.username} 邀请你查看共同空闲`,
          })),
        });
      }
    } catch (error) {
      this.setData({ view: "disconnected" });
      this.setMessage(error.message || "暂时无法读取连接状态", true);
    }
  },

  showCodeWaiting(item) {
    const minutes = Math.max(1, Math.ceil((Date.parse(item.expires_at) - Date.now()) / 60000));
    this.setData({
      view: "waiting",
      waitingKind: "code",
      inviteCode: item.code,
      codeExpiry: `约 ${minutes} 分钟后失效。对方输入即表示同意建立连接。`,
    });
    // 打开分享入口，让「发给对方」这个按钮可用（默认是关的）
    if (wx.showShareMenu) {
      wx.showShareMenu({ menus: ["shareAppMessage", "shareTimeline"] });
    }
  },

  // ---- 按用户名邀请 ----

  onUsernameInput(event) {
    const value = event.detail.value;
    this.setData({ inviteUsername: value });
    if (this.searchTimer) clearTimeout(this.searchTimer);
    if (value.trim().length < 2) {
      this.setData({ searchResults: [], searchEmpty: false });
      return;
    }
    this.searchTimer = setTimeout(() => this.searchUsers(), 280);
  },

  async searchUsers() {
    const query = this.data.inviteUsername.trim();
    if (query.length < 2) return;
    try {
      const data = await request(`/users/search?q=${encodeURIComponent(query)}`);
      const items = (data.items || []).map((item) => item.username);
      this.setData({ searchResults: items, searchEmpty: !items.length });
    } catch (error) {
      this.setData({ searchResults: [], searchEmpty: false });
      this.setMessage(error.message, true);
    }
  },

  pickUser(event) {
    this.setData({ inviteUsername: event.currentTarget.dataset.name, searchResults: [], searchEmpty: false });
    this.sendInvite();
  },

  async sendInvite() {
    const username = this.data.inviteUsername.trim();
    if (!username) return;
    this.setMessage("");
    try {
      await request("/invites", { method: "POST", header: { "Content-Type": "application/json" }, body: { username } });
      this.setData({ searchResults: [], searchEmpty: false });
      this.setMessage("邀请已发送，等待对方确认");
      await this.refresh();
    } catch (error) {
      this.setMessage(error.message, true);
    }
  },

  // ---- 邀请码 ----

  async createCode() {
    try {
      const data = await request("/invites", { method: "POST" });
      const item = { code: data.code, expires_at: data.expires_at };
      store.write(CODE_KEY, item);
      this.setMessage("邀请码已生成，15 分钟内有效");
      this.showCodeWaiting(item);
    } catch (error) {
      this.setMessage(error.message, true);
    }
  },

  onClaimInput(event) {
    this.setData({ claimCode: String(event.detail.value || "").toUpperCase().replace(/[^2-9A-HJ-NP-Z]/g, "").slice(0, 8) });
  },

  async claimCode() {
    const code = this.data.claimCode.trim();
    if (!code) return;
    try {
      await request("/claim", { method: "POST", header: { "Content-Type": "application/json" }, body: { code } });
      store.remove(CODE_KEY);
      this.setData({ claimCode: "" });
      this.setMessage("连接成功，只会共享忙闲状态");
      await this.refresh();
    } catch (error) {
      this.setMessage(error.message, true);
    }
  },

  copyCode() {
    if (!this.data.inviteCode) return;
    wx.setClipboardData({ data: this.data.inviteCode });
  },

  async cancelCode() {
    try {
      await request("/invite-code", { method: "DELETE" });
      store.remove(CODE_KEY);
      this.setMessage("邀请码已取消");
      await this.refresh();
    } catch (error) {
      this.setMessage(error.message, true);
    }
  },

  async cancelInvite() {
    if (!this.outgoingInvitationId) return;
    try {
      await request(`/invites/${encodeURIComponent(this.outgoingInvitationId)}`, { method: "DELETE" });
      this.setMessage("已撤回邀请");
      await this.refresh();
    } catch (error) {
      this.setMessage(error.message, true);
    }
  },

  async respond(event) {
    const { id, accept } = event.currentTarget.dataset;
    try {
      await request("/invites/respond", {
        method: "POST",
        header: { "Content-Type": "application/json" },
        body: { invitation_id: id, accept: accept === "true" || accept === true },
      });
      this.setMessage(accept === "true" || accept === true ? "已接受邀请" : "已拒绝邀请");
      await this.refresh();
    } catch (error) {
      this.setMessage(error.message, true);
    }
  },

  async disconnect() {
    const ok = await ui.confirm("解除连接", "确认解除连接？双方将立即无法查看彼此忙闲状态。", "解除");
    if (!ok) return;
    try {
      await request("/connection", { method: "DELETE" });
      this.setMessage("已解除连接");
      await this.refresh();
    } catch (error) {
      this.setMessage(error.message, true);
    }
  },

  // ---- 周视图 ----

  prevWeek() {
    this.monday.setDate(this.monday.getDate() - 7);
    this.loadWeek();
  },

  nextWeek() {
    this.monday.setDate(this.monday.getDate() + 7);
    this.loadWeek();
  },

  async loadWeek() {
    try {
      const data = await request(`/week?week_start=${isoDate(this.monday)}`);
      const end = new Date(this.monday);
      end.setDate(end.getDate() + 6);
      const names = ["一", "二", "三", "四", "五", "六", "日"];
      const days = (data.days || []).map((day) => {
        const date = new Date(`${String(day.date).slice(0, 10)}T00:00:00`);
        const valid = !Number.isNaN(date.getTime());
        const ranges = freeRanges(day.states || []);
        return {
          key: String(day.date),
          title: valid ? `周${names[day.day - 1]} ${date.getMonth() + 1}/${date.getDate()}` : `周${names[day.day - 1]}`,
          free: ranges.length ? `空闲 ${ranges.join("、")}` : "暂无共同空闲",
          hasFree: ranges.length > 0,
          cells: (day.states || []).map((state, index) => ({
            key: `${day.date}-${index}`,
            num: index + 1,
            state,
            label: `${STATE_LABELS[state] || "状态未知"}`,
          })),
        };
      });
      this.setData({
        days,
        weekRange: `${this.monday.getMonth() + 1}月${this.monday.getDate()}日 — ${end.getMonth() + 1}月${end.getDate()}日`,
      });
    } catch (error) {
      this.setData({ days: [] });
      this.setMessage(error.message || "这一周暂时无法读取，请稍后重试。", true);
    }
  },

  goLogin() {
    wx.navigateTo({ url: "/pages/login/index" });
  },

  back() {
    wx.navigateBack({ delta: 1, fail: () => wx.switchTab({ url: "/pages/profile/index" }) });
  },
});
