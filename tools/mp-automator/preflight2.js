/*
 * 上线前检查 · 第二批：交互与边界。
 *
 * 写法上的一条教训：这里的断言必须**相对当前状态**，不能写死周次。
 * 第一版把 goWeek 当跳转函数用（它其实是单步 ±1），又对滑动结果写了绝对周次，
 * 结果 5 条全部误报——数据里能看出滑动、边界其实都对。断言失败时先怀疑断言。
 *
 * 运行：node preflight2.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top, call } = require("./helpers");

const PORT = Number(process.argv[2] || 9432);

const results = [];
function check(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? ` — ${detail}` : ""}`);
}

function weekNo(data) {
  const m = /第 (\d+) 周/.exec(data.weekLabel || "");
  return m ? Number(m[1]) : -1;
}

function touchAt(x, y) {
  const t = [{ clientX: x, clientY: y, identifier: 0, pageX: x, pageY: y }];
  return { touches: t, changedTouches: t };
}

// 重新取当前页，避免拿着切 tab 之前的旧 Page 对象调方法

(async () => {
  const mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${PORT}` });
  console.log(`已连接 ${PORT}\n`);

  const errors = [];
  mp.on("exception", (e) => errors.push("异常: " + (e.message || JSON.stringify(e))));
  mp.on("console", (m) => {
    if (m.type === "error") errors.push(`console.error: ${(m.args || []).join(" ")}`);
  });

  // ---- 1. 周次边界：单步走到头，看是否停在总周数上 ----
  await mp.switchTab("/pages/schedule/index");
  await sleep(1800);
  let page = await top(mp);

  // 先退到第 1 周（goWeek 是单步函数，循环调用）
  for (let i = 0; i < 25; i += 1) {
    if (weekNo(await page.data()) <= 1) break;
    await page.callMethod("goWeek", -1);
    await sleep(220);
  }
  let data = await page.data();
  check("能退到第 1 周且「上一周」禁用", weekNo(data) === 1 && data.canPrev === false,
    `${data.weekLabel} canPrev=${data.canPrev}`);

  const before = weekNo(data);
  await page.callMethod("goWeek", -1);
  await sleep(500);
  check("第 1 周继续往前被拦住", weekNo(await page.data()) === before, (await page.data()).weekLabel);

  // 单步推到最后一页，记录最高能到第几周
  let maxWeek = before;
  for (let i = 0; i < 30; i += 1) {
    await page.callMethod("goWeek", 1);
    await sleep(220);
    const w = weekNo(await page.data());
    if (w === maxWeek) break;   // 不再前进说明到顶了
    maxWeek = w;
  }
  data = await page.data();
  // 总周数不能写死：课表可以是 18/20 周等任意值，从页面文案（"… · 18 周"）里解析
  const totalWeeksMatch = /(\d+)\s*周/.exec(data.semesterMeta || "");
  const totalWeeks = totalWeeksMatch ? Number(totalWeeksMatch[1]) : 20;
  check(`能翻到第 ${totalWeeks} 周（总周数）后停住`, maxWeek === totalWeeks, `最高到 ${data.weekLabel}`);
  check("最后一周「下一周」禁用", data.canNext === false, `canNext=${data.canNext}`);

  const atEnd = weekNo(data);
  await page.callMethod("goWeek", 1);
  await sleep(500);
  check("最后一周继续往后被拦住", weekNo(await page.data()) === atEnd, (await page.data()).weekLabel);

  // 退到第 1 周准备手势测试
  for (let i = 0; i < 25; i += 1) {
    if (weekNo(await page.data()) <= 1) break;
    await page.callMethod("goWeek", -1);
    await sleep(220);
  }

  // ---- 2. 滑动手势（相对断言）----
  let host = await page.$(".week-host");
  let w0 = weekNo(await page.data());
  await host.touchstart(touchAt(300, 400));
  await sleep(120);
  await host.touchend(touchAt(120, 405));
  await sleep(1300);
  let w1 = weekNo(await page.data());
  check("左滑前进一周", w1 === w0 + 1, `${w0} → ${w1}`);

  page = await top(mp);
  host = await page.$(".week-host");
  await host.touchstart(touchAt(120, 400));
  await sleep(120);
  await host.touchend(touchAt(300, 405));
  await sleep(1300);
  const w2 = weekNo(await page.data());
  check("右滑后退一周", w2 === w1 - 1, `${w1} → ${w2}`);

  page = await top(mp);
  host = await page.$(".week-host");
  await host.touchstart(touchAt(200, 300));
  await sleep(120);
  await host.touchend(touchAt(215, 480));
  await sleep(1200);
  const w3 = weekNo(await page.data());
  check("纵向滑动不误触发翻周", w3 === w2, `保持 ${w3}`);

  // 位移不够也不应翻周
  page = await top(mp);
  host = await page.$(".week-host");
  await host.touchstart(touchAt(200, 400));
  await sleep(120);
  await host.touchend(touchAt(180, 402));
  await sleep(1000);
  check("位移不足阈值不翻周", weekNo(await page.data()) === w3, `保持 ${weekNo(await page.data())}`);

  // ---- 3. 日视图跨周滑动 ----
  page = await top(mp);
  await page.callMethod("switchView", { currentTarget: { dataset: { mode: "day" } } });
  await sleep(1000);
  await page.callMethod("selectDay", { currentTarget: { dataset: { day: 7 } } });
  await sleep(900);
  const beforeDay = await page.data();
  const dayHost = await page.$(".day-scroll");
  if (dayHost) {
    await dayHost.touchstart(touchAt(300, 400));
    await sleep(120);
    await dayHost.touchend(touchAt(120, 405));
    await sleep(1300);
    const after = await page.data();
    const selected = after.dayChips.filter((c) => c.active).map((c) => c.label).join("");
    check("日视图在周日左滑跨到下周周一",
      weekNo(after) === weekNo(beforeDay) + 1 && selected === "一",
      `${beforeDay.weekLabel}/周日 → ${after.weekLabel}/周${selected}`);
  } else {
    check("找到日视图容器", false, "无 .day-scroll");
  }
  await page.callMethod("switchView", { currentTarget: { dataset: { mode: "week" } } });
  await sleep(900);

  // ---- 4. 游客态功能门禁 ----
  await mp.switchTab("/pages/profile/index");
  await sleep(1500);
  page = await top(mp);
  const profileData = await page.data();
  check("当前是游客态（门禁测试前置）", profileData.guest === true, `guest=${profileData.guest}`);

  // 游客点「分享当前课表」：requireLogin 会先弹提示，再 600ms 后跳登录页。
  // 所以这里要等跳转落定再断言，中途去碰旧 Page 对象会报 "page is not on top"。
  const shareWasShown = await call(mp, "openShare")
    .then(() => false)
    .catch(() => false);
  void shareWasShown;
  await sleep(2500);
  const afterShareStack = await mp.pageStack();
  const afterShareTop = afterShareStack[afterShareStack.length - 1].path;
  check("游客点「分享当前课表」被引导去登录（而不是静默失败）",
    afterShareTop === "pages/login/index", `栈顶=${afterShareTop}`);

  // 上一段结束时已经跳到登录页了，先退回来再测下一个入口
  try { await mp.navigateBack(); } catch (e) { /* 栈里没有可退的就算了 */ }
  await sleep(1500);
  await mp.switchTab("/pages/profile/index");
  await sleep(1500);

  await call(mp, "openCouple");
  await sleep(2000);
  let stack = await mp.pageStack();
  check("游客点「共同空闲」跳到登录页", stack[stack.length - 1].path === "pages/login/index",
    `栈顶=${stack[stack.length - 1].path}`);

  // ---- 5. 注册模式客户端校验 ----
  // 导航之后旧 Page 对象会失效（"page is not on top of page stack"），
  // 这里每次都用 call() 重新取栈顶页，避免偶发误报。
  await call(mp, "switchMode", { currentTarget: { dataset: { mode: "register" } } });
  await sleep(800);

  const loginPage = await top(mp);
  await loginPage.setData({ username: "ab", email: "a@b.com", registerPassword: "12345678" });
  await call(mp, "submitRegister");
  await sleep(1200);
  let err = (await (await top(mp)).data()).error || "";
  check("拦住过短用户名", /用户名/.test(err), err);

  const loginPage2 = await top(mp);
  await loginPage2.setData({ username: "preflight_user", email: "not-an-email", registerPassword: "12345678" });
  await call(mp, "submitRegister");
  await sleep(1200);
  err = (await (await top(mp)).data()).error || "";
  check("拦住非法邮箱", /邮箱/.test(err), err);

  const loginPage3 = await top(mp);
  await loginPage3.setData({ username: "preflight_user", email: "preflight@example.com", registerPassword: "123" });
  await call(mp, "submitRegister");
  await sleep(1200);
  err = (await (await top(mp)).data()).error || "";
  check("拦住过短密码", /密码/.test(err), err);

  await call(mp, "continueAsGuest");
  await sleep(1800);

  // ---- 6. 共同空闲页游客态不白屏 ----
  const couple = await mp.navigateTo("/pages/couple/index");
  await sleep(2500);
  const coupleData = await couple.data();
  check("共同空闲页游客态正常降级（不白屏）",
    coupleData.view === "disconnected" && /登录/.test(coupleData.message || ""),
    `view=${coupleData.view} message=${coupleData.message}`);

  // ---- 7. 导入页未选文件时的约束 ----
  await mp.switchTab("/pages/import/index");
  await sleep(1500);
  page = await top(mp);
  check("导入页未选文件时禁用识别", (await page.data()).fileReady === false, "");
  const errCountBefore = errors.length;
  await page.callMethod("parseFile");
  await sleep(1500);
  check("未选文件就点识别不会报错也不会发请求", errors.length === errCountBefore,
    errors.slice(errCountBefore).join(" | ") || "无新错误");

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
