// Security boundary: credentials and access tokens stay in memory only. The
// service worker caches the static shell, never API responses.
const API_BASE = `${location.origin}/web-api`;
const SESSION_HISTORY_KEY = "hanshang-session-established-v1";
const DAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
const COLORS = ["#087b58", "#2962a9", "#8b55a6", "#c06a2b", "#b43e5a", "#547b2c"];
const COURSE_PALETTES = [
  { background: "#dff5eb", border: "#74c9aa", text: "#123f31", secondary: "#285f4e" },
  { background: "#e4ecfb", border: "#8da9df", text: "#173665", secondary: "#365482" },
  { background: "#f1e5f7", border: "#bd8fd1", text: "#502865", secondary: "#704b81" },
  { background: "#fff0d9", border: "#e2b45f", text: "#593b08", secondary: "#795b24" },
  { background: "#f9e3e8", border: "#d98ea0", text: "#652535", secondary: "#844556" },
  { background: "#e8f1d8", border: "#9fbe67", text: "#314713", secondary: "#526a30" },
];
const SECTION_TIMES = {
  summer: ["08:00", "08:55", "09:55", "10:50", "11:45", "14:30", "15:25", "16:20", "17:15", "18:10", "19:30", "20:25"],
  winter: ["08:00", "08:55", "09:55", "10:50", "11:45", "14:00", "14:55", "15:50", "16:45", "17:40", "19:00", "19:50"],
};
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

let accessToken = "";
let currentUser = null;
let cloudSnapshot = { semesters: [], courses: [], schedules: [], cursor: 0 };
let currentSemester = null;
let currentCourses = [];
let selectedWeek = 1;
let viewMode = "week";
let selectedDay = Math.min(Math.max(new Date().getDay() || 7, 1), 7);
let educationPreview = null;
let sharePreview = null;
let activeShareCode = "";
let messageTimer = null;
let scheduleAnimationDirection = 0;

let messageFadeTimer = null;

function hasSessionHistory() {
  try { return localStorage.getItem(SESSION_HISTORY_KEY) === "1"; } catch { return false; }
}

function rememberSessionHistory() {
  try { localStorage.setItem(SESSION_HISTORY_KEY, "1"); } catch { /* Cookie recovery still works. */ }
}

function forgetSessionHistory() {
  try { localStorage.removeItem(SESSION_HISTORY_KEY); } catch { /* Ignore restricted storage. */ }
}

function setMessage(text, isError = false, login = false) {
  const element = login ? $("#login-message") : $("#app-message");
  clearTimeout(messageFadeTimer);
  element.classList.remove("leaving");
  element.textContent = text;
  element.classList.toggle("error", isError);
  if (!login) {
    clearTimeout(messageTimer);
    if (text) messageTimer = setTimeout(() => {
      // 先渐隐再清空，消息不再瞬消
      element.classList.add("leaving");
      messageFadeTimer = setTimeout(() => {
        element.textContent = "";
        element.classList.remove("leaving");
      }, 300);
    }, 4500);
  }
}

async function request(path, options = {}) {
  return requestAt(API_BASE, path, options);
}

async function requestAt(base, path, options = {}) {
  // 同源 /web-api 请求需要带 HttpOnly 会话 Cookie；跨域直连（如教务导入）
  // 只走 Bearer token，必须显式 omit credentials——后端 CORS 不放行跨域凭据，
  // include 会让浏览器直接拦截响应并报 "Failed to fetch"。
  const credentials = options.credentials ?? "include";
  const response = await fetch(`${base}${path}`, {
    ...options,
    credentials,
    headers: {
      "Content-Type": "application/json",
      ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
      ...(options.headers || {}),
    },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(body.message || body.detail?.message || "请求失败，请稍后再试");
    error.status = response.status;
    throw error;
  }
  return body.data;
}

async function enterApp(user, welcome = false) {
  userSignedOut = false;
  rememberSessionHistory();
  authFailCount = 0;
  loginRetryScheduled = false;
  hideOfflineHint();
  currentUser = user;
  $("#boot-view").classList.add("hidden");
  $("#login-view").classList.add("hidden");
  $("#app-view").classList.remove("hidden");
  $("#profile-name").textContent = currentUser.username;
  showPage("schedule");
  await loadCloudSchedule();
  promptWebNotificationsOnce();
  if (welcome) setMessage(`欢迎回来，${currentUser.username}`);
}

function showLogin() {
  $("#boot-view").classList.add("hidden");
  $("#login-view").classList.remove("hidden");
}

// 手动退出标记：退出后不再自动尝试恢复会话。
let userSignedOut = false;
let sessionRetryCount = 0;
let authFailCount = 0;
let recoveryTimer = null;
let loginRetryScheduled = false;

function sessionRecoveryPending() {
  return !userSignedOut && !currentUser && !accessToken;
}

function showOfflineHint(error = null) {
  const hint = $("#boot-view p");
  if (hint) {
    // 区分"网络不通"与"服务器错误"：5xx 提示服务器端问题，网络异常提示连接问题
    const status = error && error.status;
    hint.textContent = navigator.onLine
      ? status
        ? `服务器暂时不可用（${status}），正在自动重试…`
        : "连接服务器失败，正在自动重试…"
      : "当前离线，联网后会自动恢复登录";
  }
  const retry = $("#boot-retry");
  if (retry) retry.classList.remove("hidden");
}

// 401/403 是"登录状态失效"，不是网络问题：提示语不能误导用户去查网络。
function showSessionRecoveryHint() {
  const hint = $("#boot-view p");
  if (hint) hint.textContent = "登录状态已失效，正在尝试自动恢复…";
  const retry = $("#boot-retry");
  if (retry) retry.classList.add("hidden");
}

function hideOfflineHint() {
  const retry = $("#boot-retry");
  if (retry) retry.classList.add("hidden");
}

function scheduleRecovery() {
  if (recoveryTimer) clearTimeout(recoveryTimer);
  recoveryTimer = setTimeout(() => {
    if (sessionRecoveryPending()) restoreSession();
  }, 15000);
}

let refreshInFlight = null;

// key 带版本号：政策重大更新时递增，存量用户下次访问会重新弹窗同意。
// v1 = 2026-08-13 首版；v2 = 2026-09-02 第 2 版（新增不收集红线、AI 脱敏细节）。
const PRIVACY_CONSENT_KEY = "privacyConsentedAtV2";

function privacyConsented() {
  return !!localStorage.getItem(PRIVACY_CONSENT_KEY);
}

function showPrivacyConsent() {
  const dialog = document.getElementById("privacy-consent-dialog");
  if (!dialog.open) dialog.showModal();
}

$("#privacy-consent-accept").addEventListener("click", () => {
  localStorage.setItem(PRIVACY_CONSENT_KEY, String(Date.now()));
  closeDialog("privacy-consent-dialog");
  restoreSession();
});

$("#privacy-consent-decline").addEventListener("click", () => {
  if (confirm("不同意隐私政策将无法使用课表功能。确定不同意吗？")) {
    closeDialog("privacy-consent-dialog");
    setMessage("未同意隐私政策，暂不能进入课表。刷新页面可重新选择。", true);
  }
});

$("#privacy-consent-link").addEventListener("click", (event) => {
  event.preventDefault();
  showDialog("privacy-dialog");
});

async function restoreSession() {
  // 隐私政策门禁（金标联盟/应用商店合规）：未同意前不发起任何 API 请求
  //（含会话恢复），也不写入会话 Cookie。
  if (!privacyConsented()) {
    showPrivacyConsent();
    return;
  }
  // 单飞：页面加载、回前台、恢复联网、定时恢复可能并发触发 refresh。
  // 共享同一个在途请求，避免同一刷新凭据被并发消费（单次轮换竞态 → 一方 401）。
  const initiated = !refreshInFlight;
  if (initiated) {
    refreshInFlight = request("/api/auth/refresh", { method: "POST" })
      .finally(() => { refreshInFlight = null; });
  }
  try {
    const data = await refreshInFlight;
    if (!initiated) return; // 由发起方统一完成登录态建立
    accessToken = data.access_token;
    const user = data.user || await request("/api/user/profile");
    sessionRetryCount = 0;
    await enterApp(user);
  } catch (error) {
    if (!initiated) return; // 由发起方统一处理失败与重试
    // 只有服务器明确拒绝会话（401/403，如 Cookie 失效或被撤销）才显示登录页。
    // 离线、后台恢复瞬间、代理抖动或服务器 5xx 时保持等待态并自动重试，
    // 绝不把"网络暂时不可用"误显示成"请登录"。
    const definitive = error && (error.status === 401 || error.status === 403);
    if (definitive || userSignedOut) {
      // HttpOnly refresh Cookie cannot be inspected by JavaScript, and the
      // server returns the same 401 for "no Cookie" and "expired Cookie".
      // A browser that has never established a session is a normal first
      // visit: show the login form silently instead of claiming it expired.
      if (!userSignedOut && !hasSessionHistory()) {
        accessToken = "";
        authFailCount = 0;
        sessionRetryCount = 0;
        showLogin();
        setMessage("", false, true);
        return;
      }
      // 多页面同时刷新会用同一刷新凭据触发单次轮换竞态（一个成功、另一个
      // 401）；iOS 清后台后 cookie 也可能短暂不可读。允许有限次快速自动
      // 重试，超限才停在登录页。
      authFailCount += 1;
      if (authFailCount <= 3 && !userSignedOut && sessionRecoveryPending()) {
        const delay = [2000, 5000, 10000][authFailCount - 1] || 15000;
        if (recoveryTimer) clearTimeout(recoveryTimer);
        recoveryTimer = setTimeout(() => {
          if (sessionRecoveryPending()) restoreSession();
        }, delay);
        showSessionRecoveryHint();
        return;
      }
      accessToken = "";
      sessionRetryCount = 0;
      showLogin();
      if (!userSignedOut) setMessage("登录已过期，请重新登录", true, true);
      // 登录页刚出现时只自动再试一次（竞态的另一方可能刚完成轮换）。
      // 必须一次性：令牌确实失效时若无限重试，会每 2 秒轰炸服务器。
      if (!userSignedOut && sessionRecoveryPending() && !loginRetryScheduled) {
        loginRetryScheduled = true;
        setTimeout(() => {
          if (sessionRecoveryPending()) restoreSession();
        }, 2000);
      }
      return;
    }
    authFailCount = 0;
    if (sessionRetryCount < 3) {
      sessionRetryCount += 1;
      await new Promise((resolve) => setTimeout(resolve, 800 * sessionRetryCount));
      return restoreSession();
    }
    sessionRetryCount = 0;
    showOfflineHint(error);
    scheduleRecovery();
  }
}

// 等待态手动重试
function retrySession() {
  if (sessionRecoveryPending()) restoreSession();
}
$("#boot-retry").addEventListener("click", retrySession);

// 回到前台或恢复联网时，只要会话尚未建立就自动重试。
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  if (sessionRecoveryPending()) restoreSession();
});
window.addEventListener("online", () => {
  if (sessionRecoveryPending()) restoreSession();
});

