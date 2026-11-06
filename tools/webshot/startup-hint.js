// 启动轻提示截图：缓存课表 + refresh 挂起 → 顶栏应出现"正在同步本机课表…"
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const ROOT = 'C:/Users/yourname/Documents/主页/output/web-redesign-20260915/web';
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.css': 'text/css' };
const semester = { uuid: 's', name: '秋季学期', start_date: '2026-08-31', total_weeks: 18, is_current: true, updated_at: 1, deleted: false };
const snap = { semesters: [semester], courses: [{ uuid: 'c1', semester_uuid: 's', name: '数据结构与算法分析', teacher: '示例教师', color: 4291442154, note: '', updated_at: 2, deleted: false }], schedules: [{ uuid: 's1', course_uuid: 'c1', day_of_week: 1, start_section: 1, end_section: 2, weeks_type: 0, custom_weeks: '', location: '文津楼E206', updated_at: 3, deleted: false }], cursor: 1 };
(async () => {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    let f = path.join(ROOT, decodeURIComponent(u.pathname));
    if (u.pathname.endsWith('/')) f = path.join(f, 'index.html');
    fs.readFile(f, (e, d) => { if (e) { res.writeHead(404); res.end(); return; } res.writeHead(200, { 'content-type': MIME[path.extname(f).toLowerCase()] || 'application/octet-stream' }); res.end(d); });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const browser = await chromium.launch({ headless: true, executablePath: 'C:/Users/yourname/AppData/Local/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-win64/chrome-headless-shell.exe' });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  await page.route('**/web-api/**', (route) => {
    const p = new URL(route.request().url()).pathname;
    if (p.endsWith('/api/auth/refresh')) return new Promise(() => {}); // 挂起 → 同步中状态
    const j = (d) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data: d }) });
    if (p.endsWith('/api/sync/pull')) return j(snap);
    return j({ items: [], unread: 0 });
  });
  await page.addInitScript(`try{
    localStorage.setItem('privacyConsentedAtV3','1');
    localStorage.setItem('hanshang-guide-seen-v2','1');
    localStorage.setItem('hanshang-notification-consent-v1','shown');
    localStorage.setItem('hanshang-session-established-v1','1');
    localStorage.setItem('hanshang-offline-schedule-v1', ${JSON.stringify(JSON.stringify({ user: { id: 7, username: '演示用户' }, snapshot: snap, savedAt: 1 }))});
  }catch(e){}`);
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`, { waitUntil: 'load' });
  await page.waitForSelector('.week-course', { timeout: 6000 });
  await page.waitForTimeout(800);
  console.log('hint text:', await page.locator('#sync-hint').textContent());
  await page.screenshot({ path: 'C:/Users/yourname/Documents/主页/output/web-redesign-20260915/shots/after/m-v51-startup-hint.png' });
  await browser.close();
  server.close();
})().catch((e) => { console.error(e); process.exit(1); });
