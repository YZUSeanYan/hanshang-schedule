// 大屏/横屏多视口验证
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
  course('大学物理IV_02', '周国欢', 'C7CEEA', [[2, 1, 2, '文津楼101·扬子津东校区'], [4, 1, 2, '文津楼101·扬子津东校区']]),
  course('大学英语（四）', '李静', 'FFCBCB', [[2, 1, 2, '教学楼A103']]),
  course('高等数学A（下）', '周立', 'FFDAC1', [[4, 1, 2, '教学楼B220'], [5, 3, 4, '教学楼B220']]),
  course('毛泽东思想和中国特色社会主义理论体系概论_01', '陈国强', 'F6E6AD', [[5, 9, 11, '文津楼E208·扬子津东校区']]),
  course('操作系统原理', '孙立军', 'A2E1DB', [[4, 5, 6, '文经楼S118']]),
  course('形势与政策（四）', '王芳', 'F3B0C3', [[5, 6, 7, '逸夫图书馆报告厅']]),
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
  const viewports = [
    ['tablet-landscape', 1180, 820],
    ['phone-landscape', 844, 390],
    ['desktop', 1440, 900],
    ['phone-portrait', 390, 844],
  ];
  for (const [name, w, h] of viewports) {
    const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 2, isMobile: h > w, hasTouch: h > w });
    const page = await ctx.newPage();
    await page.route('**/web-api/**', (route) => {
      const p = new URL(route.request().url()).pathname;
      const json = (data) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data }) });
      if (p.endsWith('/api/auth/refresh')) return json({ access_token: 't', user: { id: 7, username: '演示用户', email: 'd@x' } });
      if (p.endsWith('/api/sync/pull')) return json(snapshot);
      if (p.includes('/api/notifications')) return json({ items: [], unread: 0, next_before_id: null, has_more: false });
      return json({});
    });
    await page.addInitScript(`try{localStorage.setItem('privacyConsentedAtV3','1');localStorage.setItem('hanshang-guide-seen-v2','1');localStorage.setItem('hanshang-notification-consent-v1','shown')}catch(e){}`);
    await page.goto(base + '/index.html', { waitUntil: 'load' });
    await page.waitForSelector('.week-course', { timeout: 6000 });
    await page.waitForTimeout(700);
    await page.screenshot({ path: path.join(OUT, `m-v52-${name}.png`) });
    // 吸顶验证：滚到底后表头仍在顶部
    const stickyOk = await page.evaluate(() => {
      const host = document.getElementById('schedule-list');
      const header = document.querySelector('.week-grid-day');
      host.scrollTo(0, host.scrollHeight);
      const hr = header.getBoundingClientRect();
      const tr = host.getBoundingClientRect();
      return Math.abs(hr.top - tr.top) < 6;
    });
    console.log(name, 'sticky-header-after-scroll:', stickyOk);
    await ctx.close();
  }
  await browser.close();
  server.close();
  console.log('done');
})().catch((e) => { console.error(e); process.exit(1); });
