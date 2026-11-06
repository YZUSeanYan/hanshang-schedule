/*
 * 通用格式化工具：日期、学期起点建议、通知时间、uuid。
 * 逻辑与网页版 app.js 保持一致（同一份数据在两端要算出同一个周次）。
 */

function isoDate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

/*
 * 学期建议起点：秋季 = 9 月 1 日所在周的周一；春季 = 2 月 25 日所在周的周一
 * （贴近扬大近年开学节奏）。2026 年秋季：9 月 1 日是周二 → 第一周周一 2026-08-31。
 */
function suggestedSemesterStart(date) {
  const now = date || new Date();
  const year = now.getFullYear();
  const month = now.getMonth() + 1;
  const anchor = month >= 8 ? new Date(year, 8, 1) : month === 1 ? new Date(year - 1, 8, 1) : new Date(year, 1, 25);
  const day = anchor.getDay() || 7;
  anchor.setDate(anchor.getDate() - day + 1);
  return isoDate(anchor);
}

function parseDate(value) {
  if (!value) return null;
  const date = new Date(`${String(value).slice(0, 10)}T00:00:00`);
  return Number.isNaN(date.getTime()) ? null : date;
}

function formatNotificationTime(value) {
  const date = new Date(value || "");
  if (Number.isNaN(date.getTime())) return "";
  const pad = (n) => String(n).padStart(2, "0");
  return `${date.getMonth() + 1}月${date.getDate()}日 ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

// 周次类型文案（详情页与表单共用）
function weekTypeLabel(slot) {
  if (!slot) return "";
  if (slot.weeks_type === 0) return "每周";
  if (slot.weeks_type === 1) return "单周";
  if (slot.weeks_type === 2) return "双周";
  return `自定义 ${slot.custom_weeks || ""}`;
}

// 把「1-8,10」「1,3,5」这类周次文本解析成数字数组
function parseWeeks(text) {
  return String(text || "")
    .split(",")
    .flatMap((piece) => {
      const [start, end] = piece.trim().split("-").map(Number);
      if (!Number.isInteger(start)) return [];
      if (!Number.isInteger(end)) return [start];
      return Array.from({ length: Math.max(0, end - start + 1) }, (_, index) => start + index);
    });
}

/*
 * 小程序没有 crypto.randomUUID。服务端只把它当不透明字符串，不校验版本位，
 * 但这里仍按 RFC 4122 v4 的形态生成，避免日后接入更严格的校验时返工。
 */
function uuid() {
  let out = "";
  for (let index = 0; index < 36; index += 1) {
    if (index === 8 || index === 13 || index === 18 || index === 23) out += "-";
    else if (index === 14) out += "4";
    else {
      const value = Math.floor(Math.random() * 16);
      out += (index === 19 ? (value & 0x3) | 0x8 : value).toString(16);
    }
  }
  return out;
}

// 文件体积展示
function fileSize(bytes) {
  if (bytes < 1024 * 1024) return `${Math.ceil(bytes / 1024)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function fileExtension(name) {
  const value = String(name || "").toLowerCase();
  const dot = value.lastIndexOf(".");
  return dot >= 0 ? value.slice(dot + 1) : "";
}

module.exports = { isoDate, suggestedSemesterStart, parseDate, formatNotificationTime, weekTypeLabel, parseWeeks, uuid, fileSize, fileExtension };
