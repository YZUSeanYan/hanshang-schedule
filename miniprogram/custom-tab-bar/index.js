/*
 * 自定义 tabBar。
 *
 * 用自定义而不是原生 tabBar 的原因：原生 tabBar 的图标只认 PNG 文件，
 * 而本项目的图标是内联 SVG（由 JS 注入颜色）。自定义后既能复用同一套图标，
 * 也能跟随应用内的浅色/深色切换——原生 tabBar 只能跟随系统。
 * 代价是每个 tab 页要在 onShow 里同步 selected（见各页 onShow）。
 */
const store = require("../utils/store");

Component({
  options: { styleIsolation: "apply-shared" },

  data: {
    selected: 0,
    themeClass: "theme-light",
    list: [
      { pagePath: "/pages/schedule/index", text: "课表", icon: "calendar_month", iconFill: "f-calendar_month" },
      { pagePath: "/pages/import/index", text: "导入", icon: "download", iconFill: "f-download" },
      { pagePath: "/pages/profile/index", text: "我的", icon: "person", iconFill: "f-person" },
    ],
  },

  lifetimes: {
    attached() {
      this.syncTheme();
      this.unsubscribe = store.subscribe(() => this.syncTheme());
    },
    detached() {
      if (this.unsubscribe) this.unsubscribe();
    },
  },

  methods: {
    syncTheme() {
      this.setData({ themeClass: store.themeClass() });
    },

    switchTab(event) {
      const index = Number(event.currentTarget.dataset.index);
      const target = this.data.list[index];
      if (!target) return;
      wx.switchTab({ url: target.pagePath });
    },
  },
});
