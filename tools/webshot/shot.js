// 邗上课表网页版截图/回归夹具：静态服务 + /web-api 全 mock + 页面操作截图
// 用法: node shot.js --root <web目录> --out <截图目录> [--set name1,name2]
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
const ROOT = path.resolve(args.root);
const OUT = path.resolve(args.out || 'shots');
const ONLY = args.set ? new Set(args.set.split(',')) : null;
fs.mkdirSync(OUT, { recursive: true });

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.svg': 'image/svg+xml', '.png': 'image/png' };

// ---------- mock 数据 ----------
const ARGB = (hex) => 0xff000000 + parseInt(hex, 16);
const NOW = Date.now();
const semester = { uuid: 'sem-1', name: '2025-2026 秋季学期', start_date: '2026-09-07', total_weeks: 18, is_current: true, updated_at: 1, deleted: false };
let uid = 0;
function course(name, teacher, color, note, slots) {
  const cu = `course-${++uid}`;
  return {
    row: { uuid: cu, semester_uuid: 'sem-1', name, teacher, color: ARGB(color), note: note || '', updated_at: ++uid, deleted: false },
    slots: slots.map(([d, s, e, wt, loc]) => ({ uuid: `slot-${++uid}`, course_uuid: cu, day_of_week: d, start_section: s, end_section: e, weeks_type: wt ?? 0, custom_weeks: '', location: loc || '', updated_at: ++uid, deleted: false })),
  };
}
const C = [
  course('数据结构与算法分析', '示例教师', 'A8D8EA', '', [[1, 1, 2, 0, '扬子津东校区>>文津楼>>E206'], [3, 3, 4, 0, '扬子津东校区>>文津楼>>E206']]),
  course('大学英语（四）', '李静', 'FFCBCB', '', [[2, 1, 2, 0, '荷花池校区>>教学楼>>A103']]),
  course('马克思主义基本原理概论（2026 春）', '陈国强', 'B5EAD7', '慕课章节需自行完成', [[2, 3, 4, 0, '昭文馆报告厅'], [4, 3, 4, 0, '昭文馆报告厅']]),
  course('高等数学A（下）', '周立', 'FFDAC1', '', [[4, 1, 2, 0, '江阳路北校区>>教学楼>>B220'], [5, 3, 4, 0, '江阳路北校区>>教学楼>>B220']]),
  course('大学体育（四）—篮球', '吴鹏', 'C7CEEA', '', [[5, 5, 5, 0, '扬子津东校区>>东区篮球场']]),
  course('软件工程导论', '赵敏', 'F6E6AD', '', [[3, 7, 8, 1, '扬子津东校区>>文津楼>>N301']]),
  course('操作系统原理', '孙立军', 'A2E1DB', '', [[4, 5, 6, 0, '扬子津东校区>>文经楼>>S118']]),
  course('大学生心理健康教育', '刘悦', 'BFD8B8', '', [[3, 4, 5, 0, '扬子津西校区>>文体馆>>WE210']]),
  course('形势与政策（四）', '王芳', 'F3B0C3', '', [[5, 6, 7, 2, '荷花池校区>>逸夫图书馆>>报告厅']]),
];
const snapshot = {
  semesters: [semester],
  courses: C.map((c) => c.row),
  schedules: C.flatMap((c) => c.slots),
  cursor: 1,
};
const notifications = [
  { id: 101, title: '共同空闲邀请', body: '同学A 邀请你查看共同空闲，接受后即可看到双方都没课的节次。', created_at: '2026-09-14T10:24:00+08:00', read_at: null, data: { type: 'shared_availability_invite', route: '/features/couple_schedule' } },
  { id: 100, title: '课程提醒已开启', body: '上课提醒将在课前 10 分钟通知你。', created_at: '2026-09-13T09:12:00+08:00', read_at: '2026-09-13T10:00:00+08:00', data: null },
  { id: 99, title: '欢迎使用邗上课表', body: '你的账号已创建。课表支持截图导入、口令分享与多端同步，数据与 Android 端实时共享。', created_at: '2026-09-12T20:00:00+08:00', read_at: '2026-09-12T21:00:00+08:00', data: null },
];
const weekStates = (busy) => Array.from({ length: 12 }, (_, i) => (busy.includes(i + 1) ? 'me_busy' : 'both_free'));
const coupleWeek = {
  section_count: 12,
  days: [
    { day: 1, date: '2026-09-14', states: ['me_busy', 'me_busy', 'both_free', 'both_free', 'partner_busy', 'partner_busy', 'both_free', 'both_free', 'both_free', 'both_busy', 'both_busy', 'both_free'] },
    { day: 2, date: '2026-09-15', states: ['both_free', 'both_free', 'me_busy', 'me_busy', 'both_free', 'both_free', 'both_free', 'both_free', 'partner_busy', 'both_free', 'both_free', 'both_free'] },
    { day: 3, date: '2026-09-16', states: ['partner_busy', 'partner_busy', 'both_free', 'me_busy', 'me_busy', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_busy', 'both_free'] },
    { day: 4, date: '2026-09-17', states: ['both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'me_busy', 'me_busy', 'partner_busy', 'both_free', 'both_free', 'both_free', 'both_free'] },
    { day: 5, date: '2026-09-18', states: ['both_busy', 'both_busy', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free'] },
    { day: 6, date: '2026-09-19', states: ['both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free'] },
    { day: 7, date: '2026-09-20', states: ['both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free', 'both_free'] },
  ],
};

function mockApi(page, variant) {
  return page.route('**/web-api/**', (route) => {
    const url = new URL(route.request().url());
    const p = url.pathname;
    const json = (data, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify({ data }) });
    if (p.endsWith('/api/auth/refresh')) {
      if (variant === 'login') return route.fulfill({ status: 401, contentType: 'application/json', body: '{"message":"no session"}' });
      return json({ access_token: 'demo-token', user: { id: 7, username: '演示用户', email: 'demo@stmail.yzu.edu.cn' } });
    }
    if (p.endsWith('/api/sync/pull')) return json(variant === 'empty' ? { semesters: [semester], courses: [], schedules: [], cursor: 1 } : snapshot);
    if (p.includes('/api/notifications')) return json({ items: notifications, unread: 1, next_before_id: null, has_more: false });
    if (p.endsWith('/api/about')) return json({ display_name: 'SeanYan', intro: '扬大在读，邗上课表作者。\n有问题欢迎邮件联系。', website_url: 'https://seanyan.store', avatar_media: null, payment_qr_media: null });
    if (p.endsWith('/api/version/latest')) return json({ version_name: '1.1.2' });
    if (p.endsWith('/api/share/create')) return json({ code: 'K7M2QP', expires_at: '2026-09-22T12:00:00+08:00' });
    if (p.endsWith('/api/education-import/file-parse')) return json({ source: 'image_llm', courses: [
      { name: '数据结构与算法分析', teacher: '示例教师', slots: [{ day_of_week: 1, start_section: 1, end_section: 2, weeks_text: '1-18周', location: '扬子津东校区>>文津楼>>E206' }] },
      { name: '大学英语（四）', teacher: '李静', slots: [{ day_of_week: 2, start_section: 1, end_section: 2, weeks_text: '1-16周', location: '荷花池校区>>教学楼>>A103' }] },
      { name: '软件工程导论', teacher: '赵敏', slots: [{ day_of_week: 3, start_section: 7, end_section: 8, weeks_text: '1-18周', location: '扬子津东校区>>文津楼>>N301' }] },
    ] });
    if (p.endsWith('/api/couple-schedule/status')) {
      if (variant === 'couple-disconnected') return json({ state: 'disconnected', invitations: [{ invitation_id: 'inv-1', username: '同学B', expires_at: '2026-09-21T12:00:00+08:00' }] });
      if (variant === 'couple-code') return json({ state: 'waiting', invite_type: 'code', invitations: [] });
      return json({ state: 'connected', partner: { username: '同学A' }, invitations: [] });
    }
    if (p.includes('/api/couple-schedule/week')) return json(coupleWeek);
    return json({});
  });
}

const INIT = `try{
  localStorage.setItem('privacyConsentedAtV3','1');
  localStorage.setItem('hanshang-guide-seen-v2','1');
  localStorage.setItem('hanshang-notification-consent-v1','shown');
}catch(e){}`;

const results = [];
async function shot(page, name) {
  await page.screenshot({ path: path.join(OUT, name + '.png'), fullPage: false });
  results.push(name);
  console.log('shot:', name);
}

(async () => {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    let f = path.join(ROOT, decodeURIComponent(u.pathname));
    if (u.pathname.endsWith('/')) f = path.join(f, 'index.html');
    fs.readFile(f, (err, data) => {
      if (err) { res.writeHead(404); res.end('nf'); return; }
      res.writeHead(200, { 'content-type': MIME[path.extname(f).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-cache' });
      res.end(data);
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  const base = `http://127.0.0.1:${port}`;
  const browser = await chromium.launch({ headless: true, executablePath: 'C:/Users/yourname/AppData/Local/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-win64/chrome-headless-shell.exe' });

  const MOBILE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true };
  const DESKTOP = { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 };

  async function openApp(ctxOpts, variant, extraInit = '') {
    const ctx = await browser.newContext(ctxOpts);
    const page = await ctx.newPage();
    await mockApi(page, variant);
    await page.addInitScript(INIT + extraInit);
    await page.goto(base + '/index.html', { waitUntil: 'load' });
    await page.waitForTimeout(900);
    return { ctx, page };
  }
  const ok = (name) => !ONLY || ONLY.has(name);

  // ============ 浅色移动版 ============
  if (ok('schedule') || ok('import') || ok('profile') || ok('dialogs')) {
    const { ctx, page } = await openApp(MOBILE, 'main');
    await page.waitForSelector('.week-course', { timeout: 5000 });
    if (ok('schedule')) await shot(page, 'm-schedule-week');
    if (ok('schedule')) {
      await page.click('[data-view-mode="day"]');
      await page.waitForTimeout(400);
      await shot(page, 'm-schedule-day');
      await page.click('[data-view-mode="week"]');
      await page.waitForTimeout(300);
    }
    if (ok('dialogs')) {
      await page.click('.week-course >> nth=0');
      await page.waitForTimeout(500);
      await shot(page, 'm-course-detail');
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
      await page.click('#header-action');
      await page.waitForTimeout(400);
      await shot(page, 'm-schedule-menu');
      await page.click('#semester-button');
      await page.waitForTimeout(400);
      await shot(page, 'm-semester-dialog');
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
      await page.click('#header-action');
      await page.waitForTimeout(300);
      await page.click('#menu-add-course');
      await page.waitForTimeout(400);
      await shot(page, 'm-course-edit');
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
    }
    if (ok('import')) {
      await page.click('.bottom-nav button[data-page="import"]');
      await page.waitForTimeout(400);
      await shot(page, 'm-import');
      // 识别后的预览确认页（含学期设置与「本学期周一」提示）
      await page.setInputFiles('#schedule-image-input', { name: 'kebiao.png', mimeType: 'image/png', buffer: Buffer.from('89504e470d0a1a0a', 'hex') });
      await page.check('#file-import-form [name="ai_consent"]');
      await page.click('#file-parse-button');
      await page.waitForSelector('#education-preview-card:not(.hidden)', { timeout: 5000 });
      await page.locator('#education-preview-card').scrollIntoViewIfNeeded();
      await page.waitForTimeout(400);
      await shot(page, 'm-import-preview');
      await page.locator('.bottom-nav').scrollIntoViewIfNeeded();
      await page.waitForTimeout(200);
    }
    if (ok('profile') || ok('dialogs')) {
      await page.click('.bottom-nav button[data-page="profile"]');
      await page.waitForTimeout(400);
      if (ok('profile')) await shot(page, 'm-profile');
      if (ok('dialogs')) {
        await page.click('#notification-inbox-button');
        await page.waitForTimeout(500);
        await shot(page, 'm-inbox');
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
        await page.click('#share-button');
        await page.waitForTimeout(500);
        await shot(page, 'm-share-dialog');
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
        await page.click('#about-button');
        await page.waitForTimeout(600);
        await shot(page, 'm-about');
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
        await page.click('#section-time-button');
        await page.waitForTimeout(400);
        await shot(page, 'm-section-time');
        await page.keyboard.press('Escape');
      }
    }
    await ctx.close();
  }

  // ============ 深色移动版 ============
  if (ok('dark')) {
    const { ctx, page } = await openApp({ ...MOBILE, colorScheme: 'dark' }, 'main');
    await page.waitForSelector('.week-course', { timeout: 5000 });
    await shot(page, 'm-dark-schedule');
    await page.click('.week-course >> nth=0');
    await page.waitForTimeout(500);
    await shot(page, 'm-dark-course-detail');
    await page.keyboard.press('Escape');
    await page.click('.bottom-nav button[data-page="import"]');
    await page.waitForTimeout(400);
    await shot(page, 'm-dark-import');
    await page.click('.bottom-nav button[data-page="profile"]');
    await page.waitForTimeout(400);
    await shot(page, 'm-dark-profile');
    await ctx.close();
  }

  // ============ 桌面版 ============
  if (ok('desktop')) {
    const { ctx, page } = await openApp(DESKTOP, 'main');
    await page.waitForSelector('.week-course', { timeout: 5000 });
    await shot(page, 'd-schedule-week');
    await page.click('.week-course >> nth=0');
    await page.waitForTimeout(500);
    await shot(page, 'd-course-detail');
    await page.keyboard.press('Escape');
    await page.click('.bottom-nav button[data-page="import"]');
    await page.waitForTimeout(400);
    await shot(page, 'd-import');
    await page.click('.bottom-nav button[data-page="profile"]');
    await page.waitForTimeout(400);
    await shot(page, 'd-profile');
    await ctx.close();
  }

  // ============ 登录页 / 空课表 ============
  if (ok('login')) {
    const { ctx, page } = await openApp(MOBILE, 'login');
    await page.waitForSelector('#login-view:not(.hidden)', { timeout: 5000 });
    await shot(page, 'm-login');
    await ctx.close();
  }
  if (ok('empty')) {
    const { ctx, page } = await openApp(MOBILE, 'empty');
    await page.waitForSelector('#schedule-empty:not(.hidden)', { timeout: 5000 });
    await shot(page, 'm-empty');
    await ctx.close();
  }

  // ============ 大字号（系统字体放大 1.3x 近似） ============
  if (ok('largefont')) {
    const { ctx, page } = await openApp(MOBILE, 'main');
    await page.waitForSelector('.week-course', { timeout: 5000 });
    await page.addStyleTag({ content: 'html{font-size:20.8px !important}' });
    await page.waitForTimeout(300);
    await shot(page, 'm-largefont-schedule');
    await page.click('.week-course >> nth=0');
    await page.waitForTimeout(500);
    await shot(page, 'm-largefont-course-detail');
    await ctx.close();
  }

  // ============ 共同空闲模块 ============
  async function coupleShots(variant, tag, ctxOpts, init = '') {
    const ctx = await browser.newContext(ctxOpts);
    const page = await ctx.newPage();
    await mockApi(page, variant);
    if (init) await page.addInitScript(init);
    await page.goto(base + '/modules/couple-schedule/index.html', { waitUntil: 'load' });
    await page.waitForTimeout(800);
    await shot(page, tag);
    await ctx.close();
  }
  if (ok('couple')) {
    await coupleShots('couple-connected', 'm-couple-connected', MOBILE);
    await coupleShots('couple-disconnected', 'm-couple-disconnected', MOBILE);
    await coupleShots('couple-code', 'm-couple-code', MOBILE, `try{sessionStorage.setItem('hanshang_shared_availability_code_v1',JSON.stringify({code:'7KMP3XQH',expires_at:new Date(Date.now()+14*60000).toISOString()}))}catch(e){}`);
    await coupleShots('couple-connected', 'm-dark-couple-connected', { ...MOBILE, colorScheme: 'dark' });
    await coupleShots('couple-connected', 'd-couple-connected', DESKTOP);
  }

  await browser.close();
  server.close();
  console.log('DONE:', results.join(','));
})().catch((e) => { console.error(e); process.exit(1); });
