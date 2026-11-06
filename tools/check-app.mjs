import { KEY as TIME_KEY, defaults as defaultTimes, validate as validateTimes, parse as parseTimes, forDate as timesForDate } from "./section-times.js?v=42";
// Security boundary: credentials and access tokens stay in memory only. The
// service worker caches the static shell, never API responses.
const API_BASE = `${location.origin}/web-api`;
const SESSION_HISTORY_KEY = "hanshang-session-established-v1";
const SIGNED_OUT_KEY = "hanshang-explicit-signout-v1";
const DAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
// 课程色与安卓对齐：马卡龙 10 色板，按课程名 UTF-16 码元哈希分配（同 CourseColors.forCourseName），
// 云端同步的 color 字段是安卓写入的 ARGB int；早期网页版写入的 0-5 序号按课程名哈希回落。
const MACARON = ["#A8D8EA", "#FFCBCB", "#B5EAD7", "#FFDAC1", "#C7CEEA", "#F6E6AD", "#A2E1DB", "#F3B0C3", "#BFD8B8", "#E7C6E7"];

function hashCourseName(name) {
  const text = String(name || "");
  let hash = 0;
  for (let index = 0; index < text.length; index += 1) hash = (hash * 31 + text.charCodeAt(index)) & 0x7fffffff;
  return hash;
}

function macaronForName(name) {
  return MACARON[hashCourseName(name) % MACARON.length];
}

// 写入云端的 ARGB int（与安卓 toARGB32 一致），保证两端显示同一颜色
// 注意不能用位或（JS 位运算会把 0xFF000000 转成负数 int32）
function forCourseNameArgb(name) {
  return 0xff000000 + parseInt(macaronForName(name).slice(1), 16);
}

// 解析课程基色：合法 ARGB int（含 int32 负数形式）直接使用；否则按课程名哈希回落到马卡龙色板
function courseBaseColor(course) {
  let raw = Number(course?.color);
  if (Number.isInteger(raw) && raw < 0) raw = raw >>> 0;
  if (Number.isInteger(raw) && raw > 0xffffff) {
    return `#${(raw & 0xffffff).toString(16).padStart(6, "0").toUpperCase()}`;
  }
  return macaronForName(course?.name);
}

function hexChannels(hex) {
  return [parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16), parseInt(hex.slice(5, 7), 16)];
}

function withAlpha(hex, alpha) {
  const [r, g, b] = hexChannels(hex);
  return `rgba(${r},${g},${b},${alpha})`;
}

// 安卓 alphaBlend(base@a, 黑/白) 的课程块文字色
function blendedText(hex, alpha, base) {
  const [r, g, b] = hexChannels(hex);
  const mix = (channel) => Math.round(channel * alpha + base * (1 - alpha));
  return `#${[mix(r), mix(g), mix(b)].map((v) => v.toString(16).padStart(2, "0")).join("")}`;
}

// 安卓 _CourseBlock：底=base 16%（浅）/30%（深），文字=base 70% 混黑 / 42% 混白，描边=base 38%，左条实色
function applyCourseColorVars(element, course) {
  const base = courseBaseColor(course);
  element.style.setProperty("--course-base", base);
  element.style.setProperty("--course-bg", withAlpha(base, 0.16));
  element.style.setProperty("--course-bg-d", withAlpha(base, 0.3));
  element.style.setProperty("--course-border", withAlpha(base, 0.38));
  element.style.setProperty("--course-text", blendedText(base, 0.7, 0));
  element.style.setProperty("--course-text-d", blendedText(base, 0.42, 255));
  return base;
}

// 内联 SVG 图标（sprite 在 index.html 内）
function iconSvg(name, className = "icon") {
  return `<svg class="${className}" aria-hidden="true"><use href="#i-${name}"/></svg>`;
}
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

const SCHEDULE_CACHE_KEY = "hanshang-offline-schedule-v1";
let cachedScheduleUserId = null;
let offlinePreview = false;

function clearScheduleCache() {
  try { localStorage.removeItem(SCHEDULE_CACHE_KEY); } catch {}
  cachedScheduleUserId = null;
}

function restoreCachedSchedule() {
  if (!privacyConsented() || !hasSessionHistory()) return false;
  try {
    const cached = JSON.parse(localStorage.getItem(SCHEDULE_CACHE_KEY) || "null");
    if (!cached || !Number.isInteger(cached.user?.id) ||
        !["semesters", "courses", "schedules"].every(key => Array.isArray(cached.snapshot?.[key]) && cached.snapshot[key].every(row => row && typeof row === "object"))) return false;
    cloudSnapshot = cached.snapshot;
    cachedScheduleUserId = cached.user.id;
    offlinePreview = true;
    $("#profile-name").textContent = cached.user.username || "离线课表";
    $("#profile-avatar").textContent = (cached.user.username || "邗").trim().charAt(0) || "邗";
    $("#boot-view").classList.add("hidden");
    $("#login-view").classList.add("hidden");
    $("#app-view").classList.remove("hidden");
    showPage("schedule");
    applyScheduleSnapshot();
    showSyncHint(navigator.onLine ? "正在同步本机课表…" : "离线课表 · 联网后自动同步", navigator.onLine);
    return true;
  } catch {
    clearScheduleCache();
    offlinePreview = false;
    cloudSnapshot = { semesters: [], courses: [], schedules: [], cursor: 0 };
    $("#app-view").classList.add("hidden");
    $("#boot-view").classList.remove("hidden");
    return false;
  }
}

