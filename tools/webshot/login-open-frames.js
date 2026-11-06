// 登录后首开课表的动画复现：iPad 视口逐帧截图
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const ROOT = path.resolve(process.argv[2]);
const OUT = path.resolve(process.argv[3]);
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };
const semester = { uuid: 's1', name: '秋季学期', start_date: '2026-08-31', total_weeks: 18, is_current: true, updated_at: 1, deleted: false };
const snap = { semesters: [semester], courses: [{ uuid: 'c1', semester_uuid: 's1', name: '数据结构与算法分析', teacher: '示例教师', color: 4291442154, note: '', updated_at: 2, deleted: false }], schedules: [{ uuid: 'sl1', course_uuid: 'c1', day_of_week: 1, start_section: 1, end_section: 2, weeks_type: 0, custom_weeks: '', location: '文津楼E206', updated_at: 3, deleted: false }], cursor: 1 };
(async () => {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    let f = path.join(ROOT, decodeURIComponent(u.pathname));
    if (u.pathname.endsWith('/')) f = path.join(f, 'index.html');
    fs.readFile(f, (err, data) => { if (err) { res.writeHead(404); res.end(); return; } res.writeHead(200, { 'content-type': MIME[path.extname(f).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-cache' }); res.end(data); });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const browser = await chromium.launch({ headless: true, executablePath: 'C:/Users/yourname/AppData/Local/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-win64/chrome-headless-shell.exe' });
  // iPad 竖屏；已同意隐私/已看指南/已处理通知询问；已有会话 → 直接 enterApp
  const ctx = await browser.newContext({ viewport: { width: 820, height: 1180 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  await page.route('**/web-api/**', (route) => {
    const p = new URL(route.request().url()).pathname;
    const j = (d) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data: d }) });
    if (p.endsWith('/api/auth/refresh')) return j({ access_token: 't', user: { id: 7, username: '演示用户', email: 'd@x' } });
    if (p.endsWith('/api/sync/pull')) return j(snap);
    return j({ items: [], unread: 0, next_before_id: null, has_more: false });
  });
  await page.addInitScript(`try{localStorage.setItem('privacyConsentedAtV3','1');localStorage.setItem('hanshang-guide-seen-v2','1');localStorage.setItem('hanshang-notification-consent-v1','shown')}catch(e){}`);
  fs.mkdirSync(OUT, { recursive: true });
  const t0 = Date.now();
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`, { waitUntil: 'commit' });
  for (const ms of [200, 400, 650, 900, 1300, 2000]) {
    const wait = t0 + ms - Date.now();
    if (wait > 0) await page.waitForTimeout(wait);
    await page.screenshot({ path: path.join(OUT, `login-open-${ms}ms.png`) });
  }
  await browser.close();
  server.close();
  console.log('done');
})().catch((e) => { console.error(e); process.exit(1); });
