/*
 * 导入课表：AI 文件识别 + 口令导入。
 *
 * 与网页版同一套接口与同一条二级流程（选文件 → AI 识别 → 预览核对 → 填学期 → 保存），
 * 三处按平台改写：
 *
 * 1. 选文件。网页版是 <input type=file>；小程序拆成两条更顺的路径：
 *    截图走 wx.chooseMedia（相册/相机），表格走 wx.chooseMessageFile——
 *    后者能从微信聊天里直接选同学发的 Excel，比在文件管理器里找文件更省事。
 * 2. 上传。wx.uploadFile 只能带一个文件，正好对应后端 file 字段；服务端零改动。
 * 3. 隐私授权。相册与聊天文件属于微信的隐私接口，必须先取得用户同意，
 *    因此这里接管 onNeedPrivacyAuthorization，弹自己的政策弹窗放行。
 */
const store = require("../../utils/store");
const sync = require("../../utils/sync");
const api = require("../../utils/api");
const ui = require("../../utils/ui");
const privacy = require("../../utils/privacy");
const { activeRows, weeksForSync, displayLocation } = require("../../utils/schedule");
const { DAYS } = require("../../utils/config");
const { forCourseNameArgb } = require("../../utils/colors");
const { suggestedSemesterStart, uuid, fileExtension, fileSize } = require("../../utils/format");

const IMAGE_EXT = ["png", "jpg", "jpeg", "webp"];
const TABLE_EXT = ["xlsx", "xls", "csv"];
const IMAGE_MAX = 8 * 1024 * 1024;
const TABLE_MAX = 5 * 1024 * 1024;

