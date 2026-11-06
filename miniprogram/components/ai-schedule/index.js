/*
 * 添加日程（AI 识别）——即 App 2.0 的「AI 日程」入口。
 *
 * 与网页版 / App 同一套接口：
 *   POST /api/schedule-ai/parse   body = { text } 或 { image_base64 }
 *   返回 { operations: [{ action, title, date, start_time, end_time,
 *                          location, note, short_title, ... }], transcript }
 *   action: create | reschedule | cancel
 *
 * 小程序侧与网页版同口径：只处理「新增」；调课 / 取消属于改动已有数据，
 * 影响面更大，引导到 App 的完整预览页去做，这里不给半成品入口。
 */
const api = require("../../utils/api");
const sync = require("../../utils/sync");
const store = require("../../utils/store");
const ui = require("../../utils/ui");
const { eventTypeLabel } = require("../../utils/events");

Component({
  options: { styleIsolation: "apply-shared", multipleSlots: true },

  properties: { show: { type: Boolean, value: false } },

  data: {
    text: "",
    busy: false,
    status: "",
    ops: [],
    transcript: "",
    error: "",
  },

  methods: {
    open() {
      this.setData({ show: true, text: "", status: "", ops: [], transcript: "", error: "", busy: false });
    },

    close() {
      this.setData({ show: false });
      this.triggerEvent("close");
    },

    onText(event) {
      this.setData({ text: event.detail.value });
    },

    parseText() {
      const text = this.data.text.trim();
      if (!text) {
        this.setData({ error: "先写下你想记的日程" });
        return;
      }
      this.parse({ text });
    },

    pickImage() {
      wx.requirePrivacyAuthorize({ success: () => this.doPickImage(), fail: () => {} });
    },

    doPickImage() {
      wx.chooseMedia({
        count: 1, mediaType: ["image"], sourceType: ["album", "camera"], sizeType: ["compressed"],
        success: (res) => {
          const file = res.tempFiles && res.tempFiles[0];
          if (!file) return;
          wx.getFileSystemManager().readFile({
            filePath: file.tempFilePath,
            encoding: "base64",
            success: (r) => this.parse({ image_base64: r.data }),
            fail: () => this.setData({ error: "图片读取失败，请重试" }),
          });
        },
        fail: () => {},
      });
    },

    async parse(payload) {
      this.setData({ busy: true, error: "", status: "正在识别…", ops: [], transcript: "" });
      try {
        const result = await api.request("/api/schedule-ai/parse", {
          method: "POST", body: payload, timeout: 60000,
        });
        const ops = (result && result.operations) || [];
        this.setData({
          busy: false,
          status: "",
          transcript: (result && result.transcript) || "",
          ops: ops.map((op) => ({
            action: op.action,
            actionLabel: op.action === "create" ? "新增" : op.action === "reschedule" ? "调课" : "取消",
            title: op.title || op.target || "未命名",
            meta: [op.date || "", op.start_time || "", op.location || ""].filter(Boolean).join(" · ") || "时间待确认",
            canAdd: op.action === "create",
          })),
          pending: ops,
        });
        if (!ops.length) this.setData({ error: "没有识别出日程，换个说法或换张图再试试" });
      } catch (error) {
        this.setData({ busy: false, status: "" });
        ui.showMessage(error.message || "识别失败，请稍后重试", true);
      }
    },

    // 只有「新增」在这里落地；其余引导到 App
    add(event) {
      const index = Number(event.currentTarget.dataset.index);
      const op = (this.data.pending || [])[index];
      if (!op) return;
      const row = sync.buildEvent({
        event_type: op.event_type || "event",
        title: op.title || op.target || "未命名",
        short_title: op.short_title || "",
        date: op.date || "",
        weekday: op.weekday || 0,
        start_time: op.start_time || "",
        end_time: op.end_time || "",
        start_section: op.start_section || 0,
        end_section: op.end_section || 0,
        busy_sections: op.busy_sections || "",
        location: op.location || "",
        note: op.note || this.data.transcript || "",
      }, null, index);
      sync.push({ events: [row] }).then(() => {
        this.setData({ show: false, ops: [], pending: [], text: "" });
        ui.showMessage("日程已添加");
        this.triggerEvent("saved");
      }).catch((error) => ui.showMessage(error.message || "保存失败", true));
    },

    goAppHint() {
      ui.showMessage("调课与取消需要在 App 里确认后生效");
    },
  },
});
