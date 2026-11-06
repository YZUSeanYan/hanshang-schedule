/*
 * 切到指定 tab 并停住，便于用 capture-ide.ps1 截开发者工具窗口来肉眼核对。
 * 用法：node tools/automator/goto.js <schedule|import|profile> [端口]
 */
const automator = require("miniprogram-automator");

const target = process.argv[2] || "schedule";
const PORT = Number(process.argv[3] || 9424);
const PAGES = {
  schedule: "/pages/schedule/index",
  import: "/pages/import/index",
  profile: "/pages/profile/index",
};

(async () => {
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  const page = await mp.switchTab(PAGES[target] || PAGES.schedule);
  await new Promise((r) => setTimeout(r, 1500));
  console.log("已切到", page.path);
  try { await mp.disconnect(); } catch (e) { /* 忽略 */ }
  process.exit(0);
})().catch((e) => { console.log("失败:", e.message); process.exit(1); });
