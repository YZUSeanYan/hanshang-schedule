/*
 * 课表主页面（周视图 / 日视图）。
 *
 * 与网页版的三处结构差异，都是小程序渲染层决定的：
 *
 * 1. 周视图不用 CSS Grid。网页版靠 grid-row: span 让课程块跨行；小程序的
 *    CSS Grid 在部分内核上对隐式行与跨行支持不一致，改为「JS 算好像素绝对定位」，
 *    重叠分栏（layoutDay）算出的 lane/laneCount 直接变成 left/width 百分比。
 *    （DOM 节点也因此从 7×N 个格子 + 课程块，变成一份纯数据数组。）
 * 2. 尺寸需要先量后画。格子高度依赖可用高度，只有渲染后才知道，所以先画骨架，
 *    onReady 量到 .week-host 的实际尺寸后再算一次并补上网格。
 * 3. 滑动手势不再「跟手拖拽」。网页版用 Pointer 事件直接改 transform；
 *    小程序要跟手只能走 WXS（渲染层直接改样式）才不掉帧，为了可维护性这里
 *    退一步：松手后按方向提交翻页，由 CSS 动画完成滑入。手感略不同，实现稳得多。
 */
const store = require("../../utils/store");
const sync = require("../../utils/sync");
const api = require("../../utils/api");
const ui = require("../../utils/ui");
const sectionTimes = require("../../utils/section-times");
const { DAYS } = require("../../utils/config");
const { coursePaint } = require("../../utils/colors");
const { activeEvents, eventsForDay, eventSectionRange, eventPaint, eventDisplayTitle, eventTimeLabel, eventTypeLabel, eventDateLabel, eventTypeIcon } = require("../../utils/events");
const { isoDate } = require("../../utils/format");
const {
  activeRows,
  activeOverrides,
  effectiveWeekdaysFor,
  normalizeCourses,
  currentSemesterOf,
  weekNumberForSemester,
  slotIsActiveInWeek,
  slotsForDay,
  dateForWeekDay,
  sectionTimeRange,
  layoutDay,
  groupOverlapping,
  displayLocation,
  parseLocationParts,
} = require("../../utils/schedule");

// 与网页版一致的网格尺度（px，按 375 宽设计，宽度变化时按比例缩放）
const HEADER_H = 46;
const MIN_ROW_H = 30;
const SECTION_COL_RATIO = 0.135;

