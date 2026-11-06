const API = "../api/admin-console";
let csrf = "",
  page = 1,
  currentUser = null;
const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
function escapeHtml(v = "") {
  const d = document.createElement("div");
  d.textContent = String(v);
  return d.innerHTML.replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}
// 按用户名稳定取色板色，用于首字母头像
function avatarHue(name = "") {
  let h = 0;
  for (const ch of String(name)) h = (h * 31 + ch.codePointAt(0)) >>> 0;
  return h % 6;
}
function avatarHtml(name = "") {
  const initial = (String(name).trim()[0] || "?").toUpperCase();
  return `<span class="avatar" data-hue="${avatarHue(name)}" aria-hidden="true">${escapeHtml(initial)}</span>`;
}
function statCard({ icon, tone = "", label, value, deltaHtml = "", meterHtml = "" }) {
  return `<div class="stat"><div class="stat-head"><span class="stat-icon"${tone ? ` data-tone="${tone}"` : ""}>${icon}</span><span class="stat-label">${label}</span></div><b>${value}</b>${deltaHtml}${meterHtml}</div>`;
}
function fmt(v) {
  if (!v) return "—";
  return new Intl.DateTimeFormat("zh-CN", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(v));
}
function toast(message) {
  const el = $("#toast");
  el.textContent = message;
  el.classList.add("show");
  setTimeout(() => el.classList.remove("show"), 2400);
}
async function request(path, options = {}) {
  const headers = { ...(options.headers || {}) };
  if (!(options.body instanceof FormData)) headers["Content-Type"] = "application/json";
  if (options.method && options.method !== "GET")
    headers["X-CSRF-Token"] = csrf;
  const response = await fetch(`${API}${path}`, {
    credentials: "same-origin",
    ...options,
    headers,
  });
  let body = {};
  try {
    body = await response.json();
  } catch {}
  if (!response.ok) {
    if (response.status === 401) showLogin();
    throw new Error(body.message || "请求失败");
  }
  return body.data;
}
function showLogin() {
  csrf = "";
  $("#appView").hidden = true;
  $("#loginView").hidden = false;
}
function showApp() {
  $("#loginView").hidden = true;
  $("#appView").hidden = false;
  loadDashboard();
}
async function boot() {
  try {
    const data = await request("/session");
    csrf = data.csrf_token;
    showApp();
  } catch {
    showLogin();
  }
}
$("#loginForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const form = e.currentTarget;
  $("#loginError").textContent = "";
  const values = Object.fromEntries(new FormData(form));
  try {
    const data = await request("/login", {
      method: "POST",
      body: JSON.stringify(values),
    });
    csrf = data.csrf_token;
    form.reset();
    showApp();
  } catch (error) {
    $("#loginError").textContent = error.message;
  }
});
$("#logoutButton").addEventListener("click", async () => {
  try {
    await request("/logout", { method: "POST", body: "{}" });
  } finally {
    showLogin();
  }
});
$("#dialogClose").addEventListener("click", () =>
  $("#userDialog").close(),
);
function go(target, shouldLoad = true) {
  $$(".page").forEach((x) => x.classList.toggle("active", x.id === target));
  $$(".nav-item").forEach((x) =>
    x.classList.toggle("active", x.dataset.target === target),
  );
  $("#pageTitle").textContent = {
    dashboard: "运行概览",
    stats: "数据看板",
    users: "用户管理",
    notifications: "通知管理",
    about: "关于页编辑",
    versions: "版本发布",
    clients: "客户端版本",
    audit: "审计日志",
  }[target];
  if (target === "users") loadUsers();
  if (target === "notifications" && shouldLoad) loadNotificationUsers();
  if (target === "about") loadAbout();
  if (target === "stats") loadStats();
  if (target === "versions") loadVersions();
  if (target === "clients") loadClientVersions();
  if (target === "audit") loadAudit();
}
$$(".nav-item").forEach((x) =>
  x.addEventListener("click", () => go(x.dataset.target)),
);
$$("[data-go]").forEach((x) =>
  x.addEventListener("click", () => go(x.dataset.go)),
);
async function loadDashboard() {
  try {
    const [stats, users] = await Promise.all([
      request("/summary"),
      request("/users?page=1&page_size=5"),
    ]);
    const labels = {
      users: ["注册用户", "👥", ""],
      push_devices: ["推送设备", "📱", "blue"],
      semesters: ["云端学期", "🗓️", "violet"],
      courses: ["云端课程", "📚", "gold"],
      schedules: ["时间安排", "⏰", "rose"],
    };
    $("#dashboardStats").innerHTML = Object.entries(labels)
      .map(([k, [label, icon, tone]]) =>
        statCard({ icon, tone, label, value: stats[k] }),
      )
      .join("");
    $("#recentUsers").innerHTML = users.items.length
      ? users.items
          .map(
            (u) =>
              `<div class="audit-item user-item">${avatarHtml(u.username)}<div class="user-meta"><div class="audit-action">${escapeHtml(u.username)}</div><div class="audit-detail">${escapeHtml(u.email)}${u.created_at ? ` · 注册于 ${fmt(u.created_at)}` : ""}</div></div><div><button class="row-action" data-notify-user="${u.id}">发通知 →</button></div></div>`,
          )
          .join("")
      : '<div class="empty">暂无用户</div>';
    $$('[data-notify-user]').forEach((x) => x.addEventListener('click', () => openNotificationForUser(x.dataset.notifyUser)));
  } catch (e) {
    toast(e.message);
  }
}
let searchTimer;
$("#userSearch").addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    page = 1;
    loadUsers();
  }, 280);
});
$("#refreshUsers").addEventListener("click", () => loadUsers());
document.querySelectorAll('[data-notification-mode]').forEach(button => {
  button.addEventListener('click', () => {
    if (notificationSending) return;
    $('#notificationMode').value = button.dataset.notificationMode;
    notificationUserChanged();
  });
});
$("#notificationForm").addEventListener("submit", sendNotification);
$("#refreshNotifications").addEventListener("click", () => loadUserNotifications());
async function loadUsers() {
  try {
    const q = encodeURIComponent($("#userSearch").value.trim());
    const data = await request(`/users?q=${q}&page=${page}&page_size=20`);
    $("#userRows").innerHTML = data.items.length
      ? data.items
          .map(
            (u) =>
              `<tr><td>${avatarHtml(u.username)}${escapeHtml(u.username)}</td><td>${escapeHtml(u.email)}</td><td><span class="course-count">${u.course_count} 门</span></td><td class="device-cell">${u.android_count ? `<span class="dev-chip">安卓 ${u.android_count}</span>` : ""}${u.web_count ? `<span class="dev-chip web">网页 ${u.web_count}</span>` : ""}${!u.android_count && !u.web_count ? '<span class="muted">无设备</span>' : ""}</td><td>${u.last_active ? fmt(u.last_active) : '<span class="muted">从未活跃</span>'}</td><td>${u.restricted ? '<span class="state-badge limited">已限制</span>' : '<span class="state-badge ok">正常</span>'}</td><td>${fmt(u.created_at)}</td><td><button class="row-action" data-notify-user="${u.id}">通知</button><button class="row-action" data-user="${u.id}">管理 →</button></td></tr>`,
          )
          .join("")
      : '<tr><td colspan="8" class="empty">没有匹配的用户</td></tr>';
    $$("[data-user]").forEach((x) =>
      x.addEventListener("click", () => openUser(x.dataset.user)),
    );
    $$("[data-notify-user]").forEach((x) =>
      x.addEventListener("click", () => openNotificationForUser(x.dataset.notifyUser)),
    );
    const pages = Math.max(1, Math.ceil(data.total / data.page_size));
    $("#userPagination").innerHTML =
      `第 ${data.page} / ${pages} 页 · 共 ${data.total} 位用户 ${data.page > 1 ? '<button id="prevPage" class="text-button">上一页</button>' : ""} ${data.page < pages ? '<button id="nextPage" class="text-button">下一页</button>' : ""}`;
    $("#prevPage")?.addEventListener("click", () => {
      page--;
      loadUsers();
    });
    $("#nextPage")?.addEventListener("click", () => {
      page++;
      loadUsers();
    });
  } catch (e) {
    toast(e.message);
  }
}
async function openUser(id) {
  try {
    currentUser = await request(`/users/${id}`);
    $("#dialogTitle").textContent = currentUser.username;
    $("#dialogBody").innerHTML =
      `<form id="userEditForm" class="detail-form"><label>用户名<input name="username" value="${escapeHtml(currentUser.username)}" required maxlength="32"></label><label>邮箱<input name="email" type="email" value="${escapeHtml(currentUser.email)}" required maxlength="255"></label><button class="primary" type="submit">保存用户信息</button></form><div class="detail-grid"><div class="detail-metric"><b>${currentUser.counts.semesters}</b><span>学期</span></div><div class="detail-metric"><b>${currentUser.counts.courses}</b><span>课程</span></div><div class="detail-metric"><b>${currentUser.counts.schedules}</b><span>安排</span></div><div class="detail-metric"><b>${currentUser.notification_count}</b><span>通知</span></div></div><div class="user-state-row">${currentUser.restricted?.active ? `<span class="state-badge limited">已限制</span><span class="muted">${escapeHtml(currentUser.restricted.reason || "未填原因")} · ${fmt(currentUser.restricted.disabled_at)}</span>` : '<span class="state-badge ok">正常</span>'}<span class="muted">最近活跃：${currentUser.last_active ? fmt(currentUser.last_active) : "从未活跃"}</span></div><div class="device-list">${(currentUser.devices || []).length || currentUser.web_count ? `${(currentUser.devices || []).map((d) => `<span class="dev-chip${d.platform === "harmony" ? " harmony" : ""}">${d.platform === "harmony" ? "鸿蒙" : "安卓"} · ${fmt(d.last_seen_at)}</span>`).join("")}${currentUser.web_count ? `<span class="dev-chip web">网页订阅 ${currentUser.web_count}</span>` : ""}` : '<span class="muted">未绑定任何推送设备</span>'}</div><div class="credential-status"><b>教务凭据：</b>${currentUser.credential_vault.exists ? `已加密同步（学号 ${escapeHtml(currentUser.credential_vault.student_id_hint || "已隐藏")}，${fmt(currentUser.credential_vault.updated_at)}）` : "未同步"}<br><small>后台仅能查看状态并删除客户端密文，不能读取教务密码。</small></div><p class="muted">注册于 ${fmt(currentUser.created_at)}</p><div class="actions"><button id="openNotificationManager" type="button" class="secondary">发送通知</button><button id="clearData" type="button" class="danger">清空云端课表数据</button>${currentUser.credential_vault.exists ? '<button id="clearCredential" type="button" class="danger">删除教务凭据密文</button>' : ""}<button id="deleteUser" type="button" class="danger">永久删除账号</button></div><p class="muted">永久删除会清除账号、课表、会话、通知、设备登记与加密凭据，且不可恢复。</p>`;
    $("#dialogBody .credential-status")?.insertAdjacentHTML(
      "beforeend",
      `<br><b>往返自检：</b>${currentUser.credential_vault.last_verified_at ? `已通过 · ${fmt(currentUser.credential_vault.last_verified_at)}` : "尚未通过"}`,
    );
    $("#userEditForm").addEventListener("submit", saveUser);
    $("#openNotificationManager").addEventListener("click", () => { const id = currentUser.id; $("#userDialog").close(); openNotificationForUser(id); });
    $("#clearData").addEventListener("click", clearData);
    $("#clearCredential")?.addEventListener("click", clearCredential);
    $("#deleteUser")?.addEventListener("click", deleteUser);
    $("#userDialog").showModal();
  } catch (e) {
    toast(e.message);
  }
}
let notificationUser = null;
const selectedRecipients = new Map();
let recipientUsers = [], recipientPage = 1, recipientTotal = 0;
let recipientSearchVersion = 0, recipientSelectionVersion = 0, recipientSearchTimer;
let notificationSending = false, notificationSelectionPending = false;
function updateNotificationSubmit() {
  $('#sendNotificationButton').textContent = notificationSending ? '正在发送，请勿重复操作…' :
    $('#notificationMode').value === 'all' ? '向全部用户发送' :
    selectedRecipients.size ? `向已选 ${selectedRecipients.size} 人发送` : '请选择收件人';
  $('#sendNotificationButton').disabled = notificationSending || notificationSelectionPending || !notificationUser;
}
function renderSelectedRecipients() {
  $('#selectedRecipientCount').textContent = `已选 ${selectedRecipients.size} / 50 人`;
  $('#clearRecipients').disabled = !selectedRecipients.size;
  $('#selectedRecipients').innerHTML = [...selectedRecipients.values()].map(user =>
    `<div class="selected-recipient"><span><b>${escapeHtml(user.username)}</b><small>${escapeHtml(user.email)}</small></span><button type="button" data-remove-recipient="${user.id}" aria-label="移除 ${escapeHtml(user.username)}">×</button></div>`
  ).join('');
}
function renderRecipientResults() {
  $('#recipientResults').innerHTML = recipientUsers.length ? recipientUsers.map(user =>
    `<label class="recipient-row"><input type="checkbox" data-recipient-id="${user.id}" ${selectedRecipients.has(user.id) ? 'checked' : ''}><span class="recipient-identity"><b>${escapeHtml(user.username)}</b><small>${escapeHtml(user.email)}</small><small>Android ${user.android_count || 0} · 网页端 ${user.web_count || 0}</small></span></label>`
  ).join('') : '<div class="empty">没有匹配的用户，请尝试其他用户名或邮箱</div>';
  const pages = Math.max(1, Math.ceil(recipientTotal / 20));
  $('#recipientPageInfo').textContent = `第 ${recipientPage} / ${pages} 页 · ${recipientTotal} 人`;
  $('#recipientPrev').disabled = recipientPage <= 1;
  $('#recipientNext').disabled = recipientPage >= pages;
}
async function searchNotificationUsers() {
  const version = ++recipientSearchVersion;
  const q = encodeURIComponent($('#notificationSearch').value.trim());
  $('#recipientResults').textContent = '正在加载用户…';
  $('#recipientPrev').disabled = $('#recipientNext').disabled = true;
  try {
    const data = await request(`/users?q=${q}&page=${recipientPage}&page_size=20`);
    if (version !== recipientSearchVersion) return;
    recipientUsers = data.items;
    recipientTotal = data.total;
    renderRecipientResults();
  } catch (error) {
    if (version !== recipientSearchVersion) return;
    recipientUsers = [];
    $('#recipientResults').innerHTML = '<div class="empty">用户加载失败 <button id="retryRecipients" class="text-button" type="button">重试</button></div>';
    $('#recipientPageInfo').textContent = '';
    $('#retryRecipients').addEventListener('click', searchNotificationUsers);
  }
}
async function loadNotificationUsers(selectedId = '') {
  if (notificationSending) return;
  if (selectedId) {
    // Fetch explicitly: a user opened from user management may be beyond page 1.
    const version = ++recipientSelectionVersion;
    notificationUser = null;
    notificationSelectionPending = true;
    updateNotificationSubmit();
    try {
      const user = await request(`/users/${Number(selectedId)}`);
      if (version !== recipientSelectionVersion) return;
      selectedRecipients.clear();
      selectedRecipients.set(user.id, user);
      $('#notificationMode').value = 'selected';
    } catch (error) {
      if (version === recipientSelectionVersion) {
        notificationSelectionPending = false;
        updateNotificationSubmit();
        toast(error.message);
      }
      return;
    }
  }
  renderSelectedRecipients();
  await Promise.all([searchNotificationUsers(), notificationUserChanged()]);
}
async function openNotificationForUser(id) {
  go('notifications', false);
  await loadNotificationUsers(String(id));
}
$('#notificationSearch').addEventListener('input', () => {
  clearTimeout(recipientSearchTimer);
  ++recipientSearchVersion;
  recipientPage = 1;
  recipientSearchTimer = setTimeout(searchNotificationUsers, 250);
});
$('#recipientPrev').addEventListener('click', () => { recipientPage--; searchNotificationUsers(); });
$('#recipientNext').addEventListener('click', () => { recipientPage++; searchNotificationUsers(); });
$('#recipientResults').addEventListener('change', event => {
  const input = event.target.closest('[data-recipient-id]');
  if (!input || notificationSending) return;
  const id = Number(input.dataset.recipientId);
  if (input.checked) {
    if (selectedRecipients.size >= 50) { input.checked = false; return toast('单次最多选择 50 人'); }
    const user = recipientUsers.find(user => user.id === id);
    if (!user) return;
    selectedRecipients.set(id, user);
  } else selectedRecipients.delete(id);
  renderSelectedRecipients();
  notificationUserChanged();
});
$('#selectedRecipients').addEventListener('click', event => {
  const button = event.target.closest('[data-remove-recipient]');
  if (!button || notificationSending) return;
  selectedRecipients.delete(Number(button.dataset.removeRecipient));
  renderSelectedRecipients();
  renderRecipientResults();
  notificationUserChanged();
});
$('#clearRecipients').addEventListener('click', () => {
  selectedRecipients.clear(); renderSelectedRecipients(); renderRecipientResults(); notificationUserChanged();
});
async function notificationUserChanged() {
  const version = ++recipientSelectionVersion;
  const all = $('#notificationMode').value === 'all';
  document.querySelectorAll('[data-notification-mode]').forEach(button => {
    button.setAttribute('aria-pressed', String((button.dataset.notificationMode === 'all') === all));
  });
  $('#recipientSelection').hidden = all;
  $('#broadcastNotice').hidden = !all;
  const deviceSelect = $('#notificationDevice');
  deviceSelect.innerHTML = '<option value="">全部已绑定设备</option>';
  deviceSelect.disabled = true;
  notificationUser = null;
  notificationSelectionPending = false;
  if (all) {
    notificationUser = '__all__';
    deviceSelect.disabled = false;
    deviceSelect.insertAdjacentHTML('beforeend', '<option value="__android__">仅 Android 设备</option><option value="__web__">仅网页端（PWA）</option>');
    $('#notificationHistory').textContent = '全部账户模式：选择具体用户可查看其发送记录';
  } else if (selectedRecipients.size === 1) {
    notificationSelectionPending = true;
    updateNotificationSubmit();
    $('#notificationHistory').textContent = '正在加载设备和发送记录…';
    const user = [...selectedRecipients.values()][0];
    try {
      const devices = await request(`/users/${user.id}/devices`);
      if (version !== recipientSelectionVersion) return;
      notificationUser = user;
      deviceSelect.disabled = false;
      deviceSelect.insertAdjacentHTML('beforeend', devices.map(device =>
        `<option value="${escapeHtml(device.device_id)}">${escapeHtml(device.platform)} · ${escapeHtml(device.label)} · ${escapeHtml(device.app_version || '版本未知')}</option>`
      ).join(''));
      await loadUserNotifications();
    } catch (error) {
      if (version !== recipientSelectionVersion) return;
      $('#notificationHistory').textContent = '设备加载失败，请重新选择该用户后重试';
      toast(error.message);
    } finally {
      if (version === recipientSelectionVersion) { notificationSelectionPending = false; updateNotificationSubmit(); }
    }
  } else if (selectedRecipients.size > 1) {
    notificationUser = { multiple: [...selectedRecipients.keys()] };
    $('#notificationHistory').textContent = `已选 ${selectedRecipients.size} 人；选择单个用户可查看其发送记录`;
  } else $('#notificationHistory').textContent = '请搜索并勾选收件人';
  updateNotificationSubmit();
}
async function sendNotification(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const values = Object.fromEntries(new FormData(form));
  if (!notificationUser || notificationSelectionPending || notificationSending) return toast('请先选择账户并等待设备加载完成');
  const button = form.querySelector("button[type=submit]");
  notificationSending = true;
  updateNotificationSubmit();
  button.disabled = true;
  $('#notificationRecipients').disabled = true;
  const deviceWasDisabled = $('#notificationDevice').disabled;
  $('#notificationDevice').disabled = true;
  try {
    let result;
    if (notificationUser === '__all__') {
      const deviceVal = $('#notificationDevice').value;
      const platformFilter = deviceVal === '__android__' ? 'android' : deviceVal === '__web__' ? 'web' : null;
      const targetDesc = platformFilter === 'android' ? '仅 Android 设备' : platformFilter === 'web' ? '仅网页端（PWA）' : '全部设备';
      if (!confirm(`确认向【全部账户 · ${targetDesc}】发送这条通知？`)) return;
      const silent = $('#notificationSilent')?.checked === true;
      result = await request('/notifications/broadcast', {
        method: 'POST',
        body: JSON.stringify({ title: values.title, body: values.body, platform: platformFilter, silent }),
      });
      toast(silent
        ? `静默公告已送达 ${result.users} 个账户的收件箱（未触发系统推送）`
        : `广播已发送：${result.users} 个账户 · Android ${result.android_status} · 网页端 ${result.web_delivered}/${result.web_total}`);
    } else if (notificationUser.multiple) {
      if (!confirm(`确认向已选的 ${notificationUser.multiple.length} 个账户发送这条通知？`)) return;
      result = await request('/notifications/batch', {
        method: 'POST',
        body: JSON.stringify({ title: values.title, body: values.body, user_ids: notificationUser.multiple }),
      });
      toast(`已发送给 ${result.targeted} 个账户`);
    } else {
      const deviceId = $('#notificationDevice').value;
      if (deviceId) values.device_id = deviceId;
      const target = $('#notificationDevice').selectedOptions[0]?.textContent || '全部已绑定设备';
      if (!confirm(`确认向“${notificationUser.username}”的“${target}”发送这条通知？`)) return;
      result = await request(`/users/${notificationUser.id}/notifications`, {
        method: 'POST',
        body: JSON.stringify(values),
      });
      toast(result.status === 'accepted' ? `已受理：${result.target_label}` : '消息已保存，推送通道暂不可用');
      await loadUserNotifications();
    }
    form.querySelector('[name=title]').value = '';
    form.querySelector('[name=body]').value = '';
    loadAudit();
  } catch (error) {
    toast(error.message);
  } finally {
    notificationSending = false;
    $('#notificationRecipients').disabled = false;
    $('#notificationDevice').disabled = deviceWasDisabled;
    updateNotificationSubmit();
  }
}
async function loadUserNotifications() {
  const container = $("#notificationHistory");
  if (!container || !notificationUser || notificationUser === '__all__' || notificationUser.multiple) return;
  const userId = notificationUser.id;
  const version = recipientSelectionVersion;
  try {
    const rows = await request(`/users/${userId}/notifications?limit=20`);
    if (version !== recipientSelectionVersion) return;
    container.innerHTML = rows.length ? rows.map((row) =>
      `<div class="audit-item"><div class="audit-action">${escapeHtml(row.title)}</div><div class="audit-detail">${escapeHtml(row.body)}<br><span class="badge ${row.status === "failed" ? "off" : ""}">${escapeHtml(row.status)}</span> · ${escapeHtml(row.target_label || '全部设备')} ${row.read_at ? " · 已读" : " · 未读"}</div><div class="audit-time">${fmt(row.created_at)}</div></div>`
    ).join("") : '<div class="empty">尚未发送通知</div>';
  } catch (error) {
    if (version !== recipientSelectionVersion) return;
    container.innerHTML = `<div class="empty">${escapeHtml(error.message)}</div>`;
  }
}
async function saveUser(e) {
  e.preventDefault();
  const values = Object.fromEntries(new FormData(e.currentTarget));
  try {
    await request(`/users/${currentUser.id}`, {
      method: "PATCH",
      body: JSON.stringify(values),
    });
    toast("用户信息已更新");
    $("#userDialog").close();
    loadUsers();
    loadDashboard();
  } catch (error) {
    toast(error.message);
  }
}
async function clearData() {
  const confirmText = prompt(
    `此操作不可撤销。请输入用户名“${currentUser.username}”确认清空云端课表数据：`,
  );
  if (confirmText === null) return;
  try {
    await request(`/users/${currentUser.id}/sync-data`, {
      method: "DELETE",
      body: JSON.stringify({ confirm: confirmText }),
    });
    toast("云端课表数据已清空");
    $("#userDialog").close();
    loadDashboard();
  } catch (e) {
    toast(e.message);
  }
}
async function clearCredential() {
  const confirmText = prompt(
    `此操作不可撤销。请输入用户名“${currentUser.username}”确认删除教务凭据密文：`,
  );
  if (confirmText === null) return;
  try {
    await request(`/users/${currentUser.id}/credential-vault`, {
      method: "DELETE",
      body: JSON.stringify({ confirm: confirmText }),
    });
    toast("教务凭据密文已删除");
    $("#userDialog").close();
  } catch (error) {
    toast(error.message);
  }
}
async function deleteUser() {
  const confirmText = prompt(
    `永久删除后不可恢复。请输入完整用户名“${currentUser.username}”确认删除账号及全部关联数据：`,
  );
  if (confirmText === null) return;
  if (!confirm("最后确认：永久删除该账号、课表、会话、分享口令、推送订阅和加密凭据？")) return;
  try {
    await request(`/users/${currentUser.id}`, {
      method: "DELETE",
      body: JSON.stringify({ confirm: confirmText }),
    });
    toast("账号及全部关联数据已永久删除");
    currentUser = null;
    $("#userDialog").close();
    loadUsers();
    loadDashboard();
    loadAudit();
  } catch (error) {
    toast(error.message);
  }
}
$("#refreshAudit").addEventListener("click", loadAudit);
$("#refreshAbout").addEventListener("click", loadAbout);
$("#aboutForm").addEventListener("submit", saveAbout);
$("#uploadAboutAvatar").addEventListener("click", () => uploadAboutMedia("avatar"));
$("#uploadAboutQr").addEventListener("click", () => uploadAboutMedia("payment_qr"));

