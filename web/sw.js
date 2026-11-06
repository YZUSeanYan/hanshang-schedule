const CACHE = "hanshang-web-shell-v73";
// 版本化资源(?v=N 内容寻址):cache-first,二次启动零网络往返。
// HTML 先读缓存、后台更新；Service Worker 版本更新时预缓存整套资源。
const SHELL = ["./", "./index.html"];
const VERSIONED = ["./app.js?v=72", "./section-times.js?v=42", "./manifest.webmanifest", "./icon.svg", "./icon-180.png", "./icon-192.png", "./icon-512.png", "./gongan-logo.png"];
const ASSETS = [...SHELL, ...VERSIONED];
self.addEventListener("install", (event) => { self.skipWaiting(); event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(ASSETS))); });
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
self.addEventListener("activate", (event) => event.waitUntil(
  caches.keys().then((keys) => Promise.all(keys.filter((key) => key.startsWith("hanshang-web-shell-") && key !== CACHE).map((key) => caches.delete(key))))
));
self.addEventListener("fetch", (event) => {
  // Never cache API responses, authorization headers or user-entered data.
  const requestUrl = new URL(event.request.url);
  if (requestUrl.origin !== self.location.origin) return;
  if (!requestUrl.pathname.startsWith("/web/") || !ASSETS.some(asset => new URL(asset,self.location.href).href === requestUrl.href)) return;
  if (event.request.method !== "GET") return;
  const isShell = SHELL.some(asset => new URL(asset,self.location.href).href === requestUrl.href);
  if (!isShell) {
    // 版本化资源:缓存优先;未命中回源并写入缓存。
    event.respondWith(
      caches.match(event.request).then((cached) => cached || fetch(event.request).then((response) => {
        if (response.ok) {
          const copy = response.clone();
          event.waitUntil(caches.open(CACHE).then((cache) => cache.put(event.request, copy)));
        }
        return response;
      }))
    );
    return;
  }
  // Show the installed shell immediately, even on a slow or disconnected network.
  const update = fetch(event.request).then(async response => {
    if (response.ok) {
      const cache = await caches.open(CACHE);
      await cache.put(event.request, response.clone());
    }
    return response;
  });
  event.waitUntil(update.catch(() => {}));
  event.respondWith(caches.open(CACHE).then(async cache =>
    await cache.match(event.request) || await cache.match("./index.html") || update
  ));
});
self.addEventListener("push", (event) => {
  let payload = { title: "邗上课表", body: "你有一条新的课程提醒。", url: "./" };
  try {
    if (event.data) payload = { ...payload, ...event.data.json() };
  } catch (_) {
    // Keep the safe default notification when an upstream payload is malformed.
  }
  event.waitUntil(self.registration.showNotification(payload.title, {
    body: payload.body,
    icon: "./icon-192.png",
    badge: "./icon-192.png",
    data: { url: payload.url || "./" },
  }));
});
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || "./", self.location.href).href;
  event.waitUntil(clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
    const existing = windows.find((client) => client.url.startsWith(self.location.origin));
    return existing ? existing.focus() : clients.openWindow(target);
  }));
});
