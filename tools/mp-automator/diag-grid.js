/*
 * 诊断：切回有课的课表后，周视图为什么是空的。
 * 把中间状态全打出来：hasCourses / grid 是否为 null / .week-host 是否在树里 /
 * 以及页面数据的其他线索。
 *
 * 运行：node diag-grid.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top, ensureCourse } = require("./helpers");

const PORT = Number(process.argv[2] || 9432);

function snapshot(data) {
  return {
    semesterName: data.semesterName,
    hasCourses: data.hasCourses,
    viewMode: data.viewMode,
    gridIsNull: data.grid === null,
    gridBlocks: data.grid ? (data.grid.blocks || []).length : "grid 为 null",
    gridWidth: data.grid ? Math.round(data.grid.width) : "-",
  };
}

(async () => {
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  await mp.mockWxMethod("showModal", { confirm: true, cancel: false });

  await mp.switchTab("/pages/schedule/index");
  await sleep(2000);

  // 先造一个「有课 + 空课表」的状态
  await ensureCourse(mp);
  await mp.switchTab("/pages/schedule/index");
  await sleep(2000);
  let page = await top(mp);
  console.log("① 初始（有课）:", JSON.stringify(snapshot(await page.data())));
  console.log("   .week-host 存在:", Boolean(await page.$(".week-host")));

  // 新建空课表
  await page.callMethod("openSemesterForm");
  await sleep(1500);
  const sf = await page.$("#semesterForm");
  const uuidsBefore = ((await sf.data()).list || []).map((s) => s.uuid);
  await sf.callMethod("fillForm", null, 1);
  await sf.setData({ name: "诊断用课表", startDate: "2027-02-22", totalWeeks: "18" });
  await sf.callMethod("save");
  await sleep(3500);

  page = await top(mp);
  console.log("② 新建空课表后:", JSON.stringify(snapshot(await page.data())));
  console.log("   .week-host 存在:", Boolean(await page.$(".week-host")));

  // 切回有课的课表
  await page.callMethod("openSemesterForm");
  await sleep(1500);
  const sf2 = await page.$("#semesterForm");
  const list = (await sf2.data()).list;
  const created = list.find((s) => uuidsBefore.indexOf(s.uuid) < 0);
  const original = list.find((s) => uuidsBefore.indexOf(s.uuid) >= 0);
  await sf2.callMethod("onActivate", { currentTarget: { dataset: { uuid: original.uuid } } });

  for (const wait of [800, 1500, 3000, 5000]) {
    await sleep(wait === 800 ? 800 : wait - 800);
    page = await top(mp);
    const data = await page.data();
    console.log(`③ 切回后 +${wait}ms:`, JSON.stringify(snapshot(data)));
    console.log("   .week-host 存在:", Boolean(await page.$(".week-host")),
      " .week-grid 存在:", Boolean(await page.$(".week-grid")));
  }

  // 试着手动触发一次重测（切到日视图再切回来）
  page = await top(mp);
  await page.callMethod("switchView", { currentTarget: { dataset: { mode: "day" } } });
  await sleep(1200);
  await page.callMethod("switchView", { currentTarget: { dataset: { mode: "week" } } });
  await sleep(2000);
  console.log("④ 手动切 日→周 之后:", JSON.stringify(snapshot(await page.data())));

  // 收尾
  if (created) {
    page = await top(mp);
    await page.callMethod("openSemesterForm");
    await sleep(1500);
    const sf3 = await page.$("#semesterForm");
    await sf3.callMethod("onSelect", { currentTarget: { dataset: { uuid: created.uuid } } });
    await sleep(700);
    await sf3.callMethod("remove");
    await sleep(3000);
  }
  await mp.restoreWxMethod("showModal");

  try { await mp.disconnect(); } catch (e) { /* 忽略 */ }
  process.exit(0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