function aboutMediaUrl(name) {
  return name ? `../api/about/media/${encodeURIComponent(name)}` : "";
}

function setAboutPreview(selector, name) {
  const image = $(selector);
  image.hidden = !name;
  if (name) image.src = `${aboutMediaUrl(name)}?v=${Date.now()}`;
  else image.removeAttribute("src");
}

async function loadAbout() {
  try {
    const data = await request("/about");
    $("#aboutName").value = data.display_name || "邗上课表";
    $("#aboutIntro").value = data.intro || "";
    $("#aboutWebsite").value = data.website_url || "";
  $("#aboutIcp").value = data.icp_beian || "";
    setAboutPreview("#aboutAvatarPreview", data.avatar_media);
    setAboutPreview("#aboutQrPreview", data.payment_qr_media);
  } catch (error) {
    toast(error.message);
  }
}

async function saveAbout(event) {
  event.preventDefault();
  const values = Object.fromEntries(new FormData(event.currentTarget));
  try {
    await request("/about", { method: "PATCH", body: JSON.stringify(values) });
    toast("关于页内容已保存");
  } catch (error) {
    toast(error.message);
  }
}

async function uploadAboutMedia(kind) {
  const input = kind === "avatar" ? $("#aboutAvatarFile") : $("#aboutQrFile");
  if (!input.files?.length) return toast("请先选择图片");
  const form = new FormData();
  form.append("upload", input.files[0]);
  try {
    const data = await request(`/about/media/${kind}`, { method: "POST", body: form });
    setAboutPreview(
      kind === "avatar" ? "#aboutAvatarPreview" : "#aboutQrPreview",
      kind === "avatar" ? data.avatar_media : data.payment_qr_media,
    );
    input.value = "";
    toast(kind === "avatar" ? "头像已上传" : "收款码已上传");
  } catch (error) {
    toast(error.message);
  }
}

