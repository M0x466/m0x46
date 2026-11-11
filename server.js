'use strict';
/**
 * EGG FINDER — your own backend (Node 18+, zero npm dependencies)
 * ---------------------------------------------------------------
 * Public API (all JSON):
 *   POST /v1/report  { placeId, jobId, reporterId, ttl, eggs:[...] }  -> { ok, accepted, retired }
 *   GET  /v1/eggs    ? placeId=&localJob=&onlyJob=&minRate=&minRank=&limit=&offset=&all=
 *                    -> { items:[...], nextOffset, serverTime, count }
 *   POST /v1/join    { placeId, jobId, uid, reporterId, userId }      -> { allowed, expiresAt, reason }
 *   GET  /health                                                        -> { ok, uptime, sightings }
 *   GET  /                                                              -> tiny live dashboard
 *
 * Auth: send header `X-Egg-Room: <ROOM_KEY>`. If ROOM_KEY is unset the API is open
 * (fine for local testing, NOT for production).
 *
 * Storage: one JSON file (DATA_FILE), rewritten atomically. Every sighting is keyed
 * by `placeId:jobId:uid` and expires on its own TTL, so stale reports vanish by
 * themselves — no cron, no cleanup jobs, no database needed.
 *
 * Run:  ROOM_KEY=changeme PORT=8080 DATA_FILE=./data/sightings.json node server.js
 * Host: any Node host, or the Dockerfile next to this file. If you put it on a
 *       PaaS (Render/Railway/Fly), set ROOM_KEY in their dashboard and mount a
 *       volume at /app/data, otherwise sightings vanish on every restart.

 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ---------------------------------------------------------------- config
const PORT = Number(process.env.PORT || 8080);
const HOST = process.env.HOST || '0.0.0.0';
const ROOM_KEY = process.env.ROOM_KEY || '';
const DATA_FILE = process.env.DATA_FILE || path.join(__dirname, 'data', 'sightings.json');
const DEFAULT_TTL_MS = Number(process.env.DEFAULT_TTL_MS || 300_000); // 5 min
const MAX_TTL_MS = Number(process.env.MAX_TTL_MS || 900_000);         // 15 min
const MAX_EGGS_PER_REPORT = Number(process.env.MAX_EGGS_PER_REPORT || 25);
const MAX_SIGHTINGS = Number(process.env.MAX_SIGHTINGS || 200_000);
const MAX_BODY_BYTES = Number(process.env.MAX_BODY_BYTES || 262_144);
const RATE_LIMIT_PER_MIN = Number(process.env.RATE_LIMIT_PER_MIN || 240);

// ---------------------------------------------------------------- storage
/** @type {Map<string, object>} key = placeId:jobId:uid */
const sightings = new Map();
let dirty = false;

function loadStore() {
  try {
    const raw = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
    const now = Date.now();
    let loaded = 0;
    for (const [key, value] of Object.entries(raw.items || {})) {
      if (!value || typeof value !== 'object') continue;
      if (!(Number(value.expiresAt) > now)) continue;
      sightings.set(key, value);
      loaded++;
    }
    log(`loaded ${loaded} live sightings from ${DATA_FILE}`);
  } catch (error) {
    if (error.code !== 'ENOENT') log(`store load skipped: ${error.message}`);
  }
}

let saving = false;
function saveStore() {
  if (!dirty || saving) return;
  saving = true;
  dirty = false;
  const items = {};
  for (const [key, value] of sightings) items[key] = value;
  const payload = JSON.stringify({ version: 1, savedAt: Date.now(), items });
  try {
    fs.mkdirSync(path.dirname(DATA_FILE), { recursive: true });
    const tmp = `${DATA_FILE}.tmp`;
    fs.writeFileSync(tmp, payload);
    fs.renameSync(tmp, DATA_FILE);
  } catch (error) {
    log(`store save failed: ${error.message}`);
    dirty = true;
  } finally {
    saving = false;
  }
}

