#!/usr/bin/env node
// Local HTTPS mirror of apps-mac.razer.com for Razer Synapse (RazerAppEngine) on macOS.
//
// Chromium inside Razer.app is started with --host-rules="MAP apps-mac.razer.com 127.0.0.1:8443"
// and --ignore-certificate-errors, so every request it makes to apps-mac.razer.com lands here.
// Node itself resolves apps-mac.razer.com normally, so this server forwards to the real CDN.
//
// Everything is passed through untouched except what rules.json says (see README.md):
//   jsonEdits  - structural edits of JSON arrays/objects (dashboard device lists, installer manifests)
//   routes     - path routing (regex -> upstream host + path, plus pathRewrite) with optional text
//                rewrites (counted against 'expect', refused with 502 when a 'required' one misses),
//                filtered by the active backend ("203-mac" | "153-win" | anything you name)
// Product knowledge lives in rules.json; this file stays generic.
//
// Zero dependencies: Node >= 20 built-ins only.

import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import dns from 'node:dns';
import net from 'node:net';
import zlib from 'node:zlib';
import { isUtf8 } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const ARGS = parseArgs(process.argv.slice(2));
const PORT = Number(ARGS.port ?? process.env.MIRROR_PORT ?? 8443);
const BIND = String(ARGS.bind ?? process.env.MIRROR_BIND ?? '127.0.0.1');
const RULES_PATH = path.resolve(String(ARGS.rules ?? process.env.MIRROR_RULES ?? path.join(ROOT, 'rules.json')));
const BACKEND_OVERRIDE = ARGS.backend ?? process.env.MIRROR_BACKEND ?? null;
const CERT_DIR = path.join(ROOT, 'certs');
const LOG_DIR = path.join(ROOT, 'logs');
const LOG_FILE = path.join(LOG_DIR, 'mirror.log');
const DEFAULT_UPSTREAM = 'apps-mac.razer.com';
const UPSTREAM_TIMEOUT_MS = 30_000;
const DNS_TTL_MS = 60_000;

// Request headers that are connection-scoped and must not be forwarded (RFC 9110 7.6.1).
const HOP_BY_HOP = new Set([
  'connection', 'keep-alive', 'proxy-connection', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'trailers', 'transfer-encoding', 'upgrade', 'http2-settings',
]);
// Dropped from upstream requests whose response we buffer and may edit: we always want a full 200.
const CONDITIONAL = new Set(['if-none-match', 'if-modified-since', 'if-match', 'if-unmodified-since', 'if-range', 'range']);
const DEFAULT_TEXT_TYPES = /^(text\/(html|css|javascript|plain|xml)|application\/(javascript|x-javascript|ecmascript|json|manifest\+json|[\w.-]+\+json))\b/i;
const TEXT_EXTENSIONS = /\.(m?js|cjs|json|webmanifest|html?|css|map|txt)$/i;

// ---------------------------------------------------------------- utilities

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const m = /^--([\w-]+)(?:=(.*))?$/.exec(argv[i]);
    if (!m) continue;
    if (m[2] !== undefined) out[m[1]] = m[2];
    else if (argv[i + 1] !== undefined && !argv[i + 1].startsWith('--')) out[m[1]] = argv[++i];
    else out[m[1]] = true;
  }
  return out;
}

fs.mkdirSync(LOG_DIR, { recursive: true });
const logStream = fs.createWriteStream(LOG_FILE, { flags: 'a' });
function log(line) {
  const s = `${new Date().toISOString()} ${line}`;
  logStream.write(s + '\n');
  if (process.env.MIRROR_QUIET !== '1') process.stdout.write(s + '\n');
}

function isLoopbackOrUnspecified(ip) {
  if (net.isIPv4(ip)) return ip.startsWith('127.') || ip === '0.0.0.0';
  if (net.isIPv6(ip)) {
    const v = ip.toLowerCase();
    if (v === '::1' || v === '::') return true;
    const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(v);
    return mapped ? isLoopbackOrUnspecified(mapped[1]) : false;
  }
  return true; // not an IP at all: refuse
}

// ---------------------------------------------------------------- certificate

function opensslBin() {
  for (const p of ['/opt/homebrew/bin/openssl', '/usr/local/bin/openssl', '/usr/bin/openssl']) {
    if (fs.existsSync(p)) return p;
  }
  return 'openssl';
}

