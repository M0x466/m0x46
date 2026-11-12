'use strict';
// M0x46 report relay v3. No Roblox scraping, sample sightings, or third-party feeds.
const http = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const MIN_RATE = 1e9;
const JOB = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const RARITIES = ['Common', 'Uncommon', 'Rare', 'Epic', 'Legendary', 'Mythic', 'Cosmic', 'Secret', 'Eternal', 'Divine'];
const isObject = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const finite = v => typeof v === 'number' && Number.isFinite(v);
const place = v => Number.isSafeInteger(v) && v > 0;
const job = v => typeof v === 'string' && JOB.test(v);
const text = (v, max, required = false) => typeof v === 'string' && v.length <= max && (!required || v.trim().length > 0) && !/[\x00-\x1f]/.test(v);
function fail(status, message) { throw Object.assign(new Error(message), {status}); }
function envInt(env, key, fallback, low, high) {
  const n = Number(env[key] ?? fallback);
  if (!Number.isSafeInteger(n) || n < low || n > high) throw new Error(`Invalid ${key}`);
  return n;
}
function createApp(options = {}) {
  const env = options.env || process.env;
  const now = options.now || Date.now;
  const roomKey = options.roomKey ?? env.ROOM_KEY ?? '';
  if (typeof roomKey !== 'string' || roomKey.length < 24 || roomKey.length > 512 || /[^\x21-\x7e]/.test(roomKey)) {
    throw new Error('ROOM_KEY must be a private key of 24-512 printable ASCII characters without spaces');
  }
  const keyHash = crypto.createHash('sha256').update(roomKey).digest();
  const maxEggs = envInt(env, 'MAX_EGGS_PER_REPORT', 256, 1, 1000);
  const maxReports = envInt(env, 'MAX_REPORTERS', 1000, 1, 10000);
  const maxSightings = envInt(env, 'MAX_SIGHTINGS', 25000, 1, 100000);
  const defaultTTL = envInt(env, 'DEFAULT_TTL_MS', 45000, 15000, 120000);
  const maxTTL = envInt(env, 'MAX_TTL_MS', 120000, defaultTTL, 120000);
  const maxBytes = envInt(env, 'MAX_BODY_BYTES', 524288, 1024, 2097152);
  const rateLimit = envInt(env, 'RATE_LIMIT_PER_MIN', 6000, 0, 100000);
  const dataFile = options.dataFile === undefined ? env.DATA_FILE || path.join(__dirname, 'data', 'reports.json') : options.dataFile;
  const reports = new Map(); // server + reporter owns a complete snapshot, including []
  const pages = new Map(); // short-lived immutable ordering for pagination
  const buckets = new Map();
  let revision = 0, persistedRevision = 0, savePromise = null, storageError = null;

  function normalizeEgg(e) {
    if (!isObject(e) || !text(e.uid, 96, true) || !text(e.name, 96, true)) fail(400, 'Every egg needs uid and name');
    if (!finite(e.rate) || e.rate <= 0 || e.rate > 1e30) fail(400, 'Invalid numeric income');
    if (e.estimated === true) fail(422, 'Estimated income cannot be published; use game display income');
    const rarity = typeof e.rarity === 'string' ? e.rarity : 'Unknown';
    if (!text(rarity, 32)) fail(400, 'Invalid rarity');
    const knownRank = RARITIES.findIndex(v => v.toLowerCase() === rarity.toLowerCase()) + 1;
    const rank = knownRank || (e.rank === undefined ? 0 : e.rank);
    if (!Number.isInteger(rank) || rank < 0 || rank > 100) fail(400, 'Invalid rarity rank');
    const mutations = Array.isArray(e.mutations) ? e.mutations : typeof e.mutations === 'string' ? e.mutations.split(/[,;|]+/).map(v => v.trim()).filter(Boolean) : [];
    if (mutations.length > 24 || mutations.some(v => !text(v, 48, true))) fail(400, 'Invalid mutations');
    const egg = {uid:e.uid, name:e.name, rate:e.rate, rarity, rank, mutations:[...new Set(mutations)], estimated:false,
      rateSource:e.rateSource === 'display' ? 'display' : 'client', traitsKnown:e.traitsKnown === true, source:'field'};
    for (const k of ['category', 'area']) {
      if (e[k] !== undefined && e[k] !== null) {
        if (!text(e[k], 96)) fail(400, `Invalid ${k}`);
        egg[k] = e[k];
      }
    }
    return egg;
  }
  function prune() {
    const t = now();
    for (const [k, r] of reports) if (r.expiresAt <= t) { reports.delete(k); revision++; }
    for (const [k, p] of pages) if (p.expiresAt <= t) pages.delete(k);
    for (const [k, b] of buckets) if (t - b.at > 120000) buckets.delete(k);
  }
  let cachedRows, cachedRevision = -1, cacheExpires = 0;
  function canonical() {
    prune();
    if (cachedRevision === revision && now() < cacheExpires) return cachedRows;
    const rows = new Map();
    for (const r of reports.values()) for (const e of r.eggs) {
      const key = `${r.placeId}:${r.jobId}:${e.uid}`;
      const old = rows.get(key);
      // Latest observation wins, even when its income decreased.
      if (!old || r.seenAt > old.seenAt || (r.seenAt === old.seenAt && r.order > old.order)) {
        rows.set(key, {...e, key, placeId:r.placeId, jobId:r.jobId, seenAt:r.seenAt, expiresAt:r.expiresAt, order:r.order});
      }
    }
    cacheExpires = Infinity;
    for (const r of reports.values()) cacheExpires = Math.min(cacheExpires, r.expiresAt);
    cachedRows = rows; cachedRevision = revision;
    return rows;
  }
  function report(body) {
    if (!isObject(body) || !place(body.placeId) || !job(body.jobId) || !text(body.reporterId, 96, true)) fail(400, 'Valid placeId, UUID jobId and reporterId required');
    if (!Array.isArray(body.eggs) || body.eggs.length > maxEggs) fail(400, `eggs must be a complete array of at most ${maxEggs}`);
    if (body.ttl !== undefined && (!finite(body.ttl) || body.ttl <= 0)) fail(400, 'ttl must be positive milliseconds');
    if (body.sequence !== undefined && (!Number.isSafeInteger(body.sequence) || body.sequence < 0)) fail(400, 'Invalid sequence');
    const eggs = body.eggs.map(normalizeEgg), ids = new Set();
    for (const e of eggs) { if (ids.has(e.uid)) fail(400, 'Duplicate uid in snapshot'); ids.add(e.uid); }
    prune();
    const jobId = body.jobId.toLowerCase();
    const key = JSON.stringify([body.placeId, jobId, body.reporterId]);
    const previous = reports.get(key);
    if (previous?.sequence !== undefined && (body.sequence === undefined || body.sequence <= previous.sequence)) fail(409, 'Outdated snapshot sequence');
    if (!previous && reports.size >= maxReports) fail(503, 'Reporter capacity reached');
    let size = eggs.length;
    for (const [k, r] of reports) if (k !== key) size += r.eggs.length;
    if (size > maxSightings) fail(503, 'Sighting capacity reached');
    const seenAt = now();
    const expiresAt = seenAt + Math.max(15000, Math.min(maxTTL, body.ttl ?? defaultTTL));
    const retired = previous ? previous.eggs.filter(e => !ids.has(e.uid)).length : 0;
    reports.set(key, {placeId:body.placeId, jobId, reporterId:body.reporterId, sequence:body.sequence, eggs, seenAt, expiresAt, order:++revision});
    return {ok:true, accepted:eggs.length, retired, expiresAt, serverTime:seenAt};
  }
  function queryNum(q, key, fallback, low, high, integer = false) {
    if (!q.has(key)) return fallback;
    const raw = q.get(key), n = Number(raw);
    if (raw === '' || !Number.isFinite(n) || n < low || n > high || (integer && !Number.isSafeInteger(n))) fail(400, `Invalid ${key}`);
    return n;
  }
  function feed(q) {
    for (const k of q.keys()) if (q.getAll(k).length > 1) fail(400, `Duplicate query parameter: ${k}`);
    const placeId = queryNum(q, 'placeId', null, 1, Number.MAX_SAFE_INTEGER, true);
    const localJob = q.get('localJob') || '';
    const excludeJob = q.get('excludeJob') || '';
    const onlyJob = q.get('onlyJob') || '';
    for (const v of [localJob, excludeJob, onlyJob]) if (v && !job(v)) fail(400, 'Invalid JobId filter');
    const minRate = Math.max(MIN_RATE, queryNum(q, 'minRate', MIN_RATE, 0, 1e30));
    const minRank = queryNum(q, 'minRank', 0, 0, 100, true);
    const limit = queryNum(q, 'limit', 20, 1, 50, true);
    const offset = queryNum(q, 'offset', 0, 0, maxSightings, true);
    const all = q.get('all') === '1' || q.get('all') === 'true';
    const signature = JSON.stringify([placeId, localJob.toLowerCase(), excludeJob.toLowerCase(), onlyJob.toLowerCase(), minRate, minRank, all, limit]);
    const live = canonical();
    let page, snapshot = q.get('snapshot');
    const matches = v => (!placeId || v.placeId === placeId) && (!excludeJob || v.jobId !== excludeJob.toLowerCase()) && (!onlyJob || v.jobId === onlyJob.toLowerCase()) && v.rate >= minRate && v.rank >= minRank;
    if (snapshot) {
      page = pages.get(snapshot);
      if (!page || page.expiresAt <= now()) fail(409, 'Pagination snapshot expired; restart at offset 0');
      if (page.signature !== signature) fail(400, 'Pagination filters changed');
    } else {
      // Crucially: exclude the local server BEFORE best-per-server selection,
      // sorting, counts, or pagination. Many local eggs cannot hide remote ones.
      let rows = [...live.values()].filter(matches);
      rows.sort((a,b) => b.rate - a.rate || b.rank - a.rank || a.key.localeCompare(b.key));
      if (!all) {
        const seen = new Set();
        rows = rows.filter(v => {const k = `${v.placeId}:${v.jobId}`; if (seen.has(k)) return false; seen.add(k); return true;});
      }
      page = {signature, keys:rows.map(v => v.key), createdAt:now(), expiresAt:now()+20000};
      if (pages.size >= 32) pages.delete(pages.keys().next().value);
      snapshot = crypto.randomBytes(16).toString('hex');
      pages.set(snapshot, page);
    }
    const eligible = page.keys.map(k => live.get(k)).filter(v => v && matches(v));
    const end = Math.min(page.keys.length, offset + limit);
    const items = page.keys.slice(offset, end).map(k => live.get(k)).filter(v => v && matches(v)).map(({order, ...v}) => ({...v, isLocal:v.jobId === localJob.toLowerCase()}));
    const reporterJobs = new Set([...reports.values()].filter(r => (!placeId || r.placeId === placeId) && (!excludeJob || r.jobId !== excludeJob.toLowerCase()) && (!onlyJob || r.jobId === onlyJob.toLowerCase())).map(r => `${r.placeId}:${r.jobId}`));
    return {items, count:items.length, total:eligible.length, serverCount:new Set(eligible.map(v => `${v.placeId}:${v.jobId}`)).size,
      reportingServerCount:reporterJobs.size, nextOffset:end < page.keys.length ? end : null, snapshot, snapshotAt:page.createdAt, snapshotExpiresAt:page.expiresAt, serverTime:now(), minRate};
  }
  function join(body) {
    if (!isObject(body) || !place(body.placeId) || !job(body.jobId) || !text(body.uid, 96, true) || !job(body.currentJob)) fail(400, 'Valid placeId, jobId, uid and currentJob required');
    if (body.jobId.toLowerCase() === body.currentJob.toLowerCase()) return {allowed:false, reason:'current_server'};
    const row = canonical().get(`${body.placeId}:${body.jobId.toLowerCase()}:${body.uid}`);
    if (!row || row.expiresAt <= now()) return {allowed:false, reason:'expired'};
    if (row.rate < MIN_RATE) return {allowed:false, reason:'below_minimum'};
    // A fresh report is NOT a reservation and does not establish capacity/access.
    return {allowed:true, placeId:row.placeId, jobId:row.jobId, uid:row.uid, expiresAt:row.expiresAt, serverTime:now(), availability:'unverified'};
  }
  function json(res, status, value) {
    const payload = JSON.stringify(value);
    res.writeHead(status, {'Content-Type':'application/json; charset=utf-8', 'Content-Length':Buffer.byteLength(payload), 'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff', ...(status === 429 ? {'Retry-After':'10'} : {})});
    res.end(payload);
  }
  function readBody(req) {
    if (!(req.headers['content-type'] || '').toLowerCase().startsWith('application/json')) {
      req.resume(); fail(415, 'Content-Type must be application/json');
    }
    return new Promise((resolve, reject) => {
      let chunks = [], size = 0, exceeded = false;
      req.on('data', chunk => {
        size += chunk.length;
        if (size > maxBytes) {
          chunks = [];
          if (!exceeded) { exceeded = true; reject(Object.assign(new Error('Report body too large'), {status:413})); }
        } else if (!exceeded) chunks.push(chunk);
      });
      req.on('end', () => {
        if (exceeded) return;
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
        catch { reject(Object.assign(new Error('Invalid JSON'), {status:400})); }
      });
      req.on('error', reject);
      req.on('aborted', () => reject(Object.assign(new Error('Request aborted'), {status:400})));
    });
  }
  const server = http.createServer(async (req,res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      if (req.method === 'GET' && url.pathname === '/health') return json(res, 200, {ok:true, service:'m0x46-egg-relay', version:3, uptime:Math.floor(process.uptime()), build:env.APP_BUILD || 'unversioned', capabilities:{excludeJob:true, snapshots:true, minRate:MIN_RATE}});
      if (req.method === 'GET' && url.pathname === '/') return json(res, 200, {service:'M0x46 Live Egg Finder', health:'/health', feed:'Authenticated client reports only'});
      const supplied = req.headers['x-egg-room'];
      if (typeof supplied !== 'string' || supplied.length > 512 || !crypto.timingSafeEqual(keyHash, crypto.createHash('sha256').update(supplied).digest())) return json(res,401,{error:'Incorrect X-Egg-Room'});
      // Do not trust X-Forwarded-For supplied by a client. Proxy/NAT shares this
      // generous aggregate bucket; tune for participating clients, not one phone.
      if (rateLimit) {
        const ip = req.socket.remoteAddress || 'unknown', t = now();
        if (buckets.size >= 4096 && !buckets.has(ip)) return json(res,429,{error:'Too many connections'});
        const b = buckets.get(ip) || {tokens:rateLimit, at:t};
        b.tokens = Math.min(rateLimit, b.tokens + Math.max(0,t-b.at)*rateLimit/60000); b.at = t;
        buckets.set(ip,b);
        if (b.tokens < 1) return json(res,429,{error:'Rate limit; retry later'});
        b.tokens--;
      }
      if (req.method === 'GET' && url.pathname === '/v1/eggs') return json(res,200,feed(url.searchParams));
      if (req.method === 'POST' && url.pathname === '/v1/report') return json(res,200,report(await readBody(req)));
      if (req.method === 'POST' && url.pathname === '/v1/join') return json(res,200,join(await readBody(req)));
      return json(res,404,{error:'Not found'});
    } catch(e) {
      if (!res.headersSent && !res.destroyed) json(res,e.status || 500,{error:e.status ? e.message : 'Internal server error'});
      if (!e.status) console.error('[M0x46] request failed:',e.message);
    }
  });
  server.requestTimeout = 10000;
  server.headersTimeout = 10000;
  server.keepAliveTimeout = 5000;
  async function load() {
    if (!dataFile) return;
    try {
      const raw = JSON.parse(await fs.readFile(dataFile,'utf8'));
      if (raw.version !== 3 || !Array.isArray(raw.reports)) throw new Error('Old store ignored; fresh client snapshots required');
      for (const r of raw.reports.slice(0,maxReports)) {
        try {
          if (!isObject(r) || !finite(r.seenAt) || r.seenAt > now() || !finite(r.expiresAt) || r.expiresAt <= now() || r.expiresAt > r.seenAt+maxTTL) continue;
          report({...r, ttl:defaultTTL}); // reuse all validation, then restore original timestamps
          const k = JSON.stringify([r.placeId, r.jobId.toLowerCase(), r.reporterId]);
          Object.assign(reports.get(k), {seenAt:r.seenAt, expiresAt:r.expiresAt});
        } catch { /* invalid persisted record is never served */ }
      }
      persistedRevision = revision;
    } catch(e) { if (e.code !== 'ENOENT') console.error('[M0x46] load:',e.message); }
  }
  async function save() {
    if (!dataFile || persistedRevision === revision) return;
    if (savePromise) { await savePromise; if (persistedRevision !== revision) return save(); return; }
    const targetRevision = revision;
    const payload = JSON.stringify({version:3, reports:[...reports.values()]});
    savePromise = (async () => {
      try {
        await fs.mkdir(path.dirname(dataFile),{recursive:true});
        await fs.writeFile(dataFile+'.tmp',payload,{mode:0o600});
        await fs.rename(dataFile+'.tmp',dataFile);
        persistedRevision = targetRevision; storageError = null;
      } catch(e) { storageError = e.message; console.error('[M0x46] save:',e.message); }
      finally { savePromise = null; }
    })();
    await savePromise;
  }
  let timer;
  async function start(port = Number(env.PORT || 8080), host = env.HOST || '0.0.0.0') {
    await load();
    await new Promise((resolve,reject) => {server.once('error',reject); server.listen(port,host,resolve);});
    timer = setInterval(() => {prune(); void save();},5000); timer.unref();
    return server.address();
  }
  async function stop() {
    clearInterval(timer);
    if (server.listening) await new Promise(resolve => { server.close(resolve); server.closeIdleConnections(); });
    prune(); await save();
  }
  return {server, start, stop, save, get storageError(){return storageError;}};
}
if (require.main === module) {
  (async () => {
    const app = createApp();
    await app.start();
    console.log('[M0x46] relay v3 listening; private X-Egg-Room authentication required');
    let stopping = false;
    for (const signal of ['SIGINT','SIGTERM']) process.on(signal, async () => {
      if (stopping) return; stopping = true;
      const deadline = setTimeout(() => process.exit(1),8000); deadline.unref();
      await app.stop(); process.exit(app.storageError ? 1 : 0);
    });
  })().catch(e => {console.error('[M0x46]',e.message);process.exitCode=1;});
}
module.exports = {createApp};
