// 管理后台 v3 预览：静态服务 + mock API + 截图
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const ROOT = path.resolve(process.argv[2]); // admin 目录
const OUT = path.resolve(process.argv[3]);
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png' };

const today = new Date();
const iso = (d) => d.toISOString().slice(0, 10);
const dau = Array.from({ length: 30 }, (_, i) => { const d = new Date(today); d.setDate(d.getDate() - 29 + i); return { date: iso(d), dau: 8 + ((i * 7) % 13) + (i > 22 ? 12 : 0) }; });
const growth = Array.from({ length: 30 }, (_, i) => { const d = new Date(today); d.setDate(d.getDate() - 29 + i); return { date: iso(d), count: (i * 5) % 4 + (i > 24 ? 3 : 0) }; });
const users = Array.from({ length: 8 }, (_, i) => ({
  id: 100 + i, username: ['演示用户', '同学甲', 'yangchen', 'testuser', '小红', 'zhou_2026', 'lixia', 'momo'][i],
  email: `user${i}@example.com`, created_at: new Date(today - (i * 86400000 * 3)).toISOString(),
  android_count: i % 3, web_count: i % 2, course_count: (i * 4) % 9,
  last_active: i % 4 === 3 ? null : iso(new Date(today - i * 86400000)),
  restricted: i === 5,
}));

function mock(page) {
  return page.route('**/api/admin-console/**', (route) => {
    const p = new URL(route.request().url()).pathname;
    const q = new URL(route.request().url()).searchParams;
    const j = (data) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ code: 0, message: 'ok', data }) });
    if (p.endsWith('/login')) return j({ csrf_token: 'demo' });
    if (p.endsWith('/session')) return j({ authenticated: true, csrf_token: 'demo' });
    if (p.endsWith('/summary')) return j({ users: 184, push_devices: 96, semesters: 210, courses: 1836, schedules: 4420 });
    if (p.endsWith('/stats/overview')) return j({ today_dau: 41, yesterday_dau: 33, wau: 88, mau: 129, total_users: 184, today_new_users: 3, week_new_users: 17, total_semesters: 210, total_courses: 1836, total_schedules: 4420, native_devices: 68, web_subscriptions: 28, total_notifications: 782, today_notifications: 95, couple_memberships: 12 });
    if (p.endsWith('/stats/dau-series')) return j(dau);
    if (p.endsWith('/stats/growth-series')) return j(growth);
    if (p.endsWith('/stats/platforms')) return j({ devices: { android: 60, harmony: 8 }, web_subscriptions: 28, notification_status: { accepted: 640, stored: 96, pending: 38, failed: 8 }, onboarding_reminders: 94 });
    if (p.endsWith('/stats/system')) return j({ mem_total_mb: 1837, mem_used_mb: 1210, load_avg: [0.42, 0.31, 0.28], disk_total_gb: 40, disk_used_gb: 17, db_size_mb: 22.4 });
    if (p.endsWith('/users') && !q.get('page')) { /* detail */ }
    if (p.match(/\/users\/\d+$/)) return j({ id: 100, username: '演示用户', email: 'demo@example.com', created_at: new Date(today - 86400000 * 20).toISOString(), counts: { semesters: 2, courses: 9, schedules: 21 }, notification_count: 12, credential_vault: { exists: false, student_id_hint: '', schema_version: null, updated_at: null, last_verified_at: null }, restricted: { active: false, reason: '', disabled_at: null }, last_active: iso(today), devices: [{ platform: 'android', last_seen_at: today.toISOString(), created_at: today.toISOString() }], web_count: 1 });
    if (p.endsWith('/users')) return j({ items: users, total: users.length, page: 1, page_size: 20 });
    if (p.endsWith('/audit')) return j([]);
    return j({});
  });
}

(async () => {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    let f = path.join(ROOT, decodeURIComponent(u.pathname));
    if (u.pathname === '/' || u.pathname.endsWith('/')) f = path.join(ROOT, 'index.html');
    fs.readFile(f, (err, data) => { if (err) { res.writeHead(404); res.end(); return; } res.writeHead(200, { 'content-type': MIME[path.extname(f).toLowerCase()] || 'application/octet-stream' }); res.end(data); });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const browser = await chromium.launch({ headless: true, executablePath: 'C:/Users/yourname/AppData/Local/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-win64/chrome-headless-shell.exe' });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 960 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await mock(page);
  await page.goto(`http://127.0.0.1:${server.address().port}/`, { waitUntil: 'load' });
  await page.waitForTimeout(1200);
  fs.mkdirSync(OUT, { recursive: true });
  await page.screenshot({ path: path.join(OUT, 'admin-v3-dashboard.png'), fullPage: false });
  await page.click('button[data-target="stats"]');
  await page.waitForTimeout(900);
  await page.screenshot({ path: path.join(OUT, 'admin-v3-stats.png'), fullPage: true });
  await page.click('button[data-target="users"]');
  await page.waitForTimeout(700);
  await page.screenshot({ path: path.join(OUT, 'admin-v3-users.png') });
  await page.click('.row-action[data-user="100"]');
  await page.waitForTimeout(600);
  await page.screenshot({ path: path.join(OUT, 'admin-v3-user-detail.png') });
  console.log('errors:', errors.length ? errors : 'none');
  await browser.close();
  server.close();
})().catch((e) => { console.error(e); process.exit(1); });
