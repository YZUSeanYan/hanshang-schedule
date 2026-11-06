/*
 * 各测试套件共用的前置准备与工具。
 *
 * 起因：几个套件原本假设"上一轮留下的状态正好合适"——硬编码课表名、假设停在某个
 * 页面上。于是单独跑都绿、连着跑就红。测试套件必须自给自足，否则绿灯没有意义。
 *
 * 这里提供 ensureCourse()：不管当前是什么状态，都能把"一个课表 + 一门课（周一 1-2 节）"
 * 准备好，供行为级断言使用。
 *
 * 另外两个踩过的坑：
 *  - call()：导航之后旧的 Page 对象会失效（"page is not on top of page stack"），
 *    所以每次重新取栈顶页并带重试。
 *  - 断言要相对：goWeek 是单步 ±1 不是跳转；总周数不一定是 20。
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SEMESTER_NAME = "自检课表";
const COURSE_NAME = "高等数学";

async function top(mp) {
  return mp.currentPage();
}

// 在"栈顶页"上调用方法；失败就重新取页重试
async function call(mp, method, arg) {
  let lastError = null;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const page = await top(mp);
    try {
      return arg === undefined ? await page.callMethod(method) : await page.callMethod(method, arg);
    } catch (error) {
      lastError = error;
      await sleep(800);
    }
  }
  throw lastError;
}

async function goto(mp, url) {
  try {
    await mp.switchTab(url);
  } catch (error) {
    await mp.reLaunch(url);
  }
  await sleep(1500);
  return top(mp);
}

// 确保存在课表与课程（周一 1-2 节，教室文津楼N204）。已有就直接用。
async function ensureCourse(mp) {
  let page = await goto(mp, "/pages/schedule/index");
  let data = await page.data();

  if (!data.hasCourses) {
    if (data.semesterName === "尚未设置学期") {
      await page.callMethod("addCourse");
      await sleep(1500);
      const form = await page.$("#semesterForm");
      if (form) {
        await form.callMethod("fillForm", null, 1);
        await form.setData({ name: SEMESTER_NAME, startDate: "2026-08-31", totalWeeks: "20" });
        await form.callMethod("save");
        await sleep(3000);
      }
      page = await top(mp);
    }

    await page.callMethod("addCourse");
    await sleep(1500);
    const courseForm = await page.$("#courseForm");
    if (courseForm) {
      await courseForm.setData({
        name: COURSE_NAME,
        teacher: "张老师",
        slots: [{
          uuid: "", dayIndex: 0, weeksIndex: 0,
          startSection: "1", endSection: "2", customWeeks: "",
          location: "扬子津东校区>>文津楼>>N204",
        }],
      });
      await courseForm.callMethod("save");
      await sleep(2500);
    }
    page = await top(mp);
  }

  data = await page.data();
  return {
    semesterName: data.semesterName,
    courseCount: ((data.grid && data.grid.blocks) || []).length,
    created: false,
  };
}

/**
 * 造一门指定时段的课程（走真实课程表单），供冲突类用例构造重叠。
 * 不要指望账号里恰好有课——自给自足才不会误判。
 * opt: { name, dayIndex(0-6,周一=0), start, end }
 */
async function addCourseAt(mp, opt) {
  const page = await goto(mp, "/pages/schedule/index");
  await page.callMethod("addCourse");
  await sleep(1500);
  const form = await page.$("#courseForm");
  await form.setData({
    name: opt.name,
    teacher: "",
    slots: [{ uuid: "", dayIndex: opt.dayIndex, weeksIndex: 0, customWeeks: "",
      startSection: String(opt.start), endSection: String(opt.end), location: "" }],
  });
  await form.callMethod("save");
  await sleep(2800);
}

/**
 * 造一条日程：打开「添加日程」面板，把 AI 识别结果直接喂给它，再走真实的保存路径。
 * 不给生产代码加任何测试专用方法——只是往真实表单里填数据，和人手填一样。
 * op: { title, date, start_section, end_section, location?, note? }
 */
async function addSchedule(mp, op) {
  const page = await goto(mp, "/pages/schedule/index");
  await page.callMethod("addAiSchedule");
  await sleep(1500);
  const comp = await page.$("#aiSchedule");
  await comp.setData({
    ops: [{ action: "create", actionLabel: "新增", title: op.title, meta: "（测试）", canAdd: true }],
    pending: [op],
  });
  await sleep(400);
  await comp.callMethod("add", { currentTarget: { dataset: { index: 0 } } });
  await sleep(2800);
}

module.exports = { sleep, top, call, goto, ensureCourse, addSchedule, addCourseAt, SEMESTER_NAME, COURSE_NAME };
