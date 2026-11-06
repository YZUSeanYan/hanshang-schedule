/*
 * 调休（放假 / 补课）功能测试。
 *
 * 行为级断言：
 *   1. 把某一天设成「放假」→ 该天的课程必须消失，且表头标出「放假」
 *   2. 把某一天设成「补课（补周一的课）」→ 该天要出现原本属于周一的课程
 *   3. 删掉这两条 → 恢复原样
 *
 * 运行：node check-holiday.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top, call, addCourseAt } = require("./helpers");

const PORT = Number(process.argv[2] || 9432);
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

  // 自给自足：不指望账号里本周一有课，自己造一门
  await addCourseAt(mp, { name: "自检课程-调休", dayIndex: 0, start: 1, end: 2 });
  await mp.switchTab("/pages/schedule/index");
  await sleep(2000);
  let page = await top(mp);
  let data = await page.data();

  const info = await page.callMethod("semesterAndCourses");
  const sem = info && info.semester;
  const week = Number((/第 (\d+) 周/.exec(data.weekLabel || "第 1 周")[1])) || 1;
  const mondayDate = new Date(String(sem.start_date).slice(0, 10) + "T00:00:00");
  mondayDate.setDate(mondayDate.getDate() + (week - 1) * 7);
  const sundayDate = new Date(mondayDate);
  sundayDate.setDate(sundayDate.getDate() + 6);
  const mondayStr = fmtDate(mondayDate);
  const sundayStr = fmtDate(sundayDate);
  console.log("本周：周一 " + mondayStr + "  周日 " + sundayStr);

  // 用列的 left 值判断课程块属于哪一天
  function blocksForDay(dayIndex) {
    const grid = data.grid;
    if (!grid || !grid.blocks) return 0;
    const colW = (grid.width - grid.width * 0.135) / 7;
    const left0 = grid.width * 0.135;
    return grid.blocks.filter((b) => {
      const left = parseFloat(/left:([\d.]+)px/.exec(b.style)[1]);
      return left >= left0 + (dayIndex - 1) * colW - 1 && left < left0 + dayIndex * colW + 1;
    }).length;
  }

  const mondayBlocksBefore = blocksForDay(1);
  const sundayBlocksBefore = blocksForDay(7);
  check("前置：周一原本有课", mondayBlocksBefore > 0, "周一 " + mondayBlocksBefore + " 块");

  // ---- 1. 把周一设成放假 ----
  await mp.switchTab("/pages/profile/index");
  await sleep(1500);
  let profile = await top(mp);
  await call(mp, "openHoliday");
  await sleep(1500);
  let holiday = await profile.$("#holiday");
  await holiday.setData({ formKind: 0, formDate: mondayStr, formNote: "测试放假" });
  await holiday.callMethod("addOverride");
  await sleep(2500);
  check("添加放假安排成功",
    (await holiday.data()).list.some((r) => r.date === mondayStr), "");

  await mp.switchTab("/pages/schedule/index");
  await sleep(2500);
  page = await top(mp);
  data = await page.data();
  const mondayHead = (data.grid && data.grid.heads || [])[0];
  check("周视图表头标出「放假」", mondayHead && mondayHead.off === true,
    "周一表头 off=" + (mondayHead && mondayHead.off));
  check("放假那天不再排课", blocksForDay(1) === 0,
    "周一块数 " + mondayBlocksBefore + " → " + blocksForDay(1));
  check("其他天的课不受影响", blocksForDay(2) > 0, "周二 " + blocksForDay(2) + " 块");

  await call(mp, "switchView", { currentTarget: { dataset: { mode: "day" } } });
  await sleep(1000);
  await call(mp, "selectDay", { currentTarget: { dataset: { day: 1 } } });
  await sleep(1200);
  data = await page.data();
  const mondayDay = (data.days || [])[0];
  check("日视图显示「今天放假，不上课」",
    mondayDay && mondayDay.off === true && mondayDay.slots.length === 0,
    mondayDay ? "off=" + mondayDay.off + " slots=" + mondayDay.slots.length : "无");
  await call(mp, "switchView", { currentTarget: { dataset: { mode: "week" } } });
  await sleep(1200);

  // ---- 2. 把周日设成「补周一的课」 ----
  await mp.switchTab("/pages/profile/index");
  await sleep(1500);
  profile = await top(mp);
  await call(mp, "openHoliday");
  await sleep(1500);
  holiday = await profile.$("#holiday");
  await holiday.setData({ formKind: 1, formDate: sundayStr, formWeekday: 0, formNote: "测试补课" });
  await holiday.callMethod("addOverride");
  await sleep(2500);
  check("添加补课安排成功",
    (await holiday.data()).list.some((r) => r.date === sundayStr), "");

  await mp.switchTab("/pages/schedule/index");
  await sleep(2500);
  page = await top(mp);
  data = await page.data();
  check("补课那天出现了原本属于周一的课", blocksForDay(7) === mondayBlocksBefore,
    "周日块数 " + sundayBlocksBefore + " → " + blocksForDay(7) + "（应为周一的 " + mondayBlocksBefore + "）");
  check("补课那天表头不标放假",
    (data.grid && data.grid.heads || [])[6] && data.grid.heads[6].off === false, "");

  // ---- 3. 只删掉本用例造的两条 → 恢复原样 ----
  await mp.switchTab("/pages/profile/index");
  await sleep(1500);
  profile = await top(mp);
  await call(mp, "openHoliday");
  await sleep(1500);
  holiday = await profile.$("#holiday");
  await mp.mockWxMethod("showModal", { confirm: true, cancel: false });
  /*
   * 这里必须只删本用例自己造的那两条（按日期精确匹配）。
   * 教训：之前写成「删掉列表里的所有行」，而当时用户已用真实账号登录，
   * 于是把云端 15 条真实调休安排一起删了（写墓碑，会同步到其他设备）。
   * 破坏性操作必须限定在自己创建的数据上，也不要假设当前是游客态。
   */
  const mineDates = [mondayStr, sundayStr];
  const toDelete = (await holiday.data()).list.filter((r) => mineDates.indexOf(r.date) >= 0);
  for (const row of toDelete) {
    await holiday.callMethod("removeOverride", { currentTarget: { dataset: { uuid: row.uuid } } });
    await sleep(2500);
  }
  await mp.restoreWxMethod("showModal");
  check("本用例的两条调休安排已删除",
    !(await holiday.data()).list.some((r) => mineDates.indexOf(r.date) >= 0),
    "列表剩 " + (await holiday.data()).list.length + " 条（他人数据不应被动过）");

  await mp.switchTab("/pages/schedule/index");
  await sleep(2500);
  page = await top(mp);
  data = await page.data();
  check("删除后周一的课回来了", blocksForDay(1) === mondayBlocksBefore,
    "周一块数 → " + blocksForDay(1) + "（应为 " + mondayBlocksBefore + "）");
  check("删除后周日恢复无课", blocksForDay(7) === sundayBlocksBefore,
    "周日块数 → " + blocksForDay(7) + "（应为 " + sundayBlocksBefore + "）");

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