async function loadAudit() {
  try {
    const rows = await request("/audit?limit=80");
    $("#auditList").innerHTML = rows.length
      ? rows
          .map(
            (r) =>
              `<div class="audit-item"><div class="audit-action">${escapeHtml(r.action)}</div><div class="audit-detail">${r.target_user_id ? `用户 #${r.target_user_id} · ` : ""}${escapeHtml(r.detail)}</div><div class="audit-time">${fmt(r.created_at)}</div></div>`,
          )
          .join("")
      : '<div class="empty">暂无审计记录</div>';
  } catch (e) {
    toast(e.message);
  }
}
setInterval(() => {
  $("#clock").textContent = new Intl.DateTimeFormat("zh-CN", {
    dateStyle: "long",
    timeStyle: "short",
  }).format(new Date());
}, 1000);
boot();

// 通用渐变柱状图（DAU 与新增注册共用）
function renderBarChart(container, series, valueKey, unit) {
  const maxVal = Math.max(...series.map(d => d[valueKey]), 1);
  const total = series.reduce((s, d) => s + d[valueKey], 0);
  const avg = Math.round(total / series.length * 10) / 10;
  const peak = series.reduce((a, b) => (b[valueKey] > a[valueKey] ? b : a), series[0]);
  const barW = 100 / series.length;
  const svgH = 150;
  const padTop = 6;
  const gridYs = [0.25, 0.5, 0.75].map(r => padTop + (svgH - padTop) * (1 - r));
  const grid = gridYs.map(y =>
    `<line x1="0" x2="100" y1="${y.toFixed(1)}" y2="${y.toFixed(1)}" stroke="#dfe9e3" stroke-width="1" stroke-dasharray="3 4" vector-effect="non-scaling-stroke"/>`
  ).join("");
  const bars = series.map((d, i) => {
    const value = d[valueKey];
    const h = Math.max(value / maxVal * (svgH - padTop), value ? 2.5 : 1.2);
    const x = i * barW;
    const isPeak = d === peak && value > 0;
    return `<rect class="bar" x="${x}%" y="${svgH - h}" width="${barW * 0.78}%" height="${h}" rx="1.2" fill="${isPeak ? "url(#barPeak)" : "url(#barGrad)"}" opacity="${value ? 0.92 : 0.22}"><title>${d.date}：${value} ${unit}</title></rect>`;
  }).join("");
  const axisDates = [0, 7, 14, 21, series.length - 1]
    .map(i => series[Math.min(i, series.length - 1)]?.date?.slice(5) || "");
  container.innerHTML =
    `<div class="chart-summary">
      <div class="cs-item"><b>${total}</b><span>30 天累计${unit}</span></div>
      <div class="cs-item"><b>${avg}</b><span>日均</span></div>
      <div class="cs-item"><b>${peak[valueKey]}</b><span>峰值 · ${peak.date?.slice(5) || ""}</span></div>
    </div>
    <div class="chart-scroll"><svg class="bar-chart" viewBox="0 0 100 ${svgH}" preserveAspectRatio="none" role="img" aria-label="近 30 天${unit}柱状图">
      <defs>
        <linearGradient id="barGrad" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#2fc486"/><stop offset="1" stop-color="#0f9d68"/>
        </linearGradient>
        <linearGradient id="barPeak" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#f0c05a"/><stop offset="1" stop-color="#c98f2b"/>
        </linearGradient>
      </defs>
      ${grid}${bars}
    </svg></div>
    <div class="chart-axis">${axisDates.map(d => `<span>${escapeHtml(d)}</span>`).join("")}</div>
    <div class="chart-foot">金色柱为区间峰值日 · 悬停查看每日数值</div>`;
}

