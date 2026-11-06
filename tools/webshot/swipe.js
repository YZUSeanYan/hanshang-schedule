// 跟手滑动 + 顶栏压缩 + 课程块填充 验证
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
  course('毛泽东思想和中国特色社会主义理论体系概论', '陈国强', 'F6E6AD', [[5, 9, 11, '昭文馆报告厅']]),
  course('数据结构与算法分析', '示例教师', 'A8D8EA', [[1, 1, 2, '文津楼E206'], [3, 3, 4, '文津楼E206']]),
  course('大学英语（四）', '李静', 'FFCBCB', [[2, 1, 2, '教学楼A103']]),
  course('高等数学A（下）', '周立', 'FFDAC1', [[4, 1, 2, '教学楼B220']]),
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
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
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
  await page.waitForTimeout(600);

  const results = {};
  const check = (name, ok) => { results[name] = ok ? 'PASS' : 'FAIL'; console.log((ok ? 'PASS ' : 'FAIL ') + name); };

  // 顶栏：课表页隐藏大标题
  check('课表页隐藏我的课表大标题', await page.locator('#page-title').evaluate((el) => getComputedStyle(el).display === 'none'));

  // 长课程名 3 节块：标题行数放开
  const longBlock = page.locator('.week-course', { hasText: '毛泽东思想' });
  check('长名课程块标题行数放开(>=8)', await longBlock.evaluate((el) => Number(getComputedStyle(el).getPropertyValue('--course-title-lines')) >= 8));

  // 跟手：拖动过程中 transform 实时跟随
  const host = page.locator('#schedule-list');
  const box = await host.boundingBox();
  const startX = box.x + box.width - 40, startY = box.y + 300;
  await page.mouse.move(startX, startY);
  await page.mouse.down();
  await page.mouse.move(startX - 60, startY, { steps: 4 });
  const midTransform = await host.evaluate((el) => el.firstElementChild.style.transform);
  check('拖动过程实时跟随(translateX)', /translateX\(-6\d/.test(midTransform) || midTransform.includes('-60px'));
  // 过阈值松手 → 切周
  await page.mouse.move(startX - 160, startY, { steps: 4 });
  await page.mouse.up();
  await page.waitForTimeout(500);
  check('拖动松手切到下一周', (await page.locator('#week-label').textContent()).includes('第 4 周'));
  // 短拖回弹：周不变
  await page.mouse.move(box.x + 40, startY);
  await page.mouse.down();
  await page.mouse.move(box.x + 90, startY, { steps: 3 });
  await page.mouse.up();
  await page.waitForTimeout(500);
  check('短拖回弹周不变', (await page.locator('#week-label').textContent()).includes('第 4 周'));

  // 日视图滑动：先切到日
  await page.click('[data-view-mode="day"]');
  await page.waitForTimeout(400);
  const dayBefore = await page.locator('.day-selector button.active').textContent();
  await page.mouse.move(startX, startY);
  await page.mouse.down();
  await page.mouse.move(startX - 160, startY, { steps: 5 });
  await page.mouse.up();
  await page.waitForTimeout(500);
  const dayAfter = await page.locator('.day-selector button.active').textContent();
  check('日视图可滑动切日(' + dayBefore.trim() + '→' + dayAfter.trim() + ')', dayBefore !== dayAfter);
  // 日视图卡片统一固定高度
  const cardHeights = await page.locator('.slot-card').evaluateAll((els) => els.map((el) => el.offsetHeight));
  check('日视图卡片固定高度一致', cardHeights.length > 0 && cardHeights.every((h) => h === cardHeights[0]));

  // 日视图周日右滑 → 跨周到下周一
  await page.evaluate(() => { window.scrollTo(0, 0); });
  // 点周日再向右滑（上一页）：应回到上一周的周六? 不：日6+1=日(7), 再滑→下周一
  await page.locator('.day-selector button >> nth=6').click(); // 周日
  await page.waitForTimeout(300);
  const weekBeforeWrap = await page.locator('#week-label').textContent();
  await page.mouse.move(startX, startY);
  await page.mouse.down();
  await page.mouse.move(startX - 160, startY, { steps: 5 });
  await page.mouse.up();
  await page.waitForTimeout(500);
  const dayWrap = await page.locator('.day-selector button.active').textContent();
  const weekWrap = await page.locator('#week-label').textContent();
  check('周日左滑跨周到下周一', dayWrap.includes('一') && weekWrap !== weekBeforeWrap);

  // 拖过课程块松手不应误开详情
  await page.click('[data-view-mode="week"]');
  await page.waitForTimeout(300);
  const block = page.locator('.week-course').first();
  const bb = await block.boundingBox();
  await page.mouse.move(bb.x + bb.width / 2, bb.y + bb.height / 2);
  await page.mouse.down();
  await page.mouse.move(bb.x - 150, bb.y, { steps: 5 });
  await page.mouse.up();
  await page.waitForTimeout(400);
  check('拖过课程块不误开详情', (await page.locator('#course-detail-dialog[open]').count()) === 0);
  // 点按课程仍开详情
  await block.click();
  await page.waitForTimeout(400);
  check('点按课程正常开详情', (await page.locator('#course-detail-dialog[open]').count()) === 1);
  await page.keyboard.press('Escape');

  await page.screenshot({ path: path.join(OUT, 'm-v48-week.png') });
  await page.click('[data-view-mode="day"]');
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(OUT, 'm-v48-day.png') });

  check('无 JS 错误', errors.length === 0);
  console.log('errors:', errors.length ? errors : 'none');
  const fails = Object.entries(results).filter(([, v]) => v === 'FAIL');
  console.log(fails.length ? 'FAILED: ' + fails.map(([k]) => k).join(',') : 'ALL PASS');
  await browser.close();
  server.close();
  process.exit(fails.length ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
