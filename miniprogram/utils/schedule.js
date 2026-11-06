/*
 * 课表领域逻辑：周次计算、排课筛选、地点解析、重叠分栏。
 * 全部由网页版 app.js 平移（同一套算法三端共用），只把 DOM 相关部分去掉。
 */
const { DAYS } = require("./config");
const { isoDate, parseWeeks } = require("./format");
const sectionTimes = require("./section-times");

// ---- 快照读取 ----

function activeRows(snapshot, name) {
  return ((snapshot && snapshot[name]) || []).filter((item) => item && !item.deleted);
}

// 课程挂上它的排课（slots），与网页版 normalizeCourses 等价
function normalizeCourses(snapshot, semester) {
  const schedules = activeRows(snapshot, "schedules");
  return activeRows(snapshot, "courses")
    .filter((course) => course.semester_uuid === semester.uuid)
    .map((course) => Object.assign({}, course, {
      slots: schedules.filter((slot) => slot.course_uuid === course.uuid),
    }));
}

// 当前学期：优先 is_current，否则取最近更新的
function currentSemesterOf(snapshot) {
  const semesters = activeRows(snapshot, "semesters");
  if (!semesters.length) return null;
  return semesters.find((item) => item.is_current)
    || semesters.slice().sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0))[0]
    || null;
}

function weekNumberForSemester(startDate) {
  if (!startDate) return 1;
  const start = new Date(`${String(startDate).slice(0, 10)}T00:00:00`);
  if (Number.isNaN(start.getTime())) return 1;
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return Math.floor((today - start) / 604800000) + 1;
}

// ---- 排课筛选 ----

/*
 * 某一周是否有这节课。
 *
 * 注意 weeks_type 缺失（null/undefined）时的行为刻意与网页版保持一致：不当作
 * "每周"，而是走自定义周次分支、因解析不出周次而判定为没有课。看起来"每周"
 * 更像合理的兜底，但三端必须显示同一个结果——两端口径不同会出现"小程序有课、
 * App 没有"这类更难查的问题。后端该字段是 NOT NULL 默认 0，正常数据不会走到这里。
 */
function slotIsActiveInWeek(slot, week) {
  if (!slot || week < 1) return false;
  if (slot.weeks_type === 0) return true;
  if (slot.weeks_type === 1) return week % 2 === 1;
  if (slot.weeks_type === 2) return week % 2 === 0;
  return parseWeeks(slot.custom_weeks).indexOf(week) >= 0;
}

function slotsForDay(courses, day, week) {
  return courses
    .flatMap((course) => (course.slots || [])
      .filter((slot) => slot.day_of_week === day && slotIsActiveInWeek(slot, week))
      .map((slot) => ({ course, slot })))
    .sort((a, b) => a.slot.start_section - b.slot.start_section);
}

function dateForWeekDay(semester, week, day) {
  if (!semester || !semester.start_date) return null;
  const date = new Date(`${String(semester.start_date).slice(0, 10)}T00:00:00`);
  if (Number.isNaN(date.getTime())) return null;
  date.setDate(date.getDate() + (week - 1) * 7 + day - 1);
  return date;
}

function sectionTimeRange(timeConfig, semester, week, day, section) {
  const date = dateForWeekDay(semester, week, day) || new Date();
  const pair = sectionTimes.forDate(timeConfig, date)[section - 1];
  return pair ? pair.join("-") : "";
}

/*
 * 同一天内按「相交则归为一组」切分（贪心，与 layoutDay 的分组口径一致）。
 * 每组是可能互相冲突的一批活动：组内条目在时间上两两有交叠。
 * 一组多于一个就是"冲突"，交给 App 的合并块渲染（而不是分栏变窄）。
 */
function groupOverlapping(entries) {
  const sorted = entries.slice().sort((a, b) => a.start - b.start || a.end - b.end);
  const groups = [];
  let index = 0;
  while (index < sorted.length) {
    const group = [sorted[index]];
    let groupEnd = sorted[index].end;
    let next = index + 1;
    while (next < sorted.length && sorted[next].start <= groupEnd) {
      group.push(sorted[next]);
      groupEnd = Math.max(groupEnd, sorted[next].end);
      next += 1;
    }
    groups.push(group);
    index = next;
  }
  return groups;
}