function isoDate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function mondayOfCurrentWeek() {
  const date = new Date();
  const day = date.getDay() || 7;
  date.setDate(date.getDate() - day + 1);
  return isoDate(date);
}

$("#semester-form").start_date.value = mondayOfCurrentWeek();

async function authenticate(path, payload, form) {
  setMessage(path.endsWith("register") ? "正在创建账号…" : "正在安全登录…", false, true);
  try {
    const data = await request(path, { method: "POST", body: JSON.stringify(payload) });
    accessToken = data.access_token;
    form.reset();
    await enterApp(data.user, true);
  } catch (error) {
    setMessage(error.message, true, true);
  } finally {
    const password = form.querySelector('input[type="password"]');
    if (password) password.value = "";
  }
}

$("#login-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  authenticate("/api/auth/login", { account: form.account.value.trim(), password: form.password.value }, form);
});

$("#register-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  authenticate("/api/auth/register", { username: form.username.value.trim(), email: form.email.value.trim(), password: form.password.value }, form);
});

const pageTitles = {
  schedule: ["邗上课表", "我的课表"],
  import: ["安全导入", "导入课表"],
  profile: ["账号与设置", "我的"],
};

function showPage(name) {
  $$(".page").forEach((page) => page.classList.toggle("active", page.id === `${name}-page`));
  $$(".bottom-nav button").forEach((button) => button.classList.toggle("active", button.dataset.page === name));
  $("#page-eyebrow").textContent = pageTitles[name][0];
  $("#page-title").textContent = pageTitles[name][1];
  $("#header-action").classList.toggle("hidden", name !== "schedule");
  document.body.classList.toggle("schedule-active", name === "schedule");
  document.documentElement.classList.toggle("schedule-active", name === "schedule");
}

$$(".bottom-nav button").forEach((button) => button.addEventListener("click", () => showPage(button.dataset.page)));

function activeRows(name) {
  return (cloudSnapshot[name] || []).filter((item) => !item.deleted);
}

function weekNumberForSemester(startDate) {
  const start = new Date(`${startDate}T00:00:00`);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return Math.floor((today - start) / 604800000) + 1;
}

function normalizeCourses(semester) {
  const schedules = activeRows("schedules");
  return activeRows("courses")
    .filter((course) => course.semester_uuid === semester.uuid)
    .map((course) => ({ ...course, slots: schedules.filter((slot) => slot.course_uuid === course.uuid) }));
}

async function loadCloudSchedule(showSuccess = false) {
  try {
    cloudSnapshot = await request("/api/sync/pull?since=0");
    const semesters = activeRows("semesters");
    currentSemester = semesters.find((item) => item.is_current) || semesters.sort((a, b) => b.updated_at - a.updated_at)[0] || null;
    if (!currentSemester) {
      currentCourses = [];
      selectedWeek = 1;
    } else {
      currentCourses = normalizeCourses(currentSemester);
      selectedWeek = Math.min(currentSemester.total_weeks, Math.max(1, weekNumberForSemester(currentSemester.start_date)));
    }
    renderSchedule();
    if (showSuccess) setMessage("已读取云端最新课表");
  } catch (error) {
    setMessage(`课表读取失败：${error.message}`, true);
  }
}

function slotIsActiveInWeek(slot, week) {
  if (week < 1) return false;
  if (slot.weeks_type === 0) return true;
  if (slot.weeks_type === 1) return week % 2 === 1;
  if (slot.weeks_type === 2) return week % 2 === 0;
  return String(slot.custom_weeks || "").split(",").flatMap((piece) => {
    const [start, end] = piece.trim().split("-").map(Number);
    if (!Number.isInteger(start)) return [];
    if (!Number.isInteger(end)) return [start];
    return Array.from({ length: Math.max(0, end - start + 1) }, (_, index) => start + index);
  }).includes(week);
}

function slotsForDay(day) {
  return currentCourses.flatMap((course) => course.slots
    .filter((slot) => slot.day_of_week === day && slotIsActiveInWeek(slot, selectedWeek))
    .map((slot) => ({ course, slot })))
    .sort((a, b) => a.slot.start_section - b.slot.start_section);
}

function dateForWeekDay(day) {
  if (!currentSemester) return null;
  const date = new Date(`${currentSemester.start_date}T00:00:00`);
  date.setDate(date.getDate() + (selectedWeek - 1) * 7 + day - 1);
  return date;
}

// 节次起止时间："08:00" -> "08:00-08:45"（每节 45 分钟）
function sectionTimeRange(section) {
  const times = sectionTimesForWeek();
  const start = times[section - 1];
  if (!start) return "";
  const [hour, minute] = start.split(":").map(Number);
  const endMinutes = hour * 60 + minute + 45;
  const end = `${String(Math.floor(endMinutes / 60)).padStart(2, "0")}:${String(endMinutes % 60).padStart(2, "0")}`;
  return `${start}-${end}`;
}

function sectionTimesForWeek() {
  const month = (dateForWeekDay(1) || new Date()).getMonth() + 1;
  return month >= 5 && month <= 9 ? SECTION_TIMES.summer : SECTION_TIMES.winter;
}

function displayLocation(value) {
  const raw = String(value || "").trim().replace(/\s+/g, " ");
  if (!raw) return "";

  // 教务复制文本的"校区>>楼>>教室"（或 →→ 箭头）分隔格式：楼宇教室放最前，校区放最后
  const parts = raw.split(/>>|→→|＞＞|->|→/).map((part) => part.trim()).filter(Boolean);
  if (parts.length >= 3) {
    return `${parts.slice(1).join("")} · ${parts[0]}`;
  }
  if (parts.length === 2) {
    return `${parts[1]} · ${parts[0]}`;
  }

  const campusPattern = /(扬子津东校区|扬子津西校区|扬子津校区|瘦西湖校区|江阳路北校区|江阳路南校区|荷花池校区|杨子金东校区)/;
  const campusMatch = raw.match(campusPattern);
  const campus = campusMatch ? campusMatch[0].replace("杨子金", "扬子津") : "";
  const withoutCampus = campusMatch
    ? raw.replace(campusMatch[0], "").replace(/^[\s·,，、-]+|[\s·,，、-]+$/g, "")
    : raw;
  const roomMatch = withoutCampus.match(/^(.+?(?:楼|馆|场|中心|实验室))\s*([A-Za-z]?\d{2,4}(?:[-—]\d+)?)?/);
  const room = roomMatch ? `${roomMatch[1]}${roomMatch[2] || ""}` : withoutCampus;
  const remainder = roomMatch
    ? withoutCampus.slice(roomMatch[0].length).replace(/^[\s·,，、-]+|[\s·,，、-]+$/g, "")
    : "";
  return [room, campus, remainder].filter(Boolean).join(" · ");
}

