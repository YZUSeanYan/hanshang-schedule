/*
 * 课程配色：与网页版 app.js 及安卓 CourseColors 三端同一套规则。
 * 云端 color 字段是安卓写入的 ARGB int，两端必须解出同一个基色，
 * 否则同一门课在 App / 网页 / 小程序里颜色不一致。
 *
 * 网页版把颜色写成 CSS 变量交给样式层算透明度；小程序这边直接把最终
 * 颜色算好（WXSS 的 var() 与 color-mix() 支持度不齐），避免渲染差异。
 */

// 马卡龙 10 色板，按课程名 UTF-16 码元哈希分配
const MACARON = ["#A8D8EA", "#FFCBCB", "#B5EAD7", "#FFDAC1", "#C7CEEA", "#F6E6AD", "#A2E1DB", "#F3B0C3", "#BFD8B8", "#E7C6E7"];

function hashCourseName(name) {
  const text = String(name || "");
  let hash = 0;
  for (let index = 0; index < text.length; index += 1) {
    hash = (hash * 31 + text.charCodeAt(index)) & 0x7fffffff;
  }
  return hash;
}

function macaronForName(name) {
  return MACARON[hashCourseName(name) % MACARON.length];
}

// 写入云端的 ARGB int。不能用位或：JS 位运算会把 0xFF000000 变成负数 int32。
function forCourseNameArgb(name) {
  return 0xff000000 + parseInt(macaronForName(name).slice(1), 16);
}

// 解析课程基色：合法 ARGB int（含 int32 负数形式）直接用，否则按课程名回落
function courseBaseColor(course) {
  let raw = Number(course && course.color);
  if (Number.isInteger(raw) && raw < 0) raw = raw >>> 0;
  if (Number.isInteger(raw) && raw > 0xffffff) {
    return `#${(raw & 0xffffff).toString(16).padStart(6, "0").toUpperCase()}`;
  }
  return macaronForName(course && course.name);
}

function hexChannels(hex) {
  return [parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16), parseInt(hex.slice(5, 7), 16)];
}

function withAlpha(hex, alpha) {
  const [r, g, b] = hexChannels(hex);
  return `rgba(${r},${g},${b},${alpha})`;
}

// 安卓 alphaBlend(base@alpha, 黑/白) 的文字色
function blendedText(hex, alpha, base) {
  const [r, g, b] = hexChannels(hex);
  const mix = (channel) => Math.round(channel * alpha + base * (1 - alpha));
  return `#${[mix(r), mix(g), mix(b)].map((v) => v.toString(16).padStart(2, "0")).join("")}`;
}

/*
 * 课程块配色。安卓 _CourseBlock：底=base 16%（深色 30%），
 * 文字=base 55% 混黑 / 30% 混白，描边=base 38%，左条用实色。
 */
function coursePaint(course, dark) {
  const base = courseBaseColor(course);
  return {
    base,
    background: withAlpha(base, dark ? 0.3 : 0.16),
    border: withAlpha(base, 0.38),
    text: dark ? blendedText(base, 0.3, 255) : blendedText(base, 0.55, 0),
    secondary: dark ? blendedText(base, 0.42, 255) : blendedText(base, 0.7, 0),
  };
}

module.exports = { MACARON, hashCourseName, macaronForName, forCourseNameArgb, courseBaseColor, withAlpha, blendedText, coursePaint };
