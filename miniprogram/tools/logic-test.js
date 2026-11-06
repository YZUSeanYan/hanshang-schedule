/*
 * 集成测试：给全局 wx 打桩，把「游客建课 → 落本机 → 周视图取数」整条链路跑一遍。
 *
 * 上面的 parity-test 比的是单个纯函数是否与网页版一致；这一份比的是模块拼起来
 * 还能不能用：push 的合并语义、墓碑删除、按账号隔离的离线快照校验、以及
 * 周视图真正依赖的那几个查询函数。小程序里这些东西错了，表现是"界面空白"，
 * 很难从报错看出原因，所以在提交前用 Node 跑一遍。
 */
const path = require("path");

// ---- wx 打桩 ----
const storage = new Map();
global.wx = {
  getStorageSync: (key) => (storage.has(key) ? storage.get(key) : ""),
  setStorageSync: (key, value) => { storage.set(key, value); },
  removeStorageSync: (key) => { storage.delete(key); },
  showToast: () => {},
  showModal: () => {},
  request: () => {},
  getWindowInfo: () => ({ statusBarHeight: 20, windowHeight: 700, windowWidth: 375, safeArea: { bottom: 700 } }),
  getMenuButtonBoundingClientRect: () => ({ top: 24, height: 32 }),
};

const store = require(path.resolve(__dirname, "..", "utils", "store.js"));
const sync = require(path.resolve(__dirname, "..", "utils", "sync.js"));
const schedule = require(path.resolve(__dirname, "..", "utils", "schedule.js"));
const { coursePaint, courseBaseColor } = require(path.resolve(__dirname, "..", "utils", "colors.js"));

const failures = [];
let checks = 0;

function expect(label, actual, wanted) {
  checks += 1;
  const a = JSON.stringify(actual);
  const b = JSON.stringify(wanted);
  if (a !== b) failures.push(`${label}\n    实际: ${a}\n    期望: ${b}`);
}

function expectTrue(label, value) {
  checks += 1;
  if (!value) failures.push(`${label}（实际为 ${JSON.stringify(value)}）`);
}

