/*
 * 滑动手势在改成 WXS 跟手之后仍然可用（功能层面：松手要能翻页）。
 * 运行：node check-swipe.js [端口]
 */
const automator = require("miniprogram-automator");
const { sleep, top, ensureCourse } = require("./helpers");

const PORT = Number(process.argv[2] || 9432);
const results = [];
function check(name, ok, detail) {
  results.push({ name, ok });
  console.log((ok ? "✓ " : "✗ ") + name + (detail ? " — " + detail : ""));
}
function touchAt(x, y) {
  const t = [{ clientX: x, clientY: y, identifier: 0, pageX: x, pageY: y }];
  return { touches: t, changedTouches: t };
}
function weekNo(data) {
  const m = /第 (\d+) 周/.exec(data.weekLabel || "");
  return m ? Number(m[1]) : -1;
}

(async () => {
  const mp = await automator.connect({ wsEndpoint: "ws://127.0.0.1:" + PORT });
  const errors = [];
  mp.on("exception", (e) => errors.push("异常: " + (e.message || JSON.stringify(e))));
  mp.on("console", (m) => {
    if (m.type === "error") errors.push("console.error: " + ((m.args || []).join(" ")));
  });

  await ensureCourse(mp);
  await mp.switchTab("/pages/schedule/index");
  await sleep(2500);
  let page = await top(mp);

  // 回到第 1 周
  for (let i = 0; i < 25; i += 1) {
    if (weekNo(await page.data()) <= 1) break;
    await page.callMethod("goWeek", -1);
    await sleep(200);
  }

  const host = await page.$(".week-host");
  const w0 = weekNo(await page.data());
  await host.touchstart(touchAt(300, 400));
  await sleep(150);
  await host.touchmove(touchAt(200, 402));
  await sleep(150);
  await host.touchend(touchAt(120, 405));
  await sleep(1500);
  const w1 = weekNo(await (await top(mp)).data());
  check("左滑前进一周", w1 === w0 + 1, w0 + " → " + w1);

  const host2 = await (await top(mp)).$(".week-host");
  await host2.touchstart(touchAt(120, 400));
  await sleep(150);
  await host2.touchend(touchAt(300, 405));
  await sleep(1500);
  const w2 = weekNo(await (await top(mp)).data());
  check("右滑后退一周", w2 === w1 - 1, w1 + " → " + w2);

  // 位移不足不翻页
  const host3 = await (await top(mp)).$(".week-host");
  await host3.touchstart(touchAt(200, 400));
  await sleep(150);
  await host3.touchend(touchAt(180, 402));
  await sleep(1200);
  check("位移不足不翻周", weekNo(await (await top(mp)).data()) === w2, "保持 " + weekNo(await (await top(mp)).data()));

  check("无运行时异常 / console.error", errors.length === 0, errors.slice(0, 4).join(" | ") || "无");

  const failed = results.filter((r) => !r.ok);
  console.log("\n=== 通过 " + (results.length - failed.length) + "/" + results.length + " ===");
  try { await mp.disconnect(); } catch (e) {}
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.log("中断:", e.message);
  process.exit(1);
});
