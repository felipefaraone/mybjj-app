const CACHE = 'mybjj-v192';
const STATIC = [
  '/', '/index.html', '/manifest.json',
  '/icon-192.png', '/icon-512.png',
  '/icon-192-maskable.png', '/icon-512-maskable.png',
  '/og-image.png',
  '/splash-750x1334.png', '/splash-1125x2436.png', '/splash-1170x2532.png',
  '/splash-1284x2778.png', '/splash-1290x2796.png',
  '/splash-1536x2048.png', '/splash-2048x2732.png',
];

self.addEventListener('install', e => {
  // Don't auto-skip-waiting. The page surfaces an "Update available"
  // banner and posts {type:'SKIP_WAITING'} when the user taps Refresh —
  // see the message listener below. First-time installs (no prior SW
  // controlling) still activate immediately because the lifecycle has
  // no `waiting` phase when there's nothing to replace.
  e.waitUntil(
    caches.open(CACHE).then(c => c.addAll(STATIC).catch(() => {}))
  );
});

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(
      keys.filter(k => k !== CACHE).map(k => caches.delete(k))
    )).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;

  const isHtml = req.mode === 'navigate' ||
                 (req.headers.get('accept') || '').includes('text/html');

  if (isHtml) {
    e.respondWith(
      fetch(req).then(r => {
        const copy = r.clone();
        caches.open(CACHE).then(c => c.put(req, copy));
        return r;
      }).catch(() =>
        caches.match(req).then(r => r || caches.match('/index.html'))
      )
    );
    return;
  }

  e.respondWith(
    caches.match(req).then(cached => {
      if (cached) return cached;
      return fetch(req).then(r => {
        if (r && r.status === 200 && r.type === 'basic') {
          const copy = r.clone();
          caches.open(CACHE).then(c => c.put(req, copy));
        }
        return r;
      }).catch(() => cached);
    })
  );
});