// 横向分布条（平台分布 / 通知状态分布共用）
function renderDistBars(container, entries, colors) {
  const total = entries.reduce((s, [, v]) => s + v, 0);
  container.innerHTML = entries.length
    ? entries.map(([label, value], i) => {
        const pct = total ? Math.round(value / total * 100) : 0;
        return `<div class="dist-row"><span class="dist-label">${escapeHtml(label)}</span><div class="dist-track"><i style="width:${Math.max(pct, value ? 2 : 0)}%;background:${colors[i % colors.length]}"></i></div><b>${value}</b><span class="dist-pct">${pct}%</span></div>`;
      }).join("")
    : '<div class="empty">暂无数据</div>';
}

async function loadStats() {
  try {
    const results = await Promise.allSettled([
      request("/stats/overview"),
      request("/stats/dau-series?days=30"),
      request("/stats/growth-series?days=30"),
      request("/stats/platforms"),
      request("/stats/system"),
      request("/stats/import-funnel?days=30"),
      request("/stats/import-failures?days=30"),
      request("/stats/retention-cohorts?weeks=8"),
      request("/stats/reminder-health?days=30"),
    ]);
    const [overview, series, growth, platforms, sys, funnel, failures, cohorts, reminder] = results.map(result =>
      result.status === "fulfilled" ? result.value : null);
    ["#statsCards", "#dauChart", "#growthChart", "#platformPanel", "#systemCards",
      "#funnelPanel", "#failurePanel", "#cohortPanel", "#reminderPanel"].forEach((selector, index) => {
      if (results[index].status === "rejected")
        $(selector).textContent = "加载失败，请点击刷新重试";
    });
    // 指标卡片（今日 DAU 带环比昨日）
    if (overview) {
    const diff = overview.today_dau - overview.yesterday_dau;
    const trend = diff > 0 ? "up" : diff < 0 ? "down" : "flat";
    const deltaHtml = `<span class="delta ${trend}">${diff > 0 ? "▲ +" : diff < 0 ? "▼ " : "— "}${diff} vs 昨日</span>`;
    const cards = [
      { label: "今日日活（DAU）", value: overview.today_dau, icon: "⚡", tone: "", deltaHtml },
      { label: "昨日日活", value: overview.yesterday_dau, icon: "🌙", tone: "blue" },
      { label: "近 7 天活跃", value: overview.wau, icon: "📅", tone: "violet" },
      { label: "近 30 天月活（MAU）", value: overview.mau, icon: "🏔️", tone: "gold" },
      { label: "注册用户", value: overview.total_users, icon: "👥", tone: "rose" },
      { label: "今日新增注册", value: overview.today_new_users, icon: "✨", tone: "" },
      { label: "近 7 天新增", value: overview.week_new_users, icon: "🌱", tone: "blue" },
      { label: "云端课程", value: overview.total_courses, icon: "📚", tone: "violet" },
      { label: "时间安排", value: overview.total_schedules, icon: "⏰", tone: "gold" },
      { label: "今日发送通知", value: overview.today_notifications, icon: "📨", tone: "rose" },
      { label: "通知总量", value: overview.total_notifications, icon: "📬", tone: "" },
      { label: "共同空闲配对", value: overview.couple_memberships, icon: "🤝", tone: "blue" },
    ];
    $("#statsCards").innerHTML = cards.map(statCard).join("");
    }
    // DAU 曲线
    if (series) renderBarChart($("#dauChart"), series, "dau", "人活跃");
    // 新增注册曲线
    if (growth) renderBarChart($("#growthChart"), growth, "count", "人注册");
    // 平台与投递分布
    if (platforms) {
    const deviceEntries = [
      ["安卓设备", platforms.devices?.android || 0],
      ["鸿蒙设备", platforms.devices?.harmony || 0],
      ["网页订阅", platforms.web_subscriptions || 0],
    ];
    const statusEntries = [
      ["已受理", platforms.notification_status?.accepted || 0],
      ["已入库", platforms.notification_status?.stored || 0],
      ["待投递", platforms.notification_status?.pending || 0],
      ["失败", platforms.notification_status?.failed || 0],
    ];
    renderDistBars($("#platformBars"), deviceEntries, ["#0f9d68", "#3a7bd5", "#8e5cc7"]);
    renderDistBars($("#statusBars"), statusEntries, ["#0f9d68", "#5f8f7a", "#c98f2b", "#c0392b"]);
    $("#onboardingCount").textContent = platforms.onboarding_reminders ?? 0;
    }
    // 系统状态（内存 / 磁盘带使用率进度条）
    if (sys) {
    const memPct = Math.min(100, Math.round(sys.mem_used_mb / Math.max(sys.mem_total_mb, 1) * 100));
    const diskPct = Math.min(100, Math.round(sys.disk_used_gb / Math.max(sys.disk_total_gb, 1) * 100));
    const level = (p) => (p >= 90 ? "high" : p >= 70 ? "warn" : "");
    const meterHtml = (pct) =>
      `<div class="meter"><i style="width:${pct}%"${level(pct) ? ` data-level="${level(pct)}"` : ""}></i></div><span class="meter-note">已用 ${pct}%</span>`;
    const sysCards = [
      { label: "内存", value: `${sys.mem_used_mb} / ${sys.mem_total_mb} MB`, icon: "🧠", tone: "blue", meterHtml: meterHtml(memPct) },
      { label: "磁盘", value: `${sys.disk_used_gb} / ${sys.disk_total_gb} GB`, icon: "💾", tone: "violet", meterHtml: meterHtml(diskPct) },
      { label: "负载（1m）", value: sys.load_avg[0].toFixed(2), icon: "🔥", tone: "gold" },
      { label: "负载（5m）", value: sys.load_avg[1].toFixed(2), icon: "📊", tone: "" },
      { label: "数据库", value: `${sys.db_size_mb} MB`, icon: "🗄️", tone: "rose" },
    ];
    $("#systemCards").innerHTML = sysCards.map(statCard).join("");
    }
    // 四组指标（数据看板扩展 2026-09-18）
    if (funnel) renderImportFunnel(funnel);
    if (failures) renderImportFailures(failures);
    if (cohorts) renderRetentionCohorts(cohorts);
    if (reminder) renderReminderHealth(reminder);
  } catch (error) {
    toast(error.message);
  }
}

