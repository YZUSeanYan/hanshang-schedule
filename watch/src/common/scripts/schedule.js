/**
 * 邗上课表 Watch - 课表领域逻辑
 * 与手机 App 保持一致的规则：
 *   - 周次：weekNumberOf(start_date, date)，start_date 已归一化为第 1 周周一
 *   - 周类型：0 每周 / 1 单周 / 2 双周 / 3 自定义（weeks_type int）
 *   - custom_weeks：逗号平铺列表字符串（如 "1,2,3"），兼容范围写法 "1-18"
 *   - 节次：12 小节，春夏季(5-9月) 与秋冬季两套作息
 *   - day_of_week：1=周一 … 7=周日（与 DateTime.weekday 一致）
 */

/** 扬大节次作息表（与 App section_times.dart 完全一致） */
const SPRING_SUMMER = [
  ["08:00", "08:45"], ["08:55", "09:40"], ["09:55", "10:40"], ["10:50", "11:35"],
  ["11:45", "12:30"], ["14:30", "15:15"], ["15:25", "16:10"], ["16:20", "17:05"],
  ["17:15", "18:00"], ["18:10", "18:55"], ["19:30", "20:15"], ["20:25", "21:10"],
];
const AUTUMN_WINTER = [
  ["08:00", "08:45"], ["08:55", "09:40"], ["09:55", "10:40"], ["10:50", "11:35"],
  ["11:45", "12:30"], ["14:00", "14:45"], ["14:55", "15:40"], ["15:50", "16:35"],
  ["16:45", "17:30"], ["17:40", "18:25"], ["19:00", "19:45"], ["19:50", "20:35"],
];

export function sectionTimes() {
  const m = new Date().getMonth() + 1;
  return m >= 5 && m <= 9 ? SPRING_SUMMER : AUTUMN_WINTER;
}

export function toMin(hhmm) {
  const p = hhmm.split(":");
  return parseInt(p[0], 10) * 60 + parseInt(p[1], 10);
}

/** 第 i 节（1 起）开始时间（分钟数，0 点起） */
export function sectionStartMin(i) {
  return toMin(sectionTimes()[i - 1][0]);
}

/** 第 i 节结束时间（分钟数） */
export function sectionEndMin(i) {
  return toMin(sectionTimes()[i - 1][1]);
}

/** 节次区间文案，如 3-4 节 → "09:55-11:35" */
export function sectionText(startSection, endSection) {
  const t = sectionTimes();
  return t[startSection - 1][0] + "-" + t[endSection - 1][1];
}

/** "YYYY-MM-DD" -> 本地 Date */
export function parseDate(str) {
  const p = String(str).split("-");
  return new Date(+p[0], +p[1] - 1, +p[2]);
}

function dayNum(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

/** 所在周的周一 */
export function mondayOf(date) {
  const d = dayNum(date);
  const wd = d.getDay() === 0 ? 7 : d.getDay();
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() - (wd - 1));
}

/** 学期第几周（1 起；开学前 <= 0） */
export function weekNumberOf(startDateStr, date) {
  const s = parseDate(startDateStr);
  const t = dayNum(date);
  const days = Math.floor((t.getTime() - s.getTime()) / 86400000);
  return Math.floor(days / 7) + 1;
}

/** 解析 custom_weeks：兼容 "1,2,3" / "1-18" / 数字 / 数组 */
export function parseCustomWeeks(v) {
  if (Array.isArray(v)) return v.map(Number).filter((n) => Number.isFinite(n));
  if (typeof v === "number") return [v];
  if (!v) return [];
  const out = [];
  String(v).split(/[,，\s]+/).forEach((part) => {
    const m = part.match(/^(\d+)\s*-\s*(\d+)$/);
    if (m) {
      for (let w = +m[1]; w <= +m[2]; w++) out.push(w);
    } else if (/^\d+$/.test(part)) {
      out.push(+part);
    }
  });
  return out;
}

/** 某课程排课是否在第 week 周上课（weeks_type: 0每周 1单周 2双周 3自定义） */
export function occursInWeek(weeksType, customWeeks, week) {
  if (week < 1) return false;
  switch (weeksType) {
    case 1: return week % 2 === 1;                 // 单周
    case 2: return week >= 2 && week % 2 === 0;    // 双周
    case 3: return parseCustomWeeks(customWeeks).indexOf(week) >= 0; // 自定义
    default: return true;                          // 每周
  }
}

export const WEEK_LABELS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
export const WEEK_SHORT = ["一", "二", "三", "四", "五", "六", "日"];

/** 课程颜色盘（与 App course_colors.dart 一致，浅色系+深色文字） */
export const COURSE_COLORS = [
  "#A8D8EA", "#FFCBCB", "#B5EAD7", "#FFDAC1", "#C7CEEA",
  "#F6E6AD", "#A2E1DB", "#F3B0C3", "#BFD8B8", "#E7C6E7",
];

export function courseColor(course) {
  const idx = (course && course.color) || 0;
  return COURSE_COLORS[((idx % COURSE_COLORS.length) + COURSE_COLORS.length) % COURSE_COLORS.length];
}

/**
 * 某天的课程列表（已按开始节次排序）。
 * 依赖 app.ux 全局状态：def.currentSemester / def.schedules / def.courseMap
 */
export function dayCourses(def, date) {
  const sem = def.currentSemester;
  if (!sem || !def.schedules) return [];
  const week = weekNumberOf(sem.start_date, date);
  const wd = date.getDay() === 0 ? 7 : date.getDay();
  const byCourse = {};
  def.schedules.forEach((s) => {
    if (!s || s.deleted) return;
    if (s.day_of_week !== wd) return;
    const c = def.courseMap && def.courseMap[s.course_uuid];
    if (!c || c.semester_uuid !== sem.uuid || c.deleted) return;
    if (!occursInWeek(s.weeks_type, s.custom_weeks, week)) return;
    (byCourse[c.uuid] = byCourse[c.uuid] || []).push(s);
  });
  const items = [];
  Object.keys(byCourse).forEach((uuid) => {
    const c = def.courseMap[uuid];
    const slots = byCourse[uuid].sort((a, b) => a.start_section - b.start_section);
    const first = slots[0];
    const last = slots[slots.length - 1];
    const locs = [];
    slots.forEach((s) => { if (s.location) locs.push(s.location); });
    items.push({
      course_uuid: uuid,
      name: c.name,
      teacher: c.teacher || "",
      location: locs.join(" / "),
      start_section: first.start_section,
      end_section: last.end_section,
      timeText: sectionText(first.start_section, last.end_section),
      startMin: sectionStartMin(first.start_section),
      endMin: sectionEndMin(last.end_section),
      color: courseColor(c),
    });
  });
  items.sort((a, b) => a.startMin - b.startMin);
  return items;
}

/**
 * 下一节课信息（今日）：
 *   { item, kind: "next"|"ongoing"|"none", startsInMin }
 * kind=none 表示今天没有剩余课程
 */
export function nextCourseInfo(def, date, nowMin) {
  const items = dayCourses(def, date);
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    if (nowMin < it.startMin) {
      return { item: it, kind: "next", startsInMin: it.startMin - nowMin };
    }
    if (nowMin >= it.startMin && nowMin < it.endMin) {
      return { item: it, kind: "ongoing", startsInMin: 0 };
    }
  }
  return { item: null, kind: "none", startsInMin: 0 };
}