function renderWeekGrid(container) {
  const activeSlots = currentCourses.flatMap((course) => course.slots
    .filter((slot) => slotIsActiveInWeek(slot, selectedWeek))
    .map((slot) => ({ course, slot })));
  const sectionCount = Math.max(12, Math.min(20, ...activeSlots.map(({ slot }) => slot.end_section), 12));
  const grid = document.createElement("div");
  grid.className = "week-grid";
  grid.style.setProperty("--section-count", sectionCount);

  const corner = document.createElement("div");
  corner.className = "week-grid-corner";
  corner.textContent = "节次";
  corner.style.gridColumn = "1";
  corner.style.gridRow = "1";
  grid.append(corner);

  const today = isoDate(new Date());
  DAYS.forEach((name, index) => {
    const day = index + 1;
    const date = dateForWeekDay(day);
    const header = document.createElement("div");
    header.className = "week-grid-day";
    header.style.gridColumn = day + 1;
    header.style.gridRow = "1";
    if (date && isoDate(date) === today) header.classList.add("today");
    const weekday = document.createElement("b");
    weekday.textContent = name.replace("周", "");
    const dayNumber = document.createElement("span");
    dayNumber.textContent = date ? String(date.getDate()) : "";
    header.append(weekday, dayNumber);
    grid.append(header);
  });

  const times = sectionTimesForWeek();
  for (let section = 1; section <= sectionCount; section += 1) {
    const label = document.createElement("div");
    label.className = "week-grid-section";
    label.style.gridColumn = "1";
    label.style.gridRow = section + 1;
    const number = document.createElement("b");
    number.textContent = section;
    const time = document.createElement("span");
    time.textContent = sectionTimeRange(section);
    label.append(number, time);
    grid.append(label);
    for (let day = 1; day <= 7; day += 1) {
      const cell = document.createElement("div");
      cell.className = "week-grid-cell";
      cell.style.gridColumn = day + 1;
      cell.style.gridRow = section + 1;
      grid.append(cell);
    }
  }

  activeSlots.forEach(({ course, slot }) => {
    const start = Math.max(1, Math.min(sectionCount, Number(slot.start_section) || 1));
    const end = Math.max(start, Math.min(sectionCount, Number(slot.end_section) || start));
    const day = Math.max(1, Math.min(7, Number(slot.day_of_week) || 1));
    const palette = COURSE_PALETTES[Math.abs(course.color || 0) % COURSE_PALETTES.length];
    const button = document.createElement("button");
    button.type = "button";
    button.className = "week-course";
    button.style.gridColumn = day + 1;
    button.style.gridRow = `${start + 1} / ${end + 2}`;
    button.style.setProperty("--course-bg", palette.background);
    button.style.setProperty("--course-border", palette.border);
    button.style.setProperty("--course-text", palette.text);
    button.style.setProperty("--course-secondary", palette.secondary);
    const sectionSpan = end - start + 1;
    const titleLength = Array.from(String(course.name || "")).length;
    const titleLines = Math.max(2, Math.min(6, sectionSpan * 2));
    const titleSize = titleLength > 18 ? ".49rem" : titleLength > 12 ? ".54rem" : titleLength > 8 ? ".59rem" : ".66rem";
    button.style.setProperty("--course-title-lines", titleLines);
    button.style.setProperty("--course-title-size", titleSize);
    button.classList.toggle("single-section", sectionSpan === 1);
    const title = document.createElement("strong");
    title.textContent = String(course.name || "").replace(/（/g, "\n（");
    const detail = document.createElement("span");
    const location = displayLocation(slot.location);
    // 单节卡空间小：只显示教师（地点在悬停/长按 title 里）；多节卡显示地点+教师
    const detailText = sectionSpan === 1
      ? (course.teacher || location || `第 ${start}-${end} 节`)
      : ([location, course.teacher].filter(Boolean).join(" · ") || `第 ${start}-${end} 节`);
    detail.textContent = detailText;
    button.append(title, detail);
    button.title = [course.name, slot.location, course.teacher].filter(Boolean).join(" · ");
    button.setAttribute("aria-label", `${course.name}，${DAYS[day - 1]}第 ${start}-${end} 节${detail.textContent ? `，${detail.textContent}` : ""}`);
    button.addEventListener("click", () => showCourseDetail(course.uuid));
    grid.append(button);
  });

  container.append(grid);
}

function courseSlotButton(course, slot) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "slot-card";
  const color = document.createElement("i");
  color.className = "slot-color";
  color.style.background = COLORS[Math.abs(course.color || 0) % COLORS.length];
  const main = document.createElement("span");
  main.className = "slot-main";
  const title = document.createElement("strong");
  title.textContent = course.name;
  const detail = document.createElement("span");
  const location = displayLocation(slot.location);
  detail.textContent = [location, course.teacher || "教师待补充"].filter(Boolean).join(" · ");
  main.append(title, detail);
  const time = document.createElement("span");
  time.className = "slot-time";
  const startTime = sectionTimeRange(slot.start_section).split("-")[0];
  const endTime = sectionTimeRange(slot.end_section).split("-")[1];
  time.textContent = `第 ${slot.start_section}-${slot.end_section} 节${startTime ? ` ${startTime}-${endTime}` : ""}`;
  button.append(color, main, time);
  button.title = [course.name, slot.location, course.teacher].filter(Boolean).join(" · ");
  button.addEventListener("click", () => showCourseDetail(course.uuid));
  return button;
}

function renderDaySelector() {
  const selector = $("#day-selector");
  selector.replaceChildren(...DAYS.map((name, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = name.replace("周", "");
    button.classList.toggle("active", selectedDay === index + 1);
    button.addEventListener("click", () => { selectedDay = index + 1; renderSchedule(); });
    return button;
  }));
}

function renderScheduleHeader() {
  $("#semester-name").textContent = currentSemester?.name || "尚未设置学期";
  $("#semester-meta").textContent = currentSemester ? `${currentSemester.start_date} 开学 · ${currentSemester.total_weeks} 周` : "点此设置";
  $("#week-label").textContent = `第 ${selectedWeek} 周`;
  const weekStart = dateForWeekDay(1);
  const weekEnd = dateForWeekDay(7);
  $("#week-range").textContent = weekStart && weekEnd ? `${weekStart.getMonth() + 1}/${weekStart.getDate()}–${weekEnd.getMonth() + 1}/${weekEnd.getDate()}` : "";
  $("#prev-week").disabled = !currentSemester || selectedWeek <= 1;
  $("#next-week").disabled = !currentSemester || selectedWeek >= currentSemester.total_weeks;
  $("#day-selector").classList.toggle("hidden", viewMode !== "day");
  renderDaySelector();
}

function renderSchedule() {
  renderScheduleHeader();
  const container = $("#schedule-list");
  container.classList.remove("week-slide-out-next", "week-slide-out-prev");
  container.replaceChildren();
  container.classList.toggle("week-grid-host", viewMode === "week");
  const hasCourses = Boolean(currentSemester && currentCourses.length);
  $("#schedule-empty").classList.toggle("hidden", hasCourses);
  if (!hasCourses) return;
  if (viewMode === "week") {
    renderWeekGrid(container);
    applyScheduleAnimation(container);
    return;
  }
  const days = viewMode === "day" ? [selectedDay] : [1, 2, 3, 4, 5, 6, 7];
  days.forEach((day) => {
    const group = document.createElement("section");
    group.className = "day-group";
    const heading = document.createElement("h3");
    heading.textContent = DAYS[day - 1];
    group.append(heading);
    const slots = slotsForDay(day);
    if (!slots.length) {
      const empty = document.createElement("div");
      empty.className = "empty-day";
      empty.textContent = "本周无课";
      group.append(empty);
    } else slots.forEach(({ course, slot }) => group.append(courseSlotButton(course, slot)));
    container.append(group);
  });
  applyScheduleAnimation(container);
}

