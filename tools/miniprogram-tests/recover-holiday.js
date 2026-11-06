/*
 * 紧急恢复：把被我的测试误删的调休安排找回来。
 *
 * 事故：check-holiday.js 里"删除全部"的循环没限定只删自己建的那两条，而当时用户
 * 已用真实账号登录，于是把云端 15 条真实调休安排一起删了（写墓碑，会同步到其他设备）。
 *
 * 可恢复的原因：删除只是打墓碑（deleted: true），原始行仍留在快照里。这里走**应用
 * 自己的「手动添加」路径**逐条重建——不给生产代码加任何测试专用方法。uuid 会变，
 * 但日期 / 类型 / 补课星期 / 备注都还原，功能上无损。
 *
 * 运行：node recover-holiday.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top } = require("./helpers");

const PORT = Number(process.argv[2] || 9432);

(async () => {
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  await mp.switchTab("/pages/schedule/index");
  await sleep(2000);
  let page = await top(mp);

  const info = await page.callMethod("semesterAndCourses");
  const snapshot = (info && info.snapshot) || {};
  const all = snapshot.overrides || [];
  const tombstoned = all.filter((r) => r && r.deleted);
  const alive = all.filter((r) => r && !r.deleted);

  console.log(`快照里 overrides 共 ${all.length} 条：存活 ${alive.length}，墓碑 ${tombstoned.length}`);
  if (!tombstoned.length) {
    console.log("没有可恢复的墓碑行");
    try { await mp.disconnect(); } catch (e) {}
    process.exit(0);
  }

  console.log("待恢复：");
  tombstoned.forEach((r) => console.log(`   ${r.date}  ${r.kind}  weekday=${r.weekday}  ${JSON.stringify(r.note || "")}`));

  // 走应用的「手动添加」重建
  await mp.switchTab("/pages/profile/index");
  await sleep(1500);
  page = await top(mp);
  await page.callMethod("openHoliday");
  await sleep(1800);
  let holiday = await page.$("#holiday");

  for (const row of tombstoned) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(row.date || "")) {
      console.log("  跳过日期非法的行:", JSON.stringify(row.date));
      continue;
    }
    await holiday.setData({
      formKind: row.kind === "makeup" ? 1 : 0,
      formDate: row.date,
      formWeekday: Math.max(0, Math.min(6, (Number(row.weekday) || 1) - 1)),
      formNote: row.note || "",
    });
    await holiday.callMethod("addOverride");
    await sleep(1600);
    console.log(`  已重建 ${row.date} ${row.kind}`);
  }

  holiday = await page.$("#holiday");
  const after = await holiday.data();
  console.log(`\n恢复后：现存 ${after.list.length} 条`);
  after.list.forEach((r) => console.log("   ", r.date, r.label));

  try { await mp.disconnect(); } catch (e) {}
  process.exit(0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