// ---- 四组指标渲染 ----
const ENTRY_LABELS = { screenshot: "截图", excel: "表格", school: "教务", sharecode: "口令", manual: "手动/兜底" };
const STAGE_LABELS = { pick: "选择文件", upload: "上传", parse: "解析", preview: "预览", save: "保存", webview: "打开页面", login: "登录", sniff: "嗅探", input: "输入口令", apply: "应用课表", edit: "编辑" };
const entryLabel = (k) => ENTRY_LABELS[k] || k;
const stageLabel = (k) => STAGE_LABELS[k] || k;

function renderImportFunnel(f) {
  const pct = Math.round((f.success_rate || 0) * 1000) / 10;
  const cards = [
    { label: "新注册用户", value: f.new_users, icon: "👥", tone: "" },
    { label: "有导入行为", value: f.attempted_users, icon: "📥", tone: "blue" },
    { label: "首次导入成功", value: f.success_users, icon: "✅", tone: "" },
    { label: "首次导入成功率", value: `${pct}%`, icon: "🎯", tone: "gold" },
  ];
  $("#funnelCards").innerHTML = cards.map(statCard).join("");
  const attr = Object.entries(f.attribution || {}).sort((a, b) => b[1] - a[1])
    .map(([k, v]) => [entryLabel(k), v]);
  renderDistBars($("#funnelAttrBars"), attr, ["#0f9d68", "#3a7bd5", "#8e5cc7", "#c98f2b", "#5f8f7a"]);
  $("#funnelPartial").textContent = f.partial_users ?? 0;
}