function prune() {
  const now = Date.now();
  let removed = 0;
  for (const [key, value] of sightings) {
    if (!(Number(value.expiresAt) > now)) {
      sightings.delete(key);
      removed++;
    }
  }
  // Hard cap: drop the soonest-to-expire entries first.
  if (sightings.size > MAX_SIGHTINGS) {
    const sorted = [...sightings.entries()].sort((a, b) => a[1].expiresAt - b[1].expiresAt);
    for (const [key] of sorted) {
      if (sightings.size <= MAX_SIGHTINGS) break;
      sightings.delete(key);
      removed++;
    }
  }
  if (removed) dirty = true;
  return removed;
}

// ---------------------------------------------------------------- helpers
function log(message) {
  console.log(`[${new Date().toISOString()}] ${message}`);
}

function num(value) {
  const n = typeof value === 'string' ? Number(value) : value;
  return typeof n === 'number' && Number.isFinite(n) ? n : null;
}

function str(value, max = 120) {
  if (typeof value !== 'string') return '';
  return value.slice(0, max);
}

function json(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(data),
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'content-type,x-egg-room',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Cache-Control': 'no-store',
  });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(new Error('invalid json'));
      }
    });
    req.on('error', reject);
  });
}

// crude per-IP rate limit: token bucket refilled per minute
const buckets = new Map();
function rateLimited(ip) {
  if (!RATE_LIMIT_PER_MIN) return false;
  const now = Date.now();
  let bucket = buckets.get(ip);
  if (!bucket) {
    bucket = { tokens: RATE_LIMIT_PER_MIN, at: now };
    buckets.set(ip, bucket);
  }
  const minutes = (now - bucket.at) / 60_000;
  if (minutes > 0) {
    bucket.tokens = Math.min(RATE_LIMIT_PER_MIN, bucket.tokens + minutes * RATE_LIMIT_PER_MIN);
    bucket.at = now;
  }
  if (bucket.tokens < 1) return true;
  bucket.tokens -= 1;
  return false;
}

function authorised(req) {
  if (!ROOM_KEY) return true;
  return req.headers['x-egg-room'] === ROOM_KEY;
}

// ---------------------------------------------------------------- routes
function handleReport(body) {
  const placeId = num(body.placeId);
  const jobId = str(body.jobId, 64);
  const reporterId = str(body.reporterId, 64);
  if (!placeId || !jobId) return { status: 400, body: { error: 'placeId and jobId required' } };

  const ttl = Math.min(MAX_TTL_MS, Math.max(15_000, num(body.ttl) || DEFAULT_TTL_MS));
  const expiresAt = Date.now() + ttl;
  const eggs = Array.isArray(body.eggs) ? body.eggs.slice(0, MAX_EGGS_PER_REPORT) : [];
  let accepted = 0;

  for (const egg of eggs) {
    if (!egg || typeof egg !== 'object') continue;
    const uid = str(egg.uid, 96);
    if (!uid) continue;
    const rate = num(egg.rate);
    const item = {
      key: `${placeId}:${jobId}:${uid}`,
      placeId,
      jobId,
      uid,
      name: str(egg.name, 64) || 'Unknown egg',
      category: str(egg.category, 48),
      rarity: str(egg.rarity, 32),
      rank: num(egg.rank) || 0,
      rate: rate && rate > 0 ? rate : null,
      scale: num(egg.scale),
      weight: num(egg.weight),
      mutations: str(egg.mutations, 64),
      traitsKnown: egg.traitsKnown !== false,
      area: str(egg.area, 64),
      estimated: egg.estimated === true,
      source: egg.source === 'event' ? 'event' : 'field',
      reporterId,
      // player count is intentionally not stored: keep the feed about eggs, not people
      seenAt: Date.now(),
      expiresAt,
    };
    sightings.set(item.key, item);
    accepted++;
  }

  // Anything this reporter previously sent for this server and did not re-send is retired.
  let retired = 0;
  const live = new Set(eggs.map((egg) => `${placeId}:${jobId}:${str(egg && egg.uid, 96)}`));
  for (const [key, value] of sightings) {
    if (value.jobId !== jobId || value.placeId !== placeId) continue;
    if (value.reporterId !== reporterId) continue;
    if (live.has(key)) continue;
    sightings.delete(key);
    retired++;
  }

  if (accepted || retired) dirty = true;
  return { status: 200, body: { ok: true, accepted, retired, expiresAt } };
}

