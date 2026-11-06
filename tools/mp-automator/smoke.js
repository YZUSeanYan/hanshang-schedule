/*
 * 小程序端到端冒烟测试。
 *
 * 需要外部常驻的自动化服务（node tools/wxcli.js auto --project <项目> --auto-port 9423），
 * 本脚本只连接、不负责起停——反复 kill cli auto 会让 IDE 的自动化会话残留，
 * 后续连接就会 timeout。
 *
 * 运行：node tools/automator/smoke.js [端口，默认 9423]
 */
const path = require("path");
const fs = require("fs");
const automator = require("miniprogram-automator");

const PORT = Number(process.argv[2] || 9423);
const SHOTS = path.join(__dirname, "shots");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const steps = [];
const problems = [];

function record(name, ok, detail) {
  steps.push({ name, ok, detail });
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) problems.push(`${name}: ${detail || ""}`);
}

async function shot(mp, name) {
  try {
    await mp.screenshot({ path: path.join(SHOTS, `${name}.png`) });
  } catch (error) {
    console.log(`  （截图 ${name} 失败：${error.message}）`);
  }
}

// 导航在自动化环境里偶发超时，包一层容错：失败不影响已经拿到的结论
async function tryNavigate(label, fn) {
  try {
    const page = await fn();
    await sleep(1200);
    return page;
  } catch (error) {
    record(`导航到${label}`, false, error.message);
    return null;
  }
}

