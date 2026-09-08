/* ScreenAI service worker：仅缓存应用外壳，API 与 WebSocket 不经过缓存。 */
var VERSION = '__VERSION__';
var CACHE = 'screenai-shell-' + VERSION;
var SHELL = ['/', '/app.js', '/style.css', '/manifest.json', '/icon.png', '/icon-512.png'];

self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});

self.addEventListener('fetch', function (e) {
  var url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  if (url.pathname.indexOf('/api/') === 0 || url.pathname === '/ws' || url.pathname.indexOf('.mobileconfig') > 0 || url.pathname === '/ca.crt') return;
  // 网络优先，失败时回退缓存（Mac 未开机时仍能打开外壳并提示未连接）
  e.respondWith(fetch(e.request).then(function (resp) {
    if (resp && resp.ok) {
      var copy = resp.clone();
      caches.open(CACHE).then(function (c) { c.put(e.request, copy); });
    }
    return resp;
  }).catch(function () {
    return caches.match(e.request).then(function (hit) { return hit || Response.error(); });
  }));
});