Page({
  data: {
    themeClass: "theme-light",
    statusBarHeight: 20,
    tabBarHeight: 56,
    guest: true,
    // 文件导入
    fileKind: "",
    fileName: "",
    fileSummary: "尚未选择文件",
    fileReady: false,
    aiConsent: false,
    parsing: false,
    progress: 8,
    progressTitle: "正在识别课表",
    progressEta: "",
    progressStage: "",
    errorTitle: "",
    errorDetail: "",
    showError: false,
    // 识别结果
    previewCourses: [],
    semesterName: "当前学期",
    semesterStart: "",
    totalWeeks: "20",
    // 口令导入
    code: "",
    sharePreview: null,
    claiming: false,
    // 隐私授权
    showPrivacyAuth: false,
    showPrivacy: false,
  },

  onLoad(options) {
    this.unsubscribeStore = store.subscribe(() => this.render());
    this.unsubscribePrivacy = privacy.subscribe(() => this.setData({ showPrivacyAuth: true }));
    this.setData({
      themeClass: store.themeClass(),
      statusBarHeight: store.state.layout.statusBarHeight,
      tabBarHeight: 56 + (store.state.layout.safeBottom || 0),
      semesterStart: suggestedSemesterStart(),
    });
    getApp().ready().then(() => {
      this.render();
      // 分享卡片深链：?code=XXXXXX（见 profile 页 onShareAppMessage）。
      // 落地就填好口令并自动预览，免去手输 6 位——这是口令分享相对网页版的核心体验差。
      const code = String((options && options.code) || "")
        .toUpperCase().replace(/[^A-Z2-9]/g, "").slice(0, 6);
      if (code.length !== 6) return;
      this.setData({ code });
      if (store.isGuest()) {
        ui.showMessage("已填入口令，登录后即可预览并领取");
        return;
      }
      this.previewShare();
    });
  },

  onShow() {
    if (this.getTabBar) this.getTabBar().setData({ selected: 1 });
    this.render();
  },

  onUnload() {
    if (this.unsubscribeStore) this.unsubscribeStore();
    if (this.unsubscribePrivacy) this.unsubscribePrivacy();
    if (this.progressTimer) clearInterval(this.progressTimer);
  },

  render() {
    this.setData({ themeClass: store.themeClass(), guest: store.isGuest() });
  },

  // ---- 选文件 ----

  /*
   * 相册与聊天文件属于微信的隐私接口：未取得用户同意时直接调用会被拒绝，
   * 正确做法是先 requirePrivacyAuthorize，由平台回调 onNeedPrivacyAuthorization
   * （已在 app.js 注册，转成本页的授权弹窗），用户同意后再执行真正的选择动作。
   * 低版本基础库没有这套接口，直接放行，不影响老设备。
   */
  withPrivacy(action) {
    if (!wx.requirePrivacyAuthorize) return action();
    wx.requirePrivacyAuthorize({
      success: () => action(),
      fail: () => {},
    });
  },

  chooseImage() {
    this.withPrivacy(() => this.pickImage());
  },

  pickImage() {
    wx.chooseMedia({
      count: 1,
      mediaType: ["image"],
      sourceType: ["album", "camera"],
      sizeType: ["compressed", "original"],
      success: (res) => {
        const file = res.tempFiles && res.tempFiles[0];
        if (!file) return;
        this.acceptFile(file.tempFilePath, "image", file.size);
      },
      fail: () => {},
    });
  },

  chooseTable() {
    this.withPrivacy(() => this.pickTable());
  },

  pickTable() {
    wx.chooseMessageFile({
      count: 1,
      type: "file",
      extension: TABLE_EXT,
      success: (res) => {
        const file = res.tempFiles && res.tempFiles[0];
        if (!file) return;
        this.acceptFile(file.path, "table", file.size, file.name);
      },
      fail: () => {},
    });
  },

  acceptFile(path, kind, size, name) {
    const fileName = name || path.split("/").pop() || "课表文件";
    const extension = fileExtension(fileName);
    const valid = kind === "image" ? IMAGE_EXT.indexOf(extension) >= 0 : TABLE_EXT.indexOf(extension) >= 0;
    const max = kind === "image" ? IMAGE_MAX : TABLE_MAX;

    if (!valid) {
      this.setData({
        fileKind: "", fileReady: false, fileName: "",
        fileSummary: kind === "image" ? "请选择 PNG、JPG 或 WebP 截图" : "请选择 XLSX、XLS 或 CSV 表格",
      });
      return;
    }
    if (size && size > max) {
      this.setData({
        fileKind: "", fileReady: false, fileName: "",
        fileSummary: `文件过大，${kind === "image" ? "截图不能超过 8 MB" : "表格不能超过 5 MB"}`,
      });
      return;
    }
    this.setData({
      fileKind: kind,
      filePath: path,
      fileName,
      fileReady: true,
      showError: false,
      fileSummary: `已选择：${fileName}${size ? `（${fileSize(size)}）` : ""}`,
    });
  },

  toggleConsent() {
    this.setData({ aiConsent: !this.data.aiConsent });
  },

  // ---- AI 识别 ----

  startProgress() {
    const expected = this.data.fileKind === "image" ? 30 : 20;
    const startedAt = Date.now();
    this.setData({ parsing: true, showError: false, progressTitle: this.data.fileKind === "image" ? "正在识别课表截图" : "正在解析课表表格" });
    const tick = () => {
      const elapsed = (Date.now() - startedAt) / 1000;
      const progress = Math.min(92, 8 + (elapsed / expected) * 78);
      const remaining = Math.max(0, Math.ceil(expected - elapsed));
      this.setData({
        progress: Math.round(progress),
        progressEta: remaining > 0 ? `预计还需约 ${remaining} 秒` : "比预计稍久，复杂课表可能需要更多时间",
        progressStage: elapsed < 3 ? "正在安全上传文件…" : elapsed < 9 ? "正在读取课程与时间位置…" : "正在合并同一课程并检查结果…",
      });
    };
    tick();
    clearInterval(this.progressTimer);
    this.progressTimer = setInterval(tick, 500);
  },

  stopProgress() {
    clearInterval(this.progressTimer);
    this.progressTimer = null;
    this.setData({ parsing: false });
  },

  async parseFile() {
    if (!this.data.fileReady || this.data.parsing) return;
    if (!this.data.aiConsent) {
      ui.showMessage("请先勾选同意后再识别", true);
      return;
    }
    if (store.isGuest()) {
      ui.showMessage("AI 识别需要登录后使用");
      setTimeout(() => wx.navigateTo({ url: "/pages/login/index" }), 600);
      return;
    }
    this.startProgress();
    try {
      const result = await api.upload("/api/education-import/file-parse", this.data.filePath, {});
      const courses = Array.isArray(result && result.courses) ? result.courses : [];
      if (!courses.length) {
        const empty = new Error("没有从文件中识别出有效课程");
        empty.status = 502;
        throw empty;
      }
      const sourceName = result.source === "image_llm" ? "课表截图" : "表格文件";
      this.setData({
        previewCourses: courses.map((course) => ({
          key: uuid(),
          name: course.name,
          detail: this.describeCourse(course),
        })),
        semesterName: "当前学期",
        semesterStart: suggestedSemesterStart(),
        totalWeeks: "20",
      });
      this.pendingCourses = courses;
      ui.showMessage(`已从${sourceName}识别 ${courses.length} 门课程，请核对后保存`);
      wx.pageScrollTo({ selector: "#education-preview", duration: 240 });
    } catch (error) {
      this.showImportError(error);
    } finally {
      this.stopProgress();
    }
  },

  describeCourse(course) {
    const teacher = course.teacher || "教师待补充";
    const slots = (course.slots || []).map((slot) =>
      `${DAYS[(slot.day_of_week || 1) - 1]} 第${slot.start_section}-${slot.end_section}节${slot.location ? ` · ${displayLocation(slot.location)}` : ""}`
    ).join("；");
    return `${teacher} · ${slots || "时间待补充"}`;
  },

  /*
   * 错误文案按状态码分流（与网页版逐条对齐）：413 文件太大、429 次数用完、
   * 422 系列是"没识别到课表/图片不合适"、504 超时、502 识别服务不可用、
   * 没有状态码说明是网络中断。用户看到的应该是"下一步做什么"，不是错误码。
   */
  showImportError(error) {
    const status = Number((error && error.status) || 0);
    const code = Number((error && error.code) || 0);
    let title = "暂时没有识别成功";
    let detail = (error && error.message) || "请稍后重试";
    if (status === 413) {
      title = "文件太大";
      detail = "请压缩截图，或选择体积更小的课表文件后重试。";
    } else if (status === 400) {
      title = "文件无法读取";
      detail = "请确认文件没有损坏，并使用 PNG、JPG、WebP、XLSX、XLS 或 CSV 格式。";
    } else if (status === 401 || status === 403) {
      title = "登录状态已失效";
      detail = "请重新登录后再进行识别，已选择的文件不会被保存。";
    } else if (status === 429) {
      title = "今天的识别次数已用完";
      detail = "为保护接口和用户数据，识别设有次数限制，请稍后再试。";
    } else if (status === 422 || code === 42245 || code === 42246 || code === 42247) {
      title = code === 42246 ? "这张图片不适合识别" : "没有识别到课表";
      detail = (error && error.message) || (code === 42246
        ? "请更换一张只包含课表的图片。"
        : "请上传包含星期、节次和课程信息的完整截图或表格。");
    } else if (status === 504) {
      title = "本次识别超时";
      detail = "服务器没有保存文件。你可以直接重试，或换一张更清晰、内容更完整的截图。";
    } else if (status === 502) {
      title = "识别服务暂时不可用";
      detail = "文件没有保存，请稍后直接重试。";
    } else if (!status) {
      title = "网络连接中断";
      detail = "请检查网络后重试。服务器不会保留未完成的上传。";
    }
    this.setData({ showError: true, errorTitle: title, errorDetail: detail });
  },

  retryParse() {
    this.setData({ showError: false });
    this.parseFile();
  },

  reselect() {
    if (this.data.fileKind === "table") this.chooseTable();
    else this.chooseImage();
  },

  // ---- 保存识别结果 ----

  onSemesterInput(event) {
    this.setData({ [event.currentTarget.dataset.field]: event.detail.value });
  },

  onSemesterDate(event) {
    this.setData({ semesterStart: event.detail.value });
  },

  fillSuggestedStart() {
    this.setData({ semesterStart: suggestedSemesterStart() });
  },

  async savePreview() {
    if (!this.pendingCourses || !this.pendingCourses.length) return;
    const name = this.data.semesterName.trim();
    const totalWeeks = Number(this.data.totalWeeks);
    if (!name) return ui.showMessage("请填写学期名称", true);
    if (!this.data.semesterStart) return ui.showMessage("请选择第一周的周一", true);
    if (!Number.isInteger(totalWeeks) || totalWeeks < 1 || totalWeeks > 30) {
      return ui.showMessage("总周数需为 1-30 的整数", true);
    }

    const now = Date.now();
    const semesterUuid = uuid();
    const semesters = activeRows(store.activeSnapshot(), "semesters")
      .filter((item) => item.is_current)
      .map((item, index) => Object.assign({}, item, { is_current: false, updated_at: now + index }));
    semesters.push({
      uuid: semesterUuid,
      name,
      start_date: this.data.semesterStart,
      total_weeks: totalWeeks,
      is_current: true,
      updated_at: now + semesters.length + 1,
      deleted: false,
    });

    const courses = [];
    const schedules = [];
    this.pendingCourses.forEach((item, courseIndex) => {
      const courseUuid = uuid();
      courses.push({
        uuid: courseUuid,
        semester_uuid: semesterUuid,
        name: item.name,
        teacher: item.teacher || "",
        color: forCourseNameArgb(item.name),
        note: "",
        updated_at: now + 100 + courseIndex,
        deleted: false,
      });
      (item.slots || []).forEach((slot, slotIndex) => {
        schedules.push(Object.assign({
          uuid: uuid(),
          course_uuid: courseUuid,
          day_of_week: slot.day_of_week,
          start_section: slot.start_section,
          end_section: slot.end_section,
          location: slot.location || "",
          updated_at: now + 1000 + courseIndex * 10 + slotIndex,
          deleted: false,
        }, weeksForSync(slot.weeks_text)));
      });
    });

    try {
      await sync.push({ semesters, courses, schedules });
      this.pendingCourses = null;
      this.setData({
        previewCourses: [], fileKind: "", fileReady: false, fileName: "", fileSummary: "尚未选择文件", aiConsent: false,
      });
      ui.showMessage("课表已保存");
      wx.switchTab({ url: "/pages/schedule/index" });
    } catch (error) {
      ui.showMessage(error.message || "保存失败", true);
    }
  },

  // ---- 口令导入 ----

  onCodeInput(event) {
    this.setData({ code: String(event.detail.value || "").toUpperCase().replace(/[^A-Z2-9]/g, "").slice(0, 6) });
  },

  async previewShare() {
    const code = this.data.code.trim();
    if (code.length !== 6) return ui.showMessage("请输入完整的 6 位口令", true);
    try {
      const data = await api.request(`/api/share/${encodeURIComponent(code)}`);
      this.shareCode = code;
      this.setData({
        sharePreview: {
          title: `${data.payload.semester.name} · 课表预览`,
          meta: `${data.payload.courses.length} 门课程 · 有效期至 ${String(data.expires_at).slice(0, 10)}`,
          courses: data.payload.courses.map((course) => ({
            key: uuid(),
            name: course.name,
            detail: this.describeCourse(course),
          })),
        },
      });
    } catch (error) {
      ui.showMessage(error.message, true);
    }
  },

  async claimShare() {
    if (this.data.claiming) return;
    this.setData({ claiming: true });
    try {
      const data = await api.request(`/api/share/${encodeURIComponent(this.shareCode)}/claim`, {
        method: "POST",
        body: { replace_existing: false },
      });
      this.setData({ sharePreview: null, code: "", claiming: false });
      ui.showMessage(`已导入 ${data.course_count} 门课程`);
      wx.switchTab({ url: "/pages/schedule/index" });
    } catch (error) {
      this.setData({ claiming: false });
      if (/已有同一学期/.test(error.message || "")) {
        const ok = await ui.confirm("覆盖课表", "你已有同一学期的课表，是否覆盖？", "覆盖");
        if (ok) {
          this.setData({ claiming: true });
          try {
            const data = await api.request(`/api/share/${encodeURIComponent(this.shareCode)}/claim`, {
              method: "POST",
              body: { replace_existing: true },
            });
            this.setData({ sharePreview: null, code: "", claiming: false });
            ui.showMessage(`已导入 ${data.course_count} 门课程`);
            wx.switchTab({ url: "/pages/schedule/index" });
          } catch (retryError) {
            this.setData({ claiming: false });
            ui.showMessage(retryError.message, true);
          }
        }
        return;
      }
      ui.showMessage(error.message, true);
    }
  },

  // ---- 隐私授权 ----

  // 同意按钮由 open-type="agreePrivacyAuthorization" 触发，这里只负责放行回调
  onAgreePrivacy(event) {
    privacy.agree(event.currentTarget.id);
    this.setData({ showPrivacyAuth: false });
  },

  onDenyPrivacy() {
    privacy.disagree();
    this.setData({ showPrivacyAuth: false });
  },

  openPrivacy() {
    this.setData({ showPrivacy: true });
  },

  closeSheet(event) {
    this.setData({ [event.currentTarget.dataset.key]: false });
  },

  goLogin() {
    wx.navigateTo({ url: "/pages/login/index" });
  },

  noop() {},
});