function handleEggs(query) {
  const placeId = num(query.get('placeId'));
  const localJob = str(query.get('localJob'), 64);
  const onlyJob = str(query.get('onlyJob'), 64);
  const minRate = num(query.get('minRate')) || 0;
  const minRank = num(query.get('minRank')) || 0;
  const limit = Math.min(50, Math.max(1, num(query.get('limit')) || 10));
  const offset = Math.max(0, num(query.get('offset')) || 0);
  // all=1 -> one row per egg (full leaderboard). Default -> best egg per server.
  const allEggs = str(query.get('all'), 8) === '1' || str(query.get('all'), 8) === 'true';
  const now = Date.now();

  const filtered = [];
  for (const value of sightings.values()) {
    if (!(value.expiresAt > now)) continue;
    if (placeId && value.placeId !== placeId) continue;
    if (onlyJob && value.jobId !== onlyJob) continue;
    if ((value.rate || 0) < minRate) continue;
    if ((value.rank || 0) < minRank) continue;
    filtered.push(value);
  }

  let ranked;
  if (allEggs) {
    // One row per egg, so the leaderboard is not capped at one egg per server.
    ranked = filtered.slice();
  } else {
    // Best egg per server, so one server cannot fill the whole page.
    const perJob = new Map();
    for (const item of filtered) {
      const current = perJob.get(item.jobId);
      if (!current || (item.rate || 0) > (current.rate || 0)) perJob.set(item.jobId, item);
    }
    ranked = [...perJob.values()];
  }
  ranked.sort((a, b) => (b.rate || 0) - (a.rate || 0) || (b.rank || 0) - (a.rank || 0));
  const page = ranked.slice(offset, offset + limit);

  return {
    status: 200,
    body: {
      items: page.map((item) => ({
        ...item,
        isLocal: item.jobId === localJob,
        // never leak who reported it
        reporterId: undefined,
      })),
      count: page.length,
      total: ranked.length,
      nextOffset: offset + page.length < ranked.length ? offset + page.length : null,
      serverTime: now,
    },
  };
}

function handleJoin(body) {
  const placeId = num(body.placeId);
  const jobId = str(body.jobId, 64);
  const uid = str(body.uid, 96);
  if (!placeId || !jobId || !uid) return { status: 400, body: { error: 'placeId, jobId and uid required' } };

  const key = `${placeId}:${jobId}:${uid}`;
  const item = sightings.get(key);
  const now = Date.now();
  if (!item || !(item.expiresAt > now)) {
    return { status: 200, body: { allowed: false, reason: 'expired' } };
  }
  // Reservation bookkeeping: remember the claim so two users do not teleport for the
  // same egg at the same second. Purely advisory — the game is the source of truth.
  item.claims = Math.min(99, (item.claims || 0) + 1);
  item.lastClaimAt = now;
  dirty = true;
  return {
    status: 200,
    body: { allowed: true, expiresAt: item.expiresAt, claims: item.claims },
  };
}

