/*
 * 调休课表（放假 / 补课）。
 *
 * 与网页版同一套模型与同一套接口：
 *   - 手动添加 / 删除：走 sync.push 的 overrides 字段（与课程同语义：uuid + LWW + 墓碑）
 *   - AI 识别通知：POST /api/schedule-ai/holiday-parse，body 为
 *       { text }            粘贴的通知文字
 *       { image_base64 }    通知截图（小程序用 chooseMedia 拿压缩图再读 base64）
 *     返回 { adjustments: [{ date, kind, weekday, note }] }，勾选后保存。
 *
 * kind=off 放假（当天不排课）、kind=makeup 补课（当天按 weekday 那个星期走）。
 * 手动添加对游客也开放（写本机课表）；AI 识别需要账号（服务端调用）。
 */
const store = require("../../utils/store");
const sync = require("../../utils/sync");
const ui = require("../../utils/ui");
const api = require("../../utils/api");
const { activeOverrides, overrideLabelText, isoDate } = require("../../utils/schedule");

const WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];

Component({
  options: { styleIsolation: "apply-shared", multipleSlots: true },

  properties: {
    show: { type: Boolean, value: false },
  },

  data: {
    list: [],
    empty: true,
    kindRange: ["放假（不上课）", "补课（按指定星期）"],
    weekdayRange: WEEKDAYS,
    formKind: 0,
    formDate: "",
    formWeekday: 0,
    formNote: "",
    error: "",
    busy: false,
    aiText: "",
    aiOpen: false,
    aiStatus: "",
    aiParsed: [],
  },

  methods: {
    open() {
      const today = isoDate(new Date());
      this.setData({ show: true, error: "", aiStatus: "", aiParsed: [], aiText: "", formDate: today, busy: false });
      this.refresh();
    },

    close() {
      this.setData({ show: false });
      this.triggerEvent("close");
    },

    refresh() {
      const rows = activeOverrides(store.activeSnapshot())
        .slice()
        .sort((a, b) => String(a.date).localeCompare(String(b.date)))
        .map((row) => ({
          uuid: row.uuid,
          date: row.date,
          kind: row.kind,
          label: overrideLabelText(row),
          isOff: row.kind === "off",
        }));
      this.setData({ list: rows, empty: rows.length === 0, guest: store.isGuest() });
    },

    // ---- 手动添加 ----
    onFormPicker(event) {
      const { field } = event.currentTarget.dataset;
      this.setData({ [field]: Number(event.detail.value) });
    },
    onFormDate(event) {
      this.setData({ formDate: event.detail.value });
    },
    onFormNote(event) {
      this.setData({ formNote: event.detail.value });
    },

    async addOverride() {
      const { formKind, formDate, formWeekday, formNote } = this.data;
      if (!/^\d{4}-\d{2}-\d{2}$/.test(formDate || "")) {
        this.setData({ error: "请选择日期" });
        return;
      }
      const kind = formKind === 1 ? "makeup" : "off";
      const row = sync.buildOverride(
        { date: formDate, kind, weekday: kind === "makeup" ? formWeekday + 1 : 0, note: formNote },
        this.findExisting(formDate),
        0
      );
      this.setData({ busy: true, error: "" });
      try {
        await sync.push({ overrides: [row] });
        this.setData({ busy: false, formNote: "" });
        this.refresh();
        this.triggerEvent("saved");
        ui.showMessage(kind === "off" ? `${formDate} 已设为放假` : `${formDate} 已设为补课`);
      } catch (error) {
        this.setData({ busy: false, error: error.message || "保存失败" });
      }
    },

    findExisting(date) {
      return activeOverrides(store.activeSnapshot()).find((row) => row.date === date) || null;
    },

    async removeOverride(event) {
      const uuid = event.currentTarget.dataset.uuid;
      const row = activeOverrides(store.activeSnapshot()).find((item) => item.uuid === uuid);
      if (!row) return;
      const ok = await ui.confirm("删除调休安排", `删除 ${row.date} 的${overrideLabelText(row)}？`, "删除");
      if (!ok) return;
      try {
        await sync.push({ overrides: [sync.buildOverride(row, row, 0)] });
        // buildOverride 不带 deleted，这里补上墓碑标记
        await sync.push({ overrides: [Object.assign({}, row, { deleted: true, updated_at: Date.now() })] });
        this.refresh();
        this.triggerEvent("saved");
        ui.showMessage("已删除");
      } catch (error) {
        ui.showMessage(error.message || "删除失败", true);
      }
    },

    // ---- AI 识别 ----
    toggleAi() {
      this.setData({ aiOpen: !this.data.aiOpen });
    },

    onAiText(event) {
      this.setData({ aiText: event.detail.value });
    },

    parseText() {
      const text = this.data.aiText.trim();
      if (!text) {
        ui.showMessage("先粘贴通知文字", true);
        return;
      }
      this.parse({ text });
    },

    // 选图 → 读成 base64 → 送识别。小程序用 chooseMedia 拿到的是已压缩的临时文件。
    pickImage() {
      wx.requirePrivacyAuthorize({
        success: () => this.doPickImage(),
        fail: () => {},
      });
    },

    doPickImage() {
      wx.chooseMedia({
        count: 1,
        mediaType: ["image"],
        sourceType: ["album", "camera"],
        sizeType: ["compressed"],
        success: (res) => {
          const file = res.tempFiles && res.tempFiles[0];
          if (!file) return;
          if (file.size > 12 * 1024 * 1024) {
            ui.showMessage("图片不能超过 12 MB，请裁剪后重试", true);
            return;
          }
          this.readBase64(file.tempFilePath).then((base64) => {
            if (base64) this.parse({ image_base64: base64 });
            else ui.showMessage("图片读取失败，请重试", true);
          });
        },
        fail: () => {},
      });
    },

    readBase64(filePath) {
      return new Promise((resolve) => {
        wx.getFileSystemManager().readFile({
          filePath,
          encoding: "base64",
          success: (res) => resolve(res.data),
          fail: () => resolve(null),
        });
      });
    },

    async parse(payload) {
      this.setData({ aiStatus: "正在识别调休通知…预计 20 秒左右，请不要关闭页面", aiParsed: [], busy: true });
      try {
        const data = await api.request("/api/schedule-ai/holiday-parse", {
          method: "POST",
          body: payload,
          timeout: 60000,
        });
        const parsed = (data.adjustments || []).map((item) => ({
          date: item.date,
          kind: item.kind,
          weekday: Number(item.weekday) || 0,
          note: item.note || "",
          label: overrideLabelText(item),
          picked: true,
        }));
        this.setData({ aiStatus: "", aiParsed: parsed, busy: false });
        if (!parsed.length) ui.showMessage("没有识别到调休安排，可换张更清晰的截图或手动添加", true);
      } catch (error) {
        this.setData({ aiStatus: "", busy: false });
        ui.showMessage(error.message || "识别失败，请稍后重试", true);
      }
    },

    togglePick(event) {
      const index = Number(event.currentTarget.dataset.index);
      const list = this.data.aiParsed.slice();
      if (!list[index]) return;
      list[index] = Object.assign({}, list[index], { picked: !list[index].picked });
      this.setData({ aiParsed: list });
    },

    async savePicked() {
      const picked = this.data.aiParsed.filter((item) => item.picked);
      if (!picked.length) {
        ui.showMessage("先勾选要保存的安排", true);
        return;
      }
      this.setData({ busy: true });
      const now = Date.now();
      try {
        // 逐条写入；同一天已有安排则复用其 uuid，让服务端按 LWW 覆盖
        for (let i = 0; i < picked.length; i += 1) {
          const item = picked[i];
          await sync.push({
            overrides: [sync.buildOverride(item, this.findExisting(item.date), i)],
          });
        }
        this.setData({ busy: false, aiParsed: [], aiText: "" });
        this.refresh();
        this.triggerEvent("saved");
        ui.showMessage(`已保存 ${picked.length} 条调休安排`);
      } catch (error) {
        this.setData({ busy: false });
        ui.showMessage(error.message || "保存失败，请重试", true);
      }
    },

    goLogin() {
      wx.navigateTo({ url: "/pages/login/index" });
    },
  },
});
