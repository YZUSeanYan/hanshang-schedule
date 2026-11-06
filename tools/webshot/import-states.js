// 导入进行中与失败态补拍
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const ROOT = path.resolve(process.argv[2]);
const OUT = path.resolve(process.argv[3]);
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };
(async () => {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    let f = path.join(ROOT, decodeURIComponent(u.pathname));
    if (u.pathname.endsWith('/')) f = path.join(f, 'index.html');
    fs.readFile(f, (err, data) => { if (err) { res.writeHead(404); res.end(); return; } res.writeHead(200, { 'content-type': MIME[path.extname(f).toLowerCase()] || 'application/octet-stream' }); res.end(data); });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ headless: true, executablePath: 'C:/Users/yourname/AppData/Local/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-win64/chrome-headless-shell.exe' });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  await page.route('**/web-api/**', (route) => {
    const p = new URL(route.request().url()).pathname;
    const json = (data, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify({ data }) });
    if (p.endsWith('/api/auth/refresh')) return json({ access_token: 't', user: { id: 7, username: '演示用户', email: 'd@x' } });
    if (p.endsWith('/api/sync/pull')) return json({ semesters: [{ uuid: 's1', name: '秋季', start_date: '2026-09-07', total_weeks: 18, is_current: true, updated_at: 1, deleted: false }], courses: [], schedules: [], cursor: 1 });
    if (p.includes('/api/notifications')) return json({ items: [], unread: 0, next_before_id: null, has_more: false });
    if (p.endsWith('/api/education-import/file-parse')) {
      if (process.env.FAIL_PARSE) return route.fulfill({ status: 422, contentType: 'application/json', body: JSON.stringify({ code: 42245, message: '请上传包含星期、节次和课程信息的完整截图或表格。' }) });
      return new Promise((resolve) => setTimeout(resolve, 60000)); // 永不返回 → 进度态
    }
    return json({});
  });
  await page.addInitScript(`try{localStorage.setItem('privacyConsentedAtV3','1');localStorage.setItem('hanshang-guide-seen-v2','1');localStorage.setItem('hanshang-notification-consent-v1','shown');}catch(e){}`);
  await page.goto(base + '/index.html', { waitUntil: 'load' });
  await page.waitForSelector('.bottom-nav', { timeout: 6000 });
  await page.click('.bottom-nav button[data-page="import"]');
  await page.setInputFiles('#schedule-image-input', { name: 'kebiao.png', mimeType: 'image/png', buffer: Buffer.from('89504e470d0a1a0a', 'hex') });
  await page.check('#file-import-form [name="ai_consent"]');
  await page.click('#file-parse-button');
  await page.waitForTimeout(2500);
  await page.locator('#file-import-card').scrollIntoViewIfNeeded();
  await page.screenshot({ path: path.join(OUT, process.env.FAIL_PARSE ? 'm-import-error.png' : 'm-import-progress.png') });
  console.log('done');
  await browser.close();
  server.close();
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
