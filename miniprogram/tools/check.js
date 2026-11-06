/*
 * 工程自检：小程序不会在「没打开某个页面」时报出该页面的低级错误，
 * 而这些错误（图标名写错、组件路径写错、app.json 里的页面不存在）
 * 往往要到点进去才暴露。这里在提交前一次性扫出来。
 *
 * 检查项：
 *   1. app.json 里登记的每个页面，四件套（js/json/wxml）是否存在
 *   2. 每个 *.json 里 usingComponents 指向的组件是否存在
 *   3. 每个 wxml 里 <icon name="..."> 的名字是否在 utils/icons.js 里
 *   4. 每个 wxml/js 里 require 的相对路径是否能解析到 .js 文件
 */
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const problems = [];

function read(file) {
  return fs.readFileSync(path.join(ROOT, file), "utf8");
}

function exists(file) {
  return fs.existsSync(path.join(ROOT, file));
}

function walk(dir, out) {
  const result = out || [];
  for (const entry of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
    const rel = path.posix.join(dir.replace(/\\/g, "/"), entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "node_modules") continue;
      walk(rel, result);
    } else {
      result.push(rel);
    }
  }
  return result;
}

const files = walk(".");
const wxmls = files.filter((f) => f.endsWith(".wxml"));
const jsons = files.filter((f) => f.endsWith(".json"));

// 1. 页面登记
const appJson = JSON.parse(read("app.json"));
for (const page of appJson.pages) {
  for (const ext of ["js", "json", "wxml"]) {
    const target = `${page}.${ext}`;
    if (!exists(target)) problems.push(`app.json 登记了 ${page}，但缺少 ${target}`);
  }
}
// 2. 组件路径
for (const file of jsons) {
  let parsed;
  try {
    parsed = JSON.parse(read(file));
  } catch (error) {
    problems.push(`${file} 不是合法 JSON：${error.message}`);
    continue;
  }
  const map = parsed.usingComponents || {};
  for (const [name, target] of Object.entries(map)) {
    const base = target.startsWith("/")
      ? target.slice(1)
      : path.posix.join(path.posix.dirname(file), target);
    // 自定义 tabBar 的组件也可能用相对路径指到 components/
    const normalized = path.posix.normalize(base);
    if (!exists(`${normalized}.json`) || !exists(`${normalized}.wxml`) || !exists(`${normalized}.js`)) {
      problems.push(`${file} 引用组件 ${name} → ${target}，但 ${normalized}.{js,json,wxml} 不完整`);
    }
  }
}
// 3. 图标名
const iconPaths = require(path.join(ROOT, "utils", "icons.js")).PATHS;
const iconNames = new Set(Object.keys(iconPaths));
let iconUses = 0;
for (const file of wxmls) {
  const text = read(file);
  // 静态名字：name="add"
  for (const [, name] of text.matchAll(/<icon\b[^>]*\bname="([^"{}]+)"/g)) {
    iconUses += 1;
    if (!iconNames.has(name)) problems.push(`${file} 使用了不存在的图标 "${name}"`);
  }
  // 动态名字：name="{{cond ? 'a' : 'b'}}" —— 抽出里面的字符串字面量一起校验，
  // 否则这类写法会整块漏检（曾经就漏过一个不存在的图标名）
  for (const match of text.matchAll(/<icon\b[^>]*\bname="\{\{([^}]*)\}\}"/g)) {
    for (const [, literal] of match[1].matchAll(/'([a-z0-9_-]+)'/g)) {
      iconUses += 1;
      if (!iconNames.has(literal)) problems.push(`${file} 动态图标里引用了不存在的名字 "${literal}"`);
    }
  }
}
// 4. require 路径
for (const file of files.filter((f) => f.endsWith(".js") && !f.startsWith("tools/"))) {
  const text = read(file);
  const matches = text.matchAll(/require\("(\.[^"]+)"\)/g);
  for (const [, target] of matches) {
    const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(file), target));
    if (!exists(resolved) && !exists(`${resolved}.js`)) {
      problems.push(`${file} require("${target}") 无法解析到 ${resolved}`);
    }
  }
}

/*
 * 5. wxml 里绑定的事件处理函数，在对应 js 里是否真的有定义。
 * 漏一个的表现是「按钮点了没反应」，开发者工具也不会报错，必须静态查出来。
 */
let handlerUses = 0;
for (const file of wxmls) {
  const jsFile = file.replace(/\.wxml$/, ".js");
  if (!exists(jsFile)) continue;
  const wxmlText = read(file);
  const jsText = read(jsFile);
  const handlers = new Set();
  for (const match of wxmlText.matchAll(/\b(?:bind|catch):?([a-zA-Z]+)="([A-Za-z_$][\w$]*)"/g)) {
    // bindtap="x" 与 bind:tap="x" 都要覆盖；wx:for-item 这类不是事件
    if (match[1] === "for" || match[1] === "if") continue;
    handlers.add(match[2]);
  }
  for (const handler of handlers) {
    handlerUses += 1;
    if (!new RegExp(`\\b${handler}\\s*\\(`).test(jsText)) {
      problems.push(`${file} 绑定的事件 ${handler} 在 ${path.basename(jsFile)} 里没有定义`);
    }
  }
}

console.log(`页面 ${appJson.pages.length} 个 · wxml ${wxmls.length} 个 · 图标引用 ${iconUses} 处 · 可用图标 ${iconNames.size} 个 · 事件绑定 ${handlerUses} 处`);
if (problems.length) {
  console.log("\n发现问题：");
  problems.forEach((item) => console.log(`  ✗ ${item}`));
  process.exitCode = 1;
} else {
  console.log("✓ 结构自检全部通过");
}
