/*
 * 从网页版 index.html 抽取两样东西，避免手工转写出错：
 *   1) 45 个 Material Symbols 图标 path -> utils/icons.js
 *   2) M3 色板令牌（浅色 :root / 深色 [data-theme=dark]）-> tools/tokens.css（供人工核对）
 * 幂等：可重复运行。网页版改版后重跑即可同步图标。
 */
const fs = require("fs");
const path = require("path");

const WEB = process.argv[2] || path.resolve(__dirname, "../../web");
const OUT = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(WEB, "index.html"), "utf8");

// ---- 1. 图标 ----
const symbols = [...html.matchAll(/<symbol id="i-([^"]+)" viewBox="([^"]*)"><path[^>]*?d="([^"]+)"/g)];
if (!symbols.length) throw new Error("没有抽取到任何 <symbol>，检查 index.html 结构是否变化");

const entries = symbols.map(([, name, viewBox, d]) => ({ name, viewBox, d }));
// 同一个图标名可能出现两次（icon-line / icon-fill 成对，但 id 唯一，这里只做去重保护）
const seen = new Map();
for (const item of entries) if (!seen.has(item.name)) seen.set(item.name, item);

const lines = [
  "/* 由 tools/extract-from-web.js 从网页版 index.html 自动生成，请勿手改。 */",
  "/* viewBox 统一为 0 -960 960 960（Material Symbols），fill 由调用方注入。 */",
  "",
  "const PATHS = {",
];
for (const [name, item] of seen) {
  lines.push(`  ${JSON.stringify(name)}: ${JSON.stringify(item.d)},`);
}
lines.push("};", "");
lines.push("module.exports = { PATHS };", "");
fs.writeFileSync(path.join(OUT, "utils", "icons.js"), lines.join("\n"), "utf8");
console.log(`图标: 抽取 ${symbols.length} 个，去重后 ${seen.size} 个 -> utils/icons.js`);

// ---- 2. 色板令牌 ----
function block(startRe) {
  const index = html.search(startRe);
  if (index < 0) return "";
  const open = html.indexOf("{", index);
  const close = html.indexOf("}", open);
  return html.slice(open + 1, close).trim();
}

const light = block(/:root\s*\{/);
const dark = block(/\[data-theme=["']?dark["']?\]\s*\{/);
const css = [
  "/* 网页版 M3 令牌（自动抽取，供 app.wxss 核对；小程序侧已改写为 page/组件选择器） */",
  "",
  ":root /* light */ {",
  light,
  "}",
  "",
  '[data-theme="dark"] {',
  dark,
  "}",
  "",
].join("\n");
fs.writeFileSync(path.join(__dirname, "tokens.css"), css, "utf8");

const countVars = (text) => (text.match(/--[a-z0-9-]+\s*:/g) || []).length;
console.log(`色板: 浅色 ${countVars(light)} 个变量，深色 ${countVars(dark)} 个变量 -> tools/tokens.css`);

if (!/prefers-reduced-motion/.test(html)) console.log("提示: 网页版无 reduced-motion 块");