(async () => {
  // ---- 1. 游客模式建课 ----
  expectTrue("初始是游客态", store.isGuest());
  expect("游客初始课表为空", schedule.currentSemesterOf(store.activeSnapshot()), null);

  const semesterUuid = "sem-1";
  await sync.push({
    semesters: [{
      uuid: semesterUuid, name: "2026 秋季学期", start_date: "2026-08-31",
      total_weeks: 20, is_current: true, updated_at: 1, deleted: false,
    }],
  });

  const semester = schedule.currentSemesterOf(store.activeSnapshot());
  expectTrue("游客建学期后能读到当前学期", Boolean(semester));
  expect("学期名称正确", semester.name, "2026 秋季学期");

  const course = sync.buildCourse({ name: "高等数学", teacher: "张老师", note: "", semester_uuid: semesterUuid }, null);
  expectTrue("新建课程生成了 uuid", typeof course.uuid === "string" && course.uuid.length === 36);
  expect("课程色是 ARGB int", course.color > 0xffffff, true);

  const slots = [
    sync.buildSlot({ day_of_week: 1, start_section: 1, end_section: 2, weeks_type: 0, custom_weeks: "", location: "扬子津东校区>>文津楼>>N204" }, course.uuid, null, 0),
    sync.buildSlot({ day_of_week: 3, start_section: 3, end_section: 4, weeks_type: 3, custom_weeks: "1-8,10", location: "文津楼N204" }, course.uuid, null, 1),
  ];
  await sync.push({ courses: [course], schedules: slots });

  const courses = schedule.normalizeCourses(store.activeSnapshot(), semester);
  expect("课程数", courses.length, 1);
  expect("课程挂上了 2 段排课", courses[0].slots.length, 2);

  // ---- 2. 周视图取数 ----
  const monday = schedule.slotsForDay(courses, 1, 1);
  const wednesday = schedule.slotsForDay(courses, 3, 1);
  const wednesdayWeek9 = schedule.slotsForDay(courses, 3, 9);
  expect("第 1 周周一有课", monday.length, 1);
  expect("第 1 周周三有课", wednesday.length, 1);
  expect("自定义周次 1-8,10 在第 9 周无课", wednesdayWeek9.length, 0);

  // 地点解析
  expect("地点拆成楼名+教室+校区", schedule.parseLocationParts("扬子津东校区>>文津楼>>N204"),
    { room: "N204", building: "文津楼", campus: "扬子津东校区", formatted: "文津楼N204 · 扬子津东校区" });
  expect("展示格式地点能反向拆开", schedule.parseLocationParts("文津楼N204 · 扬子津东校区").room, "N204");

  // 课程配色（深浅两套都要能算出来，且深色底更实）
  const light = coursePaint(courses[0], false);
  const dark = coursePaint(courses[0], true);
  expectTrue("浅色底与深色底不同", light.background !== dark.background);
  expectTrue("基色是 6 位十六进制", /^#[0-9A-F]{6}$/.test(courseBaseColor(courses[0])));

  // ---- 3. 重叠分栏 ----
  const overlap = schedule.layoutDay([
    { course: courses[0], slot: { uuid: "a", day_of_week: 2, start_section: 1, end_section: 3 } },
    { course: courses[0], slot: { uuid: "b", day_of_week: 2, start_section: 2, end_section: 4 } },
    { course: courses[0], slot: { uuid: "c", day_of_week: 2, start_section: 6, end_section: 7 } },
  ]);
  expect("相交的两段被分成 2 栏", [overlap[0].laneCount, overlap[1].laneCount], [2, 2]);
  expect("互不相交的第三段独占一栏", overlap[2].laneCount, 1);
  expect("分栏序号依次为 0/1/0", overlap.map((item) => item.lane), [0, 1, 0]);

  // ---- 4. 更新与删除（last-write-wins 与墓碑）----
  await sync.push({ courses: [Object.assign({}, course, { name: "高等数学 A", teacher: "李老师", updated_at: Date.now() + 100 })] });
  const renamed = schedule.normalizeCourses(store.activeSnapshot(), semester)[0];
  expect("改名生效", renamed.name, "高等数学 A");
  expect("教师同步更新", renamed.teacher, "李老师");

  await sync.push({
    courses: [Object.assign({}, course, { deleted: true, updated_at: Date.now() + 200 })],
    schedules: slots.map((slot, index) => Object.assign({}, slot, { deleted: true, updated_at: Date.now() + 300 + index })),
  });
  expect("删除后课程不再出现在当前课表", schedule.normalizeCourses(store.activeSnapshot(), semester).length, 0);

  // ---- 5. 离线快照的账号隔离校验 ----
  store.state.user = { id: 42, username: "tester" };
  store.setSnapshot(store.activeSnapshot());
  store.saveScheduleCache();
  const cached = store.readScheduleCache();
  expectTrue("登录后能写出离线快照", Boolean(cached));
  expect("快照记的是当前账号", cached.user.id, 42);
  storage.set(store.KEYS.scheduleCache, { user: { id: 42 }, snapshot: { semesters: "坏数据", courses: [], schedules: [] } });
  expect("快照结构损坏时拒绝使用", store.readScheduleCache(), null);

  // ---- 6. 作息持久化 ----
  const ok = store.setTimeConfig({ version: 1, mode: "custom", times: Array.from({ length: 12 }, (_, i) => [`0${8}:00`, `0${8}:45`]) });
  expectTrue("作息写入成功", ok);
  expect("读回的作息模式正确", store.read(store.KEYS.sectionTimes, null).mode, "custom");
  expectTrue("损坏的作息会回落到自动模式", store.read(store.KEYS.sectionTimes, null).mode === "custom");

  // ---- 结果 ----
  console.log(`集成用例：${checks} 项（游客建课 / 周视图取数 / 地点解析 / 重叠分栏 / 增改删 / 快照校验 / 作息持久化）`);
  if (failures.length) {
    console.log(`\n✗ ${failures.length} 项失败：\n`);
    failures.forEach((item) => console.log(`  ✗ ${item}\n`));
    process.exitCode = 1;
  } else {
    console.log("✓ 全部通过");
  }
})();
