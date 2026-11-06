/*
 * 清理自动化测试留下的数据，把模拟器恢复到干净状态。
 *
 * 只走应用真实的删除路径（课表管理 → 删除此课表），不往生产代码里加任何测试专用
 * 方法；唯一的取巧是把 wx.showModal 打桩成"确认"，因为自动化点不到系统弹窗。
 *
 * 运行：node cleanup.js [端口]
 */
const automator = require("miniprogram-automator");

const PORT = Number(process.argv[2] || 9432);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function top(mp) {
  return mp.currentPage();
}

(async () => {
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  await mp.switchTab("/pages/schedule/index");
  await sleep(1800);

  let page = await top(mp);
  let data = await page.data();
  console.log("清理前：", data.semesterName, "课程数 =", (data.grid && data.grid.blocks || []).length);

  await mp.mockWxMethod("showModal", { confirm: true, cancel: false });

  for (let round = 0; round < 6; round += 1) {
    page = await top(mp);
    await page.callMethod("openSemesterForm");
    await sleep(1600);

    const form = await page.$("#semesterForm");
    const formData = await form.data();
    const list = formData.list || [];
    if (!list.length) {
      console.log("课表已清空");
      break;
    }

    // 选中第一个课表再点删除（删除按钮只对当前选中的课表生效）
    await form.callMethod("onSelect", { currentTarget: { dataset: { uuid: list[0].uuid } } });
    await sleep(700);
    const selected = await form.data();
    if (!selected.showDelete) {
      console.log(`课表「${list[0].name}」是最后一个，跳过（应用不允许删到零）`);
      await form.callMethod("close");
      break;
    }
    await form.callMethod("remove");
    await sleep(3000);
    console.log(`已删除课表「${list[0].name}」`);
  }

  await mp.restoreWxMethod("showModal");
  await sleep(1500);

  // 最后一个课表删不掉（应用不允许删到零），但它里面可能还有测试课程，一并清掉
  page = await top(mp);
  data = await page.data();
  let remainingBlocks = (data.grid && data.grid.blocks) || [];
  if (remainingBlocks.length) {
    await mp.mockWxMethod("showModal", { confirm: true, cancel: false });
    const uuids = [...new Set(remainingBlocks.map((b) => b.uuid))];
    for (const uuid of uuids) {
      page = await top(mp);
      await page.callMethod("onDetailDelete", { detail: { uuid } });
      await sleep(2500);
      console.log("已删除测试课程");
    }
    await mp.restoreWxMethod("showModal");
    await sleep(1500);
  }

  page = await top(mp);
  data = await page.data();
  console.log("清理后：", data.semesterName, "hasCourses =", data.hasCourses);
  console.log(data.hasCourses === false
    ? "✓ 模拟器已恢复到干净状态（保留一个空课表，应用不允许删到零）"
    : "（仍有残留，可在课表管理里手动删除）");

  try { await mp.disconnect(); } catch (e) { /* 忽略 */ }
  process.exit(0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