function applyScheduleAnimation(container) {
  if (!scheduleAnimationDirection) return;
  const className = scheduleAnimationDirection > 0 ? "week-slide-next" : "week-slide-prev";
  scheduleAnimationDirection = 0;
  container.classList.remove("week-slide-next", "week-slide-prev");
  void container.offsetWidth;
  container.classList.add(className);
}

let slideOutTimer = null;

function changeWeek(delta) {
  if (!currentSemester) return;
  const target = selectedWeek + delta;
  if (target < 1 || target > currentSemester.total_weeks) return;
  if (slideOutTimer) { clearTimeout(slideOutTimer); slideOutTimer = null; }
  scheduleAnimationDirection = delta;
  selectedWeek = target;
  renderScheduleHeader();
  const container = $("#schedule-list");
  // 双段切换：旧内容先滑出 140ms，再渲染新内容并滑入；空课表直接渲染
  if (currentCourses.length && container.childElementCount) {
    container.classList.remove("week-slide-out-next", "week-slide-out-prev");
    container.classList.add(delta > 0 ? "week-slide-out-next" : "week-slide-out-prev");
    slideOutTimer = setTimeout(() => { slideOutTimer = null; renderSchedule(); }, 140);
    return;
  }
  renderSchedule();
}

$$("[data-view-mode]").forEach((button) => button.addEventListener("click", () => {
  viewMode = button.dataset.viewMode;
  $$("[data-view-mode]").forEach((item) => item.classList.toggle("active", item === button));
  renderSchedule();
}));
$("#prev-week").addEventListener("click", () => changeWeek(-1));
$("#next-week").addEventListener("click", () => changeWeek(1));
$("#today-button").addEventListener("click", () => {
  if (!currentSemester) return;
  const target = Math.min(currentSemester.total_weeks, Math.max(1, weekNumberForSemester(currentSemester.start_date)));
  scheduleAnimationDirection = Math.sign(target - selectedWeek);
  selectedWeek = target;
  closeDialog("schedule-menu-dialog");
  renderSchedule();
});

let swipeStart = null;
$("#schedule-list").addEventListener("pointerdown", (event) => {
  if (event.target.closest("button")) return;
  swipeStart = { x: event.clientX, y: event.clientY };
});
$("#schedule-list").addEventListener("pointerup", (event) => {
  if (!swipeStart) return;
  const deltaX = event.clientX - swipeStart.x;
  const deltaY = event.clientY - swipeStart.y;
  swipeStart = null;
  if (Math.abs(deltaX) < 44 || Math.abs(deltaX) <= Math.abs(deltaY) * 1.2) return;
  changeWeek(deltaX < 0 ? 1 : -1);
});
$("#schedule-list").addEventListener("pointercancel", () => { swipeStart = null; });

function showDialog(id) { document.getElementById(id).showModal(); }

// 统一关闭动画：加 .closing 播退场动画，动画结束（或 240ms 兜底）后真正 close()。
function closeDialog(target) {
  const dialog = typeof target === "string" ? document.getElementById(target) : target;
  if (!dialog || !dialog.open || dialog.classList.contains("closing")) return;
  dialog.classList.add("closing");
  let done = false;
  const finish = () => {
    if (done) return;
    done = true;
    dialog.removeEventListener("animationend", onEnd);
    dialog.classList.remove("closing");
    dialog.close();
  };
  const onEnd = (event) => { if (event.target === dialog) finish(); };
  dialog.addEventListener("animationend", onEnd);
  setTimeout(finish, 240);
}
$$("[data-close]").forEach((button) => button.addEventListener("click", () => closeDialog(button.dataset.close)));
$$("dialog").forEach((dialog) => {
  // Esc（cancel）与背板点击也走同一套退场动画
  dialog.addEventListener("cancel", (event) => { event.preventDefault(); closeDialog(dialog); });
  dialog.addEventListener("click", (event) => { if (event.target === dialog) closeDialog(dialog); });
});

// ---- 课表管理（多课表：列表 / 切换 / 新建 / 编辑 / 删除）----

let editingSemesterUuid = "";

function renderSemesterList() {
  const container = $("#semester-list");
  const semesters = activeRows("semesters").sort((a, b) => b.updated_at - a.updated_at);
  container.replaceChildren();
  if (!semesters.length) {
    const empty = document.createElement("p");
    empty.className = "subtle";
    empty.textContent = "还没有课表，点上方「＋ 新建课表」开始";
    container.append(empty);
    return;
  }
  for (const sem of semesters) {
    const row = document.createElement("button");
    row.type = "button";
    row.className = "setting-row" + (sem.uuid === currentSemester?.uuid ? " semester-current" : "");
    const courseCount = activeRows("courses").filter((course) => course.semester_uuid === sem.uuid).length;
    const info = document.createElement("div");
    const strong = document.createElement("strong");
    strong.textContent = sem.name + (sem.uuid === currentSemester?.uuid ? " ✓ 当前" : "");
    const small = document.createElement("small");
    small.textContent = `${sem.start_date} 开学 · ${sem.total_weeks} 周 · ${courseCount} 门课`;
    info.append(strong, small);
    row.append(info);
    if (sem.uuid !== currentSemester?.uuid) {
      const activate = document.createElement("button");
      activate.type = "button";
      activate.className = "text-button";
      activate.textContent = "设为当前";
      activate.addEventListener("click", (event) => {
        event.stopPropagation();
        switchCurrentSemester(sem);
      });
      row.append(activate);
    }
    const arrow = document.createElement("b");
    arrow.textContent = "›";
    row.append(arrow);
    row.addEventListener("click", () => fillSemesterForm(sem));
    container.append(row);
  }
}

function switchCurrentSemester(semester) {
  const now = Date.now();
  const changes = activeRows("semesters")
    .filter((item) => item.is_current && item.uuid !== semester.uuid)
    .map((item, index) => ({ ...item, is_current: false, updated_at: now + index }));
  changes.push({ ...semester, is_current: true, updated_at: now + changes.length + 1 });
  request("/api/sync/push", { method: "POST", body: JSON.stringify({ semesters: changes, courses: [], schedules: [] }) })
    .then(() => loadCloudSchedule())
    .then(() => setMessage(`已切换到「${semester.name}」`))
    .catch((error) => setMessage(error.message, true));
}

function fillSemesterForm(semester) {
  editingSemesterUuid = semester ? semester.uuid : "";
  const form = $("#semester-form");
  form.name.value = semester?.name || "";
  form.start_date.value = semester?.start_date || mondayOfCurrentWeek();
  form.total_weeks.value = semester?.total_weeks || 20;
  $("#semester-form-title").textContent = semester ? "编辑课表" : "新建课表";
  $("#delete-semester-button").classList.toggle("hidden", !semester || activeRows("semesters").length <= 1);
}

function openSemesterDialog() {
  closeDialog("schedule-menu-dialog");
  renderSemesterList();
  fillSemesterForm(currentSemester);
  showDialog("semester-dialog");
}
$("#export-calendar").addEventListener("click", exportToCalendar);
$("#semester-button").addEventListener("click", openSemesterDialog);
$("#new-semester-button").addEventListener("click", () => fillSemesterForm(null));

$("#semester-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const now = Date.now();
  const semesters = activeRows("semesters")
    .filter((item) => item.is_current && item.uuid !== editingSemesterUuid)
    .map((item, index) => ({ ...item, is_current: false, updated_at: now + index }));
  const semester = {
    ...(editingSemesterUuid ? activeRows("semesters").find((item) => item.uuid === editingSemesterUuid) : {}),
    uuid: editingSemesterUuid || crypto.randomUUID(),
    name: form.name.value.trim(),
    start_date: form.start_date.value,
    total_weeks: Number(form.total_weeks.value),
    is_current: true,
    updated_at: now + semesters.length + 1,
    deleted: false,
  };
  semesters.push(semester);
  try {
    await request("/api/sync/push", { method: "POST", body: JSON.stringify({ semesters, courses: [], schedules: [] }) });
    closeDialog("semester-dialog");
    await loadCloudSchedule();
    setMessage("课表已保存并设为当前");
  } catch (error) { setMessage(error.message, true); }
});

