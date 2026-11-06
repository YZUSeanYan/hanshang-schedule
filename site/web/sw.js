const CACHE = "hanshang-web-shell-v31";
const ASSETS = ["./", "./index.html", "./app.js?v=30", "./manifest.webmanifest", "./icon.svg", "./icon-180.png", "./icon-192.png", "./icon-512.png"];
self.addEventListener("install", (event) => { self.skipWaiting(); event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(ASSETS))); });
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
self.addEventListener("activate", (event) => event.waitUntil(
  caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
));
self.addEventListener("fetch", (event) => {
  // Never cache API responses, authorization headers or user-entered data.
  const requestUrl = new URL(event.request.url);
  if (requestUrl.origin !== self.location.origin) return;
  if (requestUrl.pathname.startsWith("/web-api/")) return;
  if (event.request.method !== "GET") return;
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (response.ok) {
          const copy = response.clone();
          event.waitUntil(caches.open(CACHE).then((cache) => cache.put(event.request, copy)));
        }
        return response;
      })
      .catch(() => caches.match(event.request).then((cached) => cached || caches.match("./index.html")))
  );
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