function ensureCert() {
  const key = path.join(CERT_DIR, 'key.pem');
  const cert = path.join(CERT_DIR, 'cert.pem');
  if (!fs.existsSync(key) || !fs.existsSync(cert)) {
    fs.mkdirSync(CERT_DIR, { recursive: true });
    execFileSync(opensslBin(), [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '825',
      '-keyout', key, '-out', cert,
      '-subj', '/CN=apps-mac.razer.com/O=local synapse mirror (self-signed)',
      '-addext', 'subjectAltName=DNS:apps-mac.razer.com,DNS:localhost,IP:127.0.0.1',
      '-addext', 'extendedKeyUsage=serverAuth',
    ], { stdio: ['ignore', 'ignore', 'pipe'] });
    fs.chmodSync(key, 0o600);
    log(`cert generated ${cert}`);
  }
  return { key: fs.readFileSync(key), cert: fs.readFileSync(cert) };
}

// ---------------------------------------------------------------- rules

let rules = null;
let rulesMtime = -1;
let rulesError = null;

function compileRegex(src, flags, where) {
  try { return new RegExp(src, flags ?? ''); } catch (e) { throw new Error(`${where}: bad regex ${JSON.stringify(src)}: ${e.message}`); }
}

function compileRules(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('rules root must be an object');
  const r = {
    upstreamHost: raw.upstreamHost || DEFAULT_UPSTREAM,
    backend: raw.backend || '203-mac',
    resolve: raw.resolve && typeof raw.resolve === 'object' ? raw.resolve : {},
    jsonEdits: [],
    routes: [],
  };
  (raw.jsonEdits ?? []).forEach((e, i) => {
    const where = `jsonEdits[${i}]`;
    if (typeof e.match !== 'string') throw new Error(`${where}.match must be a regex string`);
    r.jsonEdits.push({
      name: e.name || where,
      match: compileRegex(e.match, e.flags, `${where}.match`),
      key: e.key || 'productId',
      ensure: Array.isArray(e.ensure) ? e.ensure : [],
      remove: Array.isArray(e.remove) ? e.remove : [],
      set: e.set && typeof e.set === 'object' ? e.set : null,
      setIfMissing: e.setIfMissing && typeof e.setIfMissing === 'object' ? e.setIfMissing : null,
      backend: normBackend(e.backend),
    });
  });
  (raw.routes ?? []).forEach((rt, i) => {
    const where = `routes[${i}]`;
    if (typeof rt.match !== 'string') throw new Error(`${where}.match must be a regex string`);
    r.routes.push({
      name: rt.name || where,
      backend: normBackend(rt.backend),
      match: compileRegex(rt.match, rt.flags, `${where}.match`),
      host: rt.host || null,
      path: typeof rt.path === 'string' ? rt.path : null,
      pathRewrite: (rt.pathRewrite ?? []).map((w, j) => compileRewrite(w, `${where}.pathRewrite[${j}]`)),
      keepQuery: rt.keepQuery !== false,
      noStore: rt.noStore !== false,
      textTypes: rt.textTypes ? compileRegex(rt.textTypes, 'i', `${where}.textTypes`) : null,
      noRewrite: rt.noRewrite ? compileRegex(rt.noRewrite, '', `${where}.noRewrite`) : null,
      rewrite: (rt.rewrite ?? []).map((w, j) => compileRewrite(w, `${where}.rewrite[${j}]`)),
    });
  });
  return r;
}

function normBackend(b) {
  if (b === undefined || b === null || b === '*') return null;
  return Array.isArray(b) ? b.map(String) : [String(b)];
}

function compileRewrite(w, where) {
  const base = {
    where,
    name: w.name || where,
    paths: w.paths ? compileRegex(w.paths, '', `${where}.paths`) : null,
    replace: String(w.replace ?? ''),
    // expect: {"<upstream path suffix>": count} - a different count is logged as a warning.
    expect: w.expect && typeof w.expect === 'object' ? w.expect : null,
    // required: regex on the request path - a 2xx response there with 0 matches is refused (502).
    required: w.required ? compileRegex(w.required, '', `${where}.required`) : null,
  };
  if (base.expect) {
    for (const [k, v] of Object.entries(base.expect)) {
      if (!Number.isInteger(v) || v < 0) throw new Error(`${where}.expect[${JSON.stringify(k)}] must be a non-negative integer`);
    }
  }
  if (typeof w.literal === 'string') return { ...base, literal: w.literal };
  if (typeof w.pattern === 'string') {
    const flags = w.flags ?? 'g';
    return { ...base, re: compileRegex(w.pattern, flags.includes('g') ? flags : flags + 'g', `${where}.pattern`) };
  }
  throw new Error(`${where}: needs "literal" or "pattern"`);
}

