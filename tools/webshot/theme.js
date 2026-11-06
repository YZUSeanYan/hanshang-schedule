// 深色模式开关验证
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
    fs.readFile(f, (err, data) => { if (err) { res.writeHead(404); res.end(); return; } res.writeHead(200, { 'content-type': MIME[path.extname(f).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-cache' }); res.end(data); });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ headless: true, executablePath: 'C:/Users/yourname/AppData/Local/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-win64/chrome-headless-shell.exe' });
  // 系统为浅色：验证手动深色、手动浅色覆盖、跟随系统
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, colorScheme: 'light' });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.route('**/web-api/**', (route) => {
    const p = new URL(route.request().url()).pathname;
    const j = (d) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data: d }) });
    if (p.endsWith('/api/auth/refresh')) return j({ access_token: 't', user: { id: 7, username: '演示用户', email: 'd@x' } });
    if (p.endsWith('/api/sync/pull')) return j({ semesters: [{ uuid: 's', name: '秋季', start_date: '2026-08-31', total_weeks: 18, is_current: true, updated_at: 1, deleted: false }], courses: [], schedules: [], cursor: 1 });
    return j({ items: [], unread: 0 });
  });
  await page.addInitScript(`try{localStorage.setItem('privacyConsentedAtV3','1');localStorage.setItem('hanshang-guide-seen-v2','1');localStorage.setItem('hanshang-notification-consent-v1','shown')}catch(e){}`);
  await page.goto(base + '/index.html', { waitUntil: 'load' });
  await page.waitForSelector('.bottom-nav', { timeout: 6000 });
  await page.waitForTimeout(500);

  const results = [];
  const check = (name, ok) => { results.push([name, ok]); console.log((ok ? 'PASS ' : 'FAIL ') + name); };
  const surface = () => page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--surface').trim());

  // 默认跟随系统（系统浅色 → surface 浅色）
  check('默认跟随系统=浅色', (await surface()) === '#F5FBF5');
  check('默认激活的是跟随系统', await page.locator('#theme-system.active').count() === 1);

  await page.click('.bottom-nav button[data-page="profile"]');
  await page.waitForTimeout(400);
  await page.locator('.theme-seg').scrollIntoViewIfNeeded();
  await page.screenshot({ path: path.join(OUT, 'm-v54-theme-light.png') });

  // 手动深色
  await page.click('#theme-dark');
  await page.waitForTimeout(400);
  check('点深色后 surface=深色', (await surface()) === '#121417');
  await page.click('.bottom-nav button[data-page="schedule"]');
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(OUT, 'm-v54-theme-dark-schedule.png') });

  // 刷新后持久化
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(800);
  check('刷新后深色持久化', (await surface()) === '#121417');
  check('深色按钮保持激活', await page.locator('#theme-dark.active').count() === 1);

  // 切回浅色（系统浅色时也应强制浅）
  await page.click('.bottom-nav button[data-page="profile"]');
  await page.waitForTimeout(300);
  await page.click('#theme-light');
  await page.waitForTimeout(300);
  check('手动浅色生效', (await surface()) === '#F5FBF5');

  // 切回跟随系统
  await page.click('#theme-system');
  await page.waitForTimeout(300);
  check('跟随系统恢复', (await surface()) === '#F5FBF5');

  check('无 JS 错误', errors.length === 0);
  console.log('errors:', errors.length ? errors : 'none');
  const fails = results.filter(([, ok]) => !ok);
  console.log(fails.length ? `FAILED ${fails.length}` : 'ALL PASS');
  await browser.close();
  server.close();
  process.exit(fails.length ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