let failureCache = null;
let failureEntry = "";
function renderImportFailures(f) {
  failureCache = f;
  const entries = Object.keys(f.totals_by_entry || {});
  const tabs = [["", `全部（${Object.values(f.totals_by_entry || {}).reduce((s, v) => s + v, 0)}）`]]
    .concat(entries.map((e) => [e, `${entryLabel(e)}（${f.totals_by_entry[e]}）`]));
  $("#failureTabs").innerHTML = tabs.map(([k, label]) =>
    `<button type="button" data-failure-entry="${escapeHtml(k)}" aria-pressed="${k === failureEntry}"><strong>${escapeHtml(label)}</strong></button>`).join("");
  $$("#failureTabs button").forEach((btn) => btn.addEventListener("click", () => {
    failureEntry = btn.dataset.failureEntry;
    renderImportFailures(failureCache);
  }));
  const rows = (f.rows || []).filter((r) => !failureEntry || r.entry === failureEntry);
  $("#failureTable").innerHTML = rows.length
    ? `<thead><tr><th>入口</th><th>阶段</th><th>错误码</th><th>结果</th><th>次数</th><th>最近发生</th><th>首次发生</th></tr></thead><tbody>` +
      rows.map((r) => `<tr><td>${escapeHtml(entryLabel(r.entry))}</td><td>${escapeHtml(stageLabel(r.stage))}</td><td>${escapeHtml(r.error_code || "—")}</td><td>${r.outcome === "abandon" ? "放弃" : "失败"}</td><td>${r.count}</td><td>${r.last_at ? escapeHtml(fmt(r.last_at)) : "—"}</td><td>${r.first_at ? escapeHtml(fmt(r.first_at)) : "—"}</td></tr>`).join("") +
      `</tbody>`
    : '<tbody><tr><td class="empty">近 30 天没有失败事件</td></tr></tbody>';
}

