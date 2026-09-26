const CACHE = 'mybjj-v578';
const STATIC = [
  '/', '/index.html', '/manifest.json',
  '/icon-192.png', '/icon-512.png',
  '/icon-192-maskable.png', '/icon-512-maskable.png',
  '/logo.png', '/favicon.ico', '/apple-touch-icon.png',
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

// PART 1 — do NOT delete the cache the live page is still being served from.
//
// This was the trigger for "everyone is signed out every time a version ships",
// measured on the owner's iPhone. v577 published at 09:49:36 Sydney; the first
// kick was 09:52:25, the window for Pages to publish and the SW to notice. The
// old activate deleted EVERY cache but the new one and then claimed the clients.
// The page that was still running had been loaded from one of the deleted
// caches, so from that instant every asset it asked for missed (the fetch
// handler's caches.match searches all caches) and went to the network at once.
// A Supabase token refresh landing in that saturation timed out, supabase-js
// emitted SIGNED_OUT, and the v576 mirror rescue then replayed a refresh token
// the failed attempt had already consumed — Supabase rotates refresh tokens, so
// a stored snapshot is single-use. Hence the measured signature: rescue ok,
// dead again inside 200ms, exp:false throughout.
//
// OPTIONS WEIGHED:
//   delete nothing here, prune at the next cold start — safest for the live
//     page, but there is no reliable "cold start" hook in a SW and storage
//     grows unbounded until one happens.
//   keep N versions — bounded, and N=2 already covers the only page that can
//     exist at activation time: the one running on the immediately-previous
//     cache. Chosen, with N=3 for one hop of margin (a tab left open across two
//     deploys keeps its cache instead of falling back to the network).
//   delete only the caches older than the one currently in use — we cannot know
//     from here which cache a given client loaded from.
//
// COST: the STATIC list plus a second copy of index.html (both '/' and
// '/index.html' are cached) is ~5 MB per version, so retaining 3 costs ~15 MB
// instead of ~5 MB. Well inside a PWA's budget, and it buys back the sign-out.
//
// Keys that do not parse as mybjj-v<n> are LEFT ALONE deliberately: deleting a
// cache we do not understand risks pulling the rug out from under a live page
// again, which is the whole failure being removed here.
const CACHE_PREFIX = 'mybjj-v';
const KEEP_VERSIONS = 3;
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys => {
      const mine = keys
        .map(k => {
          const rest = k.startsWith(CACHE_PREFIX) ? k.slice(CACHE_PREFIX.length) : '';
          return { k, n: /^\d+$/.test(rest) ? Number(rest) : null };
        })
        .filter(x => x.n !== null)
        .sort((a, b) => b.n - a.n);
      // Newest KEEP_VERSIONS survive; everything older goes. CACHE is the newest
      // by construction, so it is never in the doomed slice.
      return Promise.all(mine.slice(KEEP_VERSIONS).map(x => caches.delete(x.k)));
    // clients.claim() is unchanged — WHEN the update applies is _swSafeToReload /
    // applySwUpdate's decision, and this only changes what activate destroys.
    }).then(() => self.clients.claim())
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
