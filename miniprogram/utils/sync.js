/*
 * 课表同步。游客与登录用户走同一条写入路径，只是落点不同：
 *   登录用户 → /api/sync/push + /api/sync/pull，云端为准，并写一份本机快照供离线查看
 *   游客     → 直接写本机课表（hanshang-mp-guest-schedule-v1）
 *
 * 这样「手动建课」在游客模式下零门槛可用（微信审核不允许强制登录），
 * 而所有调用方（课程表单、课表管理、导入、口令领取）无需关心当前是哪种模式。
 */
const api = require("./api");
const store = require("./store");
const { uuid } = require("./format");
const { forCourseNameArgb } = require("./colors");

async function pull(silent) {
  if (store.isGuest()) {
    store.loadGuestSchedule();
    store.emit();
    return store.activeSnapshot();
  }
  const snapshot = await api.request("/api/sync/pull?since=0");
  store.setSnapshot(snapshot);
  store.saveScheduleCache();
  return snapshot;
}

/*
 * 推送变更。空数组会被后端忽略，这里原样透传即可。
 * 返回 true 表示写入成功（游客模式同样返回 true，便于调用方统一提示）。
 */
async function push(changes) {
  const payload = {
    semesters: changes.semesters || [],
    courses: changes.courses || [],
    schedules: changes.schedules || [],
    // 调休（放假/补课）覆盖行，语义与课程一致：按 uuid LWW 合并，deleted 走墓碑
    overrides: changes.overrides || [],
    events: changes.events || [],
  };
  if (store.isGuest()) {
    const snapshot = store.activeSnapshot();
    const next = {
      semesters: mergeRows(snapshot.semesters, payload.semesters),
      courses: mergeRows(snapshot.courses, payload.courses),
      schedules: mergeRows(snapshot.schedules, payload.schedules),
      overrides: mergeRows(snapshot.overrides, payload.overrides),
      events: mergeRows(snapshot.events, payload.events),
      cursor: 0,
    };
    store.saveGuestSchedule(next);
    store.emit();
    return true;
  }
  await api.request("/api/sync/push", { method: "POST", body: payload });
  await pull(true);
  return true;
}

/*
 * 本机合并：按 uuid 覆盖，updated_at 更大的赢（与后端 last-write-wins 一致）。
 * 删除是标记 deleted=true 的墓碑行，保留在数组里，语义与云端相同。
 */
function mergeRows(existing, incoming) {
  const rows = (existing || []).slice();
  (incoming || []).forEach((row) => {
    if (!row || !row.uuid) return;
    const index = rows.findIndex((item) => item.uuid === row.uuid);
    if (index === -1) rows.push(row);
    else if ((row.updated_at || 0) >= (rows[index].updated_at || 0)) rows[index] = Object.assign({}, rows[index], row);
  });
  return rows;
}

// 新建课程：生成 uuid 与课程色（ARGB），与云端字段保持一致
function buildCourse(input, existing) {
  const name = String(input.name || "").trim();
  return {
    uuid: existing ? existing.uuid : uuid(),
    semester_uuid: input.semester_uuid,
    name,
    teacher: String(input.teacher || "").trim(),
    color: existing && existing.color != null ? existing.color : forCourseNameArgb(name),
    note: String(input.note || "").trim(),
    updated_at: Date.now(),
    deleted: false,
  };
}

function buildSlot(input, courseUuid, existing, offset) {
  return {
    uuid: existing ? existing.uuid : uuid(),
    course_uuid: courseUuid,
    day_of_week: Number(input.day_of_week),
    start_section: Number(input.start_section),
    end_section: Number(input.end_section),
    weeks_type: Number(input.weeks_type),
    custom_weeks: String(input.custom_weeks || "").trim(),
    location: String(input.location || "").trim(),
    updated_at: Date.now() + (offset || 0),
    deleted: false,
  };
}

// 调休覆盖行（放假/补课）
function buildOverride(input, existing, offset) {
  return {
    uuid: existing ? existing.uuid : uuid(),
    date: String(input.date || ""),
    kind: input.kind === "makeup" ? "makeup" : "off",
    weekday: Number(input.weekday) || 0,
    note: String(input.note || "").trim(),
    updated_at: Date.now() + (offset || 0),
    deleted: input.deleted === true,
  };
}

// 日程 / 待办 / 考试（App 2.0 的事件模型）
function buildEvent(input, existing, offset) {
  return {
    uuid: existing ? existing.uuid : uuid(),
    event_type: input.event_type || "event",
    title: String(input.title || ""),
    short_title: String(input.short_title || "").trim(),
    date: String(input.date || ""),
    weekday: Number(input.weekday) || 0,
    start_time: String(input.start_time || ""),
    end_time: String(input.end_time || ""),
    start_section: Number(input.start_section) || 0,
    end_section: Number(input.end_section) || 0,
    busy_sections: String(input.busy_sections || ""),
    location: String(input.location || ""),
    note: String(input.note || "").trim(),
    updated_at: Date.now() + (offset || 0),
    deleted: input.deleted === true,
  };
}

module.exports = { pull, push, mergeRows, buildCourse, buildSlot, buildOverride, buildEvent };
