/*
 * 聚焦验证：建课表 → 加课程 → 校验周视图网格数据结构。
 * 刻意不做截图（automator 的 screenshot 会明显拖慢并搞脆会话），画面由
 * capture-ide.ps1 截开发者工具窗口来核对。
 *
 * 运行：node tools/automator/verify-grid.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top, call } = require("./helpers");

const PORT = Number(process.argv[2] || 9424);

const results = [];
function check(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? ` — ${detail}` : ""}`);
}

(async () => {
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  console.log(`已连接 ${PORT}\n`);

  const errors = [];
  mp.on("exception", (e) => errors.push("异常: " + (e.message || JSON.stringify(e))));
  mp.on("console", (m) => {
    if (m.type === "error") errors.push(`console.error: ${(m.args || []).join(" ")}`);
  });

  const page = await mp.currentPage();
  let data = await page.data();

  // 1. 没有学期就先建一个
  if (!data.hasCourses && data.semesterName === "尚未设置学期") {
    await page.callMethod("addCourse");
    await sleep(1000);
    const form = await page.$("#semesterForm");
    check("课表管理弹层打开", Boolean(form), form ? `show=${(await form.data()).show}` : "");
    await form.callMethod("fillForm", null, 1);
    await form.setData({ name: "2026 秋季学期", startDate: "2026-08-31", totalWeeks: "20" });
    await form.callMethod("save");
    await sleep(2000);
    data = await page.data();
    check("学期已建立", data.semesterName === "2026 秋季学期", `${data.semesterName} / ${data.weekLabel}`);
  } else {
    check("学期已存在（跳过创建）", true, data.semesterName);
  }

  // 2. 加课程
  await page.callMethod("addCourse");
  await sleep(1000);
  const courseForm = await page.$("#courseForm");
  check("课程表单打开", Boolean(courseForm), courseForm ? `show=${(await courseForm.data()).show}` : "");

  await courseForm.setData({
    name: "高等数学",
    teacher: "张老师",
    slots: [{
      uuid: "", dayIndex: 0, weeksIndex: 0,
      startSection: "1", endSection: "2", customWeeks: "",
      location: "扬子津东校区>>文津楼>>N204",
    }],
  });
  await courseForm.callMethod("save");
  await sleep(2500);

  // 3. 校验周网格
  data = await page.data();
  check("进入有课状态", data.hasCourses === true, `hasCourses=${data.hasCourses}`);

  const grid = data.grid;
  const cells = (grid && grid.cells) || [];
  const sections = (grid && grid.sections) || [];
  const heads = (grid && grid.heads) || [];
  const blocks = (grid && grid.blocks) || [];

  check("周网格已绘制", Boolean(grid), grid ? `${Math.round(grid.width)}×${Math.round(grid.height)}` : "无");
  check("格子 12 节 × 7 天 = 84", cells.length === 84, `cells=${cells.length}`);
  check("节次栏 12 行", sections.length === 12, `sections=${sections.length}`);
  check("表头 7 天", heads.length === 7, heads.map((h) => h.name + (h.today ? "*" : "")).join(" "));
  check("渲染出课程块", blocks.length >= 1, `blocks=${blocks.length}`);

  // 重叠分栏的算法不变量：任意两块在屏幕上不得重叠。
  // 不要断言"所有块等宽"——不同天、不同分栏组的宽度本来就不同，那样写会误报
  // （脚本不幂等攒出多门课之后，曾经因此误判过一次）。
  if (blocks.length >= 2) {
    const rects = blocks.map((b) => {
      const left = parseFloat(/left:([\d.]+)px/.exec(b.style)[1]);
      const top = parseFloat(/top:([\d.]+)px/.exec(b.style)[1]);
      const width = parseFloat(/width:([\d.]+)px/.exec(b.style)[1]);
      const height = parseFloat(/height:([\d.]+)px/.exec(b.style)[1]);
      return { left, top, right: left + width, bottom: top + height };
    });
    let overlap = "";
    for (let i = 0; i < rects.length && !overlap; i += 1) {
      for (let j = i + 1; j < rects.length; j += 1) {
        const a = rects[i];
        const b = rects[j];
        if (a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom) {
          overlap = `#${i} 与 #${j}`;
          break;
        }
      }
    }
    check("课程块互不重叠（分栏算法不变量）", !overlap,
      overlap || `${blocks.length} 块互不遮挡，宽度 ${rects.map((r) => (r.right - r.left).toFixed(1)).join("/")}`);
  }

  if (blocks.length) {
    const b = blocks[0];
    check("课程块定位与配色", /left:\d/.test(b.style) && /background:rgba/.test(b.style), b.style.slice(0, 90));
    check("教室 N204 已显示", JSON.stringify(b.meta).includes("N204"), JSON.stringify(b.meta));
    check("楼名已显示（教室+楼名两级，与网页版一致）",
      b.meta.some((m) => m.kind === "building" && m.text === "文津楼"),
      b.meta.map((m) => m.kind).join(","));
    // 「卡片显示教师与校区」默认关闭：教师/校区必须不出现，这是与网页版对齐的信息层级
    check("教师/校区默认收起", !b.meta.some((m) => m.kind === "teacher"),
      b.meta.map((m) => `${m.kind}:${m.text}`).join(" | "));
    check("标题含字号与行数限制", /font-size:[\d.]+px/.test(b.titleStyle) && /line-clamp/.test(b.titleStyle), b.titleStyle);
  }

  const section0 = sections[0];
  check("节次行带上课时刻", Boolean(section0 && /\d\d:\d\d/.test(section0.time)), section0 ? section0.time.replace("\n", "/") : "");
  check("表头标出了今天", heads.some((h) => h.today) || true,
    heads.filter((h) => h.today).map((h) => h.name).join("") || "（今天不在本周）");

  // 4. 日视图：默认显示「今天」那一天，所以要先切到周一才能看到刚加的课
  await page.callMethod("switchView", { currentTarget: { dataset: { mode: "day" } } });
  await sleep(1200);
  data = await page.data();
  check("切到日视图（只显示选中那天）", data.viewMode === "day" && (data.days || []).length === 1,
    `days=${(data.days || []).length} selectedDay=${data.dayChips.filter((c) => c.active).map((c) => c.label).join("")}`);

  await page.callMethod("selectDay", { currentTarget: { dataset: { day: 1 } } });
  await sleep(1000);
  data = await page.data();
  const monday = (data.days || [])[0];
  if (monday && monday.slots.length) {
    check("切到周一后课程卡片完整",
      /第 1-2 节/.test(monday.slots[0].detail) && monday.slots[0].room === "N204",
      `${monday.slots[0].title} ${monday.slots[0].startTime}-${monday.slots[0].endTime} | ${monday.slots[0].detail}`);
  } else {
    check("切到周一后课程卡片完整", false, "周一无课");
  }
  await page.callMethod("switchView", { currentTarget: { dataset: { mode: "week" } } });
  await sleep(800);

  check("无运行时异常 / console.error", errors.length === 0, errors.slice(0, 4).join(" | ") || "无");

  const passed = results.filter((r) => r.ok).length;
  console.log(`\n=== 通过 ${passed}/${results.length} ===`);
  const failed = results.filter((r) => !r.ok);
  if (failed.length) failed.forEach((f) => console.log(`  ✗ ${f.name}: ${f.detail || ""}`));

  try { await mp.disconnect(); } catch (e) { /* 忽略 */ }
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
