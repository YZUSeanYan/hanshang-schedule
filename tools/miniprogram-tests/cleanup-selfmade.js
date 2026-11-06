/*
 * 删掉所有标题带「自检」的数据（本次测试造的课程与日程），不碰任何其他数据。
 * 保险：匹配数超过 10 就中止。
 * 运行：node cleanup-selfmade.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top } = require("./helpers");

const PORT = Number(process.argv[2] || 9432);

(async () => {
  const mp = await automator.connect({ wsEndpoint: "ws://127.0.0.1:" + PORT });
  await mp.mockWxMethod("showModal", { confirm: true, cancel: false });

  for (let round = 0; round < 8; round += 1) {
    await mp.switchTab("/pages/schedule/index");
    await sleep(2500);
    const page = await top(mp);
    const data = await page.data();
    const blocks = (data.grid && data.grid.blocks) || [];

    // 两处都要找：普通块自身，以及合并块里的小方块
    const mine = [];
    blocks.forEach((b) => {
      if ((b.title || "").indexOf("自检") >= 0) mine.push({ uuid: b.uuid, kind: b.kind, title: b.title });
      (b.items || []).forEach((i) => {
        if ((i.title || "").indexOf("自检") >= 0) mine.push({ uuid: i.uuid, kind: i.kind, title: i.title });
      });
    });

    if (mine.length === 0) { console.log("已清理干净（第 " + round + " 轮后无残留）"); break; }
    if (mine.length > 10) { console.log("匹配数异常，已中止"); break; }

    const t = mine[0];
    console.log("  删除:", t.kind, t.title);
    if (t.kind === "event") {
      await page.callMethod("openBlockDetail", { currentTarget: { dataset: { uuid: t.uuid, kind: "event" } } });
      await sleep(1800);
      await page.callMethod("deleteEvent");
    } else {
      await page.callMethod("onDetailDelete", { detail: { uuid: t.uuid } });
    }
    await sleep(2800);
  }
  await mp.restoreWxMethod("showModal");
  try { await mp.disconnect(); } catch (e) {}
  process.exit(0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