$("#delete-semester-button").addEventListener("click", async () => {
  const semester = activeRows("semesters").find((item) => item.uuid === editingSemesterUuid);
  if (!semester) return;
  const courseCount = activeRows("courses").filter((course) => course.semester_uuid === semester.uuid).length;
  if (!confirm(`删除课表「${semester.name}」？其 ${courseCount} 门课程与全部排课将一并删除，且会同步到其他设备。`)) return;
  const now = Date.now();
  const semesters = [{ ...semester, deleted: true, updated_at: now }];
  const courses = activeRows("courses")
    .filter((course) => course.semester_uuid === semester.uuid)
    .map((course, index) => ({ ...course, slots: undefined, deleted: true, updated_at: now + index + 1 }));
  const courseUuids = new Set(courses.map((course) => course.uuid));
  const schedules = activeRows("schedules")
    .filter((slot) => courseUuids.has(slot.course_uuid))
    .map((slot, index) => ({ ...slot, deleted: true, updated_at: now + courses.length + index + 1 }));
  try {
    await request("/api/sync/push", { method: "POST", body: JSON.stringify({ semesters, courses, schedules }) });
    closeDialog("semester-dialog");
    await loadCloudSchedule();
    setMessage(`课表「${semester.name}」已删除`);
  } catch (error) { setMessage(error.message, true); }
});

function _weekTypeLabel(slot) {
  if (slot.weeks_type === 0) return "每周";
  if (slot.weeks_type === 1) return "单周";
  if (slot.weeks_type === 2) return "双周";
  return "自定义 " + (slot.custom_weeks || "");
}


// HTML 转义：课程详情等 innerHTML 渲染前的必备防护（教师/备注/地点均可含用户输入）。
function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[ch]);
}

function showCourseDetail(courseUuid) {
  const course = currentCourses.find((item) => item.uuid === courseUuid);
  if (!course) return;
  $("#course-detail-title").textContent = course.name || "课程详情";
  const body = $("#course-detail-body");
  const slots = course.slots || [];
  let html = "";
  if (course.teacher) html += "<p style='margin:4px 0'><b>教师：</b>" + esc(course.teacher) + "</p>";
  if (course.note) html += "<p style='margin:4px 0;opacity:.7;font-size:.88rem'><b>备注：</b>" + esc(course.note) + "</p>";
  if (slots.length) {
    html += "<div style='margin:10px 0 4px'><b>上课时间</b></div>";
    slots.forEach(function(slot) {
      const day = DAYS[(slot.day_of_week || 1) - 1];
      const sec = sectionTimeRange(slot.start_section) || (slot.start_section + "-" + slot.end_section + "节");
      const loc = displayLocation(slot.location) || slot.location || "";
      const wt = _weekTypeLabel(slot);
      html += "<div style='padding:6px 0;border-top:1px solid var(--line);font-size:.92rem'>"
        + day + " " + sec + " · " + wt
        + (loc ? "<br><small style='opacity:.7'>" + esc(loc) + "</small>" : "")
        + "</div>";
    });
  }
  body.innerHTML = html || "<p style='opacity:.6'>暂无详细信息</p>";
  // 编辑按钮
  $("#detail-edit-course").onclick = function() {
    closeDialog("course-detail-dialog");
    openCourseDialog(courseUuid);
  };
  // 删除按钮
  $("#detail-delete-course").onclick = async function() {
    if (!confirm("\u786e\u5b9a\u6c38\u4e45\u5220\u9664\u201c" + (course.name || "") + "\u201d\u5417\uff1f\u6b64\u64cd\u4f5c\u4f1a\u540c\u6b65\u5230\u5176\u4ed6\u8bbe\u5907\u3002")) return;
    const now = Date.now();
    const courseDelete = Object.assign({}, course, { deleted: true, updated_at: now });
    delete courseDelete.slots;
    const scheduleDeletes = (course.slots || []).map(function(slot, index) {
      return Object.assign({}, slot, { deleted: true, updated_at: now + index + 1 });
    });
    try {
      await request("/api/sync/push", { method: "POST", body: JSON.stringify({ semesters: [], courses: [courseDelete], schedules: scheduleDeletes }) });
      closeDialog("course-detail-dialog");
      await loadCloudSchedule();
      setMessage("\u8bfe\u7a0b\u5df2\u5220\u9664");
    } catch (error) { setMessage(error.message, true); }
  };
  showDialog("course-detail-dialog");
}

function openCourseDialog(courseUuid = "") {
  if (!currentSemester) return openSemesterDialog();
  const form = $("#course-form");
  form.reset();
  $("#course-slot-list").replaceChildren();
  const course = currentCourses.find((item) => item.uuid === courseUuid);
  form.course_uuid.value = course?.uuid || "";
  $("#course-dialog-title").textContent = course ? "编辑课程" : "添加课程";
  $("#delete-course").classList.toggle("hidden", !course);
  if (course) {
    form.name.value = course.name;
    form.teacher.value = course.teacher || "";
    form.note.value = course.note || "";
    course.slots.forEach((slot) => addCourseSlotEditor(slot));
  }
  if (!course?.slots.length) addCourseSlotEditor();
  showDialog("course-dialog");
}
$("#header-action").addEventListener("click", () => showDialog("schedule-menu-dialog"));
$("#menu-add-course").addEventListener("click", () => { closeDialog("schedule-menu-dialog"); openCourseDialog(); });
$("#empty-add").addEventListener("click", () => openCourseDialog());
$("#add-slot").addEventListener("click", () => addCourseSlotEditor());

function addCourseSlotEditor(slot = null) {
  const editor = document.createElement("section");
  editor.className = "course-slot-editor";
  editor.dataset.uuid = slot?.uuid || "";
  const dayOptions = DAYS.map((name, index) => `<option value="${index + 1}">${name}</option>`).join("");
  editor.innerHTML = `<div class="form-row"><label>星期<select data-field="day_of_week">${dayOptions}</select></label><label>周次<select data-field="weeks_type"><option value="0">每周</option><option value="1">单周</option><option value="2">双周</option><option value="3">自定义</option></select></label></div><div class="form-row"><label>开始节次<input data-field="start_section" type="number" min="1" max="20" value="1" required /></label><label>结束节次<input data-field="end_section" type="number" min="1" max="20" value="2" required /></label></div><label>自定义周次<input data-field="custom_weeks" placeholder="例如 1-8,10,12" /></label><label>地点<input data-field="location" maxlength="255" /></label><button class="text-button remove-slot" type="button">删除此段</button>`;
  if (slot) {
    editor.querySelector('[data-field="day_of_week"]').value = slot.day_of_week;
    editor.querySelector('[data-field="weeks_type"]').value = slot.weeks_type;
    editor.querySelector('[data-field="start_section"]').value = slot.start_section;
    editor.querySelector('[data-field="end_section"]').value = slot.end_section;
    editor.querySelector('[data-field="custom_weeks"]').value = slot.custom_weeks || "";
    editor.querySelector('[data-field="location"]').value = displayLocation(slot.location);
  }
  editor.querySelector(".remove-slot").addEventListener("click", () => {
    if ($$(".course-slot-editor").length <= 1) return setMessage("至少需要一个上课时间段", true);
    editor.remove();
  });
  $("#course-slot-list").append(editor);
}

$("#course-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const editors = $$(".course-slot-editor");
  if (!editors.length) return setMessage("至少需要一个上课时间段", true);
  if (editors.some((editor) => Number(editor.querySelector('[data-field="end_section"]').value) < Number(editor.querySelector('[data-field="start_section"]').value))) return setMessage("结束节次不能早于开始节次", true);
  const existing = currentCourses.find((item) => item.uuid === form.course_uuid.value);
  const now = Date.now();
  const courseUuid = existing?.uuid || crypto.randomUUID();
  const course = { uuid: courseUuid, semester_uuid: currentSemester.uuid, name: form.name.value.trim(), teacher: form.teacher.value.trim(), color: existing?.color || currentCourses.length % COLORS.length, note: form.note.value.trim(), updated_at: now, deleted: false };
  const activeSlotIds = new Set();
  const schedules = editors.map((editor, index) => {
    const uuid = editor.dataset.uuid || crypto.randomUUID();
    activeSlotIds.add(uuid);
    const field = (name) => editor.querySelector(`[data-field="${name}"]`).value;
    return { uuid, course_uuid: courseUuid, day_of_week: Number(field("day_of_week")), start_section: Number(field("start_section")), end_section: Number(field("end_section")), weeks_type: Number(field("weeks_type")), custom_weeks: field("custom_weeks").trim(), location: field("location").trim(), updated_at: now + index + 1, deleted: false };
  });
  (existing?.slots || []).filter((slot) => !activeSlotIds.has(slot.uuid)).forEach((slot, index) => schedules.push({ ...slot, updated_at: now + editors.length + index + 1, deleted: true }));
  try {
    await request("/api/sync/push", { method: "POST", body: JSON.stringify({ semesters: [], courses: [course], schedules }) });
    closeDialog("course-dialog");
    await loadCloudSchedule();
    setMessage(existing ? "课程已更新" : "课程已添加");
  } catch (error) { setMessage(error.message, true); }
});

