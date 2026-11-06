/*
 * 每节课时间（作息）。
 *
 * 与网页版同一套存储格式与校验（utils/section-times.js）：自动模式按上课日期
 * 在春夏/秋冬之间切换，自定义模式全年固定。这里把网页版的 input[type=time]
 * 换成 picker mode="time"（小程序没有原生时间输入框）。
 *
 * 一个刻意的行为保留：网页版在切换课表时不阻止未保存的修改，只有在关闭弹层时
 * 才确认「放弃未保存的时间修改」；小程序沿用同一策略。
 */
const store = require("../../utils/store");
const ui = require("../../utils/ui");
const sectionTimes = require("../../utils/section-times");

const ROWS = 12;

function buildRows(times) {
  return times.map((pair, index) => ({
    key: `r${index + 1}`,
    label: `第 ${index + 1} 节`,
    start: pair[0],
    end: pair[1],
  }));
}

Component({
  options: { styleIsolation: "apply-shared", multipleSlots: true },

  properties: {
    show: { type: Boolean, value: false },
  },

  data: {
    rows: [],
    automatic: true,
    error: "",
    saving: false,
  },

  methods: {
    open() {
      const config = store.state.timeConfig;
      this.setData({
        show: true,
        automatic: config.mode !== "custom",
        rows: buildRows(sectionTimes.forDate(config, new Date())),
        error: "",
        saving: false,
      });
    },

    close() {
      this.setData({ show: false });
      this.triggerEvent("close");
    },

    toggleAutomatic(event) {
      const automatic = event.detail.value;
      this.setData({
        automatic,
        rows: automatic ? buildRows(sectionTimes.defaults(new Date())) : this.data.rows,
      });
    },

    onTimeChange(event) {
      const { index, field } = event.currentTarget.dataset;
      this.setData({ [`rows[${index}].${field}`]: event.detail.value });
    },

    // 与网页版一致：春夏取 7 月 1 日、秋冬取 11 月 1 日的默认作息作为模板
    fillSeason(event) {
      const season = event.currentTarget.dataset.season;
      const anchor = season === "winter" ? new Date(2026, 10, 1) : new Date(2026, 6, 1);
      this.setData({ automatic: false, rows: buildRows(sectionTimes.defaults(anchor)), error: "" });
    },

    async save() {
      if (this.data.saving) return;
      const times = this.data.rows.map((row) => [row.start, row.end]);
      const automatic = this.data.automatic;
      const error = automatic ? "" : sectionTimes.validate(times);
      if (error) return this.setData({ error });

      this.setData({ saving: true, error: "" });
      const config = automatic ? { version: 1, mode: "automatic" } : { version: 1, mode: "custom", times };
      if (!store.setTimeConfig(config)) {
        this.setData({ saving: false, error: "无法保存设置，请检查微信存储空间" });
        return;
      }
      this.setData({ show: false, saving: false });
      ui.showMessage("每节课时间已保存；已导入手机日历的课程需重新导出并替换旧日历");
      this.triggerEvent("saved");
    },
  },
});