(async () => {
  fs.mkdirSync(SHOTS, { recursive: true });
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  console.log(`已连接自动化端口 ${PORT}\n`);

  const runtimeErrors = [];
  mp.on("exception", (e) => runtimeErrors.push("异常: " + (e.message || JSON.stringify(e))));
  mp.on("console", (m) => {
    if (m.type === "error") runtimeErrors.push(`console.error: ${(m.args || []).join(" ")}`);
  });

  const page = await mp.currentPage();
  record("当前页是课表页", page.path === "pages/schedule/index", page.path);

  try {
    // ---- 1. 首屏与自绘顶栏 ----
    await sleep(1500);
    let data = await page.data();
    record("游客模式默认可用（不强制登录）", data.guest === true, `guest=${data.guest}`);
    record("自绘顶栏量到状态栏/导航栏高度",
      data.statusBarHeight > 0 && data.navBarHeight > 0,
      `statusBar=${data.statusBarHeight} nav=${data.navBarHeight}`);
    record("底栏留白已按安全区计算", data.tabBarHeight >= 56, `tabBarHeight=${data.tabBarHeight}`);
    record("空课表显示空状态", data.hasCourses === false, `hasCourses=${data.hasCourses}`);
    await shot(mp, "01-空状态");

    // ---- 2. 用户路径：空状态按钮 → 建课表 ----
    await page.callMethod("addCourse");
    await sleep(900);
    const semesterForm = await page.$("#semesterForm");
    record("点「手动添加课程」先引导建课表", Boolean(semesterForm), semesterForm ? "课表管理已打开" : "未打开");
    await shot(mp, "02-课表管理");

    await semesterForm.callMethod("fillForm", null, 1);
    await semesterForm.setData({ name: "2026 秋季学期", startDate: "2026-08-31", totalWeeks: "20" });
    await semesterForm.callMethod("save");
    await sleep(1800);

    data = await page.data();
    record("保存课表后学期信息生效", data.semesterName === "2026 秋季学期",
      `${data.semesterName} / ${data.weekLabel} / ${data.weekRange}`);

    // ---- 3. 再加一次：这次应直接开课程表单 ----
    await page.callMethod("addCourse");
    await sleep(900);
    const courseForm = await page.$("#courseForm");
    record("有学期后直接开课程表单", Boolean(courseForm), courseForm ? "已打开" : "未打开");

    await courseForm.setData({
      name: "高等数学",
      teacher: "张老师",
      slots: [{
        uuid: "", dayIndex: 0, weeksIndex: 0,
        startSection: "1", endSection: "2", customWeeks: "",
        location: "扬子津东校区>>文津楼>>N204",
      }],
    });
    await shot(mp, "03-课程表单");
    await courseForm.callMethod("save");
    await sleep(2000);

    // ---- 4. 校验周视图数据 ----
    data = await page.data();
    record("加课后进入有课状态", data.hasCourses === true, `hasCourses=${data.hasCourses}`);

    const grid = data.grid;
    record("周网格按实测尺寸绘制", Boolean(grid) && grid.width > 0 && grid.height > 0,
      grid ? `${Math.round(grid.width)}×${Math.round(grid.height)}` : "无网格");

    const cells = (grid && grid.cells) || [];
    const sections = (grid && grid.sections) || [];
    const heads = (grid && grid.heads) || [];
    record("网格为 12 节 × 7 天", cells.length === 84 && sections.length === 12,
      `cells=${cells.length} sections=${sections.length}`);
    record("表头 7 天", heads.length === 7, heads.map((h) => h.name + (h.today ? "*" : "")).join(" "));

    const blocks = (grid && grid.blocks) || [];
    record("渲染出 1 个课程块", blocks.length === 1, `blocks=${blocks.length}`);
    if (blocks.length) {
      const b = blocks[0];
      record("课程块有定位与课程配色", /left:\d/.test(b.style) && /background:rgba/.test(b.style), b.style.slice(0, 88));
      record("信息层级：教室 N204 已显示", JSON.stringify(b.meta).includes("N204"), JSON.stringify(b.meta));
      record("楼名/教师默认收起（只留教室一行）",
        b.meta.length === 1 && b.meta[0].kind === "room",
        b.meta.map((m) => m.kind).join(","));
      record("标题带字号与行数限制", /font-size:[\d.]+px/.test(b.titleStyle) && /line-clamp/.test(b.titleStyle), b.titleStyle);
    }
    await shot(mp, "04-周视图");

    // ---- 5. 日视图 ----
    await page.callMethod("switchView", { currentTarget: { dataset: { mode: "day" } } });
    await sleep(1000);
    data = await page.data();
    record("切到日视图", data.viewMode === "day", `viewMode=${data.viewMode}`);
    record("日视图 7 天", (data.days || []).length === 7, `days=${(data.days || []).length}`);
    const monday = (data.days || [])[0];
    record("周一有课且带起止时刻", Boolean(monday && monday.slots.length === 1),
      monday && monday.slots.length ? `${monday.slots[0].startTime}-${monday.slots[0].endTime}` : "无");
    if (monday && monday.slots.length) {
      record("日视图详情含节次与教室",
        /第 1-2 节/.test(monday.slots[0].detail) && monday.slots[0].room === "N204",
        `${monday.slots[0].detail} | room=${monday.slots[0].room}`);
    }
    await shot(mp, "05-日视图");

    // ---- 6. 翻周 ----
    await page.callMethod("switchView", { currentTarget: { dataset: { mode: "week" } } });
    await sleep(900);
    await page.callMethod("goWeek", 1);
    await sleep(900);
    data = await page.data();
    record("翻到下一周", data.weekLabel === "第 2 周", data.weekLabel);
    await page.callMethod("goWeek", -1);
    await sleep(700);

    // ---- 7. 课程详情弹层 ----
    await page.callMethod("openCourseDetail", { currentTarget: { dataset: { uuid: blocks[0] ? blocks[0].uuid : "" } } });
    await sleep(1000);
    const detail = await page.$("#courseDetail");
    record("课程详情弹层打开", Boolean(detail), detail ? "已打开" : "未打开");
    await shot(mp, "06-课程详情");

    // ---- 8. 深色模式 ----
    const profile = await tryNavigate("我的页", () => mp.switchTab("/pages/profile/index"));
    if (profile) {
      const pd = await profile.data();
      record("「我的」页加载", pd.themeClass !== undefined, `guest=${pd.guest} userName=${pd.userName}`);
      await profile.callMethod("setTheme", { currentTarget: { dataset: { mode: "dark" } } });
      await sleep(900);
      record("切到深色模式", (await profile.data()).themeClass === "theme-dark", "");
      await shot(mp, "07-我的-深色");

      const ds = await tryNavigate("深色课表页", () => mp.switchTab("/pages/schedule/index"));
      if (ds) {
        await sleep(1500);
        const ddata = await ds.data();
        record("课表页跟随深色", ddata.themeClass === "theme-dark", `themeClass=${ddata.themeClass}`);
        const db = ddata.grid && ddata.grid.blocks && ddata.grid.blocks[0];
        record("深色下课程块仍渲染", Boolean(db), db ? db.style.slice(0, 60) : "无");
        await shot(mp, "08-周视图-深色");
      }
      await profile.callMethod("setTheme", { currentTarget: { dataset: { mode: "light" } } });
    }

    // ---- 9. 导入页与登录页 ----
    const importPage = await tryNavigate("导入页", () => mp.switchTab("/pages/import/index"));
    if (importPage) {
      record("导入页加载", (await importPage.data()).themeClass !== undefined, "");
      await shot(mp, "09-导入页");
    }
    const loginPage = await tryNavigate("登录页", () => mp.navigateTo("/pages/login/index"));
    if (loginPage) {
      record("登录页可达", (await loginPage.data()).mode === "login", "");
      await shot(mp, "10-登录页");
    }
  } catch (error) {
    record("测试流程", false, error.message);
  }

  record("无运行时异常 / console.error", runtimeErrors.length === 0,
    runtimeErrors.slice(0, 6).join(" | ") || "无");

  console.log("\n=== 汇总 ===");
  console.log(`通过 ${steps.filter((s) => s.ok).length}/${steps.length}`);
  console.log(`截图：${SHOTS}`);
  if (problems.length) {
    console.log("\n失败项：");
    problems.forEach((p) => console.log("  ✗ " + p));
  }

  try { await mp.disconnect(); } catch (e) { /* 忽略 */ }
  process.exit(problems.length ? 1 : 0);
})().catch((error) => {
  console.log("测试中断:", error.message);
  process.exit(1);
});