$("#delete-course").addEventListener("click", async () => {
  const uuid = $("#course-form").course_uuid.value;
  const course = currentCourses.find((item) => item.uuid === uuid);
  if (!course || !confirm(`确定永久删除“${course.name}”吗？此操作会同步到其他设备。`)) return;
  const now = Date.now();
  const courseDelete = { ...course, slots: undefined, deleted: true, updated_at: now };
  delete courseDelete.slots;
  const scheduleDeletes = course.slots.map((slot, index) => ({ ...slot, deleted: true, updated_at: now + index + 1 }));
  try {
    await request("/api/sync/push", { method: "POST", body: JSON.stringify({ semesters: [], courses: [courseDelete], schedules: scheduleDeletes }) });
    closeDialog("course-dialog");
    await loadCloudSchedule();
    setMessage("课程已删除");
  } catch (error) { setMessage(error.message, true); }
});

function weeksForSync(text) {
  const value = String(text || "");
  const numbers = [...value.matchAll(/\d+/g)].map((match) => Number(match[0]));
  if (value.includes("单")) return { weeks_type: 1, custom_weeks: "" };
  if (value.includes("双")) return { weeks_type: 2, custom_weeks: "" };
  if (!numbers.length) return { weeks_type: 0, custom_weeks: "" };
  const weeks = numbers.length === 2 && numbers[1] >= numbers[0] ? `${numbers[0]}-${numbers[1]}` : [...new Set(numbers)].join(",");
  return { weeks_type: 3, custom_weeks: weeks };
}

function renderCourseList(container, courses) {
  container.replaceChildren(...courses.map((course) => {
    const item = document.createElement("article");
    item.className = "course";
    const name = document.createElement("strong");
    name.textContent = course.name;
    const detail = document.createElement("span");
    detail.textContent = `${course.teacher || "教师待补充"} · ${(course.slots || []).map((slot) => `${DAYS[slot.day_of_week - 1]} 第${slot.start_section}-${slot.end_section}节${slot.location ? ` · ${displayLocation(slot.location)}` : ""}`).join("；") || "时间待补充"}`;
    item.append(name, detail);
    return item;
  }));
}

// 服务器代抓导入已于 2026-09 下线：服务器不接收、不存储学号/教务密码/课表页面。
// 课表导入只保留两条路径：手动粘贴解析（本地完成）与口令导入（同学分享）。

// ---- iPhone 手动导入（Safari 直连 VPN 后复制课表文本回来解析）----

// 宽松解析 WebVPN 课表页复制文本：逐行识别"课程名 + 星期 + 节次(+地点)"。
// 页面格式可能随学校改版变化；无法识别的行会计数并在预览中提示，便于
// 收集真实样本后迭代（对应 Android 端 yzu_parser 的思路）。
const MANUAL_DAY_MAP = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 7, 天: 7 };

function parseManualText(text) {
  const lines = String(text || "").split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  // 教务系统"本学期课表"复制文本是块状结构（课程名 | 编号_学分 起块）；
  // 优先块状解析，无块状特征时回退到逐行宽松解析。
  const courseBlockRe = /^(.+?)\s*\|\s*[0-9A-Za-z]+_\d+学分$/;
  if (lines.some((line) => courseBlockRe.test(line))) {
    return parseManualBlocks(lines, courseBlockRe);
  }
  return parseManualLines(lines);
}

function parseManualBlocks(lines, courseBlockRe) {
  const courses = [];
  let unrecognized = 0;
  let i = 0;
  while (i < lines.length) {
    const match = lines[i].match(courseBlockRe);
    if (!match) { i += 1; continue; }
    const name = match[1].trim();
    i += 1;
    const block = [];
    while (i < lines.length && !courseBlockRe.test(lines[i]) && !/^(实习课安排|实验课安排)/.test(lines[i])) {
      block.push(lines[i]);
      i += 1;
    }
    const parsed = parseManualBlock(name, block);
    if (parsed.slots.length) courses.push(parsed);
    else unrecognized += 1;
  }
  return { courses, unrecognized };
}

function parseManualBlock(name, block) {
  // 教师：含 * 的行（"教师F*"、"段伟丽* 外教5 张倩"）
  const teacherLine = block.find((line) => line.includes("*"));
  const teachers = teacherLine ? teacherLine.replace(/\*/g, "").split(/\s+/).filter(Boolean) : [];
  // 节次行与地点行分组收集、按序一一对应：
  // 节次行 "1-18周>>星期四>>9-10节"（一节课可多行），地点行 "扬子津东校区>>文津楼>>E206"
  const slotRe = /^(\d+(?:-\d+)?周)>>星期([一二三四五六日])>>(\d+)-(\d+)节$/;
  const locationRe = /^(.+?)(?:>>|→→|＞＞)(.+?)(?:>>|→→|＞＞)(.+)$/;
  const slotLines = [];
  const locationLines = [];
  for (const line of block) {
    const m = line.match(slotRe);
    if (m) {
      slotLines.push(m);
    } else if (locationRe.test(line) && !line.includes("周") && !line.includes("节")) {
      locationLines.push(line);
    }
  }
  const slots = slotLines.map((m, idx) => ({
    day_of_week: MANUAL_DAY_MAP[m[2]],
    start_section: Number(m[3]),
    end_section: Number(m[4]),
    weeks_text: m[1],
    location: locationLines[idx] || "",
  }));
  return { name, teacher: teachers.join(" "), slots };
}

function parseManualLines(lines) {
  // 逐行宽松解析兜底（非教务系统块状文本）
  const groups = new Map();
  let unrecognized = 0;
  for (const line of lines) {
    if (/^(首页|退出|登录|欢迎|返回|教务|学生|教师|学期|周次|作息|第\s*\d+\s*周|扬大|扬州大学|©|温馨提示|通知|公告)/.test(line)) continue;
    const parsed = parseManualLine(line);
    if (!parsed) { unrecognized += 1; continue; }
    const key = parsed.name + "||" + parsed.teacher;
    if (!groups.has(key)) groups.set(key, { name: parsed.name, teacher: parsed.teacher, slots: [] });
    groups.get(key).slots.push(...parsed.slots);
  }
  return { courses: [...groups.values()], unrecognized };
}

function parseManualLine(line) {
  const dayMatch = line.match(/(?:周|星期)([一二三四五六日天]|\d)/);
  if (!dayMatch) return null;
  const dayOfWeek = MANUAL_DAY_MAP[dayMatch[1]] || Number(dayMatch[1]);
  if (!dayOfWeek || dayOfWeek < 1 || dayOfWeek > 7) return null;
  const sectionMatch = line.match(/(?:第)?(\d{1,2})\s*[-—~至]\s*(\d{1,2})\s*节?/);
  if (!sectionMatch) return null;
  const start = Number(sectionMatch[1]);
  const end = Number(sectionMatch[2]);
  if (start < 1 || end < start || end > 14) return null;
  const dayIndex = line.search(/(?:周|星期)[一二三四五六日天\d]/);
  let head = line.slice(0, dayIndex).trim().replace(/^[·\-\d\s、]+/, "");
  const name = head.replace(/^(第\d+[课节]|课程[:：]|课名[:：])/, "").trim() || "未命名课程";
  const locationMatch = line.match(/(?:文津|文经|扬子津|瘦西湖|荷花池|江阳路|昭文馆|图书馆|教学楼|实验楼)[^\s]*|[A-Za-z0-9]*楼\d*[A-Za-z0-9]*|N\d+|A\d+|B\d+|C\d+/);
  return {
    name,
    teacher: "",
    slots: [{ day_of_week: dayOfWeek, start_section: start, end_section: end, weeks_text: "", location: locationMatch ? locationMatch[0] : "" }],
  };
}

const VPN_URL = "https://webvpn.yzu.edu.cn/login?cas_login=true";
let vpnHintTimer = null;

function hideVpnHint() {
  if (vpnHintTimer) { clearTimeout(vpnHintTimer); vpnHintTimer = null; }
  $("#vpn-fallback-hint").classList.add("hidden");
}

$("#open-vpn-button").addEventListener("click", async () => {
  window.open(VPN_URL, "_blank", "noopener");
  // 点击的同时把链接复制到剪贴板，跳转被拦截也能直接粘贴打开
  let copied = false;
  try { await navigator.clipboard.writeText(VPN_URL); copied = true; } catch { /* 无剪贴板权限时仅靠下方提示复制 */ }
  setMessage(copied
    ? "已打开 VPN 登录页，链接已复制（没跳转就粘贴到浏览器地址栏打开）；登录 → 教务系统学生端 → 课表页全选拷贝，再回本页粘贴"
    : "已在新的标签页打开 VPN 登录页：登录 → 教务系统学生端 → 课表页全选拷贝，再回到本页粘贴");
  // 2 秒后粘贴框仍空白（可能没跳转过去）→ 提示可自行复制链接
  hideVpnHint();
  vpnHintTimer = setTimeout(() => {
    vpnHintTimer = null;
    if (!$("#manual-import-form").manual_text.value.trim()) {
      $("#vpn-fallback-hint").classList.remove("hidden");
    }
  }, 2000);
});

