/*
 * 隔离验证：切换课表会不会丢课程。
 *
 * preflight3 报出「切回原课表后课程块 1 → 0」，这如果属实就是数据丢失级的问题，
 * 必须查清是应用的问题还是测量的时机问题。这里用最小步骤复现：
 *   课表 A 有一门课 → 新建课表 B（自动成为当前）→ 切回 A → 看 A 的课程还在不在
 *
 * 运行：node check-semester-switch.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top, ensureCourse } = require("./helpers");

const PORT = Number(process.argv[2] || 9432);
const results = [];
function check(name, ok, detail) {
  results.push({ name, ok });
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? ` — ${detail}` : ""}`);
}

function blocks(data) {
  return (data.grid && data.grid.blocks) || [];
}

(async () => {
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  const errors = [];
  mp.on("exception", (e) => errors.push("异常: " + (e.message || JSON.stringify(e))));
  mp.on("console", (m) => {
    if (m.type === "error") errors.push(`console.error: ${(m.args || []).join(" ")}`);
  });

  await mp.mockWxMethod("showModal", { confirm: true, cancel: false });

  await mp.switchTab("/pages/schedule/index");
  await sleep(2000);
  let page = await top(mp);

  // 1. 确保 A 里有一门课
  await ensureCourse(mp);
  await mp.switchTab("/pages/schedule/index");
  await sleep(1800);
  page = await top(mp);
  let data = await page.data();
  const nameA = data.semesterName;
  const countA = blocks(data).length;
  console.log(`课表 A = ${nameA}，课程块 ${countA}`);
  check("A 里有课程（前置）", countA > 0, `${countA} 门`);

  // 用底层同步读一次原始数据，作为"课程是否真的还在"的权威依据
  const before = await page.callMethod("semesterAndCourses");
  const rawBefore = (before && before.snapshot && before.snapshot.courses) || [];
  const activeBefore = rawBefore.filter((c) => !c.deleted && c.semester_uuid === (before.semester && before.semester.uuid));
  console.log(`底层快照：该学期未删除课程 ${activeBefore.length} 条`);

  // 2. 新建课表 B
  await page.callMethod("openSemesterForm");
  await sleep(1500);
  const sf = await page.$("#semesterForm");
  const uuidsBefore = ((await sf.data()).list || []).map((s) => s.uuid);
  await sf.callMethod("fillForm", null, 1);
  await sf.setData({ name: "隔离测试课表", startDate: "2027-02-22", totalWeeks: "18" });
  await sf.callMethod("save");
  await sleep(3000);

  page = await top(mp);
  data = await page.data();
  const nameB = data.semesterName;
  check("新建课表后切到了 B", nameB === "隔离测试课表", `当前=${nameB}`);
  check("B 是空的（课程没串到新表）", blocks(data).length === 0, `B 课程块=${blocks(data).length}`);

  // 3. 切回 A
  await page.callMethod("openSemesterForm");
  await sleep(1500);
  const sf2 = await page.$("#semesterForm");
  const list = (await sf2.data()).list;
  const created = list.find((s) => uuidsBefore.indexOf(s.uuid) < 0);
  const original = list.find((s) => uuidsBefore.indexOf(s.uuid) >= 0);
  if (!original) {
    check("找到原课表", false, "列表里没有");
    process.exit(1);
  }
  await sf2.callMethod("onActivate", { currentTarget: { dataset: { uuid: original.uuid } } });
  await sleep(3500);

  page = await top(mp);
  data = await page.data();
  const nameBack = data.semesterName;
  const countBack = blocks(data).length;
  console.log(`切回后：课表=${nameBack}，课程块 ${countBack}`);

  check("切回的是原课表 A", nameBack === nameA, `${nameBack} vs ${nameA}`);
  check("A 的课程没有丢", countBack === countA, `${countA} → ${countBack}`);

  // 4. 用底层快照复核（页面渲染可能滞后，但数据不能丢）
  const after = await page.callMethod("semesterAndCourses");
  const rawAfter = (after && after.snapshot && after.snapshot.courses) || [];
  const activeAfter = rawAfter.filter((c) => !c.deleted && c.semester_uuid === original.uuid);
  check("底层快照里该学期课程数不变（数据未丢）",
    activeAfter.length === activeBefore.length,
    `${activeBefore.length} → ${activeAfter.length}`);
  if (after && after.courses) {
    check("页面侧 normalizeCourses 也能取到课程",
      after.courses.length === activeAfter.length,
      `normalizeCourses=${after.courses.length}`);
  }

  // 收尾：删掉隔离测试课表
  if (created) {
    page = await top(mp);
    await page.callMethod("openSemesterForm");
    await sleep(1500);
    const sf3 = await page.$("#semesterForm");
    await sf3.callMethod("onSelect", { currentTarget: { dataset: { uuid: created.uuid } } });
    await sleep(700);
    await sf3.callMethod("remove");
    await sleep(3000);
    console.log("已删除隔离测试课表");
  }
  await mp.restoreWxMethod("showModal");

  check("无运行时异常", errors.length === 0, errors.slice(0, 3).join(" | ") || "无");

  const failed = results.filter((r) => !r.ok);
  console.log(`\n=== 通过 ${results.length - failed.length}/${results.length} ===`);
  try { await mp.disconnect(); } catch (e) { /* 忽略 */ }
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