function loadRules() {
  let st;
  try { st = fs.statSync(RULES_PATH); } catch (e) {
    if (!rules) { rules = compileRules({}); rulesError = `rules file missing: ${RULES_PATH}`; log(`rules ${rulesError}`); }
    return rules;
  }
  if (st.mtimeMs === rulesMtime && rules) return rules;
  rulesMtime = st.mtimeMs;
  try {
    const next = compileRules(JSON.parse(fs.readFileSync(RULES_PATH, 'utf8')));
    rules = next;
    rulesError = null;
    log(`rules loaded ${RULES_PATH} backend=${activeBackend()} jsonEdits=${rules.jsonEdits.length} routes=${rules.routes.length}`);
  } catch (e) {
    rulesError = e.message;
    log(`rules ERROR keeping previous rules: ${e.message}`);
    if (!rules) rules = compileRules({});
  }
  return rules;
}

function activeBackend() {
  return String(BACKEND_OVERRIDE ?? rules?.backend ?? '203-mac');
}

function appliesToBackend(entry) {
  return entry.backend === null || entry.backend.includes(activeBackend());
}

// ---------------------------------------------------------------- upstream DNS

const dnsCache = new Map(); // host -> { ips, until }
const directResolver = new dns.promises.Resolver();

async function resolveUpstream(host) {
  const pinned = rules?.resolve?.[host];
  if (pinned) {
    const list = (Array.isArray(pinned) ? pinned : [pinned]).filter((ip) => !isLoopbackOrUnspecified(ip));
    if (list.length) return list[0];
    throw new Error(`pinned IP for ${host} is loopback/invalid`);
  }
  const hit = dnsCache.get(host);
  if (hit && hit.until > Date.now()) return hit.ips[0];
  let ips = [];
  try {
    ips = (await dns.promises.lookup(host, { all: true })).map((a) => a.address);
  } catch { /* fall through to direct resolver */ }
  let good = ips.filter((ip) => !isLoopbackOrUnspecified(ip));
  if (!good.length) {
    // The system resolver mapped the host to loopback (e.g. an /etc/hosts entry pointing at us).
    // Ask the DNS servers directly; Resolver ignores /etc/hosts.
    try { good = (await directResolver.resolve4(host)).filter((ip) => !isLoopbackOrUnspecified(ip)); } catch { /* ignore */ }
  }
  if (!good.length) throw new Error(`refusing upstream ${host}: resolves only to loopback/none (${ips.join(',') || 'no answer'})`);
  good.sort((a, b) => Number(net.isIPv6(a)) - Number(net.isIPv6(b))); // prefer IPv4
  dnsCache.set(host, { ips: good, until: Date.now() + DNS_TTL_MS });
  return good[0];
}

const agent = new https.Agent({ keepAlive: true, maxSockets: 64, maxFreeSockets: 16, timeout: UPSTREAM_TIMEOUT_MS });

// ---------------------------------------------------------------- request planning

function planRequest(req) {
  const r = loadRules();
  // Use the raw request target (no URL normalisation) so passthrough paths stay byte-identical.
  const q = req.url.indexOf('?');
  const pathname = q < 0 ? req.url : req.url.slice(0, q);
  const search = q < 0 ? '' : req.url.slice(q);
  let host = r.upstreamHost;
  let upstreamPath = pathname + search;
  let route = null;
  for (const rt of r.routes) {
    if (!appliesToBackend(rt)) continue;
    rt.match.lastIndex = 0;
    if (!rt.match.test(pathname)) continue;
    route = rt;
    rt.match.lastIndex = 0;
    let newPath = rt.path !== null ? pathname.replace(rt.match, rt.path) : pathname;
    // pathRewrite runs on the mapped upstream path (no query string); its 'paths' filters see the request path.
    if (rt.pathRewrite.length) newPath = applyRewrites(newPath, rt.pathRewrite, pathname).text;
    upstreamPath = newPath + (rt.keepQuery ? search : '');
    if (rt.host) host = rt.host;
    break;
  }
  const edits = r.jsonEdits.filter((e) => { e.match.lastIndex = 0; return appliesToBackend(e) && e.match.test(pathname); });
  const managed = Boolean(route) || edits.length > 0;
  const qi = upstreamPath.indexOf('?');
  const upstreamPathname = qi < 0 ? upstreamPath : upstreamPath.slice(0, qi);
  return { pathname, search, host, upstreamPath, upstreamPathname, route, edits, managed };
}