$("#copy-vpn-link").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(VPN_URL);
    setMessage("链接已复制，请在浏览器地址栏粘贴打开");
  } catch {
    setMessage(`请手动复制链接：${VPN_URL}`, true);
  }
});
// 用户一旦开始粘贴/输入或提交解析，提示即不再需要
$("#manual-import-form").manual_text.addEventListener("input", hideVpnHint);
$("#manual-import-form").addEventListener("submit", hideVpnHint);

$("#manual-import-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const text = form.manual_text.value.trim();
  if (!text) return setMessage("请先粘贴课表内容", true);
  const { courses, unrecognized } = parseManualText(text);
  if (!courses.length) {
    setMessage("未能从粘贴内容中识别出课程。请确认拷贝的是课表页面内容（每行需含课程名、星期与节次）", true);
    return;
  }
  educationPreview = {
    courses,
    semester: { name: form.semester_name.value.trim(), start_date: form.semester_start.value, total_weeks: Number(form.total_weeks.value) },
  };
  renderCourseList($("#education-course-list"), courses);
  $("#education-preview-card").classList.remove("hidden");
  const note = unrecognized > 0 ? "；另有 " + unrecognized + " 行未能识别（可把样本发给我们校准）" : "";
  setMessage("已识别 " + courses.length + " 门课程" + note);
  $("#education-preview-card").scrollIntoView({ behavior: "smooth", block: "start" });
});

$("#save-education-button").addEventListener("click", async () => {
  if (!educationPreview) return;
  const now = Date.now();
  const semesterUuid = crypto.randomUUID();
  const semesters = activeRows("semesters").filter((item) => item.is_current).map((item, index) => ({ ...item, is_current: false, updated_at: now + index }));
  semesters.push({ uuid: semesterUuid, ...educationPreview.semester, is_current: true, updated_at: now + semesters.length + 1, deleted: false });
  const courses = [];
  const schedules = [];
  educationPreview.courses.forEach((item, courseIndex) => {
    const courseUuid = crypto.randomUUID();
    courses.push({ uuid: courseUuid, semester_uuid: semesterUuid, name: item.name, teacher: item.teacher || "", color: courseIndex % COLORS.length, note: "", updated_at: now + 100 + courseIndex, deleted: false });
    (item.slots || []).forEach((slot, slotIndex) => schedules.push({ uuid: crypto.randomUUID(), course_uuid: courseUuid, day_of_week: slot.day_of_week, start_section: slot.start_section, end_section: slot.end_section, ...weeksForSync(slot.weeks_text), location: slot.location || "", updated_at: now + 1000 + courseIndex * 10 + slotIndex, deleted: false }));
  });
  try {
    await request("/api/sync/push", { method: "POST", body: JSON.stringify({ semesters, courses, schedules }) });
    educationPreview = null;
    $("#education-preview-card").classList.add("hidden");
    await loadCloudSchedule();
    showPage("schedule");
    setMessage("课表已保存，并可与 Android 同步");
  } catch (error) { setMessage(error.message, true); }
});

$("#share-code").addEventListener("input", (event) => { event.target.value = event.target.value.toUpperCase().replace(/[^A-Z2-9]/g, ""); });
$("#code-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  activeShareCode = $("#share-code").value.trim();
  if (activeShareCode.length !== 6) return setMessage("请输入完整的 6 位口令", true);
  try {
    sharePreview = await request(`/api/share/${encodeURIComponent(activeShareCode)}`);
    $("#preview-title").textContent = `${sharePreview.payload.semester.name} · 课表预览`;
    $("#preview-meta").textContent = `${sharePreview.payload.courses.length} 门课程 · 有效期至 ${new Date(sharePreview.expires_at).toLocaleString("zh-CN")}`;
    renderCourseList($("#share-course-list"), sharePreview.payload.courses);
    $("#share-preview-card").classList.remove("hidden");
  } catch (error) { setMessage(error.message, true); }
});

async function claimShare(replaceExisting) {
  try {
    const data = await request(`/api/share/${encodeURIComponent(activeShareCode)}/claim`, { method: "POST", body: JSON.stringify({ replace_existing: replaceExisting }) });
    $("#share-preview-card").classList.add("hidden");
    await loadCloudSchedule();
    showPage("schedule");
    setMessage(`已导入 ${data.course_count} 门课程`);
  } catch (error) {
    if (!replaceExisting && /已有同一学期/.test(error.message) && confirm("你已有同一学期的课表，是否覆盖？")) return claimShare(true);
    setMessage(error.message, true);
  }
}
$("#claim-button").addEventListener("click", () => claimShare(false));

$("#share-button").addEventListener("click", async () => {
  if (!currentSemester) return setMessage("请先导入或创建学期", true);
  if (!currentCourses.length) return setMessage("当前课表还没有课程，先添加课程再分享", true);
  try {
    const data = await request("/api/share/create", { method: "POST", body: JSON.stringify({ semester_uuid: currentSemester.uuid }) });
    $("#created-share-code").textContent = data.code;
    showDialog("share-dialog");
  } catch (error) { setMessage(error.message, true); }
});
$("#copy-share-code").addEventListener("click", async () => {
  const code = $("#created-share-code").textContent;
  try { await navigator.clipboard.writeText(code); setMessage("口令已复制"); } catch { setMessage(`请手动复制口令：${code}`); }
});

// 手表配对：生成 6 位数字配对码（Vela 手表「邗上课表」登录页输入领取）
$("#pair-button").addEventListener("click", async () => {
  try {
    const data = await request("/api/auth/device-pair", { method: "POST" });
    $("#pair-code-display").textContent = data.code;
    showDialog("pair-dialog");
  } catch (error) { setMessage(error.message, true); }
});
$("#copy-pair-code").addEventListener("click", async () => {
  const code = $("#pair-code-display").textContent;
  try { await navigator.clipboard.writeText(code); setMessage("配对码已复制"); } catch { setMessage(`请手动输入配对码：${code}`); }
});
$("#pair-regenerate").addEventListener("click", async () => {
  try {
    const data = await request("/api/auth/device-pair", { method: "POST" });
    $("#pair-code-display").textContent = data.code;
    setMessage("已重新生成配对码");
  } catch (error) { setMessage(error.message, true); }
});

$("#refresh-button").addEventListener("click", () => loadCloudSchedule(true));

function aboutMediaUrl(name) {
  return API_BASE + "/api/about/media/" + encodeURIComponent(name);
}

async function loadAbout() {
  const loading = $("#about-loading");
  const content = $("#about-content");
  const retry = $("#about-retry");
  loading.textContent = "正在读取最新介绍…";
  loading.classList.remove("hidden");
  content.classList.add("hidden");
  retry.classList.add("hidden");
  try {
    const data = await request("/api/about");
    $("#about-name").textContent = data.display_name || "邗上课表";
    $("#about-row-summary").textContent = data.display_name || "开发者介绍与支持信息";

    // 关于页显示当前 App 版本（接口失败时隐藏版本行）
    try {
      const version = await request("/api/version/latest");
      const versionRow = $("#about-version");
      versionRow.textContent = `版本 ${version.version_name || ""}`.trim();
      versionRow.classList.toggle("hidden", !version.version_name);
    } catch { /* version row stays hidden */ }

    const avatar = $("#about-avatar");
    avatar.src = data.avatar_media ? aboutMediaUrl(data.avatar_media) : "./icon-192.png";

    const intro = $("#about-intro");
    intro.textContent = data.intro || "";
    intro.classList.toggle("hidden", !data.intro);

    const website = $("#about-website");
    let websiteUrl = null;
    try {
      const candidate = new URL(data.website_url || "");
      if (candidate.protocol === "https:") websiteUrl = candidate.href;
    } catch { /* Invalid or empty URLs stay hidden. */ }
    if (websiteUrl) website.href = websiteUrl;
    else website.removeAttribute("href");
    website.classList.toggle("hidden", !websiteUrl);

    const payment = $("#about-payment");
    const paymentQr = $("#about-payment-qr");
    if (data.payment_qr_media) paymentQr.src = aboutMediaUrl(data.payment_qr_media);
    else paymentQr.removeAttribute("src");
    payment.classList.toggle("hidden", !data.payment_qr_media);

    loading.classList.add("hidden");
    content.classList.remove("hidden");
  } catch (error) {
    loading.textContent = error.message || "暂时无法加载介绍内容";
    retry.classList.remove("hidden");
  }
}

