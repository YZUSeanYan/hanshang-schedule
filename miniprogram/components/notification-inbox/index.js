/*
 * 账户通知中心。
 *
 * 网页版是 60 秒轮询 + 打开弹层时加载；小程序沿用同一策略，但轮询只在页面
 * 可见时进行（小程序后台不允许定时器常驻），所以由调用方 onShow 触发一次刷新。
 * 「共同空闲邀请」类通知点击后不再用 iframe 打开模块，改为直接跳到共同空闲页。
 */
const api = require("../../utils/api");
const ui = require("../../utils/ui");
const { formatNotificationTime } = require("../../utils/format");

Component({
  options: { styleIsolation: "apply-shared", multipleSlots: true },

  properties: {
    show: { type: Boolean, value: false },
  },

  data: {
    items: [],
    unread: 0,
    unreadLabel: "",
    hasMore: false,
    loading: false,
    error: "",
  },

  methods: {
    open() {
      this.setData({ show: true });
      this.load(false);
    },

    close() {
      this.setData({ show: false });
      this.triggerEvent("close");
    },

    async load(append) {
      if (this.data.loading) return;
      const beforeId = append ? this.beforeId : null;
      if (!append) this.beforeId = null;
      this.setData({ loading: true, error: "" });
      try {
        const suffix = beforeId ? `&before_id=${beforeId}` : "";
        const data = await api.request(`/api/notifications?limit=20${suffix}`);
        const items = (data.items || []).map((item) => ({
          id: item.id,
          title: item.title || "账户通知",
          body: item.body || "",
          time: formatNotificationTime(item.created_at),
          unread: !item.read_at,
          isInvite: Boolean(item.data && item.data.type === "shared_availability_invite"),
        }));
        this.beforeId = data.next_before_id || null;
        this.setData({
          items: append ? this.data.items.concat(items) : items,
          unread: data.unread || 0,
          unreadLabel: data.unread ? `${data.unread} 条未读` : "全部已读",
          hasMore: Boolean(data.has_more),
          loading: false,
        });
        this.triggerEvent("unread", { unread: data.unread || 0 });
      } catch (error) {
        this.setData({ loading: false, error: error.message || "通知加载失败" });
      }
    },

    loadMore() {
      this.load(true);
    },

    async openItem(event) {
      const id = event.currentTarget.dataset.id;
      const item = this.data.items.find((entry) => entry.id === id);
      if (!item) return;
      if (item.unread) {
        try {
          await api.request(`/api/notifications/${id}/read`, { method: "POST" });
          const items = this.data.items.map((entry) => (entry.id === id ? Object.assign({}, entry, { unread: false }) : entry));
          const unread = Math.max(0, this.data.unread - 1);
          this.setData({ items, unread, unreadLabel: unread ? `${unread} 条未读` : "全部已读" });
          this.triggerEvent("unread", { unread });
        } catch (error) {
          ui.showMessage(error.message || "标记已读失败", true);
          return;
        }
      }
      if (item.isInvite) {
        this.setData({ show: false });
        wx.navigateTo({ url: "/pages/couple/index" });
      }
    },

    async removeItem(event) {
      const id = event.currentTarget.dataset.id;
      try {
        await api.request(`/api/notifications/${id}`, { method: "DELETE" });
        const items = this.data.items.filter((entry) => entry.id !== id);
        this.setData({ items });
      } catch (error) {
        ui.showMessage(error.message || "删除通知失败", true);
      }
    },

    async readAll() {
      try {
        await api.request("/api/notifications/read-all", { method: "POST" });
        await this.load(false);
      } catch (error) {
        ui.showMessage(error.message || "操作失败", true);
      }
    },

    async clearAll() {
      const ok = await ui.confirm("清空通知", "确认清空全部账户通知？此操作无法恢复。", "清空");
      if (!ok) return;
      try {
        await api.request("/api/notifications", { method: "DELETE" });
        await this.load(false);
      } catch (error) {
        ui.showMessage(error.message || "清空通知失败", true);
      }
    },
  },
});
