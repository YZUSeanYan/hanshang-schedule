/*
 * 课程表单（新增 / 编辑）。
 *
 * 网页版用 12 个 <dialog> 里最大的一块：课程名 + 教师 + 备注 + 可增删的多个
 * 上课时间段（星期/周次/起止节次/自定义周次/地点）。
 * 小程序侧改用 picker 承载星期与周次类型这两个枚举，输入框只留数字与文本，
 * 校验规则与提交字段（含 weeks_type 语义）与网页版逐条对齐。
 */
const store = require("../../utils/store");
const sync = require("../../utils/sync");
const ui = require("../../utils/ui");
const { DAYS } = require("../../utils/config");
const { displayLocation, normalizeCourses } = require("../../utils/schedule");

const WEEK_TYPES = ["每周", "单周", "双周", "自定义"];

function emptySlot() {
  return {
    uuid: "",
    dayIndex: 0,
    weeksIndex: 0,
    startSection: "1",
    endSection: "2",
    customWeeks: "",
    location: "",
  };
}

Component({
  options: { styleIsolation: "apply-shared", multipleSlots: true },

  properties: {
    show: { type: Boolean, value: false },
  },

  data: {
    title: "添加课程",
    dayRange: DAYS,
    weekRange: WEEK_TYPES,
    name: "",
    teacher: "",
    note: "",
    slots: [emptySlot()],
    showDelete: false,
    error: "",
    saving: false,
    semesterUuid: "",
    editingUuid: "",
  },

  methods: {
    /*
     * 打开表单。传 courseUuid 为编辑，空字符串为新增；
     * 没有学期时由调用方先引导建学期（与网页版 openCourseDialog 一致）。
     */
    open(semesterUuid, courseUuid) {
      const snapshot = store.activeSnapshot();
      const semester = { uuid: semesterUuid };
      const courses = normalizeCourses(snapshot, semester);
      const course = courseUuid ? courses.find((item) => item.uuid === courseUuid) : null;
      const slots = course && course.slots.length
        ? course.slots.map((slot) => ({
            uuid: slot.uuid,
            dayIndex: Math.max(0, Math.min(6, (slot.day_of_week || 1) - 1)),
            weeksIndex: Math.max(0, Math.min(3, Number(slot.weeks_type) || 0)),
            startSection: String(slot.start_section || 1),
            endSection: String(slot.end_section || 1),
            customWeeks: slot.custom_weeks || "",
            location: displayLocation(slot.location) || "",
          }))
        : [emptySlot()];

      this.setData({
        show: true,
        semesterUuid,
        editingUuid: course ? course.uuid : "",
        title: course ? "编辑课程" : "添加课程",
        name: course ? course.name : "",
        teacher: (course && course.teacher) || "",
        note: (course && course.note) || "",
        slots,
        showDelete: Boolean(course),
        error: "",
        saving: false,
      });
    },

    close() {
      this.setData({ show: false });
      this.triggerEvent("close");
    },

    onNameInput(event) {
      this.setData({ name: event.detail.value });
    },
    onTeacherInput(event) {
      this.setData({ teacher: event.detail.value });
    },
    onNoteInput(event) {
      this.setData({ note: event.detail.value });
    },

    // slots 的字段用 data-index + data-field 定位，避免为每段单独写方法
    onSlotInput(event) {
      const { index, field } = event.currentTarget.dataset;
      this.setData({ [`slots[${index}].${field}`]: event.detail.value });
    },
    onSlotPicker(event) {
      const { index, field } = event.currentTarget.dataset;
      this.setData({ [`slots[${index}].${field}`]: Number(event.detail.value) });
    },

    addSlot() {
      this.setData({ slots: this.data.slots.concat([emptySlot()]) });
    },

    removeSlot(event) {
      const index = Number(event.currentTarget.dataset.index);
      if (this.data.slots.length <= 1) {
        ui.showMessage("至少需要一个上课时间段", true);
        return;
      }
      const slots = this.data.slots.slice();
      slots.splice(index, 1);
      this.setData({ slots });
    },

    async save() {
      if (this.data.saving) return;
      const name = this.data.name.trim();
      if (!name) {
        this.setData({ error: "请填写课程名称" });
        return;
      }
      const slots = this.data.slots;
      const bad = slots.find((slot) => Number(slot.endSection) < Number(slot.startSection));
      if (bad) {
        this.setData({ error: "结束节次不能早于开始节次" });
        return;
      }
      if (slots.some((slot) => Number(slot.startSection) < 1 || Number(slot.endSection) > 20)) {
        this.setData({ error: "节次需在 1-20 之间" });
        return;
      }

      this.setData({ saving: true, error: "" });
      const snapshot = store.activeSnapshot();
      const courses = normalizeCourses(snapshot, { uuid: this.data.semesterUuid });
      const existing = this.data.editingUuid ? courses.find((item) => item.uuid === this.data.editingUuid) : null;

      const course = sync.buildCourse(
        { name, teacher: this.data.teacher, note: this.data.note, semester_uuid: this.data.semesterUuid },
        existing
      );

      const keptUuids = [];
      const schedules = slots.map((slot, index) => {
        if (slot.uuid) keptUuids.push(slot.uuid);
        return sync.buildSlot(
          {
            day_of_week: slot.dayIndex + 1,
            start_section: slot.startSection,
            end_section: slot.endSection,
            weeks_type: slot.weeksIndex,
            custom_weeks: slot.customWeeks,
            location: slot.location,
          },
          course.uuid,
          slot.uuid ? { uuid: slot.uuid } : null,
          index
        );
      });
      // 被删掉的时间段要打墓碑行推上去，否则云端仍留着旧排课（与网页版一致）
      (existing ? existing.slots : []).forEach((slot, index) => {
        if (keptUuids.includes(slot.uuid)) return;
        schedules.push(Object.assign({}, slot, {
          deleted: true,
          updated_at: Date.now() + slots.length + index + 1,
        }));
      });

      try {
        await sync.push({ courses: [course], schedules });
        this.setData({ show: false, saving: false });
        ui.showMessage(existing ? "课程已更新" : "课程已添加");
        this.triggerEvent("saved");
      } catch (error) {
        this.setData({ saving: false, error: error.message || "保存失败" });
      }
    },

    async remove() {
      if (!this.data.editingUuid) return;
      const courses = normalizeCourses(store.activeSnapshot(), { uuid: this.data.semesterUuid });
      const course = courses.find((item) => item.uuid === this.data.editingUuid);
      if (!course) return;
      const ok = await ui.confirm("删除课程", `确定永久删除「${course.name}」吗？此操作会同步到其他设备。`, "删除");
      if (!ok) return;

      const now = Date.now();
      const courseDelete = Object.assign({}, course, { deleted: true, updated_at: now });
      delete courseDelete.slots;
      const scheduleDeletes = (course.slots || []).map((slot, index) =>
        Object.assign({}, slot, { deleted: true, updated_at: now + index + 1 })
      );
      try {
        await sync.push({ courses: [courseDelete], schedules: scheduleDeletes });
        this.setData({ show: false });
        ui.showMessage("课程已删除");
        this.triggerEvent("saved");
      } catch (error) {
        this.setData({ error: error.message || "删除失败" });
      }
    },
  },
});