const dashboard = (stats) => `<!doctype html>
<html><head><meta charset="utf-8"><title>Egg Finder — server</title>
<style>
 body{margin:0;font:14px/1.5 ui-monospace,monospace;background:#0b0a14;color:#e9e6ff;padding:28px}
 h1{font-size:18px;letter-spacing:.14em;margin:0 0 18px;color:#b79bff}
 .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px;margin-bottom:22px}
 .card{background:#16122a;border:1px solid #2c2450;border-radius:10px;padding:14px}
 .k{color:#8d85b5;font-size:11px;letter-spacing:.1em}
 .v{font-size:22px;margin-top:4px}
 table{border-collapse:collapse;width:100%;max-width:900px}
 td,th{padding:7px 10px;border-bottom:1px solid #221c3d;text-align:left;font-size:12px}
 th{color:#8d85b5;font-weight:600;letter-spacing:.08em}
</style></head><body>
<h1>EGG FINDER · SERVER</h1>
<div class="grid">
 <div class="card"><div class="k">UPTIME</div><div class="v">${Math.floor(stats.uptime)}s</div></div>
 <div class="card"><div class="k">LIVE SIGHTINGS</div><div class="v">${stats.live}</div></div>
 <div class="card"><div class="k">SERVERS TRACKED</div><div class="v">${stats.jobs}</div></div>
 <div class="card"><div class="k">BEST EGG NOW</div><div class="v" style="font-size:15px">${stats.best || '—'}</div></div>
</div>
<table><tr><th>RATE /s</th><th>EGG</th><th>RARITY</th><th>AREA</th><th>SERVER</th></tr>
${stats.rows}</table>
</body></html>`;

function statsSnapshot() {
  const now = Date.now();
  const live = [...sightings.values()].filter((v) => v.expiresAt > now);
  const jobs = new Set(live.map((v) => v.jobId));
  live.sort((a, b) => (b.rate || 0) - (a.rate || 0));
  const rows = live
    .slice(0, 15)
    .map(
      (v) =>
        `<tr><td>${v.rate ? v.rate.toLocaleString('en-US') : '—'}</td><td>${escapeHtml(v.name)}</td>` +
        `<td>${escapeHtml(v.rarity || '—')}</td><td>${escapeHtml(v.area || '—')}</td>` +
        `<td>${escapeHtml(v.jobId.slice(0, 8))}…</td></tr>`
    )
    .join('');
  return {
    uptime: process.uptime(),
    live: live.length,
    jobs: jobs.size,
    best: live[0] ? `${live[0].name} · ${(live[0].rate || 0).toLocaleString('en-US')}/s` : null,
    rows: rows || '<tr><td colspan="5" style="color:#6d6690">no live sightings yet</td></tr>',
  };
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// ---------------------------------------------------------------- server
const server = http.createServer(async (req, res) => {
  const ip = req.socket.remoteAddress || 'unknown';
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'content-type,x-egg-room',
      'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    });
    return res.end();
  }
  if (rateLimited(ip)) return json(res, 429, { error: 'slow down' });

  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  try {
    if (req.method === 'GET' && url.pathname === '/health') {
      return json(res, 200, { ok: true, uptime: Math.floor(process.uptime()), sightings: sightings.size });
    }
    if (req.method === 'GET' && url.pathname === '/') {
      const html = dashboard(statsSnapshot());
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      return res.end(html);
    }
    if (!authorised(req)) return json(res, 401, { error: 'bad room key' });

    if (req.method === 'POST' && url.pathname === '/v1/report') {
      const result = handleReport(await readBody(req));
      return json(res, result.status, result.body);
    }
    if (req.method === 'GET' && url.pathname === '/v1/eggs') {
      const result = handleEggs(url.searchParams);
      return json(res, result.status, result.body);
    }
    if (req.method === 'POST' && url.pathname === '/v1/join') {
      const result = handleJoin(await readBody(req));
      return json(res, result.status, result.body);
    }
    return json(res, 404, { error: 'not found' });
  } catch (error) {
    return json(res, 400, { error: error.message || 'bad request' });
  }
});

loadStore();
prune();
setInterval(() => {
  const removed = prune();
  if (removed) log(`pruned ${removed} expired sightings`);
  saveStore();
}, 15_000).unref();

process.on('SIGINT', () => {
  saveStore();
  log('bye');
  process.exit(0);
});
process.on('SIGTERM', () => {
  saveStore();
  process.exit(0);
});

server.listen(PORT, HOST, () => {
  log(`egg-finder backend listening on http://${HOST}:${PORT}`);
  log(ROOM_KEY ? 'room key required (X-Egg-Room)' : 'WARNING: ROOM_KEY unset — API is open');
});
