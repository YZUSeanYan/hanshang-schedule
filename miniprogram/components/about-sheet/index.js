/*
 * 关于邗上课表。
 *
 * 网页版点击后串行拉 /api/about 与 /api/version/latest，并在失败时给「重新加载」。
 * 小程序沿用同一接口与同一降级策略（版本行拿不到就整行隐藏，不显示空白）。
 * 唯一的差别是官网链接：个人主体小程序不能用 web-view，故不提供点击跳转，
 * 改为长按复制链接，避免给出一个点了没反应的死链。
 */
const api = require("../../utils/api");
const { API_BASE } = require("../../utils/config");

Component({
  options: { styleIsolation: "apply-shared", multipleSlots: true },

  properties: {
    show: { type: Boolean, value: false },
  },

  data: {
    loading: true,
    error: "",
    name: "邗上课表",
    version: "",
    intro: "",
    avatar: "",
    website: "",
    paymentQr: "",
  },

  methods: {
    open() {
      this.setData({ show: true });
      this.load();
    },

    close() {
      this.setData({ show: false });
      this.triggerEvent("close");
    },

    async load() {
      this.setData({ loading: true, error: "" });
      try {
        const data = await api.request("/api/about");
        const patch = {
          loading: false,
          name: data.display_name || "邗上课表",
          avatar: data.avatar_media ? this.mediaUrl(data.avatar_media) : "",
          intro: data.intro || "",
          paymentQr: data.payment_qr_media ? this.mediaUrl(data.payment_qr_media) : "",
          website: /^https:\/\//.test(data.website_url || "") ? data.website_url : "",
        };
        this.setData(patch);
        this.triggerEvent("name", { name: patch.name });
        try {
          const version = await api.request("/api/version/latest");
          this.setData({ version: version.version_name ? `版本 ${version.version_name}` : "" });
        } catch (error) {
          // 版本接口失败不阻塞关于页，隐藏版本行即可
          this.setData({ version: "" });
        }
      } catch (error) {
        this.setData({ loading: false, error: error.message || "暂时无法加载介绍内容" });
      }
    },

    mediaUrl(name) {
      return `${API_BASE}/api/about/media/${encodeURIComponent(name)}`;
    },

    copyWebsite() {
      if (!this.data.website) return;
      wx.setClipboardData({ data: this.data.website });
    },
  },
});
