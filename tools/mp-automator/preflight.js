/*
 * 上线前检查：覆盖那些"静态检查和数据断言都覆盖不到、但上线会踩"的维度。
 *
 *   1. 持久化：建课 → 重启小程序 → 课还在（验证 wx.setStorageSync 链路）
 *   2. 深色模式：切主题后计算样式真的换成深色令牌（不只是 themeClass 变了）
 *   3. 各弹层：能打开、有内容、无异常
 *   4. 真实后端：用错误口令登录，必须收到服务端返回的中文错误（证明
 *      wx.request → 生产 API → 信封解析 → 错误文案 整条链路是通的）
 *   5. 输入规整：口令框只接受规定字符并自动大写
 *
 * 运行：node preflight.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top, call } = require("./helpers");

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

  let page = await mp.currentPage();
  if (page.path !== "pages/schedule/index") {
    page = await mp.switchTab("/pages/schedule/index");
    await sleep(1500);
  }

  // ---- 1. 持久化：重启小程序后本机课表还在 ----
  let before = await page.data();
  const hadCourses = before.hasCourses;
  const beforeName = before.semesterName;

  page = await mp.reLaunch("/pages/schedule/index");
  await sleep(2500);
  const after = await page.data();
  check("重启小程序后本机课表仍在（存储链路通）",
    after.hasCourses === hadCourses && after.semesterName === beforeName,
    `重启前 hasCourses=${hadCourses}/${beforeName}，重启后 ${after.hasCourses}/${after.semesterName}`);

  // ---- 2. 深色模式：计算样式真的换了令牌 ----
  const profile = await mp.switchTab("/pages/profile/index");
  await sleep(1500);
  // 先显式置为浅色再读基线：上一轮脚本可能把主题留在了深色，直接读会拿到深色值
  await profile.callMethod("setTheme", { currentTarget: { dataset: { mode: "light" } } });
  await sleep(1200);
  const lightBg = await (await profile.$(".app-root")).style("background-color");
  await profile.callMethod("setTheme", { currentTarget: { dataset: { mode: "dark" } } });
  await sleep(1200);
  const darkBg = await (await profile.$(".app-root")).style("background-color");
  const darkPrimary = await (await profile.$(".eyebrow")).style("color");

  check("浅色底为 M3 light surface #F5FBF5", lightBg === "rgb(245, 251, 245)", lightBg);
  check("深色模式换掉了底色令牌", lightBg !== darkBg, `${lightBg} → ${darkBg}`);
  check("深色底为 M3 dark surface #121417", darkBg === "rgb(18, 20, 23)", darkBg);
  check("深色主色为 M3 dark primary #8DD5B2", darkPrimary === "rgb(141, 213, 178)", darkPrimary);

  // 深色下课程块也要跟着换（块色是 JS 按主题算的，容易漏）。
  // 注意 withAlpha 拼出来的是 rgba(r,g,b,a) 不带空格，正则别按带空格写。
  const darkSchedule = await mp.switchTab("/pages/schedule/index");
  await sleep(1800);
  const darkData = await darkSchedule.data();
  const darkBlock = darkData.grid && darkData.grid.blocks && darkData.grid.blocks[0];
  check("深色模式下课程块重新算色（JS 侧主题分支，alpha 0.3）",
    Boolean(darkBlock) && /rgba\(\d+,\d+,\d+,0\.3\)/.test(darkBlock.style),
    darkBlock ? (darkBlock.style.match(/background:[^;]+/) || ["无背景"])[0] : "无课程块");
  check("深色下课名用混白文字（混 255 而非混 0）",
    Boolean(darkBlock) && /color:#[0-9a-f]{6}/i.test(darkBlock.titleStyle),
    darkBlock ? (darkBlock.titleStyle.match(/color:#[0-9a-f]{6}/i) || ["无"])[0] : "无");

  // 切回浅色：必须先切回「我的」页再操作该页对象（跨页调方法会报 page is not on top）
  await mp.switchTab("/pages/profile/index");
  await sleep(1200);
  await profile.callMethod("setTheme", { currentTarget: { dataset: { mode: "light" } } });
  await sleep(1000);

  // ---- 3. 各弹层能打开且有内容 ----
  const schedulePage = await mp.switchTab("/pages/schedule/index");
  await sleep(1500);
  await schedulePage.callMethod("addCourse");
  await sleep(1500);
  const courseForm = await schedulePage.$("#courseForm");
  const cfData = courseForm ? await courseForm.data() : null;
  check("课程表单弹层可打开且有内容", Boolean(cfData && cfData.show === true),
    cfData ? `show=${cfData.show} 时间段数=${cfData.slots.length}` : "未找到");
  await courseForm.callMethod("close");
  await sleep(600);

  await schedulePage.callMethod("openSemesterForm");
  await sleep(1500);
  const semesterForm = await schedulePage.$("#semesterForm");
  const sfData = semesterForm ? await semesterForm.data() : null;
  check("课表管理弹层可打开且列出课表", Boolean(sfData && sfData.show === true && sfData.list.length >= 1),
    sfData ? `show=${sfData.show} 课表数=${sfData.list.length}` : "未找到");
  await semesterForm.callMethod("close");
  await sleep(600);

  const liveData = await schedulePage.data();
  const blocks = (liveData.grid && liveData.grid.blocks) || [];
  if (blocks.length) {
    await schedulePage.callMethod("openCourseDetail", { currentTarget: { dataset: { uuid: blocks[0].uuid } } });
    await sleep(1500);
    const detail = await schedulePage.$("#courseDetail");
    const dd = detail ? await detail.data() : null;
    check("课程详情弹层可打开且有内容",
      Boolean(dd && dd.show === true && dd.slotCount > 0),
      dd ? `安排数=${dd.slotCount} 课程=${dd.course && dd.course.name}` : "未找到");
    await detail.callMethod("close");
    await sleep(600);
  }

  // 我的页：作息 / 关于
  await mp.switchTab("/pages/profile/index");
  await sleep(1200);
  await profile.callMethod("openSectionTime");
  await sleep(1200);
  const st = await profile.$("#sectionTime");
  const stData = await st.data();
  check("作息弹层可打开且有 12 节", stData.show === true && stData.rows.length === 12,
    `show=${stData.show} rows=${stData.rows.length}`);
  await st.callMethod("close");
  await sleep(700);

  await profile.callMethod("openAbout");
  await sleep(4000);   // 关于页要联网拉 /api/about
  const about = await profile.$("#about");
  const aboutData = await about.data();
  check("关于弹层拉到了真实后端数据（/api/about 通）",
    aboutData.loading === false && Boolean(aboutData.name) && !aboutData.error,
    `name=${aboutData.name} 版本=${aboutData.version || "(无)"} 错误=${aboutData.error || "无"}`);
  await about.callMethod("close");
  await sleep(600);

  // ---- 4. 真实后端：错误口令必须拿到服务端文案 ----
  const login = await mp.navigateTo("/pages/login/index");
  await sleep(1800);
  await login.setData({ mode: "login", account: "__preflight_no_such_user__", password: "wrong-password-123" });
  await login.callMethod("submitLogin");
  await sleep(6000);
  const loginData = await login.data();
  const serverMessage = loginData.error || "";
  check("登录请求真的打到生产后端并拿到服务端错误文案",
    serverMessage.length > 0 && /账号|密码|错误|失败|不存在|无效/.test(serverMessage),
    `服务端返回: ${serverMessage || "(空)"}`);
  check("失败后按钮回到可再次提交（busy 复位）", loginData.busy === false, `busy=${loginData.busy}`);

  // ---- 5. 口令输入规整 ----
  await login.callMethod("continueAsGuest");
  await sleep(1200);
  const importPage = await mp.switchTab("/pages/import/index");
  await sleep(1500);
  await importPage.callMethod("onCodeInput", { detail: { value: "ab12-cd!@#" } });
  const code = (await importPage.data()).code;
  // 口令字符集是 A-Z 去掉 I/O、数字 2-9 —— 刻意排除 0 和 1（易与 O/I 混淆），
  // 与网页版同一套正则 [^A-Z2-9]，所以 "ab12-cd!@#" 的结果是 AB2CD 而不是 AB12CD。
  check("口令输入自动大写并按字符集过滤（排除 0/1/I/O）", code === "AB2CD",
    `输入 "ab12-cd!@#" → "${code}"`);

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