function saveScheduleCache() {
  if (!currentUser || userSignedOut) return;
  try {
    localStorage.setItem(SCHEDULE_CACHE_KEY, JSON.stringify({
      user: { id: currentUser.id, username: currentUser.username },
      snapshot: cloudSnapshot, savedAt: Date.now(),
    }));
    cachedScheduleUserId = currentUser.id;
  } catch { /* A full/restricted browser store must not block the online timetable. */ }
}

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
  try {
    localStorage.removeItem(SIGNED_OUT_KEY);
    localStorage.setItem(SESSION_HISTORY_KEY, "1");
  } catch { /* Cookie recovery still works. */ }
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
  if (offlinePreview && !accessToken && !path.startsWith("/api/auth/")) {
    throw new Error("当前显示本机课表，请联网恢复账号后再使用此功能");
  }
  const credentials = options.credentials ?? "include";
  const isFormData = typeof FormData !== "undefined" && options.body instanceof FormData;
  const response = await fetch(`${base}${path}`, {
    ...options,
    credentials,
    headers: {
      ...(!isFormData ? { "Content-Type": "application/json" } : {}),
      ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
      ...(options.headers || {}),
    },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(body.message || body.detail?.message || "请求失败，请稍后再试");
    error.status = response.status;
    error.code = body.detail?.code ?? body.code ?? null;
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
  if (cachedScheduleUserId !== null && cachedScheduleUserId !== user.id) {
    clearScheduleCache();
    cloudSnapshot = { semesters: [], courses: [], schedules: [], cursor: 0 };
    applyScheduleSnapshot();
  }
  offlinePreview = false;
  currentUser = user;
  $("#boot-view").classList.add("hidden");
  $("#login-view").classList.add("hidden");
  $("#app-view").classList.remove("hidden");
  $("#profile-name").textContent = currentUser.username;
  $("#profile-avatar").textContent = (currentUser.username || "邗").trim().charAt(0) || "邗";
  showPage("schedule");
  await loadCloudSchedule();
  refreshNotificationSummary();
  promptWebNotificationsOnce();
  if (welcome) setMessage(`欢迎回来，${currentUser.username}`);
}

function showLogin() {
  $$("dialog[open]").forEach(dialog => dialog.close());
  document.querySelector("#availability-module-dialog iframe")?.remove();
  offlinePreview = false;
  currentUser = null;
  clearScheduleCache();
  cloudSnapshot = { semesters: [], courses: [], schedules: [], cursor: 0 };
  currentSemester = null;
  currentCourses = [];
  $("#app-view").classList.add("hidden");
  document.body.classList.remove("schedule-active");
  document.documentElement.classList.remove("schedule-active");
  $("#boot-view").classList.add("hidden");
  $("#login-view").classList.remove("hidden");
}

// 手动退出标记：退出后不再自动尝试恢复会话。
let userSignedOut = (() => { try { return localStorage.getItem(SIGNED_OUT_KEY) === "1"; } catch { return false; } })();
let sessionEpoch = 0;
let sessionRetryCount = 0;
let authFailCount = 0;
let recoveryTimer = null;
let loginRetryScheduled = false;

function sessionRecoveryPending() {
  return !userSignedOut && !currentUser && !accessToken;
}

function showOfflineHint(error = null) {
  if (offlinePreview) {
    showSyncHint("离线课表 · 联网后自动同步", false);
    return;
  }
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
// v1 = 2026-08-13；v2 = 2026-09-02；v3 = 2026-09-13（截图/表格 AI 导入说明）。
const PRIVACY_CONSENT_KEY = "privacyConsentedAtV3";
const PREVIOUS_COMPATIBLE_PRIVACY_CONSENT_KEY = "privacyConsentedAtV2";

function privacyConsented() {
  if (localStorage.getItem(PRIVACY_CONSENT_KEY)) return true;
  // 第 3 版只补充用户主动使用 AI 文件导入时的数据处理说明。已同意第 2 版的
  // 老用户直接迁移，避免再次用全屏弹窗打断；首次访问仍需明确同意。
  if (localStorage.getItem(PREVIOUS_COMPATIBLE_PRIVACY_CONSENT_KEY)) {
    localStorage.setItem(PRIVACY_CONSENT_KEY, String(Date.now()));
    return true;
  }
  return false;
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
  if (userSignedOut) { showLogin(); return; }
  const epoch = sessionEpoch;
  // 隐私政策门禁（金标联盟/应用商店合规）：未同意前不发起任何 API 请求
  //（含会话恢复），也不写入会话 Cookie。
  if (!privacyConsented()) {
    showPrivacyConsent();
    return;
  }
  if (!navigator.onLine) {
    showOfflineHint();
    scheduleRecovery();
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
    if (epoch !== sessionEpoch || userSignedOut) return;
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

// 学期建议起点：秋季 = 9 月 1 日所在周的周一，春季 = 2 月 25 日所在周的周一（贴近扬大近年开学节奏）
// 2026 年秋季学期：9 月 1 日是周二 → 第一周周一为 2026-08-31
function suggestedSemesterStart(date = new Date()) {
  const year = date.getFullYear();
  const month = date.getMonth() + 1;
  const anchor = month >= 8 ? new Date(year, 8, 1) : month === 1 ? new Date(year - 1, 8, 1) : new Date(year, 1, 25);
  const day = anchor.getDay() || 7;
  anchor.setDate(anchor.getDate() - day + 1);
  return isoDate(anchor);
}

$("#semester-form").start_date.value = suggestedSemesterStart();

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

function applyScheduleSnapshot() {
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
}

// 顶栏轻量同步/离线指示（替代打扰用户的大 toast）
function showSyncHint(text, syncing = true) {
  const hint = $("#sync-hint");
  hint.textContent = text;
  hint.classList.toggle("syncing", syncing);
  hint.classList.remove("hidden");
}

function hideSyncHint() {
  $("#sync-hint").classList.add("hidden");
}

async function loadCloudSchedule(showSuccess = false) {
  const owner = currentUser?.id;
  try {
    const snapshot = await request("/api/sync/pull?since=0");
    if (!owner || userSignedOut || currentUser?.id !== owner) return;
    cloudSnapshot = snapshot;
    applyScheduleSnapshot();
    saveScheduleCache();
    hideSyncHint();
    if (showSuccess) setMessage("已读取云端最新课表");
  } catch (error) {
    hideSyncHint();
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

let timeConfig = {version:1,mode:"automatic"};
try { timeConfig = parseTimes(localStorage.getItem(TIME_KEY)); } catch {}
function sectionTimeRange(section, date = dateForWeekDay(1) || new Date()) {
  const pair = timesForDate(timeConfig, date)[section-1];
  return pair ? pair.join("-") : "";
}
function sectionTimesForWeek() { return timesForDate(timeConfig,dateForWeekDay(1)||new Date()).map(t=>t[0]); }

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
    time.textContent = [...new Set([1,2,3,4,5,6,7].map(day => sectionTimeRange(section, dateForWeekDay(day)||new Date())))].join("\n");
    time.style.whiteSpace = "pre-line";
    label.append(number, time);
    grid.append(label);
    for (let day = 1; day <= 7; day += 1) {
      const cell = document.createElement("div");
      cell.className = "week-grid-cell";
      // 安卓周视图斑马纹：奇数节次行叠 surfaceContainerLowest 35%
      if (section % 2 === 1) cell.classList.add("alt");
      cell.style.gridColumn = day + 1;
      cell.style.gridRow = section + 1;
      grid.append(cell);
    }
  }

  // 安卓 _placeOverlappingCourses：同一天相交课程贪心分栏，互不遮挡
  for (let day = 1; day <= 7; day += 1) {
    const daySlots = activeSlots.filter(({ slot }) => slot.day_of_week === day);
    const sorted = [...daySlots].sort((a, b) => a.slot.start_section - b.slot.start_section || a.slot.end_section - b.slot.end_section);
    let index = 0;
    while (index < sorted.length) {
      const group = [sorted[index]];
      let groupEnd = sorted[index].slot.end_section;
      let next = index + 1;
      while (next < sorted.length && sorted[next].slot.start_section <= groupEnd) {
        group.push(sorted[next]);
        groupEnd = Math.max(groupEnd, sorted[next].slot.end_section);
        next += 1;
      }
      const laneEnds = [];
      const lanes = [];
      for (const item of group) {
        let lane = laneEnds.findIndex((endSection) => endSection < item.slot.start_section);
        if (lane === -1) { lane = laneEnds.length; laneEnds.push(item.slot.end_section); }
        else laneEnds[lane] = item.slot.end_section;
        lanes.push(lane);
      }
      group.forEach((item, groupIndex) => renderCourseButton(item.course, item.slot, lanes[groupIndex], laneEnds.length));
      index = next;
    }
  }

  function renderCourseButton(course, slot, lane, laneCount) {
    const start = Math.max(1, Math.min(sectionCount, Number(slot.start_section) || 1));
    const end = Math.max(start, Math.min(sectionCount, Number(slot.end_section) || start));
    const day = Math.max(1, Math.min(7, Number(slot.day_of_week) || 1));
    const compact = laneCount > 1;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "week-course";
    button.style.gridColumn = day + 1;
    button.style.gridRow = `${start + 1} / ${end + 2}`;
    if (compact) {
      button.classList.add("compact");
      button.style.justifySelf = "start";
      button.style.width = `calc(${100 / laneCount}% - 2px)`;
      button.style.marginLeft = `calc(${(lane * 100) / laneCount}% + 1px)`;
    }
    applyCourseColorVars(button, course);
    const sectionSpan = end - start + 1;
    const titleLength = Array.from(String(course.name || "")).length;
    // 行数随块高放开：名称最多 9 行，元信息最多 5 行，填满块内空间（对齐安卓的按高度测量）
    const titleLines = Math.max(2, Math.min(9, sectionSpan * 4));
    const detailLines = sectionSpan === 1 ? 1 : Math.max(2, Math.min(5, (sectionSpan - 1) * 2));
    const titleSize = titleLength > 18 ? ".49rem" : titleLength > 12 ? ".54rem" : titleLength > 8 ? ".59rem" : compact ? ".54rem" : ".66rem";
    button.style.setProperty("--course-title-lines", titleLines);
    button.style.setProperty("--course-title-size", titleSize);
    button.style.setProperty("--course-detail-lines", detailLines);
    button.classList.toggle("single-section", sectionSpan === 1);
    const location = displayLocation(slot.location);
    const title = document.createElement("strong");
    title.textContent = String(course.name || "").replace(/（/g, "\n（");
    button.append(title);
    if (sectionSpan === 1) {
      // 单节卡空间小：只显示一行（教师优先，其次地点）
      const single = document.createElement("span");
      single.textContent = course.teacher || location || `第 ${start}-${end} 节`;
      button.append(single);
    } else {
      // 多节卡：地点（可多行）+ 教师（固定一行靠底），对齐安卓的底部元信息
      if (location) {
        const loc = document.createElement("span");
        loc.className = "course-loc";
        loc.textContent = location;
        button.append(loc);
      }
      if (course.teacher) {
        const teacher = document.createElement("span");
        teacher.className = "course-teacher";
        teacher.textContent = course.teacher;
        button.append(teacher);
      }
      if (!location && !course.teacher) {
        const fallback = document.createElement("span");
        fallback.className = "course-loc";
        fallback.textContent = `第 ${start}-${end} 节`;
        button.append(fallback);
      }
    }
    button.title = [course.name, slot.location, course.teacher].filter(Boolean).join(" · ");
    button.setAttribute("aria-label", `${course.name}，${DAYS[day - 1]}第 ${start}-${end} 节${location ? `，${location}` : ""}${course.teacher ? `，${course.teacher}` : ""}`);
    button.addEventListener("click", () => showCourseDetail(course.uuid));
    grid.append(button);
  }

  container.append(grid);
}

function courseSlotButton(course, slot) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "slot-card";
  const color = document.createElement("i");
  color.className = "slot-color";
  color.style.background = courseBaseColor(course);
  // 安卓日视图：左色条 → 起止时间列 → 竖分隔线 → 课程名与元信息
  const time = document.createElement("span");
  time.className = "slot-time";
  const startTime = sectionTimeRange(slot.start_section, dateForWeekDay(slot.day_of_week)||new Date()).split("-")[0];
  const endTime = sectionTimeRange(slot.end_section, dateForWeekDay(slot.day_of_week)||new Date()).split("-")[1];
  const timeStart = document.createElement("b");
  timeStart.textContent = startTime || `第 ${slot.start_section} 节`;
  const timeEnd = document.createElement("i");
  timeEnd.textContent = endTime || `至第 ${slot.end_section} 节`;
  time.append(timeStart, timeEnd);
  const divider = document.createElement("i");
  divider.className = "slot-divider";
  const main = document.createElement("span");
  main.className = "slot-main";
  const title = document.createElement("strong");
  title.textContent = course.name;
  const detail = document.createElement("span");
  const location = displayLocation(slot.location);
  detail.textContent = [`第 ${slot.start_section}-${slot.end_section} 节`, location, course.teacher].filter(Boolean).join(" · ");
  main.append(title, detail);
  button.append(color, time, divider, main);
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
  $("#time-transition").classList.toggle("hidden", viewMode!=="week" || sectionTimeRange(6,dateForWeekDay(1)||new Date())===sectionTimeRange(6,dateForWeekDay(7)||new Date()));
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

// ---- 跟手拖拽切周/切日：横向拖动实时跟随，过阈值松手切换，不足回弹；周视图切周、日视图切日（日界可跨周） ----
let scheduleDrag = null;
let suppressClickAfterDrag = false;
const scheduleHost = $("#schedule-list");

function scheduleTarget(dir) {
  // dir：1=下一页，-1=上一页；越界返回 null
  if (viewMode === "day") {
    let day = selectedDay + dir;
    let week = selectedWeek;
    if (day < 1) {
      if (week <= 1) return null;
      day = 7; week -= 1;
    } else if (day > 7) {
      if (!currentSemester || week >= currentSemester.total_weeks) return null;
      day = 1; week += 1;
    }
    return { week, day };
  }
  if (!currentSemester) return null;
  const week = selectedWeek + dir;
  if (week < 1 || week > currentSemester.total_weeks) return null;
  return { week };
}

scheduleHost.addEventListener("pointerdown", (event) => {
  if (event.pointerType === "mouse" && event.button !== 0) return;
  suppressClickAfterDrag = false; // 上一次拖拽的抑制已在松手后的 click 消费；新手势一律放行
  scheduleDrag = { id: event.pointerId, x: event.clientX, y: event.clientY, dx: 0, following: false, allowed: true, dir: 0 };
});
scheduleHost.addEventListener("pointermove", (event) => {
  if (!scheduleDrag || event.pointerId !== scheduleDrag.id) return;
  const dx = event.clientX - scheduleDrag.x;
  const dy = event.clientY - scheduleDrag.y;
  if (!scheduleDrag.following) {
    if (Math.abs(dx) >= 8 && Math.abs(dx) > Math.abs(dy) * 1.2) {
      scheduleDrag.following = true;
      try { scheduleHost.setPointerCapture(event.pointerId); } catch { /* 老内核无捕获 */ }
      const content = scheduleHost.firstElementChild;
      if (content) content.style.transition = "none";
    } else if (Math.abs(dy) > 10) {
      scheduleDrag = null; // 让位纵向滚动
      return;
    } else return;
  }
  const dir = dx < 0 ? 1 : -1;
  scheduleDrag.dir = dir;
  scheduleDrag.allowed = scheduleTarget(dir) !== null;
  scheduleDrag.dx = scheduleDrag.allowed ? dx : dx * 0.35; // 边界橡皮筋
  const content = scheduleHost.firstElementChild;
  if (content) content.style.transform = `translateX(${scheduleDrag.dx}px)`;
});

function finishScheduleDrag(cancelled) {
  const drag = scheduleDrag;
  scheduleDrag = null;
  if (!drag || !drag.following) return;
  const content = scheduleHost.firstElementChild;
  if (Math.abs(drag.dx) > 12) suppressClickAfterDrag = true;
  if (!content) return;
  const width = scheduleHost.clientWidth || 320;
  const commit = !cancelled && drag.allowed && Math.abs(drag.dx) >= Math.min(96, width * 0.26);
  if (!commit) {
    content.style.transition = "transform .22s cubic-bezier(.22,.8,.3,1)";
    content.style.transform = "translateX(0)";
    const cleanup = () => { content.style.transition = ""; };
    content.addEventListener("transitionend", cleanup, { once: true });
    setTimeout(cleanup, 300);
    return;
  }
  const dir = drag.dir;
  // 直接换页：被拖走的旧页顺势飞出视野，新页从同方向滑入，不再有先闪出再闪入的空档
  const target = scheduleTarget(dir);
  if (!target) return;
  scheduleAnimationDirection = dir;
  selectedWeek = target.week;
  if (target.day) selectedDay = target.day;
  renderScheduleHeader();
  renderSchedule();
}
scheduleHost.addEventListener("pointerup", () => finishScheduleDrag(false));
scheduleHost.addEventListener("pointercancel", () => finishScheduleDrag(true));
// 拖拽后的 click 抑制：拖动过课程块松手不应误开课程详情
scheduleHost.addEventListener("click", (event) => {
  if (suppressClickAfterDrag) {
    suppressClickAfterDrag = false;
    event.preventDefault();
    event.stopPropagation();
  }
}, true);

function showDialog(id) { document.getElementById(id).showModal(); }

// 统一关闭动画：加 .closing 播退场动画，动画结束（或 240ms 兜底）后真正 close()。
function closeDialog(target) {
  const dialog = typeof target === "string" ? document.getElementById(target) : target;
  if (!dialog || !dialog.open || dialog.classList.contains("closing")) return;
  if (dialog.id === "section-time-dialog" && (timeSaving || (timeDirty && !confirm("放弃未保存的时间修改？")))) return;
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

// ---- 外观：跟随系统 / 浅色 / 深色（「我的」页可切换，与安卓一致） ----
const THEME_KEY = "hanshang-theme-mode-v1";

function applyThemeMode(mode) {
  const root = document.documentElement;
  if (mode === "dark") root.dataset.theme = "dark";
  else if (mode === "light") root.dataset.theme = "light";
  else delete root.dataset.theme;
  for (const id of ["theme-system", "theme-light", "theme-dark"]) {
    const button = document.getElementById(id);
    if (button) button.classList.toggle("active", id === `theme-${mode}`);
  }
}

function currentThemeMode() {
  try {
    const saved = localStorage.getItem(THEME_KEY);
    return ["system", "light", "dark"].includes(saved) ? saved : "system";
  } catch {
    return "system";
  }
}

for (const mode of ["system", "light", "dark"]) {
  document.getElementById(`theme-${mode}`)?.addEventListener("click", () => {
    try { localStorage.setItem(THEME_KEY, mode); } catch { /* 受限存储仍生效本次会话 */ }
    applyThemeMode(mode);
  });
}
applyThemeMode(currentThemeMode());

// ---- 课表管理（多课表：列表 / 切换 / 新建 / 编辑 / 删除）----

let editingSemesterUuid = "";

function renderSemesterList() {
  const container = $("#semester-list");
  const semesters = activeRows("semesters").sort((a, b) => b.updated_at - a.updated_at);
  container.replaceChildren();
  if (!semesters.length) {
    const empty = document.createElement("p");
    empty.className = "subtle";
    empty.textContent = "还没有课表，点上方「新建课表」开始";
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
    strong.textContent = sem.name + (sem.uuid === currentSemester?.uuid ? " · 当前" : "");
    const small = document.createElement("small");
    small.textContent = `${sem.start_date} 开学 · ${sem.total_weeks} 周 · ${courseCount} 门课`;
    info.append(strong, small);
    row.append(info);
    if (sem.uuid !== currentSemester?.uuid) {
      const activate = document.createElement("button");
      activate.type = "button";
      activate.className = "btn-tonal btn btn-sm";
      activate.textContent = "设为当前";
      activate.addEventListener("click", (event) => {
        event.stopPropagation();
        switchCurrentSemester(sem);
      });
      row.append(activate);
    }
    const arrow = document.createElement("span");
    arrow.innerHTML = iconSvg("chevron_right", "icon chev");
    arrow.firstChild.setAttribute("aria-hidden", "true");
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
  form.start_date.value = semester?.start_date || suggestedSemesterStart();
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
  $("#course-detail-title").textContent = "课程详情";
  const body = $("#course-detail-body");
  const slots = course.slots || [];
  const base = courseBaseColor(course);
  // 安卓 CourseDetailSheet：课程色图标块 + 标题 + 安排数 → 分隔线 → 教师/时间段 chips/备注
  let html = `<div class="detail-head"><span class="detail-icon" style="--course-chip-bg:${withAlpha(base, 0.16)};--course-base:${base}">${iconSvg("menu_book")}</span>`
    + `<div style="min-width:0"><h2>${esc(course.name || "课程详情")}</h2><small>${slots.length} 个上课安排</small></div></div>`
    + '<div class="detail-divider" role="separator"></div>';
  if (course.teacher) html += `<div class="detail-row">${iconSvg("person")}<span>${esc(course.teacher)}</span></div>`;
  if (slots.length) {
    slots.forEach(function(slot) {
      const day = DAYS[(slot.day_of_week || 1) - 1];
      const date = dateForWeekDay(slot.day_of_week)||new Date();
      const first = sectionTimeRange(slot.start_section,date).split("-")[0];
      const last = sectionTimeRange(slot.end_section,date).split("-")[1];
      const sec = first && last ? `第 ${slot.start_section}-${slot.end_section} 节 ${first}-${last}` : `第 ${slot.start_section}-${slot.end_section} 节`;
      const loc = displayLocation(slot.location) || slot.location || "";
      const wt = _weekTypeLabel(slot);
      html += `<div class="detail-slot"><div class="detail-row" style="padding:0">${iconSvg("schedule")}<span>${day} ${sec} · ${wt}${loc ? `<br><small style="color:var(--on-surface-variant)">${esc(loc)}</small>` : ""}</span></div></div>`;
    });
  }
  if (course.note) html += `<div class="detail-row">${iconSvg("notes")}<span>${esc(course.note)}</span></div>`;
  if (!course.teacher && !slots.length && !course.note) html += '<p class="subtle" style="margin:4px 0">暂无详细信息</p>';
  body.innerHTML = html;
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
  const course = { uuid: courseUuid, semester_uuid: currentSemester.uuid, name: form.name.value.trim(), teacher: form.teacher.value.trim(), color: existing?.color ?? forCourseNameArgb(form.name.value.trim()), note: form.note.value.trim(), updated_at: now, deleted: false };
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
    const icon = document.createElement("span");
    icon.className = "course-icon";
    icon.innerHTML = iconSvg("menu_book");
    const name = document.createElement("strong");
    name.textContent = course.name;
    const detail = document.createElement("span");
    detail.textContent = `${course.teacher || "教师待补充"} · ${(course.slots || []).map((slot) => `${DAYS[slot.day_of_week - 1]} 第${slot.start_section}-${slot.end_section}节${slot.location ? ` · ${displayLocation(slot.location)}` : ""}`).join("；") || "时间待补充"}`;
    item.append(icon, name, detail);
    return item;
  }));
}

// ---- 截图 / Excel AI 导入 ----
let selectedScheduleFile = null;
let selectedScheduleKind = null;
let fileImporting = false;
let fileProgressTimer = null;
const imageExtensions = new Set(["png", "jpg", "jpeg", "webp"]);
const tableExtensions = new Set(["xlsx", "xls", "csv"]);

function fileExtension(name) {
  const value = String(name || "").toLowerCase();
  const dot = value.lastIndexOf(".");
  return dot >= 0 ? value.slice(dot + 1) : "";
}

function selectScheduleFile(file, expectedKind) {
  if (!file) return;
  $("#file-import-error").classList.add("hidden");
  const extension = fileExtension(file.name);
  const valid = expectedKind === "image" ? imageExtensions.has(extension) : tableExtensions.has(extension);
  const max = expectedKind === "image" ? 8 * 1024 * 1024 : 5 * 1024 * 1024;
  if (!valid) {
    selectedScheduleFile = null;
    selectedScheduleKind = null;
    $("#file-selection").textContent = expectedKind === "image" ? "请选择 PNG、JPG 或 WebP 截图" : "请选择 XLSX、XLS 或 CSV 表格";
    $("#file-parse-button").disabled = true;
    return;
  }
  if (file.size > max) {
    selectedScheduleFile = null;
    selectedScheduleKind = null;
    $("#file-selection").textContent = `文件过大，${expectedKind === "image" ? "截图不能超过 8 MB" : "表格不能超过 5 MB"}`;
    $("#file-parse-button").disabled = true;
    return;
  }
  selectedScheduleFile = file;
  selectedScheduleKind = expectedKind;
  const size = file.size < 1024 * 1024 ? `${Math.ceil(file.size / 1024)} KB` : `${(file.size / 1024 / 1024).toFixed(1)} MB`;
  $("#file-selection").textContent = `已选择：${file.name}（${size}）`;
  $("#file-parse-button").disabled = false;
}

$("#schedule-image-input").addEventListener("change", (event) => selectScheduleFile(event.target.files?.[0], "image"));
$("#schedule-table-input").addEventListener("change", (event) => selectScheduleFile(event.target.files?.[0], "table"));

// 部分安卓 WebView 对"覆盖层透明 input"的触摸命中不稳：点击落在图标/文字上时兜底触发文件选择
for (const [labelId, inputId] of [["choose-schedule-image", "schedule-image-input"], ["choose-schedule-table", "schedule-table-input"]]) {
  const label = document.getElementById(labelId);
  const input = document.getElementById(inputId);
  label.addEventListener("click", (event) => {
    if (event.target === input) return; // 覆盖层命中正常，交给原生行为
    event.preventDefault();
    input.click();
  });
  // 安卓 WebApp 外壳可能完全不实现系统文件选择器：点击后 2.5s 无变化时给出浏览器兜底指引
  const standalone = window.matchMedia?.("(display-mode: standalone)").matches || navigator.standalone === true;
  if (standalone && /Android/i.test(navigator.userAgent)) {
    label.addEventListener("click", () => {
      setTimeout(() => {
        if (!selectedScheduleFile) $("#android-file-hint")?.classList.remove("hidden");
      }, 2500);
    });
  }
}

function updateFileProgress(startedAt, expectedSeconds) {
  const elapsed = (performance.now() - startedAt) / 1000;
  const remaining = Math.max(0, Math.ceil(expectedSeconds - elapsed));
  const progress = Math.min(92, 8 + (elapsed / expectedSeconds) * 78);
  $("#file-progress-bar").style.width = `${progress}%`;
  $("#file-progress-meter").setAttribute("aria-valuenow", String(Math.round(progress)));
  $("#file-progress-eta").textContent = remaining > 0
    ? `预计还需约 ${remaining} 秒`
    : "比预计稍久，复杂课表可能需要更多时间";
  $("#file-progress-stage").textContent = elapsed < 3
    ? "正在安全上传文件…"
    : elapsed < 9
      ? "正在读取课程与时间位置…"
      : "正在合并同一课程并检查结果…";
}

function startFileProgress() {
  clearInterval(fileProgressTimer);
  const expectedSeconds = selectedScheduleKind === "image" ? 18 : 12;
  const startedAt = performance.now();
  $("#file-import-error").classList.add("hidden");
  $("#file-import-progress").classList.remove("hidden");
  $("#file-progress-title").textContent = selectedScheduleKind === "image"
    ? "正在识别课表截图"
    : "正在解析课表表格";
  updateFileProgress(startedAt, expectedSeconds);
  fileProgressTimer = setInterval(() => updateFileProgress(startedAt, expectedSeconds), 500);
}

function stopFileProgress() {
  clearInterval(fileProgressTimer);
  fileProgressTimer = null;
  $("#file-import-progress").classList.add("hidden");
}

function showFileImportError(error) {
  const status = Number(error?.status || 0);
  const code = Number(error?.code || 0);
  let title = "暂时没有识别成功";
  let detail = error?.message || "请稍后重试";
  if (status === 413) {
    title = "文件太大";
    detail = "请压缩截图，或选择体积更小的课表文件后重试。";
  } else if (status === 400) {
    title = "文件无法读取";
    detail = "请确认文件没有损坏，并使用 PNG、JPG、WebP、XLSX、XLS 或 CSV 格式。";
  } else if (status === 401 || status === 403) {
    title = "登录状态已失效";
    detail = "请重新登录后再进行识别，已选择的文件不会被保存。";
  } else if (status === 429) {
    title = "今天的识别次数已用完";
    detail = "为保护接口和用户数据，识别设有次数限制，请稍后再试。";
  } else if (status === 422 || code === 42245 || code === 42246 || code === 42247) {
    title = code === 42246 ? "这张图片不适合识别" : "没有识别到课表";
    detail = error?.message || (code === 42246
      ? "请更换一张只包含课表的图片。"
      : "请上传包含星期、节次和课程信息的完整截图或表格。");
  } else if (status === 504) {
    title = "本次识别超时";
    detail = "服务器没有保存文件。你可以直接重试，或换一张更清晰、内容更完整的截图。";
  } else if (status === 502 || code === 50232) {
    title = "识别服务暂时不可用";
    detail = "文件没有保存，请稍后直接重试。";
  } else if (!status) {
    title = "网络连接中断";
    detail = "请检查网络后重试。服务器不会保留未完成的上传。";
  }
  $("#file-error-title").textContent = title;
  $("#file-error-detail").textContent = detail;
  $("#file-import-error").classList.remove("hidden");
}

$("#file-progress-privacy").addEventListener("click", () => showDialog("privacy-dialog"));
$("#file-import-retry").addEventListener("click", () => $("#file-import-form").requestSubmit());
$("#file-import-reselect").addEventListener("click", () => {
  (selectedScheduleKind === "table" ? $("#schedule-table-input") : $("#schedule-image-input")).click();
});

$("#file-import-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!selectedScheduleFile || fileImporting) return;
  const form = event.currentTarget;
  if (!form.reportValidity()) return;
  fileImporting = true;
  const button = $("#file-parse-button");
  button.disabled = true;
  button.textContent = "正在识别…";
  startFileProgress();
  try {
    const body = new FormData();
    body.append("file", selectedScheduleFile, selectedScheduleFile.name);
    const result = await request("/api/education-import/file-parse", { method: "POST", body });
    const courses = Array.isArray(result?.courses) ? result.courses : [];
    if (!courses.length) {
      const emptyResult = new Error("没有从文件中识别出有效课程");
      emptyResult.status = 502;
      emptyResult.code = 50231;
      throw emptyResult;
    }
    // 学期信息在预览确认页填写（识别前不问用户）
    educationPreview = { courses, semester: null };
    fillEducationSemesterDefaults();
    renderCourseList($("#education-course-list"), courses);
    $("#education-preview-card").classList.remove("hidden");
    const sourceName = result.source === "image_llm" ? "课表截图" : "表格文件";
    setMessage(`已从${sourceName}识别 ${courses.length} 门课程，请核对后保存`);
    $("#education-preview-card").scrollIntoView({ behavior: "smooth", block: "start" });
  } catch (error) {
    showFileImportError(error);
  } finally {
    stopFileProgress();
    fileImporting = false;
    button.disabled = !selectedScheduleFile;
    button.textContent = "AI 识别并预览";
  }
});

// 识别成功后填充预览页的学期默认值与「本学期第一周周一」提示
function fillEducationSemesterDefaults() {
  const form = $("#education-semester-form");
  if (!form) return;
  const suggested = suggestedSemesterStart();
  form.semester_name.value = "当前学期";
  form.semester_start.value = suggested;
  form.total_weeks.value = 20;
  const hintButton = $("#semester-start-suggest");
  if (hintButton) hintButton.textContent = suggested;
}

$("#semester-start-suggest").addEventListener("click", () => {
  const form = $("#education-semester-form");
  if (form) form.semester_start.value = suggestedSemesterStart();
});


// 保存识别结果：学期信息在此刻（预览确认页）读取并校验
$("#education-semester-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!educationPreview) return;
  const form = event.currentTarget;
  if (!form.reportValidity()) return;
  educationPreview.semester = {
    name: form.semester_name.value.trim(),
    start_date: form.semester_start.value,
    total_weeks: Number(form.total_weeks.value),
  };
  const now = Date.now();
  const semesterUuid = crypto.randomUUID();
  const semesters = activeRows("semesters").filter((item) => item.is_current).map((item, index) => ({ ...item, is_current: false, updated_at: now + index }));
  semesters.push({ uuid: semesterUuid, ...educationPreview.semester, is_current: true, updated_at: now + semesters.length + 1, deleted: false });
  const courses = [];
  const schedules = [];
  educationPreview.courses.forEach((item, courseIndex) => {
    const courseUuid = crypto.randomUUID();
    courses.push({ uuid: courseUuid, semester_uuid: semesterUuid, name: item.name, teacher: item.teacher || "", color: forCourseNameArgb(item.name), note: "", updated_at: now + 100 + courseIndex, deleted: false });
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

async function openSharedAvailability(button = $("#shared-availability-button")) {
  button.disabled = true;
  try {
    const manifestResponse = await fetch(`${API_BASE}/api/app-manifest`, {
      credentials: "include",
      headers: accessToken ? { Authorization: `Bearer ${accessToken}` } : {},
    });
    if (!manifestResponse.ok) throw new Error("暂时无法读取功能配置");
    const envelope = await manifestResponse.json();
    const bytes = Uint8Array.from(atob(envelope.payload || ""), (char) => char.charCodeAt(0));
    const manifest = JSON.parse(new TextDecoder().decode(bytes));
    if (!Number.isInteger(manifest.revision)) throw new Error("功能配置无效");
    const launch = await request("/api/app-modules/session", {
      method: "POST",
      headers: { "X-Web-Launch": "1" },
      body: JSON.stringify({
        module_id: "couple_schedule",
        manifest_revision: manifest.revision,
      }),
    });
    const target = new URL(launch.launch_url);
    if (target.origin !== location.origin || !target.pathname.startsWith("/web/modules/")) {
      throw new Error("功能地址无效");
    }
    showAvailabilityModule(target.href);
  } catch (error) {
    setMessage(error.message || "共同空闲暂时无法打开，请稍后重试", true);
  } finally {
    button.disabled = false;
  }
}

$("#shared-availability-button").addEventListener("click", (event) => {
  openSharedAvailability(event.currentTarget);
});

// Keep the app and its in-memory session alive while the module is open.
let availabilityDialog = null;
function showAvailabilityModule(url) {
  if (!availabilityDialog) {
    availabilityDialog = document.createElement("dialog");
    availabilityDialog.id = "availability-module-dialog";
    availabilityDialog.style.cssText = "width:100%;max-width:900px;height:100dvh;max-height:100dvh;padding:0;border:0";
    const back = document.createElement("button");
    back.type = "button";
    back.className = "module-back";
    back.innerHTML = iconSvg("arrow_back") + "<span>返回</span>";
    back.onclick = () => history.back();
    availabilityDialog.append(back);
    availabilityDialog.addEventListener("cancel", event => { event.preventDefault(); history.back(); });
    document.body.append(availabilityDialog);
  }
  availabilityDialog.querySelector("iframe")?.remove();
  const frame = document.createElement("iframe");
  frame.title = "共同空闲";
  frame.style.cssText = "display:block;width:100%;height:calc(100% - 58px);border:0";
  frame.src = url;
  availabilityDialog.append(frame);
  history.pushState({ hanshangModule: true }, "", "#shared-availability");
  availabilityDialog.showModal();
}
window.addEventListener("popstate", () => {
  if (availabilityDialog?.open) {
    availabilityDialog.close();
    availabilityDialog.querySelector("iframe")?.remove();
    if (accessToken) refreshNotificationSummary();
  }
});
window.addEventListener("pageshow", event => {
  $("#shared-availability-button").disabled = false;
  if (event.persisted && sessionRecoveryPending()) restoreSession();
});

let notificationBeforeId = null;

function formatNotificationTime(value) {
  const date = new Date(value || "");
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleString("zh-CN", {
    month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit",
  });
}

async function refreshNotificationSummary() {
  try {
    const data = await request("/api/notifications?limit=1");
    $("#notification-inbox-summary").textContent = data.unread
      ? `${data.unread} 条未读通知`
      : "暂无未读通知";
  } catch {
    $("#notification-inbox-summary").textContent = "查看邀请与系统消息";
  }
}

function notificationNode(item) {
  const row = document.createElement("article");
  row.className = `notification-item${item.read_at ? "" : " unread"}`;
  row.tabIndex = 0;
  const iconWrap = document.createElement("span");
  iconWrap.innerHTML = iconSvg(item.read_at ? "notifications_none" : "notifications_active");
  const iconUse = iconWrap.querySelector("use");
  const main = document.createElement("div");
  main.className = "notification-main";
  const heading = document.createElement("div");
  heading.className = "notification-head";
  const title = document.createElement("h3");
  title.textContent = item.title || "账户通知";
  const time = document.createElement("span");
  time.className = "notification-meta";
  time.textContent = formatNotificationTime(item.created_at);
  heading.append(title, time);
  const body = document.createElement("p");
  body.textContent = item.body || "";
  main.append(heading, body);
  const side = document.createElement("div");
  side.className = "notification-side";
  let dot = null;
  if (!item.read_at) {
    dot = document.createElement("i");
    dot.className = "notification-dot";
    dot.setAttribute("aria-label", "未读");
    side.append(dot);
  }
  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "icon-button notification-delete";
  remove.innerHTML = iconSvg("delete");
  remove.setAttribute("aria-label", `删除通知：${title.textContent}`);
  side.append(remove);
  row.append(iconWrap, main, side);
  const open = async () => {
    if (!item.read_at) {
      await request(`/api/notifications/${item.id}/read`, { method: "POST" });
      item.read_at = new Date().toISOString();
      row.classList.remove("unread");
      iconUse?.setAttribute("href", "#i-notifications_none");
      dot?.remove();
      refreshNotificationSummary();
    }
    if (item.data?.type === "shared_availability_invite") {
      closeDialog("notification-inbox-dialog");
      await openSharedAvailability();
    }
  };
  row.addEventListener("click", (event) => {
    if (event.target !== remove) open().catch((error) => setMessage(error.message, true));
  });
  row.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      open().catch((error) => setMessage(error.message, true));
    }
  });
  remove.addEventListener("click", async (event) => {
    event.stopPropagation();
    try {
      await request(`/api/notifications/${item.id}`, { method: "DELETE" });
      row.remove();
      if (!$("#notification-inbox-list").children.length) {
        $("#notification-inbox-list").innerHTML = '<p class="notification-empty">暂无通知</p>';
      }
      refreshNotificationSummary();
    } catch (error) {
      setMessage(error.message || "删除通知失败", true);
    }
  });
  return row;
}

async function loadNotificationInbox(append = false) {
  const list = $("#notification-inbox-list");
  if (!append) {
    notificationBeforeId = null;
    list.innerHTML = '<p class="subtle">正在读取通知…</p>';
  }
  const suffix = notificationBeforeId ? `&before_id=${notificationBeforeId}` : "";
  try {
    const data = await request(`/api/notifications?limit=20${suffix}`);
    if (!append) list.replaceChildren();
    for (const item of data.items || []) list.append(notificationNode(item));
    if (!list.children.length) list.innerHTML = '<p class="notification-empty">暂无通知</p>';
    notificationBeforeId = data.next_before_id || null;
    $("#notification-load-more").classList.toggle("hidden", !data.has_more);
    $("#notification-unread-label").textContent = data.unread
      ? `${data.unread} 条未读`
      : "全部已读";
    $("#notification-inbox-summary").textContent = data.unread
      ? `${data.unread} 条未读通知`
      : "暂无未读通知";
  } catch (error) {
    const failure = document.createElement("p");
    failure.className = "notification-empty";
    failure.textContent = error.message || "通知加载失败";
    list.replaceChildren(failure);
    $("#notification-load-more").classList.add("hidden");
  }
}

$("#notification-inbox-button").addEventListener("click", () => {
  showDialog("notification-inbox-dialog");
  loadNotificationInbox();
});
$("#notification-load-more").addEventListener("click", () => loadNotificationInbox(true));
$("#notification-read-all").addEventListener("click", async () => {
  try {
    await request("/api/notifications/read-all", { method: "POST" });
    await loadNotificationInbox();
  } catch (error) {
    setMessage(error.message || "操作失败", true);
  }
});
$("#notification-clear-all").addEventListener("click", async () => {
  if (!confirm("确认清空全部账户通知？此操作无法恢复。")) return;
  try {
    await request("/api/notifications", { method: "DELETE" });
    await loadNotificationInbox();
  } catch (error) {
    setMessage(error.message || "清空通知失败", true);
  }
});

$("#logout-button").addEventListener("click", async () => {
  const revoke = request("/api/auth/logout", { method: "POST" }).catch(() => {});
  sessionEpoch += 1;
  try { localStorage.setItem(SIGNED_OUT_KEY, "1"); } catch {}
  userSignedOut = true;
  offlinePreview = false;
  clearScheduleCache();
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
  setMessage("已退出，本机课表缓存已清除", false, true);
  await revoke;
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
    await request("/api/push/subscribe", { method: "POST", body: JSON.stringify({ endpoint: subscription.endpoint, keys: json.keys, section_times: timeConfig.mode === "custom" ? timeConfig.times : null }) });
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
if ("serviceWorker" in navigator) navigator.serviceWorker.register("./sw.js").catch(() => {});
queueMicrotask(() => {
  if (location.hash === "#shared-availability") history.replaceState(null, "", location.pathname + location.search);
  restoreCachedSchedule();
  restoreSession();
});

function exportToCalendar() {
  if (!currentSemester) return setMessage("请先设置学期");
  var courses = normalizeCourses(currentSemester);
  if (!courses.length) return setMessage("当前学期没有课程可导出");
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
        var times = timesForDate(timeConfig,d);
        if (!times[startSec-1] || !times[endSec-1]) continue;
        var startParts = times[startSec - 1][0].split(":").map(Number);
        var endParts = times[endSec - 1][1].split(":").map(Number);
        var dtstart = new Date(d);
        dtstart.setHours(startParts[0], startParts[1], 0, 0);
        var dtend = new Date(dtstart);
        dtend.setHours(endParts[0], endParts[1], 0, 0);
        dates.push({ dtstart: dtstart, dtend: dtend });
      }
      if (dates.length) allEvents.push({ summary: course.name, desc: desc, location: location, dates: dates });
    });
  });
  if (!allEvents.length) return setMessage("所有课程的有效周次为空");
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
  setMessage("已导出 " + count + " 条上课时间到日历文件，正在下载…");
}
window.exportToCalendar = exportToCalendar;


