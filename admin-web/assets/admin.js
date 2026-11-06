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
    audit: "审计日志",
  }[target];
  if (target === "users") loadUsers();
  if (target === "notifications" && shouldLoad) loadNotificationUsers();
  if (target === "about") loadAbout();
  if (target === "stats") loadStats();
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
              `<tr><td>${avatarHtml(u.username)}${escapeHtml(u.username)}</td><td>${escapeHtml(u.email)}</td><td>${fmt(u.created_at)}</td><td><button class="row-action" data-notify-user="${u.id}">通知</button><button class="row-action" data-user="${u.id}">管理 →</button></td></tr>`,
          )
          .join("")
      : '<tr><td colspan="4" class="empty">没有匹配的用户</td></tr>';
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
      `<form id="userEditForm" class="detail-form"><label>用户名<input name="username" value="${escapeHtml(currentUser.username)}" required maxlength="32"></label><label>邮箱<input name="email" type="email" value="${escapeHtml(currentUser.email)}" required maxlength="255"></label><button class="primary" type="submit">保存用户信息</button></form><div class="detail-grid"><div class="detail-metric"><b>${currentUser.counts.semesters}</b><span>学期</span></div><div class="detail-metric"><b>${currentUser.counts.courses}</b><span>课程</span></div><div class="detail-metric"><b>${currentUser.counts.schedules}</b><span>安排</span></div></div><div class="credential-status"><b>教务凭据：</b>${currentUser.credential_vault.exists ? `已加密同步（学号 ${escapeHtml(currentUser.credential_vault.student_id_hint || "已隐藏")}，${fmt(currentUser.credential_vault.updated_at)}）` : "未同步"}<br><small>后台仅能查看状态并删除客户端密文，不能读取教务密码。</small></div><p class="muted">注册于 ${fmt(currentUser.created_at)}</p><div class="actions"><button id="openNotificationManager" type="button" class="secondary">发送通知</button><button id="clearData" type="button" class="danger">清空云端课表数据</button>${currentUser.credential_vault.exists ? '<button id="clearCredential" type="button" class="danger">删除教务凭据密文</button>' : ""}<button id="deleteUser" type="button" class="danger">永久删除账号</button></div><p class="muted">永久删除会清除账号、课表、会话、通知、设备登记与加密凭据，且不可恢复。</p>`;
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
      result = await request('/notifications/broadcast', {
        method: 'POST',
        body: JSON.stringify({ title: values.title, body: values.body, platform: platformFilter }),
      });
      toast(`广播已发送：${result.users} 个账户 · Android ${result.android_status} · 网页端 ${result.web_delivered}/${result.web_total}`);
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

async function loadStats() {
  try {
    const results = await Promise.allSettled([
      request("/stats/overview"),
      request("/stats/dau-series?days=30"),
      request("/stats/system"),
    ]);
    const [overview, series, sys] = results.map(result =>
      result.status === "fulfilled" ? result.value : null);
    ["#statsCards", "#dauChart", "#systemCards"].forEach((selector, index) => {
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
    ];
    $("#statsCards").innerHTML = cards.map(statCard).join("");
    }
    // DAU 曲线（渐变柱状图 + 网格线 + 摘要）
    if (series) {
    const maxVal = Math.max(...series.map(d => d.dau), 1);
    const total = series.reduce((s, d) => s + d.dau, 0);
    const avg = Math.round(total / series.length * 10) / 10;
    const peak = series.reduce((a, b) => (b.dau > a.dau ? b : a), series[0]);
    const barW = 100 / series.length;
    const svgH = 150;
    const padTop = 6;
    const gridYs = [0.25, 0.5, 0.75].map(r => padTop + (svgH - padTop) * (1 - r));
    const grid = gridYs.map(y =>
      `<line x1="0" x2="100" y1="${y.toFixed(1)}" y2="${y.toFixed(1)}" stroke="#dfe9e3" stroke-width="1" stroke-dasharray="3 4" vector-effect="non-scaling-stroke"/>`
    ).join("");
    const bars = series.map((d, i) => {
      const h = Math.max(d.dau / maxVal * (svgH - padTop), d.dau ? 2.5 : 1.2);
      const x = i * barW;
      const isPeak = d === peak && d.dau > 0;
      return `<rect class="bar" x="${x}%" y="${svgH - h}" width="${barW * 0.78}%" height="${h}" rx="1.2" fill="${isPeak ? "url(#barPeak)" : "url(#barGrad)"}" opacity="${d.dau ? 0.92 : 0.22}"><title>${d.date}：${d.dau} 人活跃</title></rect>`;
    }).join("");
    const axisDates = [0, 7, 14, 21, series.length - 1]
      .map(i => series[Math.min(i, series.length - 1)]?.date?.slice(5) || "");
    $("#dauChart").innerHTML =
      `<div class="chart-summary">
        <div class="cs-item"><b>${total}</b><span>30 天累计活跃人次</span></div>
        <div class="cs-item"><b>${avg}</b><span>日均活跃</span></div>
        <div class="cs-item"><b>${peak.dau}</b><span>峰值 · ${peak.date?.slice(5) || ""}</span></div>
      </div>
      <div class="chart-scroll"><svg viewBox="0 0 100 ${svgH}" preserveAspectRatio="none" role="img" aria-label="近 30 天日活人数柱状图">
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
  } catch (error) {
    toast(error.message);
  }
}
$("#refreshStats").addEventListener("click", loadStats);
