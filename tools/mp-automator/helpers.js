/*
 * 各测试套件共用的前置准备与工具。
 *
 * 起因：几个套件原本假设"上一轮留下的状态正好合适"——preflight3 硬编码要找
 * 「2026 秋季学期」，而 cleanup 会把它删掉；preflight2 又假设自己停在课表页。
 * 于是单独跑都绿、连着跑就红。测试套件必须自给自足，否则绿灯没有意义。
 *
 * 这里提供 ensureCourse()：不管当前是什么状态，都能把"一个课表 + 一门课"准备好。
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SEMESTER_NAME = "自检课表";
const COURSE_NAME = "高等数学";

async function top(mp) {
  return mp.currentPage();
}

// 回到课表页（可能停在任意 tab 或二级页）
async function goto(mp, url) {
  try {
    await mp.switchTab(url);
  } catch (error) {
    await mp.reLaunch(url);
  }
  await sleep(1500);
  return top(mp);
}

/*
 * 确保存在课表与课程。已经有了就直接用，没有就按真实用户路径建。
 * 返回 { semesterName, courseCount, created }。
 */
async function ensureCourse(mp) {
  let page = await goto(mp, "/pages/schedule/index");
  let data = await page.data();

  if (!data.hasCourses) {
    // 没有课表时，点「手动添加课程」会先引导建课表
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
  const blocks = (data.grid && data.grid.blocks) || [];
  return {
    semesterName: data.semesterName,
    courseCount: blocks.length,
    created: false,
  };
}

/*
 * 在"栈顶页"上调用方法。
 *
 * 为什么需要：导航之后旧的 Page 对象会失效，直接调会报 "page is not on top of
 * page stack"；而导航动画未结束时 currentPage() 也可能给到旧对象。这里每次重新取，
 * 失败就再取一次重试，把这类偶发踩干净。
 */
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

module.exports = { sleep, top, call, goto, ensureCourse, SEMESTER_NAME, COURSE_NAME };
