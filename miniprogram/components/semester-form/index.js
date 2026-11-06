/*
 * 课表管理（多学期：列表 / 切换当前 / 新建 / 编辑 / 删除）。
 *
 * 网页版这张弹层里同时放了「列表」和「表单」两块；小程序沿用同一结构，
 * 只是把 date 输入换成 picker，并把「删除课表」的二次确认换成 wx.showModal。
 * 切换当前课表、删除课表都要写 is_current 与墓碑行，字段语义与网页版一致。
 */
const store = require("../../utils/store");
const sync = require("../../utils/sync");
const ui = require("../../utils/ui");
const { activeRows } = require("../../utils/schedule");
const { suggestedSemesterStart, uuid } = require("../../utils/format");

Component({
  options: { styleIsolation: "apply-shared", multipleSlots: true },

  properties: {
    show: { type: Boolean, value: false },
  },

  data: {
    list: [],
    currentUuid: "",
    name: "",
    startDate: "",
    totalWeeks: "20",
    editingUuid: "",
    formTitle: "新建课表",
    showDelete: false,
    error: "",
    busy: false,
  },

  lifetimes: {
    attached() {
      this.unsubscribe = store.subscribe(() => {
        if (this.data.show) this.refreshList();
      });
    },
    detached() {
      if (this.unsubscribe) this.unsubscribe();
    },
  },

  methods: {
    open(editUuid) {
      const snapshot = store.activeSnapshot();
      const semesters = activeRows(snapshot, "semesters").slice().sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
      const current = semesters.find((item) => item.is_current) || semesters[0] || null;
      const target = editUuid ? semesters.find((item) => item.uuid === editUuid) : current;
      this.setData({ show: true, error: "", busy: false, list: this.buildList(snapshot, semesters, current) });
      this.fillForm(target, semesters.length);
    },

    buildList(snapshot, semesters, current) {
      const courses = activeRows(snapshot, "courses");
      return semesters.map((item) => ({
        uuid: item.uuid,
        name: item.name,
        isCurrent: Boolean(current && item.uuid === current.uuid),
        meta: `${item.start_date} 开学 · ${item.total_weeks} 周 · ${courses.filter((course) => course.semester_uuid === item.uuid).length} 门课`,
      }));
    },

    refreshList() {
      const snapshot = store.activeSnapshot();
      const semesters = activeRows(snapshot, "semesters").slice().sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
      const current = semesters.find((item) => item.is_current) || semesters[0] || null;
      this.setData({ list: this.buildList(snapshot, semesters, current), currentUuid: current ? current.uuid : "" });
    },

    fillForm(semester, count) {
      this.setData({
        editingUuid: semester ? semester.uuid : "",
        name: semester ? semester.name : "",
        startDate: semester ? semester.start_date : suggestedSemesterStart(),
        totalWeeks: String(semester ? semester.total_weeks : 20),
        formTitle: semester ? "编辑课表" : "新建课表",
        showDelete: Boolean(semester) && count > 1,
      });
    },

    close() {
      this.setData({ show: false });
      this.triggerEvent("close");
    },

    onSelect(event) {
      const semester = activeRows(store.activeSnapshot(), "semesters").find((item) => item.uuid === event.currentTarget.dataset.uuid);
      if (!semester) return;
      const count = activeRows(store.activeSnapshot(), "semesters").length;
      this.fillForm(semester, count);
    },

    onNew() {
      const count = activeRows(store.activeSnapshot(), "semesters").length;
      this.fillForm(null, count);
    },

    async onActivate(event) {
      const target = activeRows(store.activeSnapshot(), "semesters").find((item) => item.uuid === event.currentTarget.dataset.uuid);
      if (!target || this.data.busy) return;
      this.setData({ busy: true });
      const now = Date.now();
      const changes = activeRows(store.activeSnapshot(), "semesters")
        .filter((item) => item.is_current && item.uuid !== target.uuid)
        .map((item, index) => Object.assign({}, item, { is_current: false, updated_at: now + index }));
      changes.push(Object.assign({}, target, { is_current: true, updated_at: now + changes.length + 1 }));
      try {
        await sync.push({ semesters: changes });
        this.setData({ busy: false });
        ui.showMessage(`已切换到「${target.name}」`);
      } catch (error) {
        this.setData({ busy: false });
        ui.showMessage(error.message || "切换失败", true);
      }
    },

    onNameInput(event) {
      this.setData({ name: event.detail.value });
    },
    onWeeksInput(event) {
      this.setData({ totalWeeks: event.detail.value });
    },
    onDateChange(event) {
      this.setData({ startDate: event.detail.value });
    },

    async save() {
      if (this.data.busy) return;
      const name = this.data.name.trim();
      const totalWeeks = Number(this.data.totalWeeks);
      if (!name) return this.setData({ error: "请填写课表名称" });
      if (!this.data.startDate) return this.setData({ error: "请选择第一周的周一" });
      if (!Number.isInteger(totalWeeks) || totalWeeks < 1 || totalWeeks > 30) {
        return this.setData({ error: "总周数需为 1-30 的整数" });
      }
      this.setData({ busy: true, error: "" });

      const now = Date.now();
      const existing = this.data.editingUuid
        ? activeRows(store.activeSnapshot(), "semesters").find((item) => item.uuid === this.data.editingUuid)
        : null;
      // 保存即设为当前：其余课表统一取消 is_current
      const semesters = activeRows(store.activeSnapshot(), "semesters")
        .filter((item) => item.is_current && item.uuid !== this.data.editingUuid)
        .map((item, index) => Object.assign({}, item, { is_current: false, updated_at: now + index }));
      semesters.push(Object.assign({}, existing || {}, {
        uuid: this.data.editingUuid || uuid(),
        name,
        start_date: this.data.startDate,
        total_weeks: totalWeeks,
        is_current: true,
        updated_at: now + semesters.length + 1,
        deleted: false,
      }));

      try {
        await sync.push({ semesters });
        this.setData({ busy: false, show: false });
        ui.showMessage("课表已保存并设为当前");
        this.triggerEvent("saved");
      } catch (error) {
        this.setData({ busy: false, error: error.message || "保存失败" });
      }
    },

    async remove() {
      const semester = activeRows(store.activeSnapshot(), "semesters").find((item) => item.uuid === this.data.editingUuid);
      if (!semester) return;
      const snapshot = store.activeSnapshot();
      const courses = activeRows(snapshot, "courses").filter((course) => course.semester_uuid === semester.uuid);
      const ok = await ui.confirm(
        "删除课表",
        `删除「${semester.name}」？其 ${courses.length} 门课程与全部排课将一并删除，且会同步到其他设备。`,
        "删除"
      );
      if (!ok) return;

      const now = Date.now();
      const semesters = [Object.assign({}, semester, { deleted: true, updated_at: now })];
      const courseRows = courses.map((course, index) => {
        const row = Object.assign({}, course, { deleted: true, updated_at: now + index + 1 });
        delete row.slots;
        return row;
      });
      const courseUuids = courseRows.map((course) => course.uuid);
      const schedules = activeRows(snapshot, "schedules")
        .filter((slot) => courseUuids.indexOf(slot.course_uuid) >= 0)
        .map((slot, index) => Object.assign({}, slot, { deleted: true, updated_at: now + courseRows.length + index + 1 }));

      try {
        await sync.push({ semesters, courses: courseRows, schedules });
        this.setData({ show: false });
        ui.showMessage(`课表「${semester.name}」已删除`);
        this.triggerEvent("saved");
      } catch (error) {
        this.setData({ error: error.message || "删除失败" });
      }
    },
  },
});