/*
 * 同一天相交的课程与日程一起贪心分栏，互不遮挡。
 * 返回 [{ item, lane, laneCount }]。
 */
function layoutDay(entries) {
  const sorted = entries.slice().sort((a, b) => a.slot.start_section - b.slot.start_section || a.slot.end_section - b.slot.end_section);
  const result = [];
  let index = 0;
  while (index < sorted.length) {
    const group = [sorted[index]];
    let groupEnd = sorted[index].slot.end_section;
    let next = index + 1;
    while (next < sorted.length && sorted[next].slot.start_section <= groupEnd) {
      group.push(sorted[next]);
      groupEnd = Math.max(groupEnd, sorted[next].slot.end_section);
      next += 1;
    }
    const laneEnds = [];
    const lanes = [];
    group.forEach((item) => {
      let lane = laneEnds.findIndex((endSection) => endSection < item.slot.start_section);
      if (lane === -1) {
        lane = laneEnds.length;
        laneEnds.push(item.slot.end_section);
      } else {
        laneEnds[lane] = item.slot.end_section;
      }
      lanes.push(lane);
    });
    group.forEach((item, groupIndex) => {
      result.push(Object.assign({}, item, { lane: lanes[groupIndex], laneCount: laneEnds.length }));
    });
    index = next;
  }
  return result;
}

// ---- 地点解析（与安卓 parseCourseLocation 同规则）----

function displayLocation(value) {
  const raw = String(value || "").trim().replace(/\s+/g, " ");
  if (!raw) return "";

  // 教务复制文本的「校区>>楼>>教室」分隔格式：楼宇教室放最前，校区放最后
  const parts = raw.split(/>>|→→|＞＞|->|→/).map((part) => part.trim()).filter(Boolean);
  if (parts.length >= 3) return `${parts.slice(1).join("")} · ${parts[0]}`;
  if (parts.length === 2) return `${parts[1]} · ${parts[0]}`;

  const campusPattern = /(扬子津东校区|扬子津西校区|扬子津校区|瘦西湖校区|江阳路北校区|江阳路南校区|荷花池校区|杨子金东校区)/;
  const campusMatch = raw.match(campusPattern);
  const campus = campusMatch ? campusMatch[0].replace("杨子金", "扬子津") : "";
  const withoutCampus = campusMatch
    ? raw.replace(campusMatch[0], "").replace(/^[\s·,，、-]+|[\s·,，、-]+$/g, "")
    : raw;
  const roomMatch = withoutCampus.match(/^(.+?(?:楼|馆|场|中心|实验室))\s*([A-Za-z]?\d{2,4}(?:[-—]\d+)?)?/);
  const room = roomMatch ? `${roomMatch[1]}${roomMatch[2] || ""}` : withoutCampus;
  const remainder = roomMatch
    ? withoutCampus.slice(roomMatch[0].length).replace(/^[\s·,，、-]+|[\s·,，、-]+$/g, "")
    : "";
  return [room, campus, remainder].filter(Boolean).join(" · ");
}

/*
 * 结构化地点拆分：课程卡片按层级展示——教室醒目、楼名次要、校区默认收起进详情。
 * 解析不出结构时只给 formatted 兜底。
 */
function parseLocationParts(value) {
  const formatted = displayLocation(value);
  const raw = String(value || "").trim().replace(/^[@\s]+/, "").replace(/\s+/g, " ");
  const empty = { room: "", building: "", campus: "", formatted };
  if (!raw) return empty;

  let campus = "";
  let rest = raw;
  const arrowParts = raw.split(/>>|→→|＞＞|->|→/).map((part) => part.trim()).filter(Boolean);
  if (arrowParts.length >= 3) {
    return { room: arrowParts.slice(2).join(""), building: arrowParts[1], campus: arrowParts[0], formatted };
  }
  if (arrowParts.length === 2) {
    if (arrowParts[0].indexOf("校区") >= 0) {
      campus = arrowParts[0];
      rest = arrowParts[1];
    } else {
      return { room: arrowParts[1], building: arrowParts[0], campus: "", formatted };
    }
  } else {
    // 已是展示格式（"文津楼N204 · 扬子津东校区"）：先剥 "· xx校区" 后缀，
    // 否则 lastIndexOf("校区") 会把整串吞成 campus
    const suffix = raw.match(/^(.*?)\s*·\s*([^·]*校区)\s*$/);
    if (suffix) {
      campus = suffix[2].trim();
      rest = suffix[1].trim();
    } else {
      const campusEnd = raw.lastIndexOf("校区");
      if (campusEnd >= 0) {
        campus = raw.slice(0, campusEnd + 2).trim();
        rest = raw.slice(campusEnd + 2).replace(/^[\s:：-]+/, "").trim();
      }
    }
  }

  const roomMatch = rest.match(/[A-Za-z]{0,3}\d{2,4}[A-Za-z]?$/);
  if (roomMatch) {
    const building = rest.slice(0, roomMatch.index).trim();
    if (building || campus) return { room: roomMatch[0], building, campus, formatted };
    return { room: roomMatch[0], building: "", campus: "", formatted };
  }
  if (rest && rest !== campus && /(楼|馆|中心|实验室|体育场|操场|学院楼)/.test(rest)) {
    return { room: "", building: rest, campus, formatted };
  }
  return { room: "", building: "", campus, formatted };
}

