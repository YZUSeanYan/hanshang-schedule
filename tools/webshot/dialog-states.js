// 补拍：隐私政策长弹窗（滚动）、首次指南、通知授权询问、桌面共同空闲已有，以及导入预览卡
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
  const MOBILE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true };
  const mock = (page) => page.route('**/web-api/**', (route) => {
    const p = new URL(route.request().url()).pathname;
    const json = (data, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify({ data }) });
    if (p.endsWith('/api/auth/refresh')) return json({ access_token: 't', user: { id: 7, username: '演示用户', email: 'd@x' } });
    if (p.endsWith('/api/sync/pull')) return json({ semesters: [{ uuid: 's1', name: '秋季学期', start_date: '2026-09-07', total_weeks: 18, is_current: true, updated_at: 1, deleted: false }], courses: [], schedules: [], cursor: 1 });
    if (p.includes('/api/notifications')) return json({ items: [], unread: 0, next_before_id: null, has_more: false });
    return json({});
  });

  // 隐私政策长弹窗（滚动检查：顶部/滚到底部）
  {
    const ctx = await browser.newContext(MOBILE);
    const page = await ctx.newPage();
    await mock(page);
    await page.addInitScript(`try{localStorage.setItem('privacyConsentedAtV3','1');localStorage.setItem('hanshang-guide-seen-v2','1');localStorage.setItem('hanshang-notification-consent-v1','shown');}catch(e){}`);
    await page.goto(base + '/index.html', { waitUntil: 'load' });
    await page.waitForSelector('.bottom-nav', { timeout: 6000 });
    await page.evaluate(() => document.getElementById('privacy-dialog').showModal());
    await page.waitForTimeout(500);
    await page.screenshot({ path: path.join(OUT, 'm-privacy-top.png') });
    await page.locator('#privacy-dialog .dialog-form').evaluate((el) => el.scrollTo(0, el.scrollHeight));
    await page.waitForTimeout(300);
    await page.screenshot({ path: path.join(OUT, 'm-privacy-bottom.png') });
    const canScroll = await page.locator('#privacy-dialog .dialog-form').evaluate((el) => el.scrollHeight > el.clientHeight);
    console.log('privacy dialog scrollable:', canScroll);
    await ctx.close();
  }
  // 首次指南 + 通知授权 + 隐私同意门禁
  {
    const ctx = await browser.newContext(MOBILE);
    const page = await ctx.newPage();
    await mock(page);
    await page.addInitScript(`try{localStorage.setItem('hanshang-guide-seen-v2','1');localStorage.setItem('hanshang-notification-consent-v1','shown');}catch(e){}`); // 不设隐私同意 → 门禁弹窗
    await page.goto(base + '/index.html', { waitUntil: 'load' });
    await page.waitForTimeout(700);
    await page.screenshot({ path: path.join(OUT, 'm-privacy-consent.png') });
    await ctx.close();
  }
  {
    const ctx = await browser.newContext(MOBILE);
    const page = await ctx.newPage();
    await mock(page);
    await page.addInitScript(`try{localStorage.setItem('privacyConsentedAtV3','1');}catch(e){}`); // 触发首次指南+通知询问
    await page.goto(base + '/index.html', { waitUntil: 'load' });
    await page.waitForTimeout(1200);
    await page.screenshot({ path: path.join(OUT, 'm-first-guide-or-consent.png') });
    await ctx.close();
  }
  await browser.close();
  server.close();
  console.log('done');
})().catch((e) => { console.error(e); process.exit(1); });
