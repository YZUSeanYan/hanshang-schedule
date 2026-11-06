/*
 * 只连接、不负责起停自动化服务——服务由外部常驻（tools/wxcli.js auto）。
 * 这样反复诊断时不会因为反复 kill 掉 cli auto 而让 IDE 的自动化会话残留。
 *
 * 运行：node tools/automator/inspect.js [端口，默认 9423]
 */
const path = require("path");
const fs = require("fs");
const automator = require("miniprogram-automator");

const PORT = Number(process.argv[2] || 9423);
const SHOTS = path.join(__dirname, "shots");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  fs.mkdirSync(SHOTS, { recursive: true });
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  console.log("已连接 端口", PORT);

  const logs = [];
  mp.on("exception", (e) => logs.push("exception: " + (e.message || JSON.stringify(e))));
  mp.on("console", (m) => logs.push(`${m.type}: ${(m.args || []).join(" ")}`));

  const page = await mp.currentPage();
  console.log("当前页:", page.path);

  await sleep(3000);
  await mp.screenshot({ path: path.join(SHOTS, "inspect.png") });
  console.log("已截图 inspect.png");

  const selectors = [".app-root", ".schedule-root", ".app-header", ".empty-state",
    ".guest-bar", ".schedule-toolbar", ".week-host", ".tabbar"];
  console.log("\n关键节点：");
  for (const selector of selectors) {
    const node = await page.$(selector);
    if (!node) { console.log(`  ✗ ${selector}`); continue; }
    let snippet = "";
    try { snippet = (await node.wxml()).replace(/\s+/g, " ").slice(0, 120); } catch (e) { snippet = "(取不到)"; }
    console.log(`  ✓ ${selector} | ${snippet}`);
  }

  const data = await page.data();
  console.log("\n数据:", JSON.stringify({
    hasCourses: data.hasCourses,
    guest: data.guest,
    themeClass: data.themeClass,
    statusBarHeight: data.statusBarHeight,
    tabBarHeight: data.tabBarHeight,
  }));

  console.log("\nconsole：");
  logs.slice(0, 12).forEach((l) => console.log("  " + l));
  if (!logs.length) console.log("  （无）");

  try { await mp.disconnect(); } catch (e) { /* 忽略 */ }
  process.exit(0);
})().catch((error) => {
  console.log("失败:", error.message);
  process.exit(1);
});
