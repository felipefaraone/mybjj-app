const CACHE = 'mybjj-v588';
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
  // PART 2 (v588): a page says which cache it runs on (see the note above
  // cleanupCaches). Replies with this worker's CACHE so a page that does not know
  // yet learns the cache it was loaded under.
  if (event.data && event.data.type === 'CLIENT_HELLO') {
    const id = event.source && event.source.id;
    const asked = event.data.cache;
    const cache = (typeof asked === 'string' && versionOf(asked) !== null) ? asked : CACHE;
    const port = event.ports && event.ports[0];
    try { if (port) port.postMessage({ cache: cache }); } catch (_) {}
    if (id) {
      event.waitUntil(
        updateMeta(m => { m.clients[id] = { cache: cache, at: Date.now() }; })
          .then(() => maybeCleanup())
      );
    }
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
//
// (Superseded in v588 by PART 2 below; kept as the record of why.)
// PART 2 (v588) — keep-3 was not enough. On 4 Oct four versions shipped in
// eight hours (v582 13:37, v583 19:20, v584 20:46, v585 21:27). An iPhone PWA
// suspended on v582 resumed after v585 activated; keep-3 had already deleted
// v582 at v585's activation, and the 26 Sep failure came back. Keeping N caches
// only protects against N-1 deploys while a page is away, and nothing bounds how
// many deploys happen while a phone sleeps.
//
// THE RULE NOW. A version cache is deleted only when BOTH:
//   (a) no live client is mapped to it — clients.matchAll({includeUncontrolled:
//       true}) against the client -> cache map below; AND
//   (b) it is older than MAX_CACHE_AGE_MS (14 days) by the time this origin first
//       saw it, OR there are more than MAX_CACHES (8) version caches — then the
//       oldest unused ones (by version number) go first, only until 8 remain.
// CACHE itself and any cache mapped to a live client are never deleted, whatever
// the count. Keys that do not parse as mybjj-v<n> are still left alone.
//
// WHO USES WHICH CACHE: the PAGE tells us. On load it asks its controller (the
// worker that served its navigation) for CACHE, keeps that name for its whole
// life, and re-posts it on every return to the foreground (CLIENT_HELLO). Why not
// record it here when the navigation is fetched: a navigation's FetchEvent has an
// empty clientId, and the field that does carry it (resultingClientId) is not
// dependable in Safari; and iOS stops service workers freely, so anything held
// only in this worker's memory is lost. The page re-sending on resume re-teaches
// a restarted worker.
//
// WHY THIS HOLDS FOR A SUSPENDED iPHONE even if iOS does not list it in
// matchAll(): (b) alone means a cache younger than 14 days is never deleted while
// there are 8 or fewer, so four deploys in an evening cannot touch it. (a) adds
// the guarantee for a page that is visibly alive however many deploys pile up.
//
// The map and the first-seen times live in a dedicated cache (META_CACHE) so they
// survive the worker being stopped; that cache does not parse as mybjj-v<n>, so
// no cleanup (old or new) ever deletes it. It is re-read from storage on every
// change, because an old and a new worker can both be alive during an update.
//
// COST: ~5.6 MB per version (STATIC + the second copy of index.html), so the
// 8-cache ceiling is ~45 MB; in steady state (one deploy a day, 14-day window)
// it sits at 8.
const CACHE_PREFIX = 'mybjj-v';
const META_CACHE = 'mybjj-sw-meta';
const META_URL = '/__mybjj_sw_meta__';
const MAX_CACHE_AGE_MS = 14 * 24 * 60 * 60 * 1000;
const MAX_CACHES = 8;
const CLIENT_RECORD_TTL_MS = 30 * 24 * 60 * 60 * 1000;   // forget a vanished client's record after this
const CLEANUP_EVERY_MS = 60 * 60 * 1000;                 // opportunistic cleanup at most hourly

// 'mybjj-v588' -> 588; anything else -> null. Numeric, so v9 sorts before v10.
function versionOf(k) {
  const rest = k.startsWith(CACHE_PREFIX) ? k.slice(CACHE_PREFIX.length) : '';
  return /^\d+$/.test(rest) ? Number(rest) : null;
}

// { firstSeen: { 'mybjj-v587': epochMs, ... }, clients: { clientId: { cache, at } } }
function readMeta() {
  return caches.open(META_CACHE)
    .then(c => c.match(META_URL))
    .then(r => (r ? r.json() : null))
    .catch(() => null)
    .then(m => {
      m = (m && typeof m === 'object') ? m : {};
      if (!m.firstSeen || typeof m.firstSeen !== 'object') m.firstSeen = {};
      if (!m.clients || typeof m.clients !== 'object') m.clients = {};
      return m;
    });
}
// Read-modify-write, one at a time inside this worker.
let metaChain = Promise.resolve();
function updateMeta(fn) {
  metaChain = metaChain.then(() => readMeta().then(m => {
    fn(m);
    return caches.open(META_CACHE).then(c => c.put(META_URL, new Response(JSON.stringify(m), {
      headers: { 'content-type': 'application/json' },
    })));
  })).catch(() => {});
  return metaChain;
}

// Returns the names it deleted. Never throws.
function cleanupCaches() {
  let doomed = [];
  return Promise.all([
    caches.keys(),
    self.clients.matchAll({ includeUncontrolled: true, type: 'all' }).catch(() => null),
  ]).then(([keys, live]) => updateMeta(m => {
    const now = Date.now();
    const mine = keys.filter(k => versionOf(k) !== null).sort((a, b) => versionOf(a) - versionOf(b));   // oldest first
    for (const k of mine) if (!m.firstSeen[k]) m.firstSeen[k] = now;
    for (const k of Object.keys(m.firstSeen)) if (!mine.includes(k)) delete m.firstSeen[k];
    // If the client list could not be read, protect every recorded client.
    const liveIds = live ? new Set(live.map(c => c.id)) : null;
    const inUse = new Set([CACHE]);
    for (const [id, rec] of Object.entries(m.clients)) {
      const alive = !liveIds || liveIds.has(id);
      if (alive && rec && rec.cache) inUse.add(rec.cache);
      if (!alive && !(rec && now - rec.at < CLIENT_RECORD_TTL_MS)) delete m.clients[id];
    }
    const unused = mine.filter(k => !inUse.has(k));
    const out = new Set(unused.filter(k => now - m.firstSeen[k] > MAX_CACHE_AGE_MS));
    let left = mine.length - out.size;
    for (const k of unused) {
      if (left <= MAX_CACHES) break;
      if (!out.has(k)) { out.add(k); left--; }
    }
    doomed = mine.filter(k => out.has(k));
    for (const k of doomed) delete m.firstSeen[k];
  }))
    .then(() => Promise.all(doomed.map(k => caches.delete(k))))
    .then(() => doomed)
    .catch(() => []);
}
let lastCleanup = 0;
function maybeCleanup() {
  if (Date.now() - lastCleanup < CLEANUP_EVERY_MS) return Promise.resolve([]);
  lastCleanup = Date.now();
  return cleanupCaches();
}

self.addEventListener('activate', e => {
  e.waitUntil(
    (lastCleanup = Date.now(), cleanupCaches())
    // clients.claim() is unchanged — WHEN the update applies is _swSafeToReload /
    // applySwUpdate's decision, and this only changes what activate destroys.
    .then(() => self.clients.claim())
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
