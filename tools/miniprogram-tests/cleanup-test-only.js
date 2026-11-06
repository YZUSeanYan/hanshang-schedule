/*
 * 只删掉「label 含测试」的调休安排，不碰任何其他数据。
 * 注意用 label 而不是日期匹配：按日期匹配会在周次变化后漏掉上一轮的测试数据
 * （曾经因此漏了一条 2026-09-06 的「测试补课」）。
 * 保险：匹配数超过 3 就中止。
 * 运行：node cleanup-test-only.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top, call } = require("./helpers");

const PORT = Number(process.argv[2] || 9432);

(async () => {
  const mp = await automator.connect({ wsEndpoint: "ws://127.0.0.1:" + PORT });
  await mp.mockWxMethod("showModal", { confirm: true, cancel: false });
  await mp.switchTab("/pages/profile/index");
  await sleep(1800);
  await call(mp, "openHoliday");
  await sleep(2000);
  const page = await top(mp);
  const holiday = await page.$("#holiday");

  for (let round = 0; round < 5; round += 1) {
    const list = (await holiday.data()).list || [];
    const mine = list.filter((r) => /测试/.test(String(r.label || "")));
    if (mine.length === 0) { console.log("已清理干净"); break; }
    if (mine.length > 3) { console.log("匹配数异常，已中止"); break; }
    console.log("  删除:", mine[0].date, mine[0].label);
    await holiday.callMethod("removeOverride", { currentTarget: { dataset: { uuid: mine[0].uuid } } });
    await sleep(2200);
  }

  const after = await (await top(mp)).$("#holiday");
  const d = await after.data();
  console.log("清理后剩", d.list.length, "条");
  d.list.forEach((r) => console.log("   ", r.date, "|", r.label));

  await mp.restoreWxMethod("showModal");
  try { await mp.disconnect(); } catch (e) {}
  process.exit(0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
