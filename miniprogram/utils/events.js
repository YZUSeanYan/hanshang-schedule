/*
 * 日程 / 待办 / 考试（统称"事件"），即 App 2.0 的核心功能。
 *
 * 与网页版、App 同一套模型：快照里多一类 `events` 行
 *   {
 *     uuid, event_type: "event"|"ddl"|"exam"|"recurring",
 *     title, short_title,               // short_title 是格子上的简写，详情里看全称
 *     date, weekday,                    // recurring 用 weekday，其余用 date
 *     start_time, end_time,             // 时刻表达（"14:00"）
 *     start_section, end_section,       // 节次表达（与课程一致）
 *     busy_sections,                    // "8,9,10"，写库与共同空闲共用的占节依据
 *     location, note, color,
 *     updated_at, deleted
 *   }
 * 配色与课程同一套语言（马卡龙 + ARGB），但用安卓 _EventBlock 的另一档透明度配方，
 * 让"日程"与"课"在视觉上能区分。
 */
const { DAYS } = require("./config");
const { isoDate, parseWeeks } = require("./format");
const { macaronForName, courseBaseColor, withAlpha, blendedText } = require("./colors");
const { activeRows, dateForWeekDay } = require("./schedule");
const sectionTimes = require("./section-times");

const EVENT_TYPE_LABELS = { event: "日程", ddl: "待办", exam: "考试", recurring: "每周" };
const EVENT_TYPE_ICONS = { event: "event_available", ddl: "playlist_add", exam: "school", recurring: "sync" };

function activeEvents(snapshot) {
  return activeRows(snapshot, "events");
}

function eventTypeLabel(type) {
  return EVENT_TYPE_LABELS[type] || EVENT_TYPE_LABELS.event;
}

function eventTypeIcon(type) {
  return EVENT_TYPE_ICONS[type] || EVENT_TYPE_ICONS.event;
}

// 显示色：未指定时按标题稳定哈希取马卡龙色（与课程同一套配色语言）
function eventColorOf(event) {
  const raw = Number(event && event.color);
  if (Number.isInteger(raw) && raw !== 0) return courseBaseColor({ name: event.title, color: raw });
  return macaronForName((event && event.title) || "");
}

/*
 * 安卓 _EventBlock 配方：底=base 10%（浅）/22%（深），文字=base 70% 混黑 / 42% 混白，
 * 描边=base 55%。与课程块（16%/30%、38%）刻意不同，让两者一眼能分开。
 */
function eventPaint(event, dark) {
  const base = eventColorOf(event);
  return {
    base,
    background: withAlpha(base, dark ? 0.22 : 0.1),
    border: withAlpha(base, 0.55),
    text: dark ? blendedText(base, 0.42, 255) : blendedText(base, 0.7, 0),
    chipBg: withAlpha(base, 0.18),
    chipText: dark ? blendedText(base, 0.5, 255) : blendedText(base, 0.75, 0),
  };
}

function clockMinutes(value) {
  return sectionTimes.minutes(value);
}

// "8,9,10" → [8,9,10]；节次域上限 20
function parseBusySections(raw) {
  const result = new Set();
  String(raw || "").split(",").forEach((piece) => {
    const value = Number(piece.trim());
    if (Number.isInteger(value) && value >= 1 && value <= 20) result.add(value);
  });
  return [...result].sort((a, b) => a - b);
}

/*
 * 日程占用的节次（写库与共同空闲共用的依据）：节次表达直接展开；
 * 时刻表达按作息表求交集；待办等无时间日程不占节次，返回空。
 */
function computeEventBusySections(input, timeConfig) {
  const { startSection, endSection, startTime, endTime, date } = input;
  if (startSection >= 1 && endSection >= startSection) {
    return Array.from({ length: Math.min(30, endSection) - startSection + 1 }, (_, index) => startSection + index);
  }
  const start = clockMinutes(startTime);
  const end = clockMinutes(endTime);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return [];
  const busy = [];
  sectionTimes.forDate(timeConfig, date).forEach((pair, index) => {
    const sectionStart = clockMinutes(pair[0]);
    const sectionEnd = clockMinutes(pair[1]);
    if (!Number.isFinite(sectionStart) || !Number.isFinite(sectionEnd)) return;
    if (sectionStart < end && start < sectionEnd) busy.push(index + 1);
  });
  return busy;
}

// 日程在 date 是否发生
function eventOccursOn(event, date) {
  if (event.event_type === "recurring") {
    const weekday = Number(event.weekday) || 0;
    return weekday >= 1 && weekday <= 7 && weekday === (date.getDay() || 7);
  }
  if (!event.date) return false;
  return event.date === isoDate(date);
}

// 周视图占位区间：优先 busy_sections，其次起止节次；都没有则 null（待办不占网格）
function eventSectionRange(event) {
  const busy = parseBusySections(event.busy_sections);
  if (busy.length) return [busy[0], busy[busy.length - 1]];
  const start = Number(event.start_section) || 0;
  const end = Number(event.end_section) || 0;
  if (start >= 1 && end >= start) return [start, end];
  return null;
}

function eventStartMinutes(event, date, timeConfig) {
  const byTime = clockMinutes(event.start_time);
  if (Number.isFinite(byTime)) return byTime;
  const start = Number(event.start_section) || 0;
  if (start >= 1) {
    const pair = sectionTimes.forDate(timeConfig, date)[start - 1];
    const value = pair ? clockMinutes(pair[0]) : NaN;
    if (Number.isFinite(value)) return value;
  }
  return null;
}

function eventTimeLabel(event, date, timeConfig) {
  if (event.start_time) return event.end_time ? `${event.start_time}-${event.end_time}` : event.start_time;
  const start = Number(event.start_section) || 0;
  const end = Number(event.end_section) || 0;
  if (start >= 1 && end >= start) {
    const times = sectionTimes.forDate(timeConfig, date);
    const from = times[start - 1] ? times[start - 1][0] : "";
    const to = times[end - 1] ? times[end - 1][1] : "";
    if (from && to) return `${from}-${to}（第${start}-${end}节）`;
    return `第${start}-${end}节`;
  }
  return "";
}

// 格子上优先展示 AI 简写，完整标题在详情里
function eventDisplayTitle(event) {
  return ((event && event.short_title) || "").trim() || String((event && event.title) || "");
}

function eventDateLabel(event) {
  if (event.event_type === "recurring") {
    const weekday = Number(event.weekday) || 0;
    return weekday >= 1 && weekday <= 7 ? `每周${DAYS[weekday - 1].replace("周", "")}` : "每周";
  }
  return event.date || "未定日期";
}

function eventsForDay(snapshot, date) {
  return activeEvents(snapshot).filter((event) => eventOccursOn(event, date));
}

module.exports = {
  EVENT_TYPE_LABELS,
  EVENT_TYPE_ICONS,
  activeEvents,
  eventTypeLabel,
  eventTypeIcon,
  eventColorOf,
  eventPaint,
  parseBusySections,
  computeEventBusySections,
  eventOccursOn,
  eventSectionRange,
  eventStartMinutes,
  eventTimeLabel,
  eventDisplayTitle,
  eventDateLabel,
  eventsForDay,
};
