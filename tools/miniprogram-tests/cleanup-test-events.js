/*
 * 只删掉标题含「自检日程」的测试日程，不碰任何其他数据。
 * 保险：匹配数超过 5 就中止。
 *
 * 运行：node cleanup-test-events.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top } = require("./helpers");

const PORT = Number(process.argv[2] || 9432);

(async () => {
  const mp = await automator.connect({ wsEndpoint: "ws://127.0.0.1:" + PORT });
  await mp.switchTab("/pages/schedule/index");
  await sleep(2500);
  let page = await top(mp);
  let data = await page.data();

  const mine = ((data.grid && data.grid.blocks) || []).filter((b) =>
    (b.title || "").indexOf("自检日程") >= 0 ||
    (b.items || []).some((i) => (i.title || "").indexOf("自检日程") >= 0));
  console.log("找到测试日程相关块:", mine.length);

  if (mine.length === 0 || mine.length > 5) {
    console.log("数量异常或无需清理，已中止（不做任何删除）");
    try { await mp.disconnect(); } catch (e) {}
    process.exit(0);
  }

  await mp.mockWxMethod("showModal", { confirm: true, cancel: false });
  for (const block of mine) {
    // 合并块里的项目也要展开取 uuid
    const targets = block.merged
      ? block.items.filter((i) => (i.title || "").indexOf("自检日程") >= 0)
      : [block];
    for (const t of targets) {
      if (!t.uuid) continue;
      await mp.switchTab("/pages/schedule/index");
      await sleep(1200);
      page = await top(mp);
      await page.callMethod("openBlockDetail", { currentTarget: { dataset: { uuid: t.uuid, kind: "event" } } });
      await sleep(1800);
      await page.callMethod("deleteEvent");
      await sleep(2500);
      console.log("  已删除:", t.title);
    }
  }
  await mp.restoreWxMethod("showModal");

  await mp.switchTab("/pages/schedule/index");
  await sleep(2500);
  page = await top(mp);
  data = await page.data();
  const left = ((data.grid && data.grid.blocks) || []).filter((b) =>
    (b.title || "").indexOf("自检日程") >= 0 ||
    (b.items || []).some((i) => (i.title || "").indexOf("自检日程") >= 0));
  console.log("清理后剩余:", left.length);

  try { await mp.disconnect(); } catch (e) {}
  process.exit(0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