function buildUpstreamHeaders(req, plan) {
  const h = {};
  const connTokens = new Set(String(req.headers.connection || '').toLowerCase().split(',').map((s) => s.trim()).filter(Boolean));
  for (let i = 0; i < req.rawHeaders.length; i += 2) {
    const name = req.rawHeaders[i];
    const lower = name.toLowerCase();
    if (HOP_BY_HOP.has(lower) || connTokens.has(lower) || lower === 'host') continue;
    if (lower.startsWith(':')) continue;
    if (plan.managed && (CONDITIONAL.has(lower) || lower === 'accept-encoding')) continue;
    const v = req.rawHeaders[i + 1];
    if (h[name] === undefined) h[name] = v;
    else h[name] = Array.isArray(h[name]) ? [...h[name], v] : [h[name], v];
  }
  h.Host = plan.host;
  if (plan.managed) h['Accept-Encoding'] = 'identity';
  return h;
}

function filterResponseHeaders(rawHeaders, drop) {
  const out = [];
  const connTokens = new Set();
  for (let i = 0; i < rawHeaders.length; i += 2) {
    if (rawHeaders[i].toLowerCase() === 'connection') String(rawHeaders[i + 1]).toLowerCase().split(',').forEach((t) => connTokens.add(t.trim()));
  }
  for (let i = 0; i < rawHeaders.length; i += 2) {
    const lower = rawHeaders[i].toLowerCase();
    if (HOP_BY_HOP.has(lower) || connTokens.has(lower) || drop.has(lower)) continue;
    out.push(rawHeaders[i], rawHeaders[i + 1]);
  }
  return out;
}

// ---------------------------------------------------------------- body editing

function decodeBody(buf, encoding) {
  const enc = String(encoding || 'identity').toLowerCase().trim();
  if (enc === 'identity' || enc === '') return buf;
  if (enc === 'gzip' || enc === 'x-gzip') return zlib.gunzipSync(buf);
  if (enc === 'br') return zlib.brotliDecompressSync(buf);
  if (enc === 'deflate') { try { return zlib.inflateSync(buf); } catch { return zlib.inflateRawSync(buf); } }
  if (enc === 'zstd' && typeof zlib.zstdDecompressSync === 'function') return zlib.zstdDecompressSync(buf);
  throw new Error(`unsupported content-encoding ${enc}`);
}

function isTextual(contentType, pathname, route) {
  const ct = String(contentType || '').trim();
  if (route?.textTypes) return route.textTypes.test(ct);
  if (DEFAULT_TEXT_TYPES.test(ct)) return true;
  if (!ct || /^(application\/octet-stream|binary\/octet-stream)\b/i.test(ct)) return TEXT_EXTENSIONS.test(pathname);
  return false;
}

// Applies rewrites in order. Returns the new text, the total count and one {w, n} per entry that ran.
function applyRewrites(text, rewrites, pathname) {
  let count = 0;
  const hits = [];
  for (const w of rewrites) {
    if (w.paths && !w.paths.test(pathname)) continue;
    let n = 0;
    if (w.literal !== undefined) {
      if (w.literal) {
        const parts = text.split(w.literal);
        n = parts.length - 1;
        text = parts.join(w.replace);
      }
    } else {
      w.re.lastIndex = 0;
      n = [...text.matchAll(w.re)].length;
      w.re.lastIndex = 0;
      text = text.replace(w.re, w.replace); // String.replace semantics: $1, $<name>, $&
    }
    count += n;
    hits.push({ w, n });
  }
  return { text, count, hits };
}