/*
 * 把 AI 识别出来的周次文本转成同步字段：
 * 「单周」「双周」→ weeks_type 1/2；null weeks_text → 每周；其余 → 自定义。
 */
function weeksForSync(text) {
  const value = String(text || "");
  const numbers = (value.match(/\d+/g) || []).map(Number);
  if (value.indexOf("单") >= 0) return { weeks_type: 1, custom_weeks: "" };
  if (value.indexOf("双") >= 0) return { weeks_type: 2, custom_weeks: "" };
  if (!numbers.length) return { weeks_type: 0, custom_weeks: "" };
  const weeks = numbers.length === 2 && numbers[1] >= numbers[0]
    ? `${numbers[0]}-${numbers[1]}`
    : Array.from(new Set(numbers)).join(",");
  return { weeks_type: 3, custom_weeks: weeks };
}

/*
 * ---- 调休（放假 / 补课）----
 *
 * 与网页版同一套模型：快照里多一类 `overrides` 行，按天覆盖「这天实际按哪个星期上课」。
 *   { uuid, date:"YYYY-MM-DD", kind:"off"|"makeup", weekday:1-7, note, updated_at, deleted }
 *   kind=off    → 放假，当天不排课
 *   kind=makeup → 补课，当天按 weekday 那个星期的课表走
 * 走 /api/sync/push 的 `overrides` 字段，LWW 与墓碑语义与课程一致。
 */

function activeOverrides(snapshot) {
  return activeRows(snapshot, "overrides");
}

/*
 * 某天实际按哪个星期上课：放假 → null（不上课）；补课 → 指定星期；否则 → 该天自己的星期。
 * 周日按 7 表示，与 slot.day_of_week 的取值一致。
 */
function effectiveWeekdayFor(overrides, date) {
  const key = isoDate(date);
  for (const row of overrides || []) {
    if (!row || row.date !== key) continue;
    if (row.kind === "off") return null;
    if (row.kind === "makeup" && row.weekday >= 1 && row.weekday <= 7) return row.weekday;
  }
  const weekday = date.getDay();
  return weekday === 0 ? 7 : weekday;
}

function overrideLabelText(row) {
  if (!row) return "";
  if (row.kind === "off") return row.note || "放假";
  const names = ["一", "二", "三", "四", "五", "六", "日"];
  const base = `补周${names[(row.weekday - 1 + 7) % 7]}的课`;
  return row.note ? `${base} · ${row.note}` : base;
}

/*
 * 某周「实际按哪个星期上课」的对照表，键为 1..7（周一..周日）。
 * 周网格与日视图都靠它决定某一天该显示哪些课。
 */
function effectiveWeekdaysFor(snapshot, semester, week) {
  const overrides = activeOverrides(snapshot);
  const table = {};
  for (let day = 1; day <= 7; day += 1) {
    const date = dateForWeekDay(semester, week, day);
    table[day] = date ? effectiveWeekdayFor(overrides, date) : day;
  }
  return table;
}

module.exports = {
  DAYS,
  activeRows,
  activeOverrides,
  effectiveWeekdayFor,
  effectiveWeekdaysFor,
  overrideLabelText,
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
  weeksForSync,
  isoDate,
};