function renderRetentionCohorts(cohorts) {
  const rows = [...cohorts].reverse();
  $("#cohortTable").innerHTML =
    `<thead><tr><th>注册周（周一）</th><th>新用户</th><th>次周留存</th><th>留存率</th></tr></thead><tbody>` +
    rows.map((c) => {
      const pct = Math.round((c.rate_w1 || 0) * 1000) / 10;
      return `<tr><td>${escapeHtml(c.week_start)}${c.partial ? " *" : ""}</td><td>${c.new_users}</td><td>${c.retained_w1}</td><td>${pct}%</td></tr>`;
    }).join("") + `</tbody>`;
}

function renderReminderHealth(r) {
  const notifPct = Math.round((r.notif_permission_rate || 0) * 1000) / 10;
  const exactPct = Math.round((r.exact_alarm_rate || 0) * 1000) / 10;
  const cards = [
    { label: "已上报设备", value: r.reported_devices, icon: "📱", tone: "" },
    { label: "通知权限开启率", value: `${notifPct}%`, icon: "🔔", tone: "blue" },
    { label: "精确闹钟授权率", value: r.exact_alarm_known ? `${exactPct}%` : "—", icon: "⏰", tone: "violet" },
    { label: "近 24h 有上报", value: r.report_recency?.lt1d ?? 0, icon: "🟢", tone: "gold" },
  ];
  $("#reminderCards").innerHTML = cards.map(statCard).join("");
  const b = r.scheduled_count_buckets || {};
  renderDistBars($("#scheduleBuckets"), [
    ["0 条", b["0"] || 0], ["1–10 条", b["1_10"] || 0], ["11–50 条", b["11_50"] || 0], [">50 条", b["gt50"] || 0],
  ], ["#c0392b", "#c98f2b", "#3a7bd5", "#0f9d68"]);
  const d = r.delivery_status || {};
  renderDistBars($("#reminderDeliveryBars"), [
    ["已受理", d.accepted || 0], ["已入库", d.stored || 0], ["待投递", d.pending || 0], ["失败", d.failed || 0],
  ], ["#0f9d68", "#5f8f7a", "#c98f2b", "#c0392b"]);
}
$("#refreshStats").addEventListener("click", loadStats);

// ==================== 版本发布管理 ====================
async function loadVersions() {
  try {
    const rows = await request("/versions?limit=20");
    const table = $("#versionsTable");
    if (!rows.length) {
      table.innerHTML = '<tbody><tr><td class="empty">还没有发布记录</td></tr></tbody>';
      return;
    }
    table.innerHTML =
      `<thead><tr><th>版本</th><th>渠道</th><th>定向账号</th><th>发布时间</th><th>操作</th></tr></thead><tbody>` +
      rows.map((r) => {
        const channel = r.channel === "targeted_test"
          ? '<span class="state-badge limited">定向测试</span>'
          : '<span class="state-badge ok">正式版</span>';
        const targets = r.targets.length
          ? r.targets.map((t) =>
              `<span class="dev-chip">${escapeHtml(t.username)}<button type="button" class="chip-x" data-remove-target="${r.id}:${t.user_id}" title="移出名单">×</button></span>`).join("")
          : '<span class="muted">全员可见</span>';
        return `<tr>
          <td><b>${escapeHtml(r.version_name)}</b><br><small class="muted">code ${r.version_code}${r.is_force_update ? " · 强制" : ""}${r.force_codes ? ` · 强更 ${escapeHtml(r.force_codes)}` : ""}</small></td>
          <td>${channel}</td>
          <td>${targets}
            <span class="dev-chip web add-target-chip" data-add-target="${r.id}" title="添加定向账号">＋ 添加</span>
          </td>
          <td><small>${fmt(r.published_at)}</small></td>
          <td>${r.sha256 ? `<button type="button" class="row-action" data-copy-sha="${escapeHtml(r.sha256)}">复制 SHA</button>` : ""}</td>
        </tr>`;
      }).join("") +
      `</tbody>`;
  } catch (e) {
    toast(e.message);
  }
}
$("#refreshVersions").addEventListener("click", loadVersions);

