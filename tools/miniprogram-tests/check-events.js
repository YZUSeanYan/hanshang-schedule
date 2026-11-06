/*
 * 日程与冲突合并块的行为测试（App 2.0 的核心体验）。
 *
 * 全程自给自足：自己造课、自己造日程、自己清理，不依赖账号里恰好有什么数据
 * （上一版就是因为 assume「已有周一 1-2 的课」而整片误报）。
 *
 *   1. 自建一门周一 1-2 的课，再在同一时段造一条日程 → 应渲染成「冲突合并块」
 *   2. 点按合并块 → 弹出展开列表
 *   3. 不重叠的日程 → 普通日程块
 *   4. 日视图也显示日程
 *   5. 收尾：只删自己造的（标题带「自检」），并加数量保险
 *
 * 运行：node check-events.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top, addSchedule, addCourseAt } = require("./helpers");

const PORT = Number(process.argv[2] || 9432);
const COURSE = "自检课程-冲突";
const TITLE_A = "自检日程-重叠";
const TITLE_B = "自检日程-独立";

const results = [];
function check(name, ok, detail) {
  results.push({ name, ok });
  console.log((ok ? "✓ " : "✗ ") + name + (detail ? " — " + detail : ""));
}

function fmtDate(d) {
  const p = (n) => String(n).padStart(2, "0");
  return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate());
}

(async () => {
  const mp = await automator.connect({ wsEndpoint: "ws://127.0.0.1:" + PORT });
  const errors = [];
  mp.on("exception", (e) => errors.push("异常: " + (e.message || JSON.stringify(e))));
  mp.on("console", (m) => {
    if (m.type === "error") errors.push("console.error: " + ((m.args || []).join(" ")));
  });

  // 开跑前先自清理：上一轮的残留会让本轮误判（曾因此整片红）
  await mp.mockWxMethod("showModal", { confirm: true, cancel: false });
  for (let round = 0; round < 8; round += 1) {
    await mp.switchTab("/pages/schedule/index");
    await sleep(1500);
    const p0 = await top(mp);
    const d0 = await p0.data();
    const mine0 = [];
    ((d0.grid && d0.grid.blocks) || []).forEach((b) => {
      if ((b.title || "").indexOf("自检") >= 0) mine0.push({ uuid: b.uuid, kind: b.kind });
      (b.items || []).forEach((i) => { if ((i.title || "").indexOf("自检") >= 0) mine0.push({ uuid: i.uuid, kind: i.kind }); });
    });
    if (!mine0.length) break;
    const t0 = mine0[0];
    if (t0.kind === "event") {
      await p0.callMethod("openBlockDetail", { currentTarget: { dataset: { uuid: t0.uuid, kind: "event" } } });
      await sleep(1500);
      await p0.callMethod("deleteEvent");
    } else {
      await p0.callMethod("onDetailDelete", { detail: { uuid: t0.uuid } });
    }
    await sleep(2200);
  }
  await mp.restoreWxMethod("showModal");
  console.log("前置清理完成");

  // 自建一门周一 1-2 的课（不假设账号里有什么）
  await addCourseAt(mp, { name: COURSE, dayIndex: 0, start: 1, end: 2 });
  await mp.switchTab("/pages/schedule/index");
  await sleep(2500);
  let page = await top(mp);
  let data = await page.data();

  const info = await page.callMethod("semesterAndCourses");
  const sem = info && info.semester;
  const week = Number((/第 (\d+) 周/.exec(data.weekLabel || "第 1 周")[1])) || 1;
  const monday = new Date(String(sem.start_date).slice(0, 10) + "T00:00:00");
  monday.setDate(monday.getDate() + (week - 1) * 7);
  const mondayStr = fmtDate(monday);
  console.log("本周周一:", mondayStr);

  function blocks() { return (data.grid && data.grid.blocks) || []; }
  function mergedBlocks() { return blocks().filter((b) => b.merged); }
  function myMerged() {
    return mergedBlocks().filter((b) => (b.items || []).some((i) => (i.title || "").indexOf("自检") >= 0));
  }

  // ---- 1. 同段日程 → 冲突合并块 ----
  await addSchedule(mp, { title: TITLE_A, date: mondayStr, start_section: 1, end_section: 2 });
  await mp.switchTab("/pages/schedule/index");
  await sleep(2800);
  page = await top(mp);
  data = await page.data();
  const m = myMerged();
  check("同段日程触发冲突合并块", m.length >= 1, "含自检项的合并块 " + m.length + " 个");

  const merged = m[0];
  if (merged) {
    check("合并块内含两个活动的小方块", merged.items.length >= 2,
      merged.items.map((i) => i.title).join(" / "));
    check("小方块各用自身活动的主色", merged.items.every((i) => /^rgb\(|^#/.test(i.base)),
      merged.items.map((i) => i.base).join(" / "));
    check("合并块占满整列（宽度与普通块相当）",
      parseFloat(/width:([\d.]+)px/.exec(merged.style)[1]) > 30, merged.style.slice(0, 50));

    await page.callMethod("openConflict", { currentTarget: { dataset: { key: merged.key } } });
    await sleep(1200);
    const conflict = (await page.data()).conflictItems || [];
    check("点按展开列出全部活动", conflict.length >= 2, conflict.map((i) => i.title).join(" / "));
    check("展开列表标出类型", conflict.every((i) => i.kindLabel), conflict.map((i) => i.kindLabel).join("/"));
    await page.callMethod("closeConflict");
    await sleep(800);
  }

  // ---- 2. 不重叠的日程 → 普通块 ----
  const beforeNormal = blocks().filter((b) => !b.merged).length;
  await addSchedule(mp, { title: TITLE_B, date: mondayStr, start_section: 9, end_section: 10 });
  await mp.switchTab("/pages/schedule/index");
  await sleep(2800);
  page = await top(mp);
  data = await page.data();
  const afterNormal = blocks().filter((b) => !b.merged).length;
  check("不重叠的日程是普通块（不合并）", afterNormal > beforeNormal,
    "普通块 " + beforeNormal + " → " + afterNormal);
  check("重叠的那组仍保持合并", myMerged().length >= 1, "合并块 " + myMerged().length);

  // ---- 3. 日视图 ----
  await page.callMethod("switchView", { currentTarget: { dataset: { mode: "day" } } });
  await sleep(1000);
  await page.callMethod("selectDay", { currentTarget: { dataset: { day: 1 } } });
  await sleep(1500);
  data = await page.data();
  const dayEvents = ((data.days || [])[0] || {}).events || [];
  check("日视图显示日程", dayEvents.length >= 2, dayEvents.map((e) => e.title).join(" / "));
  await page.callMethod("switchView", { currentTarget: { dataset: { mode: "week" } } });
  await sleep(1000);

  // ---- 4. 收尾：只删自己造的 ----
  await mp.mockWxMethod("showModal", { confirm: true, cancel: false });

  // 删日程
  for (const title of [TITLE_A, TITLE_B]) {
    await mp.switchTab("/pages/schedule/index");
    await sleep(1500);
    page = await top(mp);
    data = await page.data();
    // 重叠的日程藏在合并块里，普通块里找不到——两处都要找
    const target = blocks().filter((b) => !b.merged)
      .find((b) => (b.title || "").indexOf(title) >= 0)
      || mergedBlocks().flatMap((b) => b.items || []).find((i) => (i.title || "").indexOf(title) >= 0);
    if (!target) { console.log("  未找到待清理日程:", title); continue; }
    await page.callMethod("openBlockDetail", { currentTarget: { dataset: { uuid: target.uuid, kind: "event" } } });
    await sleep(1500);
    await page.callMethod("deleteEvent");
    await sleep(2500);
    console.log("  已删除日程:", title);
  }

  // 删自建课程
  await mp.switchTab("/pages/schedule/index");
  await sleep(1500);
  page = await top(mp);
  data = await page.data();
  const ctarget = blocks().find((b) => (b.title || "").indexOf(COURSE) >= 0)
    || mergedBlocks().flatMap((b) => b.items || []).find((i) => (i.title || "").indexOf(COURSE) >= 0);
  if (ctarget) {
    await page.callMethod("onDetailDelete", { detail: { uuid: ctarget.uuid } });
    await sleep(2500);
    console.log("  已删除课程:", COURSE);
  }
  await mp.restoreWxMethod("showModal");

  await mp.switchTab("/pages/schedule/index");
  await sleep(2500);
  page = await top(mp);
  data = await page.data();
  const leftovers = blocks().filter((b) =>
    (b.title || "").indexOf("自检") >= 0 ||
    (b.items || []).some((i) => (i.title || "").indexOf("自检") >= 0));
  check("自建数据已清理干净", leftovers.length === 0, "剩 " + leftovers.length + " 项");

  check("全程无运行时异常 / console.error", errors.length === 0,
    errors.slice(0, 4).join(" | ") || "无");

  const failed = results.filter((r) => !r.ok);
  console.log("\n=== 通过 " + (results.length - failed.length) + "/" + results.length + " ===");
  try { await mp.disconnect(); } catch (e) {}
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
