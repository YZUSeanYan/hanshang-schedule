/*
 * 每节课作息时间：与网页版 section-times.js 同一套规则与同一份存储格式，
 * 换成 CommonJS（小程序不支持 ES module 的 import/export 写法）。
 * 存储格式 {version:1, mode:"automatic"|"custom", times:[[起,止]×12]} 两端一致。
 */
const { KEYS } = require("./config");

const KEY = KEYS.sectionTimes;
const SUMMER = ["08:00", "08:55", "09:55", "10:50", "11:45", "14:30", "15:25", "16:20", "17:15", "18:10", "19:30", "20:25"];

function clock(minutes) {
  return `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
}

function minutes(value) {
  return /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(value) ? Number(value.slice(0, 2)) * 60 + Number(value.slice(3)) : NaN;
}

// 扬大默认作息：冬季（10 月—次年 4 月）下午首节后移 30 分钟，其余不变
function defaults(date) {
  const winter = date.getMonth() < 4 || date.getMonth() > 8;
  return SUMMER.map((start, index) => {
    const value = minutes(start) - (winter && index >= 5 ? 30 : 0);
    return [clock(value), clock(value + 45)];
  });
}

function validate(times) {
  if (!Array.isArray(times) || times.length !== 12) return "请设置完整的 12 节课时间";
  let previous = -1;
  for (let i = 0; i < 12; i += 1) {
    const pair = times[i];
    if (!Array.isArray(pair) || pair.length !== 2 || pair.some((v) => typeof v !== "string" || !Number.isFinite(minutes(v)))) {
      return `第 ${i + 1} 节时间格式不正确`;
    }
    const [start, end] = pair.map(minutes);
    if (end <= start) return `第 ${i + 1} 节下课时间必须晚于上课时间`;
    if (start < previous) return `第 ${i + 1} 节与上一节时间重叠`;
    previous = end;
  }
  return "";
}

function parse(raw) {
  try {
    const data = typeof raw === "string" ? JSON.parse(raw) : raw;
    if (data && data.version === 1 && data.mode === "custom" && !validate(data.times)) return data;
  } catch (error) {
    // 存储损坏时回落到自动作息，不影响课表显示
  }
  return { version: 1, mode: "automatic" };
}

function forDate(config, date) {
  return config && config.mode === "custom" ? config.times : defaults(date);
}

module.exports = { KEY, SUMMER, clock, minutes, defaults, validate, parse, forDate };
