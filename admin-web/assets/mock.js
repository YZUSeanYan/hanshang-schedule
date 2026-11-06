// 本地预览专用 mock:拦截 admin.js 的 fetch,返回演示数据。勿部署到服务器。
(() => {
  const names = ["张雨晴", "李昊然", "王梓涵", "陈思远", "刘一诺", "赵启铭", "孙嘉怡", "周子墨", "吴欣怡", "郑凯文", "林沐阳", "黄诗涵"];
  const users = Array.from({ length: 128 }, (_, i) => ({
    id: i + 1,
    username: names[i % names.length] + (i >= names.length ? `_${Math.floor(i / names.length)}` : ""),
    email: `user${i + 1}@example.test`,
    created_at: new Date(Date.now() - i * 86400000 * 1.7).toISOString(),
    android_count: i % 3 === 0 ? 1 : 0,
    web_count: i % 4 === 0 ? 1 : 0,
  }));
  const ok = (data) => new Response(JSON.stringify({ data }), {
    status: 200, headers: { "Content-Type": "application/json" },
  });
  window.fetch = async (url, options = {}) => {
    const u = new URL(url, location.href);
    const p = u.pathname;
    if (options.method === "POST" || options.method === "PATCH" || options.method === "DELETE")
      return ok({ status: "accepted", target_label: "全部设备", users: 128, android_status: "ok", web_delivered: 96, web_total: 96, targeted: 3, avatar_media: "", payment_qr_media: "" });
    if (p.endsWith("/session")) return ok({ csrf_token: "mock" });
    if (p.endsWith("/summary")) return ok({ users: 128, push_devices: 96, semesters: 5, courses: 342, schedules: 1287 });
    if (p.includes("/stats/overview")) return ok({ today_dau: 37, yesterday_dau: 29, wau: 84, mau: 112, total_users: 128 });
    if (p.includes("/stats/dau-series")) {
      const days = Number(u.searchParams.get("days") || 30);
      const series = [];
      let peak = -1, peakIdx = 0;
      const vals = [];
      for (let i = days - 1; i >= 0; i--) {
        const wob = Math.sin(i / 4.2) * 12;
        const v = Math.max(0, Math.round(24 + wob + ((i * 37) % 13) - 5));
        vals.push(v);
        if (v > peak) { peak = v; peakIdx = days - 1 - i; }
      }
      for (let i = days - 1; i >= 0; i--) {
        const d = new Date(Date.now() - i * 86400000);
        series.push({ date: d.toISOString().slice(0, 10), dau: vals[days - 1 - i] });
      }
      return ok(series);
    }
    if (p.includes("/stats/system")) return ok({ mem_used_mb: 892, mem_total_mb: 1838, disk_used_gb: 21.4, disk_total_gb: 40, load_avg: [0.42, 0.38, 0.31], db_size_mb: 48.6 });
    if (p.endsWith("/users")) {
      const q = (u.searchParams.get("q") || "").toLowerCase();
      const page = Number(u.searchParams.get("page") || 1);
      const ps = Number(u.searchParams.get("page_size") || 20);
      let items = users.filter((x) => !q || x.username.toLowerCase().includes(q) || x.email.includes(q));
      const total = items.length;
      items = items.slice((page - 1) * ps, page * ps);
      return ok({ items, total, page, page_size: ps });
    }
    const userMatch = p.match(/\/users\/(\d+)$/);
    if (userMatch) {
      const usr = users.find((x) => x.id === Number(userMatch[1])) || users[0];
      return ok({ ...usr, counts: { semesters: 2, courses: 18, schedules: 96 }, credential_vault: { exists: true, student_id_hint: "已隐藏", updated_at: new Date().toISOString(), last_verified_at: new Date().toISOString() } });
    }
    if (p.includes("/devices")) return ok([{ device_id: "dev-1", platform: "android", label: "Xiaomi 14", app_version: "1.0.33" }]);
    if (p.includes("/notifications")) return ok([
      { title: "服务维护通知", body: "本周日凌晨 2:00-4:00 服务器例行维护，期间同步可能短暂中断。", status: "accepted", target_label: "全部设备", read_at: new Date().toISOString(), created_at: new Date(Date.now() - 86400000 * 2).toISOString() },
      { title: "新学期课表已开放同步", body: "2026 秋季学期课表现在可以同步了。", status: "accepted", target_label: "全部设备", read_at: null, created_at: new Date(Date.now() - 86400000 * 6).toISOString() },
    ]);
    if (p.includes("/audit")) return ok([
      { action: "user.delete", target_user_id: 57, detail: "永久删除账号及关联数据", created_at: new Date(Date.now() - 3600000 * 3).toISOString() },
      { action: "notification.broadcast", target_user_id: null, detail: "广播《服务维护通知》→ 128 账户", created_at: new Date(Date.now() - 86400000).toISOString() },
      { action: "user.update", target_user_id: 12, detail: "修改邮箱", created_at: new Date(Date.now() - 86400000 * 1.5).toISOString() },
      { action: "about.update", target_user_id: null, detail: "更新关于页文案", created_at: new Date(Date.now() - 86400000 * 3).toISOString() },
      { action: "admin.login", target_user_id: null, detail: "管理员登录成功", created_at: new Date(Date.now() - 86400000 * 4).toISOString() },
    ]);
    if (p.includes("/about")) return ok({ display_name: "邗上课表", intro: "扬大人自己的课表 App。", website_url: "https://hanshang.seanyan.store", icp_beian: "苏ICP备2026057230号-2A", avatar_media: "", payment_qr_media: "" });
    return ok({});
  };
})();
