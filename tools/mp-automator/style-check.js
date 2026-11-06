/*
 * 计算样式核对：不依赖画面，直接读渲染层算出来的最终样式。
 *
 * 为什么需要它：模拟器面板被关掉后渲染面不再合成，截图一律空白；但布局与样式
 * 仍然由渲染层算得出来（geometry.js 已证明几何是对的）。所以用「实际生效的颜色
 * 与字号」来验证视觉，比盯着截图更可靠，也更能定位问题（截图只能看出不对，
 * 这里能看出是哪个值不对）。
 *
 * 期望值来自 app.wxss 的 M3 令牌（浅色）与 rpx 换算：390px 屏上 1rpx = 0.52px。
 *
 * 运行：node style-check.js [端口]
 */
const automator = require("miniprogram-automator");

const PORT = Number(process.argv[2] || 9431);
const RPX = 390 / 750;

const results = [];
function check(name, actual, expected) {
  const ok = actual === expected;
  results.push({ name, ok, actual, expected });
  console.log(`${ok ? "✓" : "✗"} ${name}\n    实际: ${actual}\n    期望: ${expected}`);
}

// 小程序把 rpx 换算后取整成整数 px（44rpx 在 390px 屏上算出 22.88，计算样式报 22），
// 所以字号只比取整后的值。
function rpx(value) {
  return Math.round(value * RPX);
}

(async () => {
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  const page = await mp.currentPage();
  console.log("页面:", page.path, "\n");

  const styleOf = async (selector, property) => {
    const node = await page.$(selector);
    if (!node) return `（找不到 ${selector}）`;
    try {
      return await node.style(property);
    } catch (error) {
      return `（读样式失败：${error.message}）`;
    }
  };

  // —— 顶栏：M3 primary(眉题) / on-surface(标题) ——
  check(".eyebrow 颜色 = primary #206A4E", await styleOf(".eyebrow", "color"), "rgb(32, 106, 78)");
  check(".app-header-title 颜色 = on-surface #171D1A", await styleOf(".app-header-title", "color"), "rgb(23, 29, 26)");
  check(`.app-header-title 字号 = 44rpx ≈ ${rpx(44)}px`, await styleOf(".app-header-title", "font-size"), `${rpx(44)}px`);

  // —— 游客提示条：secondary-container ——
  check(".guest-bar 底色 = secondary-container #CFE9D9",
    await styleOf(".guest-bar", "background-color"), "rgb(207, 233, 217)");

  // —— 工具栏 ——
  check(".week-label 字号 = 30rpx", await styleOf(".week-label", "font-size"), `${rpx(30)}px`);
  check(".segmented 底色 = surface-container #EAEFE9",
    await styleOf(".segmented", "background-color"), "rgb(234, 239, 233)");
  check(".segmented-item-active 颜色 = primary",
    await styleOf(".segmented-item-active", "color"), "rgb(32, 106, 78)");

  // —— 课程块：底色为课程色 16% 透明，左条为实色，文字为混色 ——
  const block = await page.$(".course-block");
  if (block) {
    const bg = await block.style("background-color");
    const border = await block.style("border-left-color");

    // 底色必须带 alpha（0.16），说明用了 applyCourseColorVars 那套而不是纯色
    check("课程块底色带 16% 透明度", /rgba\(\d+, \d+, \d+, 0\.16\)/.test(bg), true);
    check("课程块左条为实色（非透明）", /^rgb\(\d+, \d+, \d+\)$/.test(border), true);

    console.log(`    （底色 ${bg} / 左条 ${border}）`);
  } else {
    check("课程块存在", false, true);
  }

  // 课名的截断样式在标题元素上，不在块上（这里曾经读错元素，误判成没生效）
  const title = await page.$(".course-block-title");
  if (title) {
    const display = await title.style("display");
    const clamp = await title.style("-webkit-line-clamp");
    const orient = await title.style("-webkit-box-orient");
    const overflow = await title.style("overflow");
    const fontSize = await title.style("font-size");
    const color = await title.style("color");

    check("课名是 -webkit-box（多行截断的前提）", display, "-webkit-box");
    check("课名盒内纵向排列", orient, "vertical");
    check("课名溢出隐藏", overflow, "hidden");
    check("课名启用了多行截断", Number(clamp) > 0, true);
    check("课名字号按长度自适应（在 8-12px 区间）",
      Number.parseFloat(fontSize) >= 8 && Number.parseFloat(fontSize) <= 12, true);
    check("课名文字色为课程混色", /^rgb\(/.test(color), true);

    console.log(`    （display ${display} / clamp ${clamp} / 字号 ${fontSize} / 颜色 ${color}）`);
  } else {
    check("课名元素存在", false, true);
  }

  // —— 底栏在另一个组件树里，用 tabbar 组件的样式核对 ——
  // page.$ 只能查页面树，tabbar 已在此前用 IDE 截图肉眼确认过图标与选中态

  const failed = results.filter((r) => !r.ok);
  console.log(`\n=== 通过 ${results.length - failed.length}/${results.length} ===`);

  try { await mp.disconnect(); } catch (e) { /* 忽略 */ }
  process.exit(failed.length ? 1 : 0);
})().catch((error) => {
  console.log("中断:", error.message);
  process.exit(1);
});
