// iPad 首启动画复现：逐帧截图定位"从右下角闪现到全屏"
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
  const browser = await chromium.launch({ headless: true, executablePath: 'C:/Users/yourname/AppData/Local/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-win64/chrome-headless-shell.exe' });
  // iPad 竖屏尺寸，不设任何 localStorage（= 首次启动）
  const ctx = await browser.newContext({ viewport: { width: 820, height: 1180 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  await page.route('**/web-api/**', (route) => route.fulfill({ status: 401, contentType: 'application/json', body: '{"message":"no session"}' }));
  fs.mkdirSync(OUT, { recursive: true });
  const t0 = Date.now();
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`, { waitUntil: 'commit' });
  for (const ms of [150, 350, 600, 900, 1300, 2000]) {
    const wait = t0 + ms - Date.now();
    if (wait > 0) await page.waitForTimeout(wait);
    await page.screenshot({ path: path.join(OUT, `launch-frame-${ms}ms.png`) });
  }
  await browser.close();
  server.close();
  console.log('frames captured');
})().catch((e) => { console.error(e); process.exit(1); });
