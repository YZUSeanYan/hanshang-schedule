// 课表间距优化验证：行高/滚动/滑动/透明度
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const ROOT = path.resolve(process.argv[2]);
const OUT = path.resolve(process.argv[3]);
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };

const ARGB = (hex) => 0xff000000 + parseInt(hex, 16);
const semester = { uuid: 'sem-1', name: '2025-2026 秋季学期', start_date: '2026-08-31', total_weeks: 18, is_current: true, updated_at: 1, deleted: false };
let uid = 0;
function course(name, teacher, color, slots) {
  const cu = `course-${++uid}`;
  return { row: { uuid: cu, semester_uuid: 'sem-1', name, teacher, color: ARGB(color), note: '', updated_at: ++uid, deleted: false },
    slots: slots.map(([d, s, e, loc]) => ({ uuid: `slot-${++uid}`, course_uuid: cu, day_of_week: d, start_section: s, end_section: e, weeks_type: 0, custom_weeks: '', location: loc || '', updated_at: ++uid, deleted: false })) };
}
const C = [
  course('数据结构与算法分析', '示例教师', 'A8D8EA', [[1, 1, 2, '文津楼E206'], [3, 3, 4, '文津楼E206']]),
  course('大学英语（四）', '李静', 'FFCBCB', [[2, 1, 2, '教学楼A103']]),
  course('高等数学A（下）', '周立', 'FFDAC1', [[4, 1, 2, '教学楼B220'], [5, 3, 4, '教学楼B220']]),
  course('操作系统原理', '孙立军', 'A2E1DB', [[4, 5, 6, '文经楼S118']]),
  course('形势与政策（四）', '王芳', 'F3B0C3', [[5, 6, 7, '逸夫图书馆报告厅']]),
  course('体育舞蹈', '吴鹏', 'C7CEEA', [[6, 9, 10, '文体馆']]),
];
const snapshot = { semesters: [semester], courses: C.map((c) => c.row), schedules: C.flatMap((c) => c.slots), cursor: 1 };

(async () => {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    let f = path.join(ROOT, decodeURIComponent(u.pathname));
    if (u.pathname.endsWith('/')) f = path.join(f, 'index.html');
    fs.readFile(f, (err, data) => { if (err) { res.writeHead(404); res.end(); return; } res.writeHead(200, { 'content-type': MIME[path.extname(f).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-cache' }); res.end(data); });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ headless: true, executablePath: 'C:/Users/yourname/AppData/Local/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-win64/chrome-headless-shell.exe' });
  const INIT = `try{localStorage.setItem('privacyConsentedAtV3','1');localStorage.setItem('hanshang-guide-seen-v2','1');localStorage.setItem('hanshang-notification-consent-v1','shown');}catch(e){}`;
  async function openAt(w, h, scheme) {
    const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, colorScheme: scheme || 'light' });
    const page = await ctx.newPage();
    await page.route('**/web-api/**', (route) => {
      const p = new URL(route.request().url()).pathname;
      const json = (data) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data }) });
      if (p.endsWith('/api/auth/refresh')) return json({ access_token: 't', user: { id: 7, username: '演示用户', email: 'd@x' } });
      if (p.endsWith('/api/sync/pull')) return json(snapshot);
      if (p.includes('/api/notifications')) return json({ items: [], unread: 0, next_before_id: null, has_more: false });
      return json({});
    });
    await page.addInitScript(INIT);
    await page.goto(base + '/index.html', { waitUntil: 'load' });
    await page.waitForSelector('.week-course', { timeout: 6000 });
    await page.waitForTimeout(600); // 等入场动画结束再截屏
    return { ctx, page };
  }
  const results = {};

  // 标准手机
  let { ctx, page } = await openAt(390, 844);
  results.gridHeight844 = await page.locator('.week-grid').evaluate((el) => el.scrollHeight);
  results.hostScrollable844 = await page.locator('#schedule-list').evaluate((el) => el.scrollHeight > el.clientHeight + 4);
  await page.screenshot({ path: path.join(OUT, 'm-spacing-844.png') });
  await ctx.close();

  // 矮屏手机：应可上下滑
  ({ ctx, page } = await openAt(390, 700));
  results.gridHeight700 = await page.locator('.week-grid').evaluate((el) => el.scrollHeight);
  results.hostScrollable700 = await page.locator('#schedule-list').evaluate((el) => el.scrollHeight > el.clientHeight + 4);
  await page.screenshot({ path: path.join(OUT, 'm-spacing-700-top.png') });
  await page.locator('#schedule-list').evaluate((el) => el.scrollTo(0, el.scrollHeight));
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(OUT, 'm-spacing-700-scrolled.png') });
  // 纵向滑动不应切周
  const before = await page.locator('#week-label').textContent();
  await page.touchscreen.tap(195, 400); // 确保触摸上下文
  await page.evaluate(() => {
    const host = document.getElementById('schedule-list');
    host.dispatchEvent(new PointerEvent('pointerdown', { clientX: 195, clientY: 500, bubbles: true }));
    host.dispatchEvent(new PointerEvent('pointerup', { clientX: 200, clientY: 260, bubbles: true }));
  });
  await page.waitForTimeout(300);
  results.verticalSwipeKeepsWeek = (await page.locator('#week-label').textContent()) === before;
  // 横向滑动切周（新版跟手实现需要移动过程）
  await page.evaluate(() => {
    const host = document.getElementById('schedule-list');
    host.dispatchEvent(new PointerEvent('pointerdown', { clientX: 300, clientY: 400, pointerId: 9, bubbles: true }));
    for (let i = 1; i <= 8; i++) host.dispatchEvent(new PointerEvent('pointermove', { clientX: 300 - 30 * i, clientY: 400, pointerId: 9, bubbles: true }));
    host.dispatchEvent(new PointerEvent('pointerup', { clientX: 60, clientY: 405, pointerId: 9, bubbles: true }));
  });
  await page.waitForTimeout(600);
  results.horizontalSwipeChangesWeek = (await page.locator('#week-label').textContent()) !== before;
  results.weekAfterSwipe = await page.locator('#week-label').textContent();
  await ctx.close();

  // 深色 + 透明度
  ({ ctx, page } = await openAt(390, 844, 'dark'));
  await page.screenshot({ path: path.join(OUT, 'm-spacing-dark.png') });
  results.navBgDark = await page.locator('.bottom-nav').evaluate((el) => getComputedStyle(el).backgroundColor);
  await ctx.close();

  // 桌面
  const dctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const dpage = await dctx.newPage();
  await dpage.route('**/web-api/**', (route) => {
    const p = new URL(route.request().url()).pathname;
    const json = (data) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data }) });
    if (p.endsWith('/api/auth/refresh')) return json({ access_token: 't', user: { id: 7, username: '演示用户', email: 'd@x' } });
    if (p.endsWith('/api/sync/pull')) return json(snapshot);
    if (p.includes('/api/notifications')) return json({ items: [], unread: 0, next_before_id: null, has_more: false });
    return json({});
  });
  await dpage.addInitScript(INIT);
  await dpage.goto(base + '/index.html', { waitUntil: 'load' });
  await dpage.waitForSelector('.week-course', { timeout: 6000 });
  await dpage.screenshot({ path: path.join(OUT, 'd-spacing.png') });
  results.navBgLight = await dpage.locator('.bottom-nav').evaluate((el) => getComputedStyle(el).backgroundColor);
  await dctx.close();

  console.log(JSON.stringify(results, null, 2));
  await browser.close();
  server.close();
})().catch((e) => { console.error(e); process.exit(1); });