// 发布表单
$("#versionPublishForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const f = form.elements;
  const targets = f.target_accounts.value.split(/[,，\s]+/).map((x) => x.trim()).filter(Boolean);
  const payload = {
    version_name: f.version_name.value.trim(),
    version_code: Number(f.version_code.value),
    apk_url: f.apk_url.value.trim(),
    sha256: f.sha256.value.trim(),
    release_notes: f.release_notes.value,
    is_force_update: f.is_force_update.checked,
    force_codes: f.force_codes.value.trim(),
    target_accounts: targets,
    notify_targets: f.notify_targets.checked,
  };
  try {
    const data = await request("/versions", { method: "POST", body: JSON.stringify(payload) });
    const note = data.notifications?.length
      ? "；通知：" + data.notifications.map((n) => n.status).join("/")
      : "";
    toast(`已发布 ${data.release_channel === "targeted_test" ? "定向测试版" : "正式版"}（code ${data.version_code}）${note}`);
    form.reset();
    f.notify_targets.checked = true;
    loadVersions();
  } catch (e) {
    toast(e.message);
  }
});

// 定向账号管理：移除 / 添加（行内 prompt）
$("#versionsTable").addEventListener("click", async (event) => {
  const removeBtn = event.target.closest("[data-remove-target]");
  if (removeBtn) {
    const [vid, uid] = removeBtn.dataset.removeTarget.split(":").map(Number);
    if (!confirm("把该账号移出定向名单？移出后他不再看到此版本。")) return;
    try {
      await request(`/versions/${vid}/targets/${uid}`, { method: "DELETE" });
      toast("已移出定向名单");
      loadVersions();
    } catch (e) {
      toast(e.message);
    }
    return;
  }
  const addBtn = event.target.closest("[data-add-target]");
  if (addBtn) {
    const vid = Number(addBtn.dataset.addTarget);
    const account = prompt("要加入定向名单的用户名或邮箱：");
    if (!account || !account.trim()) return;
    const notify = confirm("同时给他发送测试邀请通知？（确定=发送，取消=只加名单）");
    try {
      const data = await request(`/versions/${vid}/targets`, {
        method: "POST",
        body: JSON.stringify({ account: account.trim(), notify }),
      });
      toast(data.added.length ? "已加入定向名单" : "该账号已在名单中");
      loadVersions();
    } catch (e) {
      toast(e.message);
    }
    return;
  }
  const shaBtn = event.target.closest("[data-copy-sha]");
  if (shaBtn) {
    try {
      await navigator.clipboard.writeText(shaBtn.dataset.copySha);
      toast("SHA-256 已复制");
    } catch {
      toast("复制失败，请手动复制");
    }
  }
});

// ---------- 客户端版本分布（谁落后、给谁催更）----------
let clientVersionData = null;

async function loadClientVersions() {
  try {
    const data = await request("/stats/client-versions");
    clientVersionData = data;
    const cards = [
      { label: "当前正式版", value: `${data.latest.version_name}（${data.latest.version_code}）`, icon: "🚀", tone: "" },
      { label: "已知版本的账号", value: data.tracked_users, icon: "📱", tone: "blue" },
      { label: "版本未知的账号", value: data.untracked_users, icon: "❓", tone: "gold" },
      { label: "落后待更新", value: data.outdated_count, icon: "⏰", tone: data.outdated_count ? "rose" : "" },
    ];
    $("#clientVersionSummary").innerHTML = cards.map(statCard).join("");

    const entries = Object.entries(data.distribution || {});
    $("#clientVersionTable").innerHTML = entries.length
      ? `<thead><tr><th>versionCode</th><th>账号数</th><th>占比</th></tr></thead><tbody>${entries.map(([code, count]) => {
          const pct = data.tracked_users ? Math.round((count / data.tracked_users) * 100) : 0;
          const isLatest = Number(code) >= data.latest.version_code;
          return `<tr><td><code>${escapeHtml(code)}</code>${isLatest ? " <span class='badge'>当前</span>" : ""}</td><td>${count}</td><td>${pct}%</td></tr>`;
        }).join("")}</tbody>`
      : '<tbody><tr><td class="empty">还没有版本记录（用户下次冷启动后开始上报）</td></tr></tbody>';

    $("#outdatedUsersTable").innerHTML = data.outdated.length
      ? `<thead><tr><th>用户</th><th>邮箱</th><th>当前 versionCode</th><th>来源</th></tr></thead><tbody>${data.outdated.map((row) => `
          <tr><td>${escapeHtml(row.username)}（#${row.user_id}）</td><td>${escapeHtml(row.email)}</td>
          <td><code>${escapeHtml(String(row.current_code))}</code></td><td class="muted">${escapeHtml(row.source || "-")}</td></tr>`).join("")}</tbody>`
      : '<tbody><tr><td class="empty">所有已知账号都在最新版本上</td></tr></tbody>';
  } catch (error) {
    $("#clientVersionSummary").textContent = error.message || "加载失败，请点击刷新重试";
  }
}

$("#refreshClientVersions").addEventListener("click", loadClientVersions);

$("#notifyOutdated").addEventListener("click", async () => {
  const data = clientVersionData;
  const target = data?.latest;
  if (!target || !target.id) return alert("当前还没有正式版本记录");
  if (!data.outdated_count) return alert("没有落后用户，不需要发送");
  const prompt = [
    `给 ${data.outdated_count} 个落后用户发送「${target.version_name} 已发布」的更新提醒？`,
    "",
    "正在被定向测试更新版本的账号不会收到。",
  ].join("\n");
  if (!confirm(prompt)) return;
  try {
    const result = await request(`/versions/${target.id}/notify-outdated`, { method: "POST" });
    alert(`已发送 ${result.sent.length} 条`);
    loadClientVersions();
  } catch (error) {
    alert(error.message || "发送失败");
  }
});
