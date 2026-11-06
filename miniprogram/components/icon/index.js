/*
 * 图标组件：把 utils/icons.js 里的 Material Symbols path 渲染成内联 SVG 背景图。
 *
 * 为什么不用 <image src="xxx.svg">：小程序对外部 SVG 的支持在各端不一致，
 * 且无法像网页版那样用 currentColor 跟随文字颜色。背景图 + 运行时注入 fill
 * 是唯一能在三端稳定拿到正确颜色的做法，也是 tone 属性存在的原因。
 */
const { PATHS } = require("../../utils/icons");
const theme = require("../../utils/theme");
const store = require("../../utils/store");

const uriCache = {};

function buildStyle(name, sizeRpx, color) {
  const path = PATHS[name];
  if (!path) return "";
  const key = `${name}|${color}`;
  if (!uriCache[key]) {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path fill="${color}" d="${path}"/></svg>`;
    // encodeURIComponent 会把 # 转义，否则 data URI 里的颜色会被当成 fragment
    uriCache[key] = `data:image/svg+xml,${encodeURIComponent(svg)}`;
  }
  return `width:${sizeRpx}rpx;height:${sizeRpx}rpx;background-image:url("${uriCache[key]}")`;
}

Component({
  options: { styleIsolation: "apply-shared" },

  properties: {
    name: { type: String, value: "" },
    size: { type: Number, value: 40 },
    tone: { type: String, value: "on-surface" },
  },

  data: { iconStyle: "" },

  lifetimes: {
    attached() {
      this.unsubscribe = store.subscribe(() => this.refresh());
      this.refresh();
    },
    detached() {
      if (this.unsubscribe) this.unsubscribe();
    },
  },

  observers: {
    "name, size, tone": function refreshObserver() {
      this.refresh();
    },
  },

  methods: {
    refresh() {
      const { name, size, tone } = this.data;
      const color = theme.colorOf(tone, store.isDark());
      this.setData({ iconStyle: buildStyle(name, size, color) });
    },
  },
});
