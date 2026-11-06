/*
 * 量关键节点的真实几何（size/offset）与计算样式。
 *
 * 用途：区分「布局塌了」与「只是截图没绘制」——前者尺寸会是 0 或跑到屏幕外，
 * 后者尺寸正常。页面主体在截图里是空的，但节点确实在 wxml 树里，必须量一下才能定性。
 *
 * 运行：node tools/automator/geometry.js [端口]
 */
const automator = require("miniprogram-automator");

const PORT = Number(process.argv[2] || 9423);

(async () => {
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  const page = await mp.currentPage();
  console.log("当前页:", page.path, "\n");

  const selectors = [".app-root", ".app-header", ".app-header-title", ".guest-bar",
    ".schedule-shell", ".schedule-toolbar", ".empty-state", ".empty-title", ".empty-desc", ".btn"];

  for (const selector of selectors) {
    const node = await page.$(selector);
    if (!node) { console.log(`${selector.padEnd(20)} 不存在`); continue; }
    let size = null;
    let offset = null;
    let style = "";
    try { size = await node.size(); } catch (e) { size = "err:" + e.message; }
    try { offset = await node.offset(); } catch (e) { offset = "err:" + e.message; }
    try { style = (await node.style("display")) || ""; } catch (e) { /* 忽略 */ }
    console.log(`${selector.padEnd(20)} size=${JSON.stringify(size)} offset=${JSON.stringify(offset)} display=${style}`);
  }

  const data = await page.data();
  console.log("\nwindowHeight 相关:", JSON.stringify({
    statusBarHeight: data.statusBarHeight,
    navBarHeight: data.navBarHeight,
    tabBarHeight: data.tabBarHeight,
  }));

  try { await mp.disconnect(); } catch (e) { /* 忽略 */ }
  process.exit(0);
})().catch((error) => {
  console.log("失败:", error.message);
  process.exit(1);
});
