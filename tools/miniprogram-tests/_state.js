const automator = require("miniprogram-automator");
const { sleep, top } = require("./helpers");
(async () => {
  const mp = await automator.connect({ wsEndpoint: "ws://127.0.0.1:9432" });
  await mp.switchTab("/pages/profile/index");
  await sleep(1500);
  const page = await top(mp);
  const d = await page.data();
  console.log("登录态:", d.guest ? "游客（数据只在本机）" : `已登录 → ${d.userName}`);
  const info = await page.callMethod("openHoliday");
  void info;
  await sleep(1500);
  const holiday = await page.$("#holiday");
  const hd = await holiday.data();
  console.log("现存调休安排:", hd.list.length, "条");
  hd.list.forEach((r) => console.log("  ", r.date, r.label));
  try { await mp.disconnect(); } catch (e) {}
  process.exit(0);
})();