Page({
  data: {
    themeClass: "theme-light",
    statusBarHeight: 20,
    navBarHeight: 44,
    tabBarHeight: 56,
    eyebrow: "邗上课表",
    title: "我的课表",
    syncHint: "",
    syncHintActive: false,
    semesterName: "尚未设置学期",
    semesterMeta: "点此设置",
    weekLabel: "第 1 周",
    weekRange: "",
    canPrev: false,
    canNext: false,
    viewMode: "week",
    guest: false,
    dayChips: [],
    timeTransition: false,
    hasCourses: false,
    grid: null,
    days: [],
    // 弹层开关
    showMenu: false,
    showCourseForm: false,
    showSemesterForm: false,
    showCourseDetail: false,
    showEventDetail: false,
    eventDetail: null,
    showConflict: false,
    conflictItems: [],
  },

  onLoad() {
    const layout = store.state.layout;
    this.setData({
      statusBarHeight: layout.statusBarHeight,
      navBarHeight: layout.navBarHeight,
      tabBarHeight: 56 + (layout.safeBottom || 0),
    });
    this.unsubscribe = store.subscribe(() => this.render());
    this.selectedWeek = 1;
    this.selectedDay = Math.min(Math.max(new Date().getDay() || 7, 1), 7);
    this.viewMode = "week";
    this.gridMetrics = null;
    // 等会话恢复完再画，避免先渲染出游客空课表又跳一次
    getApp().ready().then(() => {
      this.render();
      this.measureAndLayout();
    });
  },

  onReady() {
    this.measureAndLayout();
  },

  onShow() {
    if (this.getTabBar) this.getTabBar().setData({ selected: 0 });
    if (this.screenReady) this.render();
    // 显式打开分享入口：不调用的话「分享到朋友圈」不出现（它默认是关的）
    if (wx.showShareMenu) {
      wx.showShareMenu({ menus: ["shareAppMessage", "shareTimeline"], withShareTicket: true });
    }
  },

  onUnload() {
    if (this.unsubscribe) this.unsubscribe();
  },

  onResize() {
    this.gridMetrics = null;
    this.measureAndLayout();
  },

  // 量出网格可用区域，再按行数算行高。异步一次即可，之后缓存在 this.gridMetrics。
  measureAndLayout() {
    // measuring 是防重入闸：render 里发现缺尺寸会调它，测完要放闸，否则后续再也补不了；
    // 同时上一个兜底定时器防止查询回调因页面未就绪而不返回、把闸一直关着。
    if (this.measuringTimer) clearTimeout(this.measuringTimer);
    this.measuring = true;
    this.measuringTimer = setTimeout(() => { this.measuring = false; }, 2000);

    if (this.data.viewMode !== "week") {
      this.measuring = false;
      return;
    }
    this.createSelectorQuery()
      .select(".week-host")
      .boundingClientRect((rect) => {
        this.measuring = false;
        if (!rect || !rect.width) return;
        this.screenReady = true;
        this.gridMetrics = { width: rect.width, height: rect.height };
        this.render();
      })
      .exec();
  },

  // ---- 数据 ----

  semesterAndCourses() {
    const snapshot = store.activeSnapshot();
    const semester = currentSemesterOf(snapshot);
    const courses = semester ? normalizeCourses(snapshot, semester) : [];
    return { snapshot, semester, courses };
  },

  render() {
    const { semester, courses } = this.semesterAndCourses();
    const dark = store.isDark();
    const layout = store.state.layout;

    if (!semester) {
      this.selectedWeek = 1;
    } else {
      this.selectedWeek = Math.min(
        semester.total_weeks,
        Math.max(1, this.selectedWeek || weekNumberForSemester(semester.start_date))
      );
    }
    this.semester = semester;
    this.courses = courses;

    const weekStart = semester ? dateForWeekDay(semester, this.selectedWeek, 1) : null;
    const weekEnd = semester ? dateForWeekDay(semester, this.selectedWeek, 7) : null;
    const range = weekStart && weekEnd
      ? `${weekStart.getMonth() + 1}/${weekStart.getDate()}–${weekEnd.getMonth() + 1}/${weekEnd.getDate()}`
      : "";

    const hasCourses = Boolean(semester && courses.length);
    const head = {
      themeClass: store.themeClass(),
      guest: store.isGuest(),
      eyebrow: store.isGuest() ? "邗上课表 · 本机课表" : "邗上课表",
      title: "我的课表",
      semesterName: (semester && semester.name) || "尚未设置学期",
      semesterMeta: semester ? `${semester.start_date} 开学 · ${semester.total_weeks} 周` : "点此设置",
      weekLabel: `第 ${this.selectedWeek} 周`,
      weekRange: range,
      canPrev: Boolean(semester) && this.selectedWeek > 1,
      canNext: Boolean(semester) && this.selectedWeek < semester.total_weeks,
      viewMode: this.viewMode,
      hasCourses,
      timeTransition: this.viewMode === "week" && semester
        ? sectionTimeRange(store.state.timeConfig, semester, this.selectedWeek, 1, 6)
          !== sectionTimeRange(store.state.timeConfig, semester, this.selectedWeek, 7, 6)
        : false,
      syncHint: store.isGuest() ? "本机课表" : "",
      syncHintActive: false,
    };

    const dayChips = DAYS.map((name, index) => ({
      key: name,
      label: name.replace("周", ""),
      active: this.selectedDay === index + 1,
      day: index + 1,
    }));

    // 调休（放假/补课）：本周每一天实际按哪个星期上课（放假的日子为 null）
    const dayEffective = semester
      ? effectiveWeekdaysFor(store.activeSnapshot(), semester, this.selectedWeek)
      : {};

    const payload = Object.assign({}, head, { dayChips });
    let needMeasure = false;
    if (hasCourses && this.viewMode === "week") {
      /*
       * 周网格要靠实测尺寸才算得出来，而 .week-host 只在「有课 + 周视图」时才渲染。
       * 于是有这条路径：新建一个空课表 → 有课变 false、.week-host 被 wx:if 拿掉 →
       * gridMetrics 失配（或本来就缺）→ 之后切回有课的课表时 buildGrid 因为缺尺寸
       * 返回 null，周视图一片空白，而且没有任何东西会再触发测量。现象是「切回有课的
       * 课表，网格是空的」，手动切一次日/周视图才会恢复。
       *
       * 关键点：重测必须放在 setData 的回调里。在 render 里直接测没用——那时 DOM 还
       * 是上一次的数据（.week-host 尚不存在），选择器查出来必然是空。
       */
      payload.grid = this.buildGrid(semester, courses, dark, dayEffective);
      payload.days = [];
      needMeasure = !this.gridMetrics;
    } else if (hasCourses) {
      // 日视图只画列表；周网格数据留着不用，避免白白 setData 一大坨格子
      payload.grid = null;
      payload.days = this.buildDays(semester, courses, dark, dayEffective);
    } else {
      payload.grid = null;
      payload.days = [];
    }
    // 缺尺寸时在渲染完成后再补一次测量（见上面 needMeasure 处的说明）
    this.setData(payload, () => {
      if (needMeasure && !this.measuring) this.measureAndLayout();
    });
  },

  // 周视图：算好每个格子的像素位置，课程块按重叠分栏横向并排
  buildGrid(semester, courses, dark, dayEffective) {
    const metrics = this.gridMetrics;
    if (!metrics) return null;
    const { width, height } = metrics;
    const eff = dayEffective || {};

    // 跨周渲染时，节次上限按本周实际用到的最大节次取（12 起）。
    // 口径与网页版一致：本周所有生效的排课，而不是按天去重后的。
    const activeAll = [];
    courses.forEach((course) => (course.slots || []).forEach((slot) => {
      if (slotIsActiveInWeek(slot, this.selectedWeek)) activeAll.push({ course, slot });
    }));
    const sectionCount = Math.max(12, Math.min(20, ...activeAll.map(({ slot }) => slot.end_section), 12));

    const sectionColW = Math.round(width * SECTION_COL_RATIO);
    const dayColW = (width - sectionColW) / 7;
    const bodyH = height - HEADER_H;
    const rowH = Math.max(MIN_ROW_H, bodyH / sectionCount);
    const gridH = HEADER_H + rowH * sectionCount;

    const today = isoDate(new Date());
    const heads = DAYS.map((name, index) => {
      const day = index + 1;
      const date = dateForWeekDay(semester, this.selectedWeek, day);
      return {
        key: name,
        name: name.replace("周", ""),
        num: date ? String(date.getDate()) : "",
        today: Boolean(date && isoDate(date) === today),
        // 调休：当天放假则标注出来（这天不排课）
        off: eff[day] == null,
        style: `left:${sectionColW + (day - 1) * dayColW}px;top:0;width:${dayColW}px;height:${HEADER_H}px;`,
      };
    });

    const sections = [];
    const cells = [];
    for (let index = 1; index <= sectionCount; index += 1) {
      const top = HEADER_H + (index - 1) * rowH;
      // 作息可能在一周内切换（如 5/1 起下午改点），把 7 天不同的时间竖排展示
      const times = [];
      for (let day = 1; day <= 7; day += 1) {
        const value = sectionTimeRange(store.state.timeConfig, semester, this.selectedWeek, day, index);
        if (value && times.indexOf(value) === -1) times.push(value);
      }
      sections.push({
        key: `s${index}`,
        num: index,
        time: times.join("\n"),
        style: `left:0;top:${top}px;width:${sectionColW}px;height:${rowH}px;`,
      });
      for (let day = 1; day <= 7; day += 1) {
        cells.push({
          key: `c${index}-${day}`,
          alt: index % 2 === 1,
          style: `left:${sectionColW + (day - 1) * dayColW}px;top:${top}px;width:${dayColW}px;height:${rowH}px;`,
        });
      }
    }

    /*
     * 块的生成：课程与日程一起进「相交归组」，然后按 App 的做法渲染——
     *   组内只有一个活动 → 普通块（占满整列，显示名称/地点）
     *   组内有多个活动   → 冲突合并块（占满整列，内含 N 个彩色小方块，点按展开）
     * 这里刻意不做网页版那种「分栏变窄」：那样每块只剩不到一行宽，文字看不清。
     * App 的定稿是合并占位 + 小方块 + 点按展开。
     */
    const snapshot = store.activeSnapshot();
    const blocks = [];
    for (let day = 1; day <= 7; day += 1) {
      // 调休生效：放假（effective 为 null）当天不排课；补课按指定星期排课
      const effective = eff[day];
      const date = dateForWeekDay(semester, this.selectedWeek, day) || new Date();

      const items = [];
      if (effective != null) {
        slotsForDay(courses, effective, this.selectedWeek).forEach(({ course, slot }) => {
          const start = Math.max(1, Math.min(sectionCount, Number(slot.start_section) || 1));
          const end = Math.max(start, Math.min(sectionCount, Number(slot.end_section) || start));
          items.push({ kind: "course", course, slot, uuid: course.uuid, start, end });
        });
      }
      // 日程按日期取（调休只决定「上哪天的课」，不改日程发生的日期）
      eventsForDay(snapshot, date).forEach((event) => {
        const range = eventSectionRange(event);
        if (!range) return; // 待办等无时间日程不占网格
        const start = Math.max(1, Math.min(sectionCount, range[0]));
        const end = Math.max(start, Math.min(sectionCount, range[1]));
        items.push({ kind: "event", event, uuid: event.uuid, start, end });
      });

      const colLeft = sectionColW + (day - 1) * dayColW;
      groupOverlapping(items).forEach((group) => {
        const start = Math.min(...group.map((item) => item.start));
        const end = Math.max(...group.map((item) => item.end));
        const top = HEADER_H + (start - 1) * rowH;
        const blockH = (end - start + 1) * rowH - 6;

        if (group.length > 1) {
          // ---- 冲突合并块：整列宽，内含 N 个彩色小方块 ----
          blocks.push({
            key: `conf-${day}-${start}`,
            merged: true,
            count: group.length,
            style: `left:${colLeft + 2}px;top:${top + 3}px;width:${dayColW - 4}px;height:${blockH}px;`,
            items: group.map((item) => {
              const paint = item.kind === "course" ? coursePaint(item.course, dark) : eventPaint(item.event, dark);
              const title = item.kind === "course"
                ? ((item.course.short_name || "").trim() || String(item.course.name || ""))
                : eventDisplayTitle(item.event);
              // 展开列表要显示的信息一并带出，免得展开时再去查一遍
              let detail = "";
              if (item.kind === "course") {
                const p = parseLocationParts(item.slot.location);
                const room = p.room || (!p.building ? p.formatted : "");
                detail = ["第 " + item.start + "-" + item.end + " 节", p.building, room, item.course.teacher]
                  .filter(Boolean).join(" · ");
              } else {
                detail = [eventTypeLabel(item.event.event_type),
                  eventTimeLabel(item.event, date, store.state.timeConfig),
                  item.event.location].filter(Boolean).join(" · ");
              }
              return {
                kind: item.kind,
                uuid: item.uuid,
                title,
                detail,
                background: paint.background,
                base: paint.base,
                text: paint.text,
              };
            }),
          });
          return;
        }

        // ---- 普通块 ----
        const item = group[0];
        const span = end - start + 1;
        const isCourse = item.kind === "course";
        const paint = isCourse ? coursePaint(item.course, dark) : eventPaint(item.event, dark);

        let title = "";
        let meta = [];
        if (isCourse) {
          const { course, slot } = item;
          title = ((course.short_name || "").trim() || String(course.name || "")).replace(/（/g, "\n（");
          const parts = parseLocationParts(slot.location);
          const roomText = parts.room || (!parts.building ? parts.formatted : "");
          const metaLine = store.state.cardDetail
            ? [course.teacher, parts.campus].filter(Boolean).join(" · ")
            : "";
          if (span === 1) {
            const single = [store.state.cardDetail ? course.teacher : "", roomText].filter(Boolean).join(" · ")
              || `第 ${start}-${end} 节`;
            meta = [{ text: single, kind: "room" }];
          } else {
            if (roomText) meta.push({ text: roomText, kind: "room" });
            if (parts.building) meta.push({ text: parts.building, kind: "building" });
            if (metaLine) meta.push({ text: metaLine, kind: "teacher" });
            if (!meta.length) meta.push({ text: `第 ${start}-${end} 节`, kind: "room" });
          }
        } else {
          const event = item.event;
          title = eventDisplayTitle(event);
          const timeLabel = eventTimeLabel(event, date, store.state.timeConfig);
          const loc = displayLocation(event.location) || event.location || "";
          const head = [eventTypeLabel(event.event_type), timeLabel].filter(Boolean).join(" · ");
          meta = [{ text: head, kind: "room" }];
          if (loc) meta.push({ text: loc, kind: "building" });
        }

        const nameLen = Array.from(title).length;
        const titleLines = Math.max(2, Math.min(9, span * 4));
        const fittedSize = nameLen > 18 ? 8.3 : nameLen > 12 ? 9.3 : nameLen > 8 ? 10.2 : 11.2;

        blocks.push({
          key: `${item.uuid}-${start}`,
          uuid: item.uuid,
          kind: item.kind,
          style: `left:${colLeft + 2}px;top:${top + 3}px;width:${dayColW - 4}px;height:${blockH}px;`
            + `background:${paint.background};border-left-color:${paint.base};`,
          title,
          // display:-webkit-box 必须走内联：写进 WXSS 会被编译器丢掉（实测计算样式
          // 里 display 仍是 flow-root），而 -webkit-line-clamp 单独生效是没用的。
          titleStyle: `display:-webkit-box;-webkit-box-orient:vertical;overflow:hidden;`
            + `font-size:${fittedSize}px;-webkit-line-clamp:${titleLines};color:${paint.text};`,
          meta,
          metaStyle: `display:-webkit-box;-webkit-box-orient:vertical;overflow:hidden;`
            + `-webkit-line-clamp:${span === 1 ? 1 : Math.max(2, Math.min(5, (span - 1) * 2))};`
            + `font-size:${Math.max(8, fittedSize - 1)}px;color:${paint.secondary || paint.text};`,
        });
      });
    }

    return {
      width,
      height: gridH,
      cornerStyle: `left:0;top:0;width:${sectionColW}px;height:${HEADER_H}px;`,
      heads,
      sections,
      cells,
      blocks,
      animClass: this.gridAnimClass || "",
    };
  },

  buildDays(semester, courses, dark, dayEffective) {
    const eff = dayEffective || {};
    const snapshot = store.activeSnapshot();
    const list = this.viewMode === "day" ? [this.selectedDay] : [1, 2, 3, 4, 5, 6, 7];
    return list.map((day) => {
      // 调休：放假当天不排课（用 off 标记而非 empty，文案不同）
      const effective = eff[day];
      const date = dateForWeekDay(semester, this.selectedWeek, day) || new Date();
      const entries = effective == null ? [] : slotsForDay(courses, effective, this.selectedWeek);
      // 日程也要显示（与周视图同口径）
      const eventEntries = eventsForDay(snapshot, date).map((event) => ({
        kind: "event",
        event,
        date,
      }));
      return {
        key: `d${day}`,
        title: DAYS[day - 1],
        empty: !entries.length,
        off: effective == null,
        events: eventEntries.map((item) => {
          const event = item.event;
          const paint = eventPaint(event, dark);
          return {
            key: event.uuid,
            uuid: event.uuid,
            kind: "event",
            title: eventDisplayTitle(event),
            startTime: eventTimeLabel(event, item.date, store.state.timeConfig) || eventTypeLabel(event.event_type),
            endTime: "",
            detail: [eventTypeLabel(event.event_type), displayLocation(event.location) || event.location || ""].filter(Boolean).join(" · "),
            room: "",
            paint,
          };
        }),
        slots: entries.map(({ course, slot }) => {
          const startTime = sectionTimeRange(store.state.timeConfig, semester, this.selectedWeek, day, slot.start_section).split("-")[0];
          const endTime = sectionTimeRange(store.state.timeConfig, semester, this.selectedWeek, day, slot.end_section).split("-")[1];
          const parts = parseLocationParts(slot.location);
          const roomText = parts.room || (!parts.building ? parts.formatted : "");
          const detail = [`第 ${slot.start_section}-${slot.end_section} 节`];
          if (parts.building) detail.push(parts.building);
          if (store.state.cardDetail) {
            if (course.teacher) detail.push(course.teacher);
            if (parts.campus) detail.push(parts.campus);
          }
          return {
            key: slot.uuid,
            uuid: course.uuid,
            title: (course.short_name || "").trim() || course.name,
            startTime: startTime || `第 ${slot.start_section} 节`,
            endTime: endTime || `至第 ${slot.end_section} 节`,
            detail: detail.join(" · "),
            room: roomText,
            paint: coursePaint(course, dark),
          };
        }),
      };
    });
  },

  // ---- 交互 ----

  switchView(event) {
    const mode = event.currentTarget.dataset.mode;
    if (mode === this.viewMode) return;
    this.viewMode = mode;
    if (mode === "week") {
      this.gridMetrics = null;
      this.render();
      this.measureAndLayout();
      return;
    }
    this.render();
  },

  selectDay(event) {
    this.selectedDay = Number(event.currentTarget.dataset.day);
    this.render();
  },

  goWeek(delta) {
    const semester = this.semester;
    if (!semester) return;
    const target = this.selectedWeek + delta;
    if (target < 1 || target > semester.total_weeks) return;
    this.selectedWeek = target;
    this.gridAnimClass = delta > 0 ? "week-slide-next" : "week-slide-prev";
    this.render();
    // 动画类只用于这一帧，渲染完就摘掉，避免下次翻周时被复用成静止状态
    setTimeout(() => { this.gridAnimClass = ""; }, 240);
  },

  prevWeek() { this.goWeek(-1); },
  nextWeek() { this.goWeek(1); },

  /*
   * 原生分享（右上角胶囊「转发」/ 长按分享到朋友圈）。
   *
   * 这是做小程序的主要价值所在——网页版只能退化成「复制口令再发」，而这里可以直接
   * 发出一张带信息的卡片。onShareAppMessage 必须同步返回，所以文案只用当前已有的
   * 学期名与课程数，不做任何网络请求。
   */
  onShareAppMessage() {
    // 分享回调里抛异常会让分享静默失败，所以一律兜底成通用文案
    let title = "邗上课表 — 扬大同学的课表工具";
    try {
      const { semester, courses } = this.semesterAndCourses();
      if (semester && courses.length) title = `邗上课表 · ${semester.name} · 共 ${courses.length} 门课`;
    } catch (error) { /* 用兜底文案 */ }
    return { title, path: "/pages/schedule/index" };
  },

  onShareTimeline() {
    return {
      title: this.onShareAppMessage().title,
      path: "/pages/schedule/index",
    };
  },

  backToToday() {
    const semester = this.semester;
    this.setData({ showMenu: false });
    if (!semester) return this.openSemesterForm();
    const target = Math.min(semester.total_weeks, Math.max(1, weekNumberForSemester(semester.start_date)));
    this.gridAnimClass = target >= this.selectedWeek ? "week-slide-next" : "week-slide-prev";
    this.selectedWeek = target;
    this.selectedDay = Math.min(Math.max(new Date().getDay() || 7, 1), 7);
    this.render();
  },

  /*
   * 滑动翻页的「提交」阶段。跟手的视觉反馈在 gesture.wxs（渲染层，不经 setData）；
   * 这里只判断翻不翻页——越界、总周数、日视图跨周等状态都在这一侧。
   * 位移小于 60px 或以纵向为主时不翻（与网页版同一套手感阈值）。
   */
  onSwipeCommit(dx) {
    if (Math.abs(dx) < 60) return;
    if (this.viewMode === "day") {
      const direction = dx < 0 ? 1 : -1;
      let day = this.selectedDay + direction;
      if (day < 1) {
        if (!this.semester || this.selectedWeek <= 1) return;
        this.selectedWeek -= 1;
        day = 7;
      } else if (day > 7) {
        if (!this.semester || this.selectedWeek >= this.semester.total_weeks) return;
        this.selectedWeek += 1;
        day = 1;
      }
      this.selectedDay = day;
      this.render();
      return;
    }
    this.goWeek(dx < 0 ? 1 : -1);
  },
  openBlockDetail(event) {
    const { uuid, kind } = event.currentTarget.dataset;
    if (!uuid) return;
    if (kind === "event") {
      this.openEventDetail(event);
      return;
    }
    this.openCourseDetail(event);
  },

  // 日程详情
  openEventDetail(event) {
    const uuid = event.currentTarget.dataset.uuid;
    const snapshot = store.activeSnapshot();
    const found = activeEvents(snapshot).find((item) => item.uuid === uuid);
    if (!found) return;
    const date = dateForWeekDay(this.semester, this.selectedWeek, 1) || new Date();
    this.setData({
      showEventDetail: true,
      eventDetail: {
        uuid: found.uuid,
        title: found.title || "",
        typeLabel: eventTypeLabel(found.event_type),
        typeIcon: eventTypeIcon(found.event_type),
        dateLabel: eventDateLabel(found),
        timeLabel: eventTimeLabel(found, date, store.state.timeConfig),
        location: displayLocation(found.location) || found.location || "",
        note: found.note || "",
      },
    });
  },

  // 删除日程（打墓碑，语义与课程一致）
  async deleteEvent() {
    // 数据在 this.data 上，this.eventDetail 是 undefined（曾因此让删除静默失效）
    const uuid = this.data.eventDetail && this.data.eventDetail.uuid;
    if (!uuid) return;
    const ok = await require("../../utils/ui").confirm("删除日程", "确定删除这条日程吗？此操作会同步到其他设备。", "删除");
    if (!ok) return;
    const row = require("../../utils/events").activeEvents(store.activeSnapshot()).find((item) => item.uuid === uuid);
    if (!row) return;
    try {
      await require("../../utils/sync").push({ events: [Object.assign({}, row, { deleted: true, updated_at: Date.now() })] });
      this.setData({ showEventDetail: false });
      require("../../utils/ui").showMessage("日程已删除");
    } catch (error) {
      require("../../utils/ui").showMessage(error.message || "删除失败", true);
    }
  },

  closeEventDetail() {
    this.setData({ showEventDetail: false });
  },

  /*
   * 冲突合并块的点按展开：列出同一时段的全部活动，排序与课表一致（先起始、再结束）。
   * 这是 App 的「冲突合并块」定稿形态——不把重叠项分栏变窄，而是合并占位 + 点按展开。
   */
  openConflict(event) {
    const key = event.currentTarget.dataset.key;
    const block = ((this.data.grid && this.data.grid.blocks) || []).find((item) => item.key === key);
    if (!block || !block.merged) return;
    this.setData({
      showConflict: true,
      conflictItems: block.items.map((item) => ({
        kindLabel: item.kind === "course" ? "课程" : "日程",
        title: item.title,
        detail: item.detail || "",
        chip: item.base,
        background: item.background,
      })),
    });
  },

  closeConflict() {
    this.setData({ showConflict: false });
  },

  // ---- 弹层流转 ----

  openMenu() { this.setData({ showMenu: true }); },
  closeMenu() { this.setData({ showMenu: false }); },

  addCourse() {
    this.setData({ showMenu: false });
    if (!this.semester) return this.openSemesterForm();
    this.selectComponent("#courseForm").open(this.semester.uuid, "");
  },

  // AI 添加日程（App 2.0 的「AI 日程」入口）
  addAiSchedule() {
    this.setData({ showMenu: false });
    this.selectComponent("#aiSchedule").open();
  },

  openSemesterForm() {
    this.setData({ showMenu: false });
    this.selectComponent("#semesterForm").open("");
  },

  onDetailEdit(event) {
    this.setData({ showCourseDetail: false });
    this.selectComponent("#courseForm").open(this.semester.uuid, event.detail.uuid);
  },

  // 表单保存完成后重新量一次版面：课程数变化会改变节次行数（12→更多）
  onFormSaved() {
    this.gridMetrics = null;
    this.render();
    this.measureAndLayout();
  },

  async onDetailDelete(event) {
    const uuid = event.detail.uuid;
    const course = (this.courses || []).find((item) => item.uuid === uuid);
    if (!course) return;
    const ok = await ui.confirm("删除课程", `确定永久删除「${course.name}」吗？此操作会同步到其他设备。`, "删除");
    if (!ok) return;
    const now = Date.now();
    const courseDelete = Object.assign({}, course, { deleted: true, updated_at: now });
    delete courseDelete.slots;
    const schedules = (course.slots || []).map((slot, index) =>
      Object.assign({}, slot, { deleted: true, updated_at: now + index + 1 }));
    try {
      await sync.push({ courses: [courseDelete], schedules });
      ui.showMessage("课程已删除");
    } catch (error) {
      ui.showMessage(error.message || "删除失败", true);
    }
  },

  exportCalendar() {
    this.setData({ showMenu: false });
    if (!this.semester) return ui.showMessage("请先设置学期", true);
    exportIcs(this.semester, this.courses);
  },

  goLogin() {
    wx.navigateTo({ url: "/pages/login/index" });
  },

  noop() {},
});

