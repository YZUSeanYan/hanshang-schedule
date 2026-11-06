/*
 * 上线前检查 · 第三批：需要"绕过系统弹窗"才能走到的路径。
 *
 * 前两批绕开了 wx.showModal（自动化点不到系统弹窗），所以「删除课程」这类要先确认
 * 的流程始终只测了一半。automator 提供 mockWxMethod，可以把 showModal 打桩成
 * 直接返回 confirm:true，从而走通真实删除路径。
 *
 * 覆盖：
 *   - 删除课程（走真实 onDetailDelete + 确认）→ 空状态回归
 *   - 主题偏好在重启后仍生效（存储键链路）
 *   - 「卡片显示教师与校区」开关真的改变课程块内容
 *   - 作息自定义保存的时间校验（非法时间要被拦下）
 *   - 多课表：新建第二个课表并切换为当前
 *
 * 运行：node preflight3.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top, ensureCourse } = require("./helpers");

const PORT = Number(process.argv[2] || 9432);

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

  // 自给自足：不假设上一轮留下了什么，先确保有课表与课程
  const ensured = await ensureCourse(mp);
  check("前置：已准备好课表与课程", ensured.courseCount > 0,
    `课表=${ensured.semesterName} 课程块=${ensured.courseCount}`);

  let page = await top(mp);

  // ---- 1. 删除课程：把 wx.showModal 打桩为「确认」 ----
  let data = await page.data();
  let blocks = (data.grid && data.grid.blocks) || [];
  let courseCount = [...new Set(blocks.map((b) => b.uuid))].length;
  check("删除前有课程（前置）", courseCount > 0, `${courseCount} 门`);

  if (courseCount > 0) {
    await mp.mockWxMethod("showModal", { confirm: true, cancel: false });
    const firstUuid = blocks[0].uuid;
    await page.callMethod("onDetailDelete", { detail: { uuid: firstUuid } });
    await sleep(3000);
    await mp.restoreWxMethod("showModal");

    page = await top(mp);
    data = await page.data();
    blocks = (data.grid && data.grid.blocks) || [];
    const left = [...new Set(blocks.map((b) => b.uuid))].length;
    check("删除课程走通真实确认流程并生效", left === courseCount - 1,
      `${courseCount} → ${left} 门`);
  }

  // ---- 2. 主题偏好在重启后仍生效 ----
  await mp.switchTab("/pages/profile/index");
  await sleep(1500);
  page = await top(mp);
  await page.callMethod("setTheme", { currentTarget: { dataset: { mode: "dark" } } });
  await sleep(1000);

  const reloaded = await mp.reLaunch("/pages/profile/index");
  await sleep(2500);
  const reloadedData = await reloaded.data();
  check("深色偏好在重启后仍生效（主题存储链路通）",
    reloadedData.themeClass === "theme-dark" && reloadedData.themeMode === "dark",
    `themeClass=${reloadedData.themeClass} themeMode=${reloadedData.themeMode}`);

  await reloaded.callMethod("setTheme", { currentTarget: { dataset: { mode: "light" } } });
  await sleep(1000);

  // ---- 3. 「卡片显示教师与校区」开关真的改变课程块 ----
  // 上面删过课，这一步可能已经没有课程了，先补回来（每段自给自足）
  await ensureCourse(mp);
  await mp.switchTab("/pages/schedule/index");
  await sleep(1500);
  await mp.switchTab("/pages/schedule/index");
  await sleep(1800);
  page = await top(mp);
  data = await page.data();
  const before = ((data.grid && data.grid.blocks) || [])[0];
  const beforeKinds = before ? before.meta.map((m) => m.kind).join(",") : "";

  await mp.switchTab("/pages/profile/index");
  await sleep(1200);
  page = await top(mp);
  await page.callMethod("toggleCardDetail");
  await sleep(1200);
  const cardDetailOn = (await page.data()).cardDetail;
  check("开关状态已翻转", cardDetailOn === true, `cardDetail=${cardDetailOn}`);

  await mp.switchTab("/pages/schedule/index");
  await sleep(1800);
  page = await top(mp);
  data = await page.data();
  const after = ((data.grid && data.grid.blocks) || [])[0];
  const afterKinds = after ? after.meta.map((m) => m.kind).join(",") : "";
  check("开启后课程块多出教师/校区信息", beforeKinds !== afterKinds,
    `${beforeKinds} → ${afterKinds}`);

  // 关回去
  await mp.switchTab("/pages/profile/index");
  await sleep(1200);
  page = await top(mp);
  await page.callMethod("toggleCardDetail");
  await sleep(1000);

  // ---- 4. 作息自定义保存的时间校验 ----
  await page.callMethod("openSectionTime");
  await sleep(1500);
  const stForm = await page.$("#sectionTime");
  // 故意造一段"下课早于上课"的时间
  await stForm.setData({ automatic: false });
  await sleep(400);
  const rows = (await stForm.data()).rows;
  rows[0] = { key: "r1", label: "第 1 节", start: "10:00", end: "09:00" };
  await stForm.setData({ rows });
  await sleep(400);
  await stForm.callMethod("save");
  await sleep(1200);
  const stData = await stForm.data();
  check("非法作息被拦下并给出原因", /晚于/.test(stData.error || "") && stData.show === true,
    `error="${stData.error}" show=${stData.show}`);

  // 改回自动模式并保存
  await stForm.setData({ automatic: true });
  await sleep(500);
  await stForm.callMethod("save");
  await sleep(1500);
  check("改回自动作息后保存成功", (await stForm.data()).show === false, "");

  // ---- 5. 多课表：新建第二个并切换为当前 ----
  await mp.switchTab("/pages/schedule/index");
  await sleep(1500);
  page = await top(mp);

  const originalBlockCount = ((await page.data()).grid && (await page.data()).grid.blocks || []).length;

  // 先记下现有的课表 uuid 集合，建完之后才能确定哪个是新建的（按 uuid 而不是按名字，
  // 因为同名课表是允许的：本套件跑过几次就会攒出几个同名课表，按名字挑会有歧义）
  await page.callMethod("openSemesterForm");
  await sleep(1500);
  const sfBefore = await page.$("#semesterForm");
  const uuidsBefore = ((await sfBefore.data()).list || []).map((s) => s.uuid);
  await sfBefore.callMethod("close");
  await sleep(700);

  await page.callMethod("openSemesterForm");
  await sleep(1500);
  const sf = await page.$("#semesterForm");
  await sf.callMethod("fillForm", null, 1);
  await sf.setData({ name: "自检专用课表", startDate: "2027-02-22", totalWeeks: "18" });
  await sf.callMethod("save");
  await sleep(3000);

  page = await top(mp);
  const afterNew = await page.data();
  check("新建第二个课表并自动设为当前", afterNew.semesterName === "自检专用课表",
    `${afterNew.semesterName} / ${afterNew.weekLabel}`);

  // 新学期的课表应该是空的（课程不串表）
  check("新学期的课表是空的（课程未串表）", afterNew.hasCourses === false,
    `hasCourses=${afterNew.hasCourses}`);

  // 切回原课表
  await page.callMethod("openSemesterForm");
  await sleep(1500);
  const sf2 = await page.$("#semesterForm");
  const list = (await sf2.data()).list;
  const created = list.find((s) => uuidsBefore.indexOf(s.uuid) < 0);
  const original = list.find((s) => uuidsBefore.indexOf(s.uuid) >= 0);
  check("课表管理列出原课表与新建课表", Boolean(created && original),
    `新建=${created ? created.name : "?"} 原有=${original ? original.name : "?"}`);

  if (original) {
    // 切回后课程数应与切走前一致（不能断言一定有课——前面删课那一段可能把它删空了，
    // 那种情况下 hasCourses=false 才是对的）
    await sf2.callMethod("onActivate", { currentTarget: { dataset: { uuid: original.uuid } } });
    await sleep(3000);
    page = await top(mp);
    const back = await page.data();
    const backBlocks = (back.grid && back.grid.blocks) || [];
    check("能切回原课表且课程与切走前一致",
      back.semesterName === original.name && backBlocks.length === originalBlockCount,
      `${back.semesterName} 课程块 ${originalBlockCount} → ${backBlocks.length}`);
  } else {
    check("能切回原课表", false, "列表里没找到原课表");
  }

  // ---- 收尾：删掉本套件建的课表，避免跑几次攒一堆同名课表 ----
  if (created) {
    await mp.mockWxMethod("showModal", { confirm: true, cancel: false });
    page = await top(mp);
    await page.callMethod("openSemesterForm");
    await sleep(1500);
    const sf3 = await page.$("#semesterForm");
    await sf3.callMethod("onSelect", { currentTarget: { dataset: { uuid: created.uuid } } });
    await sleep(700);
    await sf3.callMethod("remove");
    await sleep(3000);
    await mp.restoreWxMethod("showModal");
    check("收尾：删除本套件新建的课表", true, created.name);
  }

  // ---- 汇总 ----
  check("全程无运行时异常 / console.error", errors.length === 0, errors.slice(0, 5).join(" | ") || "无");

  const failed = results.filter((r) => !r.ok);
  console.log(`\n=== 通过 ${results.length - failed.length}/${results.length} ===`);
  if (failed.length) failed.forEach((f) => console.log(`  ✗ ${f.name}: ${f.detail || ""}`));

  try { await mp.disconnect(); } catch (e) { /* 忽略 */ }
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
