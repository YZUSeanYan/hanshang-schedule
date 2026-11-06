// 功能回归：离线课表、账号缓存隔离、共同空闲返回、文件选择、CRUD、通知、键盘、视图切换
// node regress.js --root <web目录>
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
const ROOT = path.resolve(args.root);
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.svg': 'image/svg+xml', '.png': 'image/png' };

const ARGB = (hex) => 0xff000000 + parseInt(hex, 16);
const semester = { uuid: 'sem-1', name: '2025-2026 秋季学期', start_date: '2026-09-07', total_weeks: 18, is_current: true, updated_at: 1, deleted: false };
const courseRow = { uuid: 'c-1', semester_uuid: 'sem-1', name: '数据结构与算法分析', teacher: '示例教师', color: ARGB('A8D8EA'), note: '', updated_at: 2, deleted: false };
const slotRow = { uuid: 's-1', course_uuid: 'c-1', day_of_week: 1, start_section: 1, end_section: 2, weeks_type: 0, custom_weeks: '', location: '文津楼E206', updated_at: 3, deleted: false };
const snapshot = { semesters: [semester], courses: [courseRow], schedules: [slotRow], cursor: 1 };

const checks = [];
function check(name, ok, extra = '') {
  checks.push({ name, ok, extra });
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${extra ? ' — ' + extra : ''}`);
}

(async () => {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    let p = decodeURIComponent(u.pathname);
    if (p.startsWith('/web/')) p = p.slice(4); // 本地用 /web/ 前缀模拟线上路径
    let f = path.join(ROOT, p);
    if (p.endsWith('/')) f = path.join(f, 'index.html');
    fs.readFile(f, (err, data) => {
      if (err) { res.writeHead(404); res.end('nf'); return; }
      res.writeHead(200, { 'content-type': MIME[path.extname(f).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-cache' });
      res.end(data);
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ headless: true, executablePath: 'C:/Users/yourname/AppData/Local/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-win64/chrome-headless-shell.exe' });
  const MOBILE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true };
  const INIT = `try{localStorage.setItem('privacyConsentedAtV3','1');localStorage.setItem('hanshang-guide-seen-v2','1');localStorage.setItem('hanshang-notification-consent-v1','shown');}catch(e){}`;
  const consoleErrors = [];

  function mockApi(page, { user = { id: 7, username: '演示用户', email: 'demo@x.yz' }, offline = false, pushLog = [] } = {}) {
    // sync/push 的数据合并回快照，模拟真实服务器持久化
    const store = JSON.parse(JSON.stringify(snapshot));
    return page.route('**/web-api/**', (route) => {
      if (offline) return route.abort('internetdisconnected');
      const p = new URL(route.request().url()).pathname;
      const json = (data, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify({ data }) });
      if (p.endsWith('/api/sync/push')) {
        const raw = route.request().postData() || '{}';
        pushLog.push(raw);
        try {
          const body = JSON.parse(raw);
          for (const key of ['semesters', 'courses', 'schedules']) {
            for (const row of body[key] || []) {
              const idx = store[key].findIndex((r) => r.uuid === row.uuid);
              if (idx >= 0) store[key][idx] = row; else store[key].push(row);
            }
          }
        } catch {}
        return json({ cursor: 2 });
      }
      if (p.endsWith('/api/auth/refresh')) return json({ access_token: 't', user });
      if (p.endsWith('/api/sync/pull')) return json(store);
      if (p.includes('/api/notifications')) return json({ items: [{ id: 1, title: '欢迎', body: '测试通知', created_at: '2026-09-14T10:00:00+08:00', read_at: null, data: null }], unread: 1, next_before_id: null, has_more: false });
      if (p.endsWith('/api/about')) return json({ display_name: 'SeanYan', intro: '', website_url: '', avatar_media: null, payment_qr_media: null });
      if (p.endsWith('/api/version/latest')) return json({ version_name: '1.1.2' });
      if (p.endsWith('/api/share/create')) return json({ code: 'K7M2QP', expires_at: '2026-09-22T12:00:00+08:00' });
      if (p.match(/\/api\/share\/[A-Z0-9]+$/)) return json({ expires_at: '2026-09-22T12:00:00+08:00', payload: { semester: { name: '分享学期', start_date: '2026-09-07', total_weeks: 18 }, courses: [{ name: '分享课程', teacher: '张三', slots: [{ day_of_week: 2, start_section: 1, end_section: 2, weeks_text: '', location: '' }] }] } });
      if (p.match(/\/api\/share\/[A-Z0-9]+\/claim$/)) return json({ course_count: 1 });
      if (p.endsWith('/api/education-import/file-parse')) return json({ source: 'image_llm', courses: [{ name: '识别课程A', teacher: '李四', slots: [{ day_of_week: 3, start_section: 5, end_section: 6, weeks_text: '1-18周', location: '文津楼E101' }] }] });
      if (p.endsWith('/api/app-manifest')) {
        const payload = Buffer.from(JSON.stringify({ revision: 1 })).toString('base64');
        return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ payload }) });
      }
      if (p.endsWith('/api/app-modules/session')) return json({ launch_url: base + '/web/modules/couple-schedule/index.html?session=test' });
      if (p.endsWith('/api/couple-schedule/status')) return json({ state: 'connected', partner: { username: '同学A' }, invitations: [] });
      if (p.includes('/api/couple-schedule/week')) return json({ section_count: 12, days: Array.from({ length: 7 }, (_, i) => ({ day: i + 1, date: `2026-09-${14 + i}`, states: Array.from({ length: 12 }, (_, s) => (s < 2 && i < 5 ? 'me_busy' : 'both_free')) })) });
      return json({});
    });
  }

  // ---------- 1. 主流程 + 渲染完整性 ----------
  {
    const ctx = await browser.newContext(MOBILE);
    const page = await ctx.newPage();
    page.on('pageerror', (e) => consoleErrors.push('pageerror: ' + e.message));
    page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push('console: ' + m.text()); });
    const pushLog = [];
    await mockApi(page, { pushLog });
    await page.addInitScript(INIT);
    await page.goto(base + '/index.html', { waitUntil: 'load' });
    await page.waitForSelector('.week-course', { timeout: 6000 });
    check('课表渲染课程块', await page.locator('.week-course').count() === 1);
    check('课程块颜色=安卓ARGB解析', await page.locator('.week-course').evaluate((el) => getComputedStyle(el).getPropertyValue('--course-base').trim()) === '#A8D8EA');
    check('今日圆形高亮', await page.locator('.week-grid-day.today span').count() === 1);
    check('底部导航3项含SVG图标', await page.locator('.bottom-nav button svg').count() === 6);
    check('导航激活项pill', await page.locator('.bottom-nav button.active span').first().textContent() === '课表');

    // 周切换
    await page.click('#next-week');
    await page.waitForTimeout(450);
    check('下一周', (await page.locator('#week-label').textContent()).includes('第 3 周'));
    await page.click('#prev-week');
    await page.waitForTimeout(450);
    check('上一周', (await page.locator('#week-label').textContent()).includes('第 2 周'));

    // 视图切换
    await page.click('[data-view-mode="day"]');
    await page.waitForTimeout(350);
    await page.click('.day-selector button >> nth=0'); // 切到周一（测试课在周一）
    await page.waitForTimeout(350);
    check('日视图渲染slot-card', await page.locator('.slot-card').count() === 1);
    check('日视图色条颜色', (await page.locator('.slot-color').first().evaluate((el) => el.style.background)) !== '');
    await page.click('[data-view-mode="week"]');

    // 课程详情 + Esc 关闭
    await page.click('.week-course');
    await page.waitForSelector('#course-detail-dialog[open]', { timeout: 3000 });
    check('详情弹层打开', true);
    check('详情含教师行', (await page.locator('#course-detail-body').textContent()).includes('示例教师'));
    await page.keyboard.press('Escape');
    await page.waitForTimeout(400);
    check('Esc关闭详情', !(await page.locator('#course-detail-dialog[open]').count()));

    // 课程编辑（保留业务路径）
    await page.click('#header-action');
    await page.waitForTimeout(350);
    await page.click('#menu-add-course');
    await page.waitForSelector('#course-dialog[open]');
    await page.fill('#course-form [name="name"]', '回归测试课程');
    await page.fill('#course-form [name="teacher"]', '测试教师');
    await page.click('#course-form button[type="submit"]');
    await page.waitForTimeout(600);
    check('新增课程触发sync/push', pushLog.length > 0 && pushLog[0].includes('回归测试课程'));
    check('新课程颜色写入ARGB整数', pushLog.length > 0 && /"color":\d{10}/.test(pushLog[0]));
    await page.waitForSelector('.week-course', { timeout: 3000 });
    check('新课程出现在课表', (await page.locator('#schedule-list').textContent()).includes('回归测试课程'));

    // 课表管理
    await page.click('#header-action');
    await page.waitForTimeout(300);
    await page.click('#semester-button');
    await page.waitForSelector('#semester-dialog[open]');
    check('学期弹窗含当前课表', (await page.locator('#semester-list').textContent()).includes('2025-2026'));
    await page.keyboard.press('Escape');
    await page.waitForTimeout(400);

    // 收件箱：标记已读 + 删除按钮存在
    await page.click('.bottom-nav button[data-page="profile"]');
    await page.waitForTimeout(300);
    check('我的页头像首字', (await page.locator('#profile-avatar').textContent()) === '演');
    await page.click('#notification-inbox-button');
    await page.waitForSelector('#notification-inbox-dialog[open] .notification-item', { timeout: 4000 });
    check('收件箱条目渲染', true);
    await page.click('.notification-item .notification-main');
    await page.waitForTimeout(500);
    check('点击后未读点消失', await page.locator('.notification-dot').count() === 0);
    await page.keyboard.press('Escape');
    await page.waitForTimeout(400);

    // 分享口令流程
    await page.click('#share-button');
    await page.waitForSelector('#share-dialog[open]');
    check('分享口令生成', (await page.locator('#created-share-code').textContent()) === 'K7M2QP');
    await page.keyboard.press('Escape');
    await page.waitForTimeout(400);

    // 口令导入预览
    await page.click('.bottom-nav button[data-page="import"]');
    await page.waitForTimeout(300);
    await page.fill('#share-code', 'k7m2qp');
    await page.click('#code-form button[type="submit"]');
    await page.waitForSelector('#share-preview-card:not(.hidden)', { timeout: 4000 });
    check('口令预览出现', (await page.locator('#share-preview-card').textContent()).includes('分享课程'));

    // 截图文件选择 → AI 解析 → 预览（学期信息在预览页填写）
    await page.setInputFiles('#schedule-image-input', { name: 'kebiao.png', mimeType: 'image/png', buffer: Buffer.from('89504e470d0a1a0a', 'hex') });
    await page.waitForTimeout(300);
    check('截图选择后按钮可用', await page.locator('#file-parse-button').isEnabled());
    check('识别前不问学期（导入卡无学期字段）', await page.locator('#file-import-form [name="semester_start"]').count() === 0);
    check('教务手动导入已移除', (await page.locator('#manual-import-form').count()) === 0 && (await page.locator('#open-vpn-button').count()) === 0);
    await page.check('#file-import-form [name="ai_consent"]');
    await page.click('#file-parse-button');
    await page.waitForSelector('#education-preview-card:not(.hidden)', { timeout: 5000 });
    check('AI解析预览出现', (await page.locator('#education-course-list').textContent()).includes('识别课程A'));
    check('预览页学期默认建议为第一周周一', (await page.locator('#education-semester-form [name="semester_start"]').inputValue()) === '2026-08-31');
    check('提示文案含本学期周一日期', (await page.locator('.semester-hint').textContent()).includes('2026-08-31'));
    const pushesBefore = pushLog.length;
    await page.click('#save-education-button');
    await page.waitForTimeout(700);
    check('保存触发sync/push且含建议开学日', pushLog.length > pushesBefore && pushLog[pushLog.length - 1].includes('"start_date":"2026-08-31"'));

    // Excel 文件选择（保存后已跳回课表页，先切回导入页）
    await page.click('.bottom-nav button[data-page="import"]');
    await page.waitForTimeout(300);
    await page.setInputFiles('#schedule-table-input', { name: 'kebiao.xlsx', mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', buffer: Buffer.from('504b', 'hex') });
    await page.waitForTimeout(300);
    check('Excel选择更新文案', (await page.locator('#file-selection').textContent()).includes('kebiao.xlsx'));

    // 错误类型文件
    await page.setInputFiles('#schedule-image-input', { name: 'bad.gif', mimeType: 'image/gif', buffer: Buffer.from('47494638', 'hex') });
    await page.waitForTimeout(300);
    check('拒绝不支持的格式', (await page.locator('#file-selection').textContent()).includes('PNG'));

    await ctx.close();
  }

  // ---------- 2. 离线课表快照 ----------
  {
    const ctx = await browser.newContext(MOBILE);
    const page = await ctx.newPage();
    await mockApi(page, { offline: true });
    await page.addInitScript(INIT + `try{
      localStorage.setItem('hanshang-session-established-v1','1');
      localStorage.setItem('hanshang-offline-schedule-v1', JSON.stringify({user:{id:7,username:'演示用户'},snapshot:${JSON.stringify(snapshot)},savedAt:Date.now()}));
    }catch(e){}`);
    await page.goto(base + '/index.html', { waitUntil: 'load' });
    await page.waitForTimeout(900);
    check('离线显示缓存课表', await page.locator('.week-course').count() === 1);
    check('离线轻提示（顶栏小字，非大弹窗）', await page.locator('#sync-hint').isVisible() && ((await page.locator('#sync-hint').textContent()) || '').includes('课表'));
    await ctx.close();
  }

  // ---------- 3. 账号缓存隔离 ----------
  {
    const ctx = await browser.newContext(MOBILE);
    const page = await ctx.newPage();
    await mockApi(page, { user: { id: 8, username: '另一个账号', email: 'b@x.yz' } });
    await page.addInitScript(INIT + `try{
      localStorage.setItem('hanshang-session-established-v1','1');
      localStorage.setItem('hanshang-offline-schedule-v1', JSON.stringify({user:{id:7,username:'旧账号'},snapshot:${JSON.stringify(snapshot)},savedAt:Date.now()}));
    }catch(e){}`);
    await page.goto(base + '/index.html', { waitUntil: 'load' });
    await page.waitForTimeout(1200);
    check('换账号后显示新用户', (await page.locator('#profile-name').textContent()) === '另一个账号');
    const cache = await page.evaluate(() => JSON.parse(localStorage.getItem('hanshang-offline-schedule-v1') || 'null'));
    check('缓存已切换为新账号', cache?.user?.id === 8);
    await ctx.close();
  }

  // ---------- 4. 共同空闲模块：打开、返回按钮、浏览器返回 ----------
  {
    const ctx = await browser.newContext(MOBILE);
    const page = await ctx.newPage();
    await mockApi(page);
    await page.addInitScript(INIT);
    await page.goto(base + '/index.html', { waitUntil: 'load' });
    await page.waitForSelector('.week-course', { timeout: 6000 });
    await page.click('.bottom-nav button[data-page="profile"]');
    await page.click('#shared-availability-button');
    await page.waitForSelector('#availability-module-dialog[open] iframe', { timeout: 6000 });
    check('共同空闲模块以对话框打开', true);
    const frame = page.frameLocator('#availability-module-dialog iframe');
    await frame.locator('.avail-strip').first().waitFor({ timeout: 5000 });
    check('模块内周条渲染', (await frame.locator('.avail-day').count()) === 7);
    // 返回按钮
    await page.click('#availability-module-dialog .module-back');
    await page.waitForTimeout(500);
    check('返回按钮关闭模块', !(await page.locator('#availability-module-dialog[open]').count()));
    // 再次打开 + 浏览器返回
    await page.click('#shared-availability-button');
    await page.waitForSelector('#availability-module-dialog[open] iframe', { timeout: 6000 });
    await page.goBack();
    await page.waitForTimeout(500);
    check('浏览器返回键关闭模块', !(await page.locator('#availability-module-dialog[open]').count()));
    // 连续3次进出
    for (let i = 0; i < 3; i++) {
      await page.click('#shared-availability-button');
      await page.waitForSelector('#availability-module-dialog[open]', { timeout: 6000 });
      await page.click('#availability-module-dialog .module-back');
      await page.waitForTimeout(350);
    }
    check('连续3次进出正常', !(await page.locator('#availability-module-dialog[open]').count()));
    await ctx.close();
  }

  // ---------- 5. 键盘可达性抽查 ----------
  {
    const ctx = await browser.newContext(MOBILE);
    const page = await ctx.newPage();
    await mockApi(page);
    await page.addInitScript(INIT);
    await page.goto(base + '/index.html', { waitUntil: 'load' });
    await page.waitForSelector('.week-course', { timeout: 6000 });
    await page.keyboard.press('Tab');
    let focused = await page.evaluate(() => document.activeElement?.tagName + '.' + (document.activeElement?.className || ''));
    let found = false;
    for (let i = 0; i < 30; i++) {
      await page.keyboard.press('Tab');
      focused = await page.evaluate(() => document.activeElement?.className || '');
      if (focused.includes('week-course')) { found = true; break; }
    }
    check('Tab 可聚焦课程块', found);
    await page.keyboard.press('Enter');
    await page.waitForTimeout(450);
    check('Enter 打开课程详情', await page.locator('#course-detail-dialog[open]').count() === 1);
    await page.keyboard.press('Escape');
    await ctx.close();
  }

  console.log('consoleErrors:', consoleErrors.length ? consoleErrors : 'none');
  const failed = checks.filter((c) => !c.ok);
  console.log(`\n== ${checks.length - failed.length}/${checks.length} passed ==`);
  await browser.close();
  server.close();
  process.exit(failed.length ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
