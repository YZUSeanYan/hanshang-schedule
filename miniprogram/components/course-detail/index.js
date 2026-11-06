/*
 * 课程详情。网页版对齐安卓 CourseDetailSheet：课程色图标块 + 标题 + 安排数
 * → 分隔线 → 教师 / 每个时间段（星期 节次 时间 · 周次 + 地点）/ 备注。
 * 小程序侧不再用 innerHTML 拼字符串，改为数据驱动渲染（顺带消掉了网页版
 * 必须手写 esc() 转义的那类 XSS 风险）。
 */
const store = require("../../utils/store");
const { normalizeCourses, sectionTimeRange, displayLocation } = require("../../utils/schedule");
const { DAYS } = require("../../utils/config");
const { weekTypeLabel } = require("../../utils/format");
const { coursePaint } = require("../../utils/colors");

Component({
  options: { styleIsolation: "apply-shared", multipleSlots: true },

  properties: {
    show: { type: Boolean, value: false },
  },

  data: {
    course: null,
    slotCount: 0,
    lines: [],
    paint: {},
    hasDetail: false,
    week: 1,
  },

  methods: {
    open(courseUuid, semester, week) {
      const course = normalizeCourses(store.activeSnapshot(), semester).find((item) => item.uuid === courseUuid);
      if (!course) return;
      const dark = store.isDark();
      const slots = (course.slots || []).slice().sort(
        (a, b) => a.day_of_week - b.day_of_week || a.start_section - b.start_section
      );
      const lines = slots.map((slot) => {
        const day = DAYS[(slot.day_of_week || 1) - 1];
        // 起止时刻分别取自开始节次的"上课"与结束节次的"下课"（与网页版同口径）
        const first = sectionTimeRange(store.state.timeConfig, semester, week || 1, slot.day_of_week, slot.start_section).split("-")[0];
        const last = sectionTimeRange(store.state.timeConfig, semester, week || 1, slot.day_of_week, slot.end_section).split("-")[1];
        const clock = first && last ? ` ${first}-${last}` : "";
        return {
          key: slot.uuid,
          head: `${day} 第 ${slot.start_section}-${slot.end_section} 节${clock} · ${weekTypeLabel(slot)}`,
          location: displayLocation(slot.location) || slot.location || "",
        };
      });
      this.setData({
        show: true,
        course,
        slotCount: slots.length,
        lines,
        paint: coursePaint(course, dark),
        hasDetail: Boolean(course.teacher || slots.length || course.note),
        week: week || 1,
      });
    },

    close() {
      this.setData({ show: false });
      this.triggerEvent("close");
    },

    edit() {
      const uuid = this.data.course.uuid;
      this.setData({ show: false });
      this.triggerEvent("edit", { uuid });
    },

    remove() {
      const uuid = this.data.course.uuid;
      this.setData({ show: false });
      this.triggerEvent("delete", { uuid });
    },
  },
});