$("#about-button").addEventListener("click", () => {
  showDialog("about-dialog");
  loadAbout();
});
$("#privacy-button").addEventListener("click", () => showDialog("privacy-dialog"));
$("#about-retry").addEventListener("click", loadAbout);

$("#logout-button").addEventListener("click", async () => {
  try { await request("/api/auth/logout", { method: "POST" }); } catch { /* local state still clears */ }
  userSignedOut = true;
  forgetSessionHistory();
  loginRetryScheduled = true;
  accessToken = "";
  currentUser = null;
  cloudSnapshot = { semesters: [], courses: [], schedules: [], cursor: 0 };
  currentSemester = null;
  currentCourses = [];
  $("#app-view").classList.add("hidden");
  showLogin();
  document.body.classList.remove("schedule-active");
  document.documentElement.classList.remove("schedule-active");
  setMessage("已退出，服务器会话与本机登录状态已清除", false, true);
});

function urlBase64ToUint8Array(value) {
  const padding = "=".repeat((4 - value.length % 4) % 4);
  const raw = atob((value + padding).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from([...raw].map((character) => character.charCodeAt(0)));
}

const isStandalone = window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
async function requestWebNotifications() {
  const isAppleMobile = /iPhone|iPad|iPod/i.test(navigator.userAgent);
  const isSafari = /Safari/i.test(navigator.userAgent) && !/CriOS|FxiOS|EdgiOS|OPiOS/i.test(navigator.userAgent);
  if (isAppleMobile && (!isSafari || !isStandalone)) {
    showDialog("first-visit-guide");
    setMessage("iPhone/iPad 必须用 Safari（iOS 16.4+）添加到主屏幕，再从桌面图标打开后开启通知", true);
    return false;
  }
  if (!("Notification" in window) || !("serviceWorker" in navigator) || !("PushManager" in window)) {
    showDialog("first-visit-guide");
    setMessage("通知需要 iOS 16.4+ Safari 主屏幕网页 App；电脑请使用最新版 Safari、Chrome 或 Edge", true);
    return false;
  }
  try {
    const permission = await Notification.requestPermission();
    if (permission !== "granted") throw new Error("通知权限未开启，可在系统设置中修改");
    const { public_key: publicKey } = await request("/api/push/public-key");
    const registration = await navigator.serviceWorker.ready;
    let subscription = await registration.pushManager.getSubscription();
    if (!subscription) subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(publicKey) });
    const json = subscription.toJSON();
    await request("/api/push/subscribe", { method: "POST", body: JSON.stringify({ endpoint: subscription.endpoint, keys: json.keys }) });
    await request("/api/push/test", { method: "POST", body: "{}" });
    $("#notification-status").textContent = "已开启，并已发送测试通知";
    setMessage("通知已开启");
    return true;
  } catch (error) { setMessage(error.message, true); return false; }
}
$("#notification-button").addEventListener("click", requestWebNotifications);

function promptWebNotificationsOnce() {
  try {
    if (localStorage.getItem("hanshang-notification-consent-v1")) return;
    localStorage.setItem("hanshang-notification-consent-v1", "shown");
  } catch { /* Restricted storage must not block the app. */ }
  showDialog("notification-consent-dialog");
}
$("#notification-consent-later").addEventListener("click", () => {
  closeDialog("notification-consent-dialog");
  try { localStorage.setItem("hanshang-notification-consent-v1", "declined"); } catch { /* Ignore restricted storage. */ }
});
$("#notification-consent-allow").addEventListener("click", async () => {
  closeDialog("notification-consent-dialog");
  const enabled = await requestWebNotifications();
  try { localStorage.setItem("hanshang-notification-consent-v1", enabled ? "granted" : "declined"); } catch { /* Ignore restricted storage. */ }
});

function openGuide() { showDialog("first-visit-guide"); }
$("#guide-button").addEventListener("click", openGuide);
$("#guide-close").addEventListener("click", () => { closeDialog("first-visit-guide"); localStorage.setItem("hanshang-guide-seen-v2", "1"); });
if (!localStorage.getItem("hanshang-guide-seen-v2")) window.addEventListener("load", openGuide, { once: true });
if ("serviceWorker" in navigator) navigator.serviceWorker.register("./sw.js");
restoreSession();

function exportToCalendar() {
  if (!currentSemester) return toast("请先设置学期");
  var courses = normalizeCourses(currentSemester);
  if (!courses.length) return toast("当前学期没有课程可导出");
  var sem = currentSemester;
  var startDate = new Date(sem.start_date + "T00:00:00");
  function pad(n, w) { w = w || 2; return String(n).padStart(w, "0"); }
  function fmtDate(d) {
    return d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) +
      "T" + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
  }
  function escapeField(s) {
    return String(s).replace(/\\/g, "\\\\").replace(/,/g, "\\,").replace(/;/g, "\\;").replace(/\n/g, "\\n");
  }
  function timesForDate(d) {
    var m = d.getMonth() + 1;
    return m >= 5 && m <= 9 ? SECTION_TIMES.summer : SECTION_TIMES.winter;
  }
  var allEvents = [];
  courses.forEach(function(course) {
    (course.slots || []).forEach(function(slot) {
      var day = Number(slot.day_of_week);
      var startSec = Number(slot.start_section);
      var endSec = Number(slot.end_section);
      var location = displayLocation(slot.location) || slot.location || "";
      var teacher = course.teacher || "";
      var desc = teacher ? "教师：" + teacher : "";
      var dates = [];
      for (var w = 1; w <= sem.total_weeks; w++) {
        if (!slotIsActiveInWeek(slot, w)) continue;
        var d = new Date(startDate);
        d.setDate(d.getDate() + (w - 1) * 7 + (day - 1));
        var times = timesForDate(d);
        var startParts = (times[startSec - 1] || "08:00").split(":").map(Number);
        var endParts = (times[endSec - 1] || times[startSec - 1] || "08:45").split(":").map(Number);
        var dtstart = new Date(d);
        dtstart.setHours(startParts[0], startParts[1], 0, 0);
        var dtend = new Date(dtstart);
        dtend.setMinutes(dtend.getMinutes() + 45);
        dates.push({ dtstart: dtstart, dtend: dtend });
      }
      if (dates.length) allEvents.push({ summary: course.name, desc: desc, location: location, dates: dates });
    });
  });
  if (!allEvents.length) return toast("所有课程的有效周次为空");
  var lines = [
    "BEGIN:VCALENDAR", "VERSION:2.0",
    "PRODID:-//hanshang.seanyan.store//hanshang-schedule//CN",
    "CALSCALE:GREGORIAN",
    "X-WR-CALNAME:邗上课表 " + (sem.name || ""),
    "X-WR-TIMEZONE:Asia/Shanghai",
    "BEGIN:VTIMEZONE", "TZID:Asia/Shanghai",
    "BEGIN:STANDARD", "DTSTART:19700101T000000",
    "TZOFFSETFROM:+0800", "TZOFFSETTO:+0800", "TZNAME:CST",
    "END:STANDARD", "END:VTIMEZONE"
  ];
  var count = 0;
  allEvents.forEach(function(ev) {
    ev.dates.forEach(function(pair) {
      lines.push("BEGIN:VEVENT");
      lines.push("DTSTART;TZID=Asia/Shanghai:" + fmtDate(pair.dtstart));
      lines.push("DTEND;TZID=Asia/Shanghai:" + fmtDate(pair.dtend));
      lines.push("SUMMARY:" + escapeField(ev.summary));
      if (ev.location) lines.push("LOCATION:" + escapeField(ev.location));
      if (ev.desc) lines.push("DESCRIPTION:" + escapeField(ev.desc));
      lines.push("BEGIN:VALARM");
      lines.push("TRIGGER:-PT15M");
      lines.push("ACTION:DISPLAY");
      lines.push("DESCRIPTION:" + escapeField(ev.summary));
      lines.push("END:VALARM");
      lines.push("END:VEVENT");
      count++;
    });
  });
  lines.push("END:VCALENDAR");
  var blob = new Blob([lines.join("\r\n")], { type: "text/calendar;charset=utf-8" });
  var url = URL.createObjectURL(blob);
  var a = document.createElement("a");
  a.href = url;
  a.download = "邗上课表" + (sem.name || "") + ".ics";
  a.click();
  setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
  toast("已导出 " + count + " 条上课时间到日历文件，正在下载…");
}
window.exportToCalendar = exportToCalendar;