// Compares per-entry hit counts with each entry's 'expect' and 'required'.
// Returns { warnings: [...], fatal: string|null }.
function checkRewriteCounts(rewrites, hits, plan) {
  const byEntry = new Map(hits.map((h) => [h.w, h.n]));
  const warnings = [];
  let fatal = null;
  for (const w of rewrites) {
    const n = byEntry.get(w) ?? 0;
    if (w.expect) {
      for (const [suffix, want] of Object.entries(w.expect)) {
        const s = suffix.startsWith('/') ? suffix : `/${suffix}`;
        if (plan.upstreamPathname.endsWith(s) && n !== want) warnings.push(`${w.name}: ${n} matches, expected ${want} (${suffix})`);
      }
    }
    if (w.required && w.required.test(plan.pathname) && n === 0 && !fatal) {
      fatal = `required rewrite ${w.name} matched 0 times in ${plan.upstreamPathname}`;
    }
  }
  return { warnings, fatal };
}

function getDotted(obj, dotted) {
  let cur = obj;
  for (const k of dotted.split('.')) {
    if (cur === null || typeof cur !== 'object' || !Object.prototype.hasOwnProperty.call(cur, k)) return undefined;
    cur = cur[k];
  }
  return cur;
}

function setDotted(obj, dotted, value) {
  const keys = dotted.split('.');
  let cur = obj;
  for (let i = 0; i < keys.length - 1; i++) {
    if (cur[keys[i]] === null || typeof cur[keys[i]] !== 'object') cur[keys[i]] = {};
    cur = cur[keys[i]];
  }
  cur[keys[keys.length - 1]] = value;
}