// rpx→px 比例，随屏幕宽度变化
function layout_ratio() {
  return (store.state.layout.windowWidth || 375) / 750;
}

/*
 * 导出到日历的能力降级说明：
 * 网页版生成 .ics 后靠 <a download> 触发浏览器下载；小程序没有下载目录，
 * 且 .ics 不在 wx.openDocument 的支持列表里。这里改为写进小程序文件系统后
 * 用 wx.shareFileMessage 发到聊天，用户在聊天里点开即可用系统日历打开——
 * 这是小程序里唯一能把日历文件交到用户手上的路径。
 */
function exportIcs(semester, courses) {
  const { forDate } = sectionTimes;
  const pad = (n, w) => String(n).padStart(w || 2, "0");
  const fmt = (date) => `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}`
    + `T${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
  const escapeField = (value) => String(value).replace(/\\/g, "\\\\").replace(/,/g, "\\,")
    .replace(/;/g, "\\;").replace(/\n/g, "\\n");

  const startDate = new Date(`${semester.start_date}T00:00:00`);
  const events = [];
  courses.forEach((course) => {
    (course.slots || []).forEach((slot) => {
      const dates = [];
      for (let week = 1; week <= semester.total_weeks; week += 1) {
        if (!slotIsActiveInWeek(slot, week)) continue;
        const day = new Date(startDate);
        day.setDate(day.getDate() + (week - 1) * 7 + (slot.day_of_week - 1));
        const times = forDate(store.state.timeConfig, day);
        const start = times[slot.start_section - 1];
        const end = times[slot.end_section - 1];
        if (!start || !end) continue;
        const [sh, sm] = start[0].split(":").map(Number);
        const [eh, em] = end[1].split(":").map(Number);
        const dtStart = new Date(day);
        dtStart.setHours(sh, sm, 0, 0);
        const dtEnd = new Date(day);
        dtEnd.setHours(eh, em, 0, 0);
        dates.push({ dtStart, dtEnd });
      }
      if (dates.length) events.push({ course, slot, dates });
    });
  });

  if (!events.length) return ui.showMessage("所有课程的有效周次为空", true);

  const lines = [
    "BEGIN:VCALENDAR", "VERSION:2.0",
    "PRODID:-//hanshang.seanyan.store//hanshang-schedule//CN",
    "CALSCALE:GREGORIAN",
    `X-WR-CALNAME:邗上课表 ${semester.name || ""}`,
    "X-WR-TIMEZONE:Asia/Shanghai",
    "BEGIN:VTIMEZONE", "TZID:Asia/Shanghai",
    "BEGIN:STANDARD", "DTSTART:19700101T000000",
    "TZOFFSETFROM:+0800", "TZOFFSETTO:+0800", "TZNAME:CST",
    "END:STANDARD", "END:VTIMEZONE",
  ];
  let count = 0;
  events.forEach(({ course, slot, dates }) => {
    const location = displayLocation(slot.location) || slot.location || "";
    const desc = course.teacher ? `教师：${course.teacher}` : "";
    dates.forEach(({ dtStart, dtEnd }) => {
      lines.push("BEGIN:VEVENT");
      lines.push(`DTSTART;TZID=Asia/Shanghai:${fmt(dtStart)}`);
      lines.push(`DTEND;TZID=Asia/Shanghai:${fmt(dtEnd)}`);
      lines.push(`SUMMARY:${escapeField(course.name)}`);
      if (location) lines.push(`LOCATION:${escapeField(location)}`);
      if (desc) lines.push(`DESCRIPTION:${escapeField(desc)}`);
      lines.push("BEGIN:VALARM", "TRIGGER:-PT15M", "ACTION:DISPLAY",
        `DESCRIPTION:${escapeField(course.name)}`, "END:VALARM");
      lines.push("END:VEVENT");
      count += 1;
    });
  });
  lines.push("END:VCALENDAR");

  const filePath = `${wx.env.USER_DATA_PATH}/邗上课表${semester.name || ""}.ics`;
  try {
    wx.getFileSystemManager().writeFileSync(filePath, lines.join("\r\n"), "utf8");
  } catch (error) {
    return ui.showMessage("日历文件写入失败", true);
  }
  wx.shareFileMessage({
    filePath,
    fileName: `邗上课表${semester.name || ""}.ics`,
    success: () => ui.showMessage(`已导出 ${count} 条上课时间`),
    fail: () => ui.showMessage("已生成日历文件，可从聊天中重新分享", true),
  });
}
