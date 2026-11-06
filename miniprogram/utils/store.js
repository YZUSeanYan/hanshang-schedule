/*
 * 本地存储 + 全局状态。
 *
 * 网页版用 localStorage 存离线快照、作息、主题等；小程序换成 wx.setStorageSync，
 * 语义基本一致（同步、按小程序维度隔离、单 key 上限 1MB / 总上限 10MB，
 * 课表快照远小于此）。
 *
 * 另外这里实现了极简的订阅式状态：小程序页面之间没有共享的响应式数据，
 * 而同步、切课表、改作息都会同时影响多个页面，用一份订阅表把它们串起来，
 * 等价于网页版里那些显式的 renderSchedule()/renderScheduleHeader() 调用。
 */
const { KEYS } = require("./config");
const sectionTimes = require("./section-times");

function read(key, fallback) {
  try {
    const value = wx.getStorageSync(key);
    return value === "" || value === undefined || value === null ? fallback : value;
  } catch (error) {
    return fallback;
  }
}

function write(key, value) {
  try {
    wx.setStorageSync(key, value);
    return true;
  } catch (error) {
    return false;
  }
}

function remove(key) {
  try {
    wx.removeStorageSync(key);
  } catch (error) {
    // 删除失败不影响功能
  }
}

// ---- 全局状态 ----

const state = {
  user: null,               // 登录用户；null 表示游客或未登录
  snapshot: { semesters: [], courses: [], schedules: [], cursor: 0 },
  guestLocal: null,         // 游客模式下单独存在本机的课表快照
  offlinePreview: false,    // 正在展示本机缓存（未建立在线会话）
  timeConfig: sectionTimes.parse(read(KEYS.sectionTimes, null)),
  themeMode: read(KEYS.themeMode, "system"),
  systemTheme: "light",
  cardDetail: read(KEYS.cardDetail, "0") === "1",
  layout: { statusBarHeight: 20, navBarHeight: 44, windowHeight: 640, windowWidth: 375, safeBottom: 0 },
};

const listeners = [];

function subscribe(handler) {
  listeners.push(handler);
  return function unsubscribe() {
    const index = listeners.indexOf(handler);
    if (index >= 0) listeners.splice(index, 1);
  };
}

function emit() {
  listeners.slice().forEach((handler) => {
    try {
      handler();
    } catch (error) {
      // 单个页面渲染失败不应拖垮其他页面
    }
  });
}

// 有效主题：跟随系统时取系统值，否则用用户选择
function isDark() {
  if (state.themeMode === "dark") return true;
  if (state.themeMode === "light") return false;
  return state.systemTheme === "dark";
}

function themeClass() {
  return isDark() ? "theme-dark" : "theme-light";
}

function setThemeMode(mode) {
  state.themeMode = mode;
  write(KEYS.themeMode, mode);
  emit();
}

function setSystemTheme(theme) {
  state.systemTheme = theme === "dark" ? "dark" : "light";
  if (state.themeMode === "system") emit();
}

function setCardDetail(on) {
  state.cardDetail = Boolean(on);
  write(KEYS.cardDetail, state.cardDetail ? "1" : "0");
  emit();
}

// 返回是否写入成功：作息设置必须确认落盘后才提示成功，否则用户会以为改生效了
function setTimeConfig(config) {
  state.timeConfig = config;
  const ok = write(KEYS.sectionTimes, config);
  emit();
  return ok;
}

function setUser(user) {
  state.user = user || null;
  emit();
}

function setSnapshot(snapshot) {
  state.snapshot = snapshot || { semesters: [], courses: [], schedules: [], cursor: 0 };
  emit();
}

// 当前生效的课表数据：登录后用云端快照，游客用本机课表
function activeSnapshot() {
  if (state.user) return state.snapshot;
  if (state.guestLocal) return state.guestLocal;
  return { semesters: [], courses: [], schedules: [], cursor: 0 };
}

function isGuest() {
  return !state.user;
}

// ---- 离线快照（按账号隔离，与网页版 restoreCachedSchedule 同一套校验）----

function saveScheduleCache() {
  if (!state.user) return;
  write(KEYS.scheduleCache, {
    user: { id: state.user.id, username: state.user.username },
    snapshot: state.snapshot,
    savedAt: Date.now(),
  });
}

function readScheduleCache() {
  const cached = read(KEYS.scheduleCache, null);
  if (!cached || !cached.user || !Number.isInteger(cached.user.id)) return null;
  const snapshot = cached.snapshot;
  const valid = ["semesters", "courses", "schedules"].every(
    (key) => Array.isArray(snapshot && snapshot[key]) && snapshot[key].every((row) => row && typeof row === "object")
  );
  return valid ? cached : null;
}

function clearScheduleCache() {
  remove(KEYS.scheduleCache);
}

// ---- 游客课表（只在本机，登录后不会被覆盖）----

function saveGuestSchedule(snapshot) {
  state.guestLocal = snapshot;
  write(KEYS.guestSchedule, snapshot);
}

function loadGuestSchedule() {
  const stored = read(KEYS.guestSchedule, null);
  if (stored && Array.isArray(stored.semesters)) state.guestLocal = stored;
  return state.guestLocal;
}

function clearGuestSchedule() {
  state.guestLocal = null;
  remove(KEYS.guestSchedule);
}

// ---- 会话痕迹（决定启动时是「静默显示登录页」还是「提示登录已过期」）----

function hasSessionHistory() {
  return read(KEYS.sessionHistory, "") === "1";
}

function rememberSessionHistory() {
  remove(KEYS.signedOut);
  write(KEYS.sessionHistory, "1");
}

function forgetSessionHistory() {
  remove(KEYS.sessionHistory);
}

function markSignedOut() {
  write(KEYS.signedOut, "1");
}

function isSignedOut() {
  return read(KEYS.signedOut, "") === "1";
}

function clearSignedOut() {
  remove(KEYS.signedOut);
}

// ---- 订阅消息额度记账（小程序提醒降级方案，见 profile 页说明）----

function readSubscribeQuota() {
  const stored = read(KEYS.subscribeQuota, null);
  if (!stored || stored.date !== new Date().toDateString()) return { date: new Date().toDateString(), granted: 0, lastAt: 0 };
  return stored;
}

function bumpSubscribeQuota() {
  const quota = readSubscribeQuota();
  quota.granted += 1;
  quota.lastAt = Date.now();
  write(KEYS.subscribeQuota, quota);
  return quota;
}

module.exports = {
  KEYS,
  read,
  write,
  remove,
  state,
  subscribe,
  emit,
  isDark,
  themeClass,
  setThemeMode,
  setSystemTheme,
  setCardDetail,
  setTimeConfig,
  setUser,
  setSnapshot,
  activeSnapshot,
  isGuest,
  saveScheduleCache,
  readScheduleCache,
  clearScheduleCache,
  saveGuestSchedule,
  loadGuestSchedule,
  clearGuestSchedule,
  hasSessionHistory,
  rememberSessionHistory,
  forgetSessionHistory,
  markSignedOut,
  isSignedOut,
  clearSignedOut,
  readSubscribeQuota,
  bumpSubscribeQuota,
};
