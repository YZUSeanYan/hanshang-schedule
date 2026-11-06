/*
 * 一致性测试：把网页版 app.js / couple.js / section-times.js 里的纯函数抽出来，
 * 与本小程序的移植版喂同一批输入，逐项比对输出。
 *
 * 为什么值得写：路径解析、周次筛选、课程配色这三块是三端（Flutter/网页/小程序）
 * 必须算出同一个结果的逻辑——配色错一位，同一门课在网页和小程序里就是两个颜色；
 * 周次筛选错一档，会出现"这周有课但没显示"。这些偏差跑一遍就能发现，
 * 靠肉眼读代码发现不了。
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const WEB = process.argv[2] || path.resolve(__dirname, "../../web");
const ROOT = path.resolve(__dirname, "..");

// 从源码里按函数名抽出完整函数体（顶层 function 声明，靠花括号配对找结尾）
function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`没找到函数 ${name}`);
  let depth = 0;
  let index = source.indexOf("{", start);
  const open = index;
  for (; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    else if (source[index] === "}") {
      depth -= 1;
      if (depth === 0) break;
    }
  }
  return source.slice(start, index + 1);
}

function extractConst(source, name) {
  const start = source.indexOf(`const ${name} = [`);
  if (start < 0) throw new Error(`没找到常量 ${name}`);
  const end = source.indexOf("];", start);
  return source.slice(start, end + 2);
}

const webApp = fs.readFileSync(path.join(WEB, "app.js"), "utf8");
const webCouple = fs.readFileSync(path.join(WEB, "modules", "couple-schedule", "couple.js"), "utf8");
const webSection = fs.readFileSync(path.join(WEB, "section-times.js"), "utf8").replace(/^export /gm, "");

// 网页版那一侧：只抽纯函数，塞进一个干净的作用域里执行
const webNames = [
  "hashCourseName", "macaronForName", "forCourseNameArgb", "courseBaseColor",
  "hexChannels", "withAlpha", "blendedText", "isoDate", "suggestedSemesterStart",
  "slotIsActiveInWeek", "displayLocation", "parseLocationParts", "weeksForSync",
];
const webSource = [
  extractConst(webApp, "MACARON"),
  ...webNames.map((name) => extractFunction(webApp, name)),
  extractFunction(webCouple, "freeRanges"),
  webSection,
  "module.exports = { MACARON, " + webNames.join(", ") + ", freeRanges, defaults, validate, parse, forDate, minutes, clock };",
].join("\n\n");

const webSandbox = { module: { exports: {} }, console };
vm.createContext(webSandbox);
vm.runInContext(webSource, webSandbox);
const web = webSandbox.module.exports;

// 小程序这一侧
const mine = {
  colors: require(path.join(ROOT, "utils", "colors.js")),
  format: require(path.join(ROOT, "utils", "format.js")),
  schedule: require(path.join(ROOT, "utils", "schedule.js")),
  sectionTimes: require(path.join(ROOT, "utils", "section-times.js")),
};
// couple 页里的 freeRanges 是页内函数，这里照搬同一实现（页面无法直接被 require）
function myFreeRanges(states) {
  const result = [];
  let start = -1;
  for (let index = 0; index <= states.length; index += 1) {
    const free = index < states.length && states[index] === "both_free";
    if (free && start < 0) start = index + 1;
    if (!free && start > 0) {
      result.push(start === index ? `第${start}节` : `${start}-${index}节`);
      start = -1;
    }
  }
  return result;
}

// ---- 用例 ----

const failures = [];
let checks = 0;

function compare(label, webValue, myValue) {
  checks += 1;
  const a = JSON.stringify(webValue);
  const b = JSON.stringify(myValue);
  if (a !== b) failures.push(`${label}\n    网页版: ${a}\n    小程序: ${b}`);
}

// 1. 课程配色：哈希 / 马卡龙 / ARGB / 基色解析
const names = ["高等数学", "大学英语", "体育", "数据结构与算法", "A", "", "（实验）物理", "马克思主义基本原理概论"];
for (const name of names) {
  compare(`hashCourseName(${JSON.stringify(name)})`, web.hashCourseName(name), mine.colors.hashCourseName(name));
  compare(`macaronForName(${JSON.stringify(name)})`, web.macaronForName(name), mine.colors.macaronForName(name));
  compare(`forCourseNameArgb(${JSON.stringify(name)})`, web.forCourseNameArgb(name), mine.colors.forCourseNameArgb(name));
}

const colorCases = [
  { name: "高等数学", color: 0xffa8d8ea },
  { name: "高等数学", color: 4288453866 },
  { name: "高等数学", color: -6116702 },      // int32 负数形式
  { name: "高等数学", color: 3 },              // 早期网页版写入的序号，应回落到哈希色
  { name: "高等数学", color: 0 },
  { name: "高等数学", color: "16737792" },
  { name: "高等数学", color: null },
  { name: "体育", color: 0xff3388cc },
];
for (const item of colorCases) {
  compare(`courseBaseColor(${JSON.stringify(item)})`, web.courseBaseColor(item), mine.colors.courseBaseColor(item));
}
for (const hex of ["#A8D8EA", "#000000", "#FFFFFF", "#7F3A21"]) {
  compare(`withAlpha(${hex},0.16)`, web.withAlpha(hex, 0.16), mine.colors.withAlpha(hex, 0.16));
  compare(`blendedText(${hex},0.55,0)`, web.blendedText(hex, 0.55, 0), mine.colors.blendedText(hex, 0.55, 0));
  compare(`blendedText(${hex},0.3,255)`, web.blendedText(hex, 0.3, 255), mine.colors.blendedText(hex, 0.3, 255));
}

// 2. 周次筛选
const slots = [
  { weeks_type: 0 },
  { weeks_type: 1 },
  { weeks_type: 2 },
  { weeks_type: 3, custom_weeks: "1-8,10,12" },
  { weeks_type: 3, custom_weeks: "1,3,5" },
  { weeks_type: 3, custom_weeks: "" },
  { weeks_type: undefined },
];
for (const slot of slots) {
  const mineFlags = [];
  const webFlags = [];
  for (let week = 0; week <= 20; week += 1) {
    webFlags.push(web.slotIsActiveInWeek(slot, week));
    mineFlags.push(mine.schedule.slotIsActiveInWeek(slot, week));
  }
  compare(`slotIsActiveInWeek(${JSON.stringify(slot)})`, webFlags, mineFlags);
}

// 3. 地点解析
const locations = [
  "",
  "@文津楼N204",
  "扬子津东校区>>文津楼>>N204",
  "扬子津东校区→→文津楼→→N204",
  "扬子津东校区 文津楼 N204",
  "文津楼N204 · 扬子津东校区",
  "瘦西湖校区 教学楼 301",
  "江阳路北校区>>体育馆>>A区",
  "杨子金东校区 文津楼 N204",
  "荷花池校区 中心实验室 105",
  "扬子津西校区 操场",
  "  多   空格   教室  ",
  "某楼12-3",
  "未知地点",
];
for (const value of locations) {
  compare(`displayLocation(${JSON.stringify(value)})`, web.displayLocation(value), mine.schedule.displayLocation(value));
  compare(`parseLocationParts(${JSON.stringify(value)})`, web.parseLocationParts(value), mine.schedule.parseLocationParts(value));
}

// 4. AI 识别周次文本
for (const text of ["1-16周", "单周", "双周", "1,3,5", "", "第1-8周", "1-16", "9-16周(单)", "3", null, "12345"]) {
  compare(`weeksForSync(${JSON.stringify(text)})`, web.weeksForSync(text), mine.schedule.weeksForSync(text));
}

// 5. 日期辅助
const dates = [new Date(2026, 8, 19), new Date(2026, 0, 15), new Date(2026, 2, 1), new Date(2026, 7, 31), new Date(2027, 1, 20)];
for (const date of dates) {
  compare(`isoDate(${date.toISOString().slice(0, 10)})`, web.isoDate(date), mine.format.isoDate(date));
  compare(`suggestedSemesterStart(${date.toISOString().slice(0, 10)})`, web.suggestedSemesterStart(date), mine.format.suggestedSemesterStart(date));
}

// 6. 作息时间
for (const date of dates) {
  compare(`defaults(${date.toISOString().slice(0, 10)})`, web.defaults(date), mine.sectionTimes.defaults(date));
}
const timesCases = [
  ["08:00", "08:45"],
  { custom: true },
];
compare("validate(合法 12 节)",
  web.validate(Array.from({ length: 12 }, (_, i) => [String(8 + i).padStart(2, "0") + ":00", String(8 + i).padStart(2, "0") + ":45"])),
  mine.sectionTimes.validate(Array.from({ length: 12 }, (_, i) => [String(8 + i).padStart(2, "0") + ":00", String(8 + i).padStart(2, "0") + ":45"])));
const badTimes = Array.from({ length: 12 }, () => ["09:00", "08:00"]);
compare("validate(下课早于上课)", web.validate(badTimes), mine.sectionTimes.validate(badTimes));
compare("validate(只有 11 节)", web.validate(Array.from({ length: 11 }, () => ["08:00", "08:45"])), mine.sectionTimes.validate(Array.from({ length: 11 }, () => ["08:00", "08:45"])));
compare("parse(自定义合法)", web.parse(JSON.stringify({ version: 1, mode: "custom", times: Array.from({ length: 12 }, (_, i) => [`0${8}:00`, `0${8}:45`]) })),
  mine.sectionTimes.parse(JSON.stringify({ version: 1, mode: "custom", times: Array.from({ length: 12 }, (_, i) => [`0${8}:00`, `0${8}:45`]) })));
compare("parse(损坏数据)",
  web.parse("{not json"),
  mine.sectionTimes.parse("{not json"));
compare("parse(null)",
  web.parse(null),
  mine.sectionTimes.parse(null));
compare("forDate(自动/冬夏)", web.forDate({ mode: "automatic" }, new Date(2026, 10, 1)), mine.sectionTimes.forDate({ mode: "automatic" }, new Date(2026, 10, 1)));

// 7. 共同空闲的连续空档合并
const stateCases = [
  ["both_free", "both_free", "me_busy", "both_free"],
  ["me_busy", "me_busy"],
  ["both_free"],
  [],
  ["both_free", "both_free", "both_free"],
  ["both_busy", "both_free", "both_free", "partner_busy", "both_free"],
];
for (const states of stateCases) {
  compare(`freeRanges(${JSON.stringify(states)})`, web.freeRanges(states), myFreeRanges(states));
}

// ---- 结果 ----
console.log(`一致性用例：${checks} 项，来自网页版 app.js / couple.js / section-times.js 的同名函数`);
if (failures.length) {
  console.log(`\n✗ ${failures.length} 项不一致：\n`);
  failures.forEach((item) => console.log(`  ✗ ${item}\n`));
  process.exitCode = 1;
} else {
  console.log("✓ 全部一致：课程配色 / 周次筛选 / 地点解析 / 周次文本 / 日期 / 作息 / 共同空闲合并");
}
