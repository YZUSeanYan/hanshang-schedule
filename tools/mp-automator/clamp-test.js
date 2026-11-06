/*
 * 判定多行截断是否真的生效——不依赖截图，靠量高度。
 *
 * 背景：计算样式里 display 读出来是 flow-root 而不是 -webkit-box，但同一批规则里的
 * -webkit-box-orient / -webkit-line-clamp 又都读对了，光看样式值无法定论。
 * 于是换个判据：给一个超长课名，量标题元素的实际高度。
 *   截断生效 → 高度被限制在 N 行以内
 *   截断失效 → 高度随文字行数增长
 *
 * 运行：node clamp-test.js [端口]
 */
const automator = require("miniprogram-automator");

const PORT = Number(process.argv[2] || 9431);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 40 个字，窄列下必然远超 4 行
const LONG_NAME = "马克思主义基本原理概论与中国特色社会主义理论体系实践研究专题";

(async () => {
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  const page = await mp.currentPage();
  if (page.path !== "pages/schedule/index") {
    await mp.switchTab("/pages/schedule/index");
    await sleep(1500);
  }

  const data = await page.data();
  const semesterName = data.semesterName;
  console.log("当前学期:", semesterName);

  // 找学期 uuid：先开一次课程表单，它内部能拿到
  await page.callMethod("addCourse");
  await sleep(1200);
  const form = await page.$("#courseForm");
  const formData = await form.data();
  console.log("课程表单已打开, semesterUuid:", formData.semesterUuid ? "(有)" : "(无)");

  await form.setData({
    name: LONG_NAME,
    teacher: "",
    slots: [{
      // 必须是「每周」，否则新课只在指定周次出现，当前周看不到
      uuid: "", dayIndex: 2, weeksIndex: 0, customWeeks: "",
      startSection: "11", endSection: "12", location: "文津楼N204",
    }],
  });
  await form.callMethod("save");
  await sleep(2500);

  const after = await page.data();
  const blocks = (after.grid && after.grid.blocks) || [];
  console.log("课程块数:", blocks.length);

  // 找刚加的那一块：按行数上限区分（自定义周次单节 → titleLines = 4）
  const target = blocks.find((b) => b.title && b.title.indexOf("马克思主义") === 0);
  if (!target) {
    console.log("✗ 没找到刚加的课程块，现有:", blocks.map((b) => b.title).join(" | "));
    process.exit(1);
  }

  const clamp = Number((/-webkit-line-clamp:(\d+)/.exec(target.titleStyle) || [])[1] || 0);
  const fontSize = Number((/font-size:([\d.]+)px/.exec(target.titleStyle) || [])[1] || 0);
  const node = await page.$(`[data-uuid="${target.uuid}"] .course-block-title`);
  const size = node ? await node.size() : null;

  // line-height 未显式设置，用的是 .course-block-title{line-height:1.1}
  const lineHeight = fontSize * 1.1;
  const maxHeight = clamp * lineHeight;

  console.log(`\n课名长度: ${LONG_NAME.length} 字`);
  console.log(`行数上限 clamp = ${clamp}，字号 = ${fontSize}px，行高 ≈ ${lineHeight.toFixed(1)}px`);
  console.log(`截断生效时标题高度上限 ≈ ${maxHeight.toFixed(1)}px`);
  console.log(`标题元素实测高度 = ${size ? size.height.toFixed(1) + "px" : "(取不到)"}`);

  if (size) {
    const clamped = size.height <= maxHeight + 2; // 留 2px 容差
    console.log(clamped
      ? "\n✓ 多行截断生效：高度被限制在行数上限内"
      : "\n✗ 多行截断未生效：高度超出上限，文字会溢出（靠父块 overflow 硬裁）");
  }

  try { await mp.disconnect(); } catch (e) { /* 忽略 */ }
  process.exit(0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