function applyJsonEdits(text, edits) {
  let data;
  try { data = JSON.parse(text); } catch { return { text, summary: 'json-parse-failed', changed: false } }
  const notes = [];
  let edited = false;
  for (const e of edits) {
    if (Array.isArray(data)) {
      if (e.remove.length) {
        const before = data.length;
        const drop = new Set(e.remove.map(String));
        data = data.filter((x) => !(x && typeof x === 'object' && drop.has(String(x[e.key]))));
        notes.push(`-${before - data.length}`);
        if (data.length !== before) edited = true;
      }
      let added = 0;
      for (const entry of e.ensure) {
        if (!data.some((x) => x && typeof x === 'object' && String(x[e.key]) === String(entry[e.key]))) { data.push(entry); added++; }
      }
      if (e.ensure.length) notes.push(`+${added}`);
      if (added) edited = true;
    }
    if (e.set && data && typeof data === 'object' && !Array.isArray(data)) {
      for (const [k, v] of Object.entries(e.set)) setDotted(data, k, v);
      notes.push(`set${Object.keys(e.set).length}`);
      edited = true;
    }
    if (e.setIfMissing && data && typeof data === 'object' && !Array.isArray(data)) {
      let n = 0;
      for (const [k, v] of Object.entries(e.setIfMissing)) {
        if (getDotted(data, k) === undefined) { setDotted(data, k, structuredClone(v)); n++; }
      }
      notes.push(`setIfMissing${n}`);
      if (n) edited = true;
    }
  }
  // Nothing to change: hand back the original bytes untouched.
  if (!edited) return { text, summary: notes.join(','), changed: false };
  // Keep the original layout: compact stays compact, pretty-printed keeps its indent.
  const indent = /^\s*[[{]\r?\n([ \t]+)\S/.exec(text)?.[1] ?? 0;
  const out = JSON.stringify(data, null, indent) + (/\n$/.test(text) ? '\n' : '');
  return { text: out, summary: notes.join(','), changed: out !== text };
}

// ---------------------------------------------------------------- handlers

// Last rewrite-count warnings and refusals, shown by /__mirror/status (and therefore status.sh).
const recentWarnings = [];
function noteWarning(msg) {
  recentWarnings.push(`${new Date().toISOString()} ${msg}`);
  if (recentWarnings.length > 20) recentWarnings.shift();
}

function statusEndpoint(res) {
  const r = loadRules();
  const body = JSON.stringify({
    ok: true, pid: process.pid, port: PORT, rulesPath: RULES_PATH, rulesError,
    backend: activeBackend(), backendOverride: BACKEND_OVERRIDE,
    upstreamHost: r.upstreamHost,
    jsonEdits: r.jsonEdits.filter(appliesToBackend).map((e) => e.name),
    inactiveJsonEdits: r.jsonEdits.filter((e) => !appliesToBackend(e)).map((e) => e.name),
    activeRoutes: r.routes.filter(appliesToBackend).map((x) => x.name),
    inactiveRoutes: r.routes.filter((x) => !appliesToBackend(x)).map((x) => x.name),
    recentWarnings,
    uptimeSec: Math.round(process.uptime()),
  }, null, 2);
  res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

async function handle(req, res) {
  const started = Date.now();
  if (req.url.startsWith('/__mirror/status')) return statusEndpoint(res);

  let plan;
  try { plan = planRequest(req); } catch (e) {
    res.writeHead(500, { 'Content-Type': 'text/plain' }); res.end(`mirror: ${e.message}\n`);
    log(`${req.method} ${req.url} -> - 500 rewritten=no bytes=0 error=${JSON.stringify(e.message)}`);
    return;
  }
  const upstreamLabel = `${plan.host}${plan.upstreamPath}`;
  const finish = (status, rewritten, bytes, extra = '') =>
    log(`${req.method} ${req.url} -> ${upstreamLabel} ${status} rewritten=${rewritten} bytes=${bytes} ms=${Date.now() - started}${extra}`);

  const fail = (err) => {
    if (!res.headersSent) {
      const body = `mirror: upstream error for ${upstreamLabel}: ${err.message}\n`;
      res.writeHead(502, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store', 'Content-Length': Buffer.byteLength(body) });
      res.end(body);
    } else {
      res.destroy(err);
    }
    finish(502, 'no', 0, ` error=${JSON.stringify(err.message)}`);
  };

  let ip;
  try { ip = await resolveUpstream(plan.host); } catch (e) { req.resume(); return fail(e); }

  const isHead = req.method === 'HEAD';
  const upstreamMethod = plan.managed && isHead ? 'GET' : req.method;
  const upReq = https.request({
    host: ip, port: 443, servername: plan.host, method: upstreamMethod, path: plan.upstreamPath,
    headers: buildUpstreamHeaders(req, plan), agent, timeout: UPSTREAM_TIMEOUT_MS,
  });
  let done = false;
  upReq.on('timeout', () => upReq.destroy(new Error(`timeout after ${UPSTREAM_TIMEOUT_MS} ms`)));
  upReq.on('error', (e) => { if (!done) { done = true; fail(e); } });
  res.on('close', () => {
    if (res.writableFinished) return;
    if (!done) { done = true; finish(499, 'no', 0, ' error="client closed"'); }
    upReq.destroy();
  });

  upReq.on('response', (up) => {
    if (!plan.managed) {
      // Pure passthrough: status, headers and body untouched (minus hop-by-hop headers).
      res.writeHead(up.statusCode, up.statusMessage, filterResponseHeaders(up.rawHeaders, new Set()));
      let bytes = 0;
      up.on('data', (c) => { bytes += c.length; });
      up.on('error', (e) => { if (!done) { done = true; res.destroy(e); finish(up.statusCode, 'no', bytes, ` error=${JSON.stringify(e.message)}`); } });
      up.on('end', () => { if (!done) { done = true; finish(up.statusCode, 'no', bytes); } });
      up.pipe(res);
      return;
    }

    // Managed: buffer, decode, maybe edit, re-emit with a correct Content-Length.
    const chunks = [];
    up.on('data', (c) => chunks.push(c));
    up.on('error', (e) => { if (!done) { done = true; fail(e); } });
    up.on('end', () => {
      if (done) return;
      done = true;
      try {
        const raw = Buffer.concat(chunks);
        let body = decodeBody(raw, up.headers['content-encoding']);
        const decoded = body !== raw;
        const tags = [];
        if (plan.route) tags.push(`route:${plan.route.name}`);
        const ok = up.statusCode >= 200 && up.statusCode < 300;
        let edited = false;
        // Route rewrites are skipped on noRewrite paths (served byte-identical); jsonEdits still apply.
        const routeRewrites = plan.route && !(plan.route.noRewrite && plan.route.noRewrite.test(plan.pathname)) ? plan.route.rewrite : [];
        if (plan.route?.rewrite.length && !routeRewrites.length) tags.push('no-rewrite-path');
        let hits = [];
        if (ok && isTextual(up.headers['content-type'], plan.pathname, plan.route)) {
          // Rewrite UTF-8 bodies as UTF-8. Anything else is handled as latin1 so every byte round-trips.
          const charset = isUtf8(body) ? 'utf8' : 'latin1';
          if (charset !== 'utf8') tags.push('latin1');
          let text = body.toString(charset);
          const before = text;
          if (routeRewrites.length) {
            const res2 = applyRewrites(text, routeRewrites, plan.pathname);
            text = res2.text; hits = res2.hits; tags.push(`rewrites=${res2.count}`);
          }
          if (plan.edits.length) {
            const { text: t, summary } = applyJsonEdits(text, plan.edits);
            text = t; tags.push(`json(${summary})`);
          }
          if (text !== before) { body = Buffer.from(text, charset); edited = true; }
        } else if (plan.edits.length || routeRewrites.length) {
          tags.push(ok ? 'not-textual' : `skipped-status-${up.statusCode}`);
        }
        if (ok && routeRewrites.length) {
          const { warnings, fatal } = checkRewriteCounts(routeRewrites, hits, plan);
          for (const w of warnings) noteWarning(`${plan.pathname}: ${w}`);
          if (warnings.length) tags.push(`warn=${JSON.stringify(warnings.join('; '))}`);
          if (fatal) {
            noteWarning(`${plan.pathname}: FATAL ${fatal}`);
            const msg = `mirror: refusing to serve ${plan.pathname} unpatched: ${fatal}\n`;
            res.writeHead(502, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store', 'Content-Length': Buffer.byteLength(msg), 'X-Mirror-Route': plan.route.name });
            res.end(isHead ? undefined : msg);
            finish(502, 'no', 0, ` ${tags.join(' ')} error=${JSON.stringify(fatal)}`);
            return;
          }
        }
        const changedBody = body !== raw; // edited and/or decoded: upstream ETag no longer describes these bytes
        const drop = new Set(['content-length', 'content-encoding']);
        if (changedBody || plan.route?.noStore) { drop.add('etag'); drop.add('cache-control'); drop.add('expires'); drop.add('last-modified'); }
        const headers = filterResponseHeaders(up.rawHeaders, drop);
        if (changedBody || plan.route?.noStore) headers.push('Cache-Control', 'no-store');
        headers.push('Content-Length', String(body.length));
        if (plan.route) {
          headers.push('X-Mirror-Route', plan.route.name, 'X-Mirror-Upstream', upstreamLabel);
          // Keep redirects on the browser-visible host and rewritten paths.
          for (let i = 0; i < headers.length; i += 2) {
            if (headers[i].toLowerCase() !== 'location') continue;
            let loc = String(headers[i + 1]).replace(`//${plan.host}/`, `//${DEFAULT_UPSTREAM}/`);
            if (plan.route.rewrite.length) loc = applyRewrites(loc, plan.route.rewrite, plan.pathname).text;
            headers[i + 1] = loc;
          }
        }
        res.writeHead(up.statusCode, up.statusMessage, headers);
        res.end(isHead ? undefined : body);
        const rewritten = edited ? 'yes' : (decoded ? 'decoded' : 'no');
        finish(up.statusCode, rewritten, isHead ? 0 : body.length, tags.length ? ` ${tags.join(' ')}` : '');
      } catch (e) {
        fail(e);
      }
    });
  });

  if (isHead || req.method === 'GET') { req.resume(); upReq.end(); } else req.pipe(upReq);
}

// ---------------------------------------------------------------- main

const tls = ensureCert();
loadRules();
const server = https.createServer({ ...tls, ALPNProtocols: ['http/1.1'] }, (req, res) => {
  handle(req, res).catch((e) => {
    log(`${req.method} ${req.url} -> - 500 rewritten=no bytes=0 error=${JSON.stringify(e.message)}`);
    if (!res.headersSent) { res.writeHead(500); res.end(); } else res.destroy();
  });
});
server.keepAliveTimeout = 65_000;
server.headersTimeout = 70_000;
server.on('upgrade', (req, socket) => {
  log(`${req.method} ${req.url} -> - 501 rewritten=no bytes=0 error="upgrade not supported"`);
  socket.end('HTTP/1.1 501 Not Implemented\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
});
server.on('clientError', (err, socket) => { if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'); });
server.on('error', (e) => { log(`server ERROR ${e.message}`); process.exit(1); });
server.listen(PORT, BIND, () => {
  log(`mirror listening https://${BIND}:${PORT} pid=${process.pid} backend=${activeBackend()} rules=${RULES_PATH}`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    log(`mirror stopping (${sig})`);
    server.close();
    agent.destroy();
    logStream.end(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