// 作息仅保存在当前浏览器；已有推送订阅的同设备作息同步给提醒服务。
let timeDirty=false, timeSaving=false;
const timeForm=$("#section-time-form"), timeAuto=$("#time-auto"), timeRows=$("#time-rows"), timeError=$("#time-error");
function fillTimeRows(times) {
  timeRows.replaceChildren(...times.map((pair,i)=>{
    const row=document.createElement("div"); row.className="time-row";
    const title=document.createElement("strong"); title.textContent=`第 ${i+1} 节`; row.append(title);
    pair.forEach((value,j)=>{
      const label=document.createElement("label"); label.textContent=j===0?"上课":"下课";
      const input=document.createElement("input"); input.type="time"; input.required=true; input.value=value;
      input.setAttribute("aria-label",`第 ${i+1} 节${j===0?"上课":"下课"}时间`); label.append(input); row.append(label);
    }); return row;
  }));
  timeRows.querySelectorAll("input").forEach(input=>input.disabled=timeAuto.checked);
}
$("#section-time-button").addEventListener("click",()=>{
  timeDirty=false; timeError.textContent=""; timeAuto.checked=timeConfig.mode!=="custom";
  fillTimeRows(timesForDate(timeConfig,new Date())); showDialog("section-time-dialog");
});
timeForm.addEventListener("input",()=>{timeDirty=true;timeError.textContent="";});
timeAuto.addEventListener("change",()=>{
  if(timeAuto.checked) fillTimeRows(defaultTimes(new Date()));
  timeRows.querySelectorAll("input").forEach(input=>input.disabled=timeAuto.checked);
});
$("#time-summer").onclick=()=>{timeAuto.checked=false;timeDirty=true;fillTimeRows(defaultTimes(new Date(2026,6,1)));};
$("#time-winter").onclick=()=>{timeAuto.checked=false;timeDirty=true;fillTimeRows(defaultTimes(new Date(2026,10,1)));};
timeForm.addEventListener("submit",async event=>{
  event.preventDefault(); if(timeSaving) return;
  const times=[...timeRows.children].map(row=>[...row.querySelectorAll("input")].map(input=>input.value));
  const error=timeAuto.checked?"":validateTimes(times);
  if(error){timeError.textContent=error;return;}
  const config=timeAuto.checked?{version:1,mode:"automatic"}:{version:1,mode:"custom",times};
  // 先确认本地存储可写，不能把无法持久化的修改提示为成功。
  try { localStorage.setItem(TIME_KEY,JSON.stringify(config)); }
  catch { timeError.textContent="浏览器无法保存设置，请允许网站存储后重试"; return; }
  timeConfig=config;timeDirty=false;timeSaving=true;$("#time-save").disabled=true; renderSchedule();
  try {
    if("serviceWorker" in navigator){
      const registration=await navigator.serviceWorker.getRegistration();
      const sub=await registration?.pushManager?.getSubscription();
      if(sub){const json=sub.toJSON();await request("/api/push/subscribe",{method:"POST",body:JSON.stringify({endpoint:sub.endpoint,keys:json.keys,section_times:config.mode==="custom"?times:null})});}
    }
    timeSaving=false; closeDialog("section-time-dialog");setMessage("每节课时间已保存；已导入手机日历的课程需重新导出并替换旧日历");
  } catch { timeError.textContent="课表时间已保存，网页提醒同步失败。请联网后再次保存，避免提醒仍使用旧时间。"; }
  finally {timeSaving=false;$("#time-save").disabled=false;}
});
window.addEventListener("storage",event=>{if(event.key===TIME_KEY){timeConfig=parseTimes(event.newValue);renderSchedule();}});

function refreshVisibleNotifications() {
  if (!accessToken || document.visibilityState !== "visible") return;
  refreshNotificationSummary();
  if ($("#notification-inbox-dialog").open) loadNotificationInbox();
}
document.addEventListener("visibilitychange", refreshVisibleNotifications);
window.addEventListener("online", refreshVisibleNotifications);
setInterval(refreshVisibleNotifications, 60000);
window.addEventListener("storage", event => {
  if (event.key === SESSION_HISTORY_KEY && event.newValue !== "1") {
    userSignedOut = true;
    accessToken = "";
    showLogin();
  }
});
