'use strict';

const http = require('http');
const http2 = require('http2');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { URL } = require('url');

const HOST = process.env.HOST || '0.0.0.0';
const PORT = Number(process.env.PORT || 8066);
const INDEX_FILE = path.join(__dirname, 'cls-telegraph-auto-viewer.html');

const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

const endpoints = {
  cls: 'https://www.cls.cn/telegraph',
  clsMobile: 'https://m.cls.cn/telegraph',
  eastmoney:
    'https://np-weblist.eastmoney.com/comm/web/getFastNewsList?client=web&biz=web_724&fastColumn=102&sortEnd=&pageSize={{limit}}&req_trace={{trace}}&callback=cb',
  sina:
    'https://zhibo.sina.com.cn/api/zhibo/feed?zhibo_id=152&tag_id=0&page=1&page_size={{limit}}&dire=f&dpc=1&callback=cb',
  wscn: 'https://wallstreetcn.com/live',
  ths: 'https://www.10jqka.com.cn/',
};

const SOURCE_TASKS = [
  { source: 'cls', sourceName: '财联社', fn: fetchClsItems },
  { source: 'eastmoney', sourceName: '东方财富', fn: fetchEastmoneyItems },
  { source: 'sina', sourceName: '新浪财经', fn: fetchSinaItems },
  { source: 'wscn', sourceName: '华尔街见闻', fn: fetchWscnItems },
  { source: 'ths', sourceName: '同花顺', fn: fetchThsItems },
];

const ALLOWED_SOURCE_SET = new Set(SOURCE_TASKS.map((x) => x.source));

const AI_PROVIDER_PRESETS = {
  deepseek: {
    label: 'DeepSeek',
    apiBase: 'https://api.deepseek.com/v1',
    model: 'deepseek-chat',
  },
  openai: {
    label: 'OpenAI',
    apiBase: 'https://api.openai.com/v1',
    model: 'gpt-4.1-mini',
  },
  gemini: {
    label: 'Gemini (OpenAI Compatible)',
    apiBase: 'https://generativelanguage.googleapis.com/v1beta/openai',
    model: 'gemini-2.0-flash',
  },
  custom: {
    label: 'Custom (OpenAI Compatible)',
    apiBase: '',
    model: '',
  },
};

const cache = {
  key: '',
  ts: 0,
  payload: null,
  ttlMs: 3000,
};
const deviceRegistry = new Map();
const silentPushAudit = [];

const RUNTIME_DIR = path.join(__dirname, '.runtime');
const DEVICE_REGISTRY_FILE = path.join(RUNTIME_DIR, 'device-registry.json');
const PUSH_AUDIT_FILE = path.join(RUNTIME_DIR, 'silent-push-audit.json');
const ACCOUNT_STORE_FILE = path.join(RUNTIME_DIR, 'account-store.json');

const aiConfig = {
  provider: process.env.AI_PROVIDER || process.env.LLM_PROVIDER || 'deepseek',
  apiKey: process.env.OPENAI_API_KEY || process.env.LLM_API_KEY || '',
  apiBase:
    process.env.OPENAI_API_BASE ||
    process.env.LLM_API_BASE ||
    process.env.DEEPSEEK_API_BASE ||
    'https://api.deepseek.com/v1',
  model:
    process.env.OPENAI_MODEL ||
    process.env.LLM_MODEL ||
    process.env.DEEPSEEK_MODEL ||
    'deepseek-chat',
  cacheTtlMs: Number(process.env.AI_CACHE_TTL_MS || 6 * 60 * 60 * 1000),
  cacheMax: Number(process.env.AI_CACHE_MAX || 800),
};

const apnsConfig = {
  teamId: String(process.env.APNS_TEAM_ID || '').trim(),
  keyId: String(process.env.APNS_KEY_ID || '').trim(),
  bundleId: String(process.env.APNS_BUNDLE_ID || process.env.IOS_BUNDLE_ID || '').trim(),
  keyPath: String(process.env.APNS_P8_PATH || '').trim(),
  keyBase64: String(process.env.APNS_P8_BASE64 || '').trim(),
  useProduction: /^(1|true|yes)$/i.test(String(process.env.APNS_USE_PRODUCTION || '').trim()),
  tokenTtlSec: clampNumber(process.env.APNS_TOKEN_TTL_SEC || 50 * 60, 10 * 60, 59 * 60),
  timeoutMs: clampNumber(process.env.APNS_TIMEOUT_MS || 8000, 1500, 20000),
  maxConcurrency: clampNumber(process.env.APNS_MAX_CONCURRENCY || 8, 1, 24),
};
const apnsJwtCache = {
  token: '',
  expireAt: 0,
  keyFingerprint: '',
};

const accountStore = {
  accounts: new Map(),
  phoneIndex: new Map(),
  appleIndex: new Map(),
  sessions: new Map(),
  phoneCodes: new Map(),
};

const authConfig = {
  debugReturnCode: !/^(0|false|no)$/i.test(String(process.env.AUTH_DEBUG_CODE_RESPONSE || 'true')),
  sessionDays: clampNumber(process.env.AUTH_SESSION_DAYS || 30, 1, 180),
};

const aiCache = new Map();

function sendJson(res, code, data) {
  const body = JSON.stringify(data);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  });
  res.end(body);
}

function sendFile(res, filename, contentType) {
  fs.readFile(filename, (err, data) => {
    if (err) {
      sendJson(res, 500, { ok: false, error: 'read_file_failed' });
      return;
    }
    res.writeHead(200, {
      'Content-Type': contentType,
      'Cache-Control': 'no-store',
    });
    res.end(data);
  });
}

function parseLimit(searchParams) {
  const raw = Number(searchParams.get('limit') || 120);
  if (!Number.isFinite(raw)) return 120;
  return Math.max(20, Math.min(500, Math.floor(raw)));
}

function parseSources(searchParams) {
  const raw = String(searchParams.get('sources') || '').trim().toLowerCase();
  if (!raw) return SOURCE_TASKS.map((task) => task.source);

  const out = [];
  const seen = new Set();

  for (const token of raw.split(',')) {
    const key = String(token || '').trim().toLowerCase();
    if (!key || seen.has(key)) continue;
    if (!ALLOWED_SOURCE_SET.has(key)) continue;
    seen.add(key);
    out.push(key);
  }

  if (out.length === 0) throw new Error('invalid_sources');
  return out;
}

function parseBoolean(input, fallback = false) {
  if (typeof input === 'boolean') return input;
  const text = String(input || '').trim().toLowerCase();
  if (!text) return fallback;
  if (['1', 'true', 'yes', 'y', 'on'].includes(text)) return true;
  if (['0', 'false', 'no', 'n', 'off'].includes(text)) return false;
  return fallback;
}

function normalizeClock(raw, fallback = '22:30') {
  const text = String(raw || '').trim();
  if (!text) return fallback;
  const m = text.match(/^(\d{1,2}):(\d{1,2})$/);
  if (!m) return fallback;
  const hh = Number(m[1]);
  const mm = Number(m[2]);
  if (!Number.isFinite(hh) || !Number.isFinite(mm)) return fallback;
  if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return fallback;
  return `${String(hh).padStart(2, '0')}:${String(mm).padStart(2, '0')}`;
}

function ensureRuntimeDir() {
  try {
    fs.mkdirSync(RUNTIME_DIR, { recursive: true });
  } catch (_) {
    // ignore runtime dir failure; process will fallback to in-memory mode.
  }
}

function loadJSONFile(filename, fallback) {
  try {
    const raw = fs.readFileSync(filename, 'utf8');
    if (!raw || !raw.trim()) return fallback;
    return JSON.parse(raw);
  } catch (_) {
    return fallback;
  }
}

function writeJSONAtomic(filename, payload) {
  const temp = `${filename}.tmp`;
  const text = JSON.stringify(payload, null, 2);
  fs.writeFileSync(temp, text, 'utf8');
  fs.renameSync(temp, filename);
}

function persistDeviceRegistry() {
  try {
    ensureRuntimeDir();
    writeJSONAtomic(DEVICE_REGISTRY_FILE, {
      updatedAt: new Date().toISOString(),
      count: deviceRegistry.size,
      devices: Array.from(deviceRegistry.values()),
    });
  } catch (_) {
    // ignore disk persistence failure
  }
}

function persistPushAudit() {
  try {
    ensureRuntimeDir();
    writeJSONAtomic(PUSH_AUDIT_FILE, {
      updatedAt: new Date().toISOString(),
      count: silentPushAudit.length,
      records: silentPushAudit,
    });
  } catch (_) {
    // ignore disk persistence failure
  }
}

function bootstrapRuntimeStores() {
  ensureRuntimeDir();

  const deviceState = loadJSONFile(DEVICE_REGISTRY_FILE, null);
  const loadedDevices = Array.isArray(deviceState && deviceState.devices) ? deviceState.devices : [];
  for (const row of loadedDevices) {
    const token = normalizeDeviceToken(row && row.deviceToken);
    if (!token) continue;
    deviceRegistry.set(token, {
      deviceToken: token,
      platform: String((row && row.platform) || 'ios').trim().toLowerCase() || 'ios',
      bundleId: String((row && row.bundleId) || '').trim().slice(0, 120),
      appVersion: String((row && row.appVersion) || '').trim().slice(0, 40),
      pushEnabled: Boolean(row && row.pushEnabled),
      keywords: normalizeKeywordList(row && row.keywords),
      sources: normalizeSourceList(row && row.sources),
      accountId: String((row && row.accountId) || '').trim().slice(0, 80),
      pushPolicy: sanitizePushPolicy(
        row && row.pushPolicy ? row.pushPolicy : {
          mode: 'all',
          tradingHoursOnly: false,
          dndEnabled: false,
          dndStart: '22:30',
          dndEnd: '07:30',
          rateLimitPerHour: 8,
          sources: normalizeSourceList(row && row.sources),
        }
      ),
      pushHistory: Array.isArray(row && row.pushHistory)
        ? row.pushHistory
            .map((x) => Number(x) || 0)
            .filter((x) => x > 0)
            .slice(-300)
        : [],
      updatedAt: String((row && row.updatedAt) || new Date().toISOString()),
      createdAt: String((row && row.createdAt) || new Date().toISOString()),
    });
  }

  const auditState = loadJSONFile(PUSH_AUDIT_FILE, null);
  const records = Array.isArray(auditState && auditState.records) ? auditState.records : [];
  for (const row of records.slice(-200)) {
    if (!row || typeof row !== 'object') continue;
    silentPushAudit.push(row);
  }
}

function nowISO() {
  return new Date().toISOString();
}

function randomToken(size = 24) {
  return crypto.randomBytes(size).toString('hex');
}

function normalizePhone(raw) {
  const text = String(raw || '').trim();
  const normalized = text.replace(/[^\d+]/g, '');
  if (normalized.length < 6 || normalized.length > 24) return '';
  return normalized;
}

function maskPhone(phone) {
  const value = String(phone || '').trim();
  if (!value) return '';
  if (value.length <= 7) return value;
  return `${value.slice(0, 3)}****${value.slice(-4)}`;
}

function maskAppleUser(userID) {
  const value = String(userID || '').trim();
  if (!value) return '';
  if (value.length <= 8) return value;
  return `${value.slice(0, 4)}...${value.slice(-4)}`;
}

function sanitizeUIDList(list, limit = 3000) {
  const input = Array.isArray(list) ? list : [];
  const seen = new Set();
  const out = [];
  for (const x of input) {
    const uid = String(x || '').trim();
    if (!uid || seen.has(uid)) continue;
    seen.add(uid);
    out.push(uid.slice(0, 120));
    if (out.length >= limit) break;
  }
  return out;
}

function sanitizeKeywordSubscriptions(list) {
  const input = Array.isArray(list) ? list : [];
  const seen = new Set();
  const out = [];

  for (const row of input) {
    const keyword = String(row && row.keyword ? row.keyword : '').trim();
    const normalized = keyword.toLowerCase();
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    out.push({
      id: String((row && row.id) || randomToken(10)).slice(0, 48),
      keyword: keyword.slice(0, 80),
      isEnabled: row && Object.prototype.hasOwnProperty.call(row, 'isEnabled') ? Boolean(row.isEnabled) : true,
      createdAt: clampNumber((row && row.createdAt) || Math.floor(Date.now() / 1000), 1, 32503680000),
    });
    if (out.length >= 500) break;
  }

  return out;
}

function sanitizePushPolicy(raw) {
  const policy = raw && typeof raw === 'object' ? raw : {};
  const modeRaw = String(policy.mode || '').trim();
  const mode = ['keywordsOnly', 'highPriorityOnly', 'all'].includes(modeRaw) ? modeRaw : 'all';
  const tradingHoursOnly = Boolean(policy.tradingHoursOnly);
  const dndEnabled = Boolean(policy.dndEnabled);
  const dndStart = normalizeClock(policy.dndStart, '22:30');
  const dndEnd = normalizeClock(policy.dndEnd, '07:30');
  const rateLimitPerHour = clampNumber(policy.rateLimitPerHour || 8, 1, 30);
  const sources = normalizeSourceList(policy.sources);
  return {
    mode,
    tradingHoursOnly,
    dndEnabled,
    dndStart,
    dndEnd,
    rateLimitPerHour,
    sources,
  };
}

function sanitizeCloudState(raw) {
  const payload = raw && typeof raw === 'object' ? raw : {};
  const selectedSources = normalizeSourceList(payload.selectedSources);
  return {
    starredUIDs: sanitizeUIDList(payload.starredUIDs, 4000),
    readUIDs: sanitizeUIDList(payload.readUIDs, 6000),
    keywordSubscriptions: sanitizeKeywordSubscriptions(payload.keywordSubscriptions),
    selectedSources: selectedSources.length ? selectedSources : SOURCE_TASKS.map((x) => x.source),
    pushStrategy: sanitizePushPolicy(payload.pushStrategy),
    updatedAt: nowISO(),
  };
}

function defaultCloudState() {
  return sanitizeCloudState({});
}

function persistAccountStore() {
  try {
    ensureRuntimeDir();
    const payload = {
      updatedAt: nowISO(),
      accounts: Array.from(accountStore.accounts.values()),
      phoneIndex: Object.fromEntries(accountStore.phoneIndex),
      appleIndex: Object.fromEntries(accountStore.appleIndex),
      sessions: Array.from(accountStore.sessions.values()),
    };
    writeJSONAtomic(ACCOUNT_STORE_FILE, payload);
  } catch (_) {
    // ignore account store persistence failures
  }
}

function bootstrapAccountStore() {
  const data = loadJSONFile(ACCOUNT_STORE_FILE, null);
  if (!data || typeof data !== 'object') return;

  const accounts = Array.isArray(data.accounts) ? data.accounts : [];
  for (const row of accounts) {
    if (!row || typeof row !== 'object') continue;
    const id = String(row.id || '').trim();
    if (!id) continue;
    accountStore.accounts.set(id, {
      id,
      provider: String((row.provider) || 'phone').trim() || 'phone',
      phone: normalizePhone(row.phone),
      appleUserId: String((row.appleUserId) || '').trim(),
      createdAt: String((row.createdAt) || nowISO()),
      updatedAt: String((row.updatedAt) || nowISO()),
      cloudState: sanitizeCloudState(row.cloudState),
      devices: row.devices && typeof row.devices === 'object' ? row.devices : {},
    });
  }

  const phoneIndex = data.phoneIndex && typeof data.phoneIndex === 'object' ? data.phoneIndex : {};
  for (const [phone, accountId] of Object.entries(phoneIndex)) {
    const normalizedPhone = normalizePhone(phone);
    if (!normalizedPhone) continue;
    if (!accountStore.accounts.has(String(accountId))) continue;
    accountStore.phoneIndex.set(normalizedPhone, String(accountId));
  }

  const appleIndex = data.appleIndex && typeof data.appleIndex === 'object' ? data.appleIndex : {};
  for (const [appleUserId, accountId] of Object.entries(appleIndex)) {
    const uid = String(appleUserId || '').trim();
    if (!uid) continue;
    if (!accountStore.accounts.has(String(accountId))) continue;
    accountStore.appleIndex.set(uid, String(accountId));
  }

  const sessions = Array.isArray(data.sessions) ? data.sessions : [];
  const now = Date.now();
  for (const row of sessions) {
    if (!row || typeof row !== 'object') continue;
    const token = String(row.token || '').trim();
    const accountId = String(row.accountId || '').trim();
    if (!token || !accountId) continue;
    if (!accountStore.accounts.has(accountId)) continue;
    const expireAt = Number(row.expireAt) || 0;
    if (expireAt <= now) continue;
    accountStore.sessions.set(token, {
      token,
      accountId,
      deviceId: String((row.deviceId) || '').trim(),
      deviceName: String((row.deviceName) || '').trim().slice(0, 80),
      createdAt: Number(row.createdAt) || now,
      expireAt,
    });
  }
}

function createSession(account, deviceInfo) {
  const now = Date.now();
  const expireAt = now + authConfig.sessionDays * 24 * 60 * 60 * 1000;
  const token = randomToken(32);
  const session = {
    token,
    accountId: account.id,
    deviceId: String((deviceInfo && deviceInfo.deviceId) || '').trim().slice(0, 80),
    deviceName: String((deviceInfo && deviceInfo.deviceName) || '').trim().slice(0, 80),
    createdAt: now,
    expireAt,
  };
  accountStore.sessions.set(token, session);
  persistAccountStore();
  return session;
}

function buildAccountProfile(account) {
  return {
    accountId: account.id,
    provider: account.provider,
    phoneMasked: account.phone ? maskPhone(account.phone) : '',
    appleMasked: account.appleUserId ? maskAppleUser(account.appleUserId) : '',
    createdAt: account.createdAt,
  };
}

function buildSessionResponse(session, account) {
  return {
    token: session.token,
    expiresAt: new Date(session.expireAt).toISOString(),
    account: buildAccountProfile(account),
  };
}

function resolveSession(req) {
  const auth = String(req.headers.authorization || '').trim();
  if (!auth) return null;
  const token = auth.toLowerCase().startsWith('bearer ') ? auth.slice(7).trim() : '';
  if (!token) return null;
  const session = accountStore.sessions.get(token);
  if (!session) return null;
  if ((Number(session.expireAt) || 0) <= Date.now()) {
    accountStore.sessions.delete(token);
    persistAccountStore();
    return null;
  }
  const account = accountStore.accounts.get(session.accountId);
  if (!account) return null;
  return { token, session, account };
}

function requireSession(req, res) {
  const resolved = resolveSession(req);
  if (!resolved) {
    sendJson(res, 401, { ok: false, error: 'unauthorized' });
    return null;
  }
  return resolved;
}

function upsertPhoneAccount(phone) {
  const normalized = normalizePhone(phone);
  if (!normalized) throw new Error('invalid_phone');

  const existingId = accountStore.phoneIndex.get(normalized);
  if (existingId && accountStore.accounts.has(existingId)) {
    const account = accountStore.accounts.get(existingId);
    account.updatedAt = nowISO();
    return account;
  }

  const id = `acct_${randomToken(10)}`;
  const account = {
    id,
    provider: 'phone',
    phone: normalized,
    appleUserId: '',
    createdAt: nowISO(),
    updatedAt: nowISO(),
    cloudState: defaultCloudState(),
    devices: {},
  };
  accountStore.accounts.set(id, account);
  accountStore.phoneIndex.set(normalized, id);
  persistAccountStore();
  return account;
}

function upsertAppleAccount(appleUserId) {
  const uid = String(appleUserId || '').trim();
  if (!uid) throw new Error('invalid_apple_user');

  const existingId = accountStore.appleIndex.get(uid);
  if (existingId && accountStore.accounts.has(existingId)) {
    const account = accountStore.accounts.get(existingId);
    account.updatedAt = nowISO();
    return account;
  }

  const id = `acct_${randomToken(10)}`;
  const account = {
    id,
    provider: 'apple',
    phone: '',
    appleUserId: uid,
    createdAt: nowISO(),
    updatedAt: nowISO(),
    cloudState: defaultCloudState(),
    devices: {},
  };
  accountStore.accounts.set(id, account);
  accountStore.appleIndex.set(uid, id);
  persistAccountStore();
  return account;
}

function issuePhoneCode(phone) {
  const normalized = normalizePhone(phone);
  if (!normalized) throw new Error('invalid_phone');
  const code = String(Math.floor(100000 + Math.random() * 900000));
  const expireAt = Date.now() + 5 * 60 * 1000;
  accountStore.phoneCodes.set(normalized, { code, expireAt, issuedAt: Date.now() });
  return { code, expireAt };
}

function verifyPhoneCode(phone, code) {
  const normalized = normalizePhone(phone);
  const normalizedCode = String(code || '').trim();
  if (!normalized || !normalizedCode) throw new Error('invalid_phone_or_code');
  const row = accountStore.phoneCodes.get(normalized);
  if (!row) throw new Error('code_not_found');
  if ((Number(row.expireAt) || 0) <= Date.now()) {
    accountStore.phoneCodes.delete(normalized);
    throw new Error('code_expired');
  }
  if (String(row.code) !== normalizedCode) {
    throw new Error('code_mismatch');
  }
  accountStore.phoneCodes.delete(normalized);
  return true;
}

function updateAccountCloudState(account, cloudState) {
  if (!account || !account.id) throw new Error('account_not_found');
  account.cloudState = sanitizeCloudState(cloudState);
  account.updatedAt = nowISO();
  persistAccountStore();
  return account.cloudState;
}

function encodeCursor(ctime, uid) {
  const safeTime = Math.max(0, Math.floor(Number(ctime) || 0));
  const safeUid = String(uid || '').trim();
  if (!safeUid) return null;
  return Buffer.from(`${safeTime}|${safeUid}`, 'utf8').toString('base64');
}

function decodeCursorToken(token) {
  const raw = String(token || '').trim();
  if (!raw) return null;

  let decoded = '';
  try {
    decoded = Buffer.from(raw, 'base64').toString('utf8');
  } catch (_) {
    return null;
  }

  const sep = decoded.indexOf('|');
  if (sep <= 0 || sep >= decoded.length - 1) return null;
  const ctime = Number(decoded.slice(0, sep));
  const uid = decoded.slice(sep + 1).trim();
  if (!Number.isFinite(ctime) || ctime < 0 || !uid) return null;

  return {
    token: raw,
    ctime: Math.floor(ctime),
    uid,
  };
}

function parseCursor(searchParams) {
  const raw = String(searchParams.get('cursor') || '').trim();
  if (!raw) return null;

  const point = decodeCursorToken(raw);
  if (!point) throw new Error('invalid_cursor');
  return point;
}

function isAfterCursor(item, cursorPoint) {
  if (!item || !cursorPoint) return true;
  const leftTime = Number(item.ctime) || 0;
  const rightTime = Number(cursorPoint.ctime) || 0;
  if (leftTime !== rightTime) return leftTime > rightTime;
  return String(item.uid || '') > String(cursorPoint.uid || '');
}

function clampNumber(input, min, max) {
  const n = Number(input);
  if (!Number.isFinite(n)) return min;
  return Math.min(max, Math.max(min, n));
}

function readRequestBody(req, maxBytes = 512 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];

    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        reject(new Error('payload_too_large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

async function readJsonBody(req) {
  const raw = await readRequestBody(req);
  if (!raw || !raw.trim()) return {};
  try {
    return JSON.parse(raw);
  } catch (_) {
    throw new Error('invalid_json_body');
  }
}

function stripTags(html) {
  return String(html || '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+\n/g, '\n')
    .replace(/\n\s+/g, '\n')
    .replace(/[ \t]+/g, ' ')
    .trim();
}

function formatTime(epochSec) {
  const n = Number(epochSec);
  if (!Number.isFinite(n) || n <= 0) return '';
  const d = new Date(n * 1000);
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ss = String(d.getSeconds()).padStart(2, '0');
  return `${hh}:${mm}:${ss}`;
}

function toEpochSeconds(input) {
  if (input === null || input === undefined) return 0;
  if (typeof input === 'number') {
    if (input > 1e12) return Math.floor(input / 1000);
    if (input > 1e9) return Math.floor(input);
  }
  const text = String(input).trim();
  if (!text) return 0;

  if (/^\d{10,16}$/.test(text)) {
    if (text.length > 10) return Number(text.slice(0, 10));
    return Number(text);
  }

  const normalized = text.replace(/-/g, '/');
  const ms = Date.parse(normalized);
  if (Number.isFinite(ms)) return Math.floor(ms / 1000);

  return 0;
}

function extractNextDataJson(html) {
  const scriptTagMarker = '<script id="__NEXT_DATA__" type="application/json">';
  const tagStart = html.indexOf(scriptTagMarker);
  if (tagStart >= 0) {
    const jsonStart = tagStart + scriptTagMarker.length;
    const end = html.indexOf('</script>', jsonStart);
    if (end > jsonStart) {
      return html.slice(jsonStart, end);
    }
  }

  const assignMarker = '__NEXT_DATA__ =';
  const assignStart = html.indexOf(assignMarker);
  if (assignStart < 0) return null;

  let i = html.indexOf('{', assignStart + assignMarker.length);
  if (i < 0) return null;

  const start = i;
  let depth = 0;
  let inStr = false;
  let esc = false;

  for (; i < html.length; i += 1) {
    const ch = html[i];

    if (inStr) {
      if (esc) {
        esc = false;
      } else if (ch === '\\') {
        esc = true;
      } else if (ch === '"') {
        inStr = false;
      }
      continue;
    }

    if (ch === '"') {
      inStr = true;
      continue;
    }
    if (ch === '{') {
      depth += 1;
      continue;
    }
    if (ch === '}') {
      depth -= 1;
      if (depth === 0) {
        return html.slice(start, i + 1);
      }
    }
  }

  return null;
}

function parseJsonp(raw) {
  const text = String(raw || '').trim();
  if (!text) throw new Error('jsonp_empty');

  let body = '';
  const safeEnd = ');}catch';
  if (text.includes(safeEnd)) {
    const open = text.indexOf('(');
    const close = text.lastIndexOf(safeEnd);
    if (open < 0 || close <= open) throw new Error('jsonp_bad_wrapper_try');
    body = text.slice(open + 1, close);
  } else {
    const open = text.indexOf('(');
    const close = text.lastIndexOf(')');
    if (open < 0 || close <= open) throw new Error('jsonp_bad_wrapper');
    body = text.slice(open + 1, close);
  }

  return JSON.parse(body);
}

function extractJsonArrayByKey(html, key) {
  const marker = `"${key}":[`;
  const idx = html.indexOf(marker);
  if (idx < 0) return null;

  let i = idx + marker.length - 1;
  let depth = 0;
  let inStr = false;
  let esc = false;
  let end = -1;

  for (; i < html.length; i += 1) {
    const ch = html[i];

    if (inStr) {
      if (esc) {
        esc = false;
      } else if (ch === '\\') {
        esc = true;
      } else if (ch === '"') {
        inStr = false;
      }
      continue;
    }

    if (ch === '"') {
      inStr = true;
      continue;
    }
    if (ch === '[') {
      depth += 1;
      continue;
    }
    if (ch === ']') {
      depth -= 1;
      if (depth === 0) {
        end = i;
        break;
      }
    }
  }

  if (end < 0) return null;
  return html.slice(idx + marker.length - 1, end + 1);
}

function extractEscapedJsonArrayByKey(html, escapedKey) {
  const marker = `\\"${escapedKey}\\":[`;
  const idx = html.indexOf(marker);
  if (idx < 0) return null;

  let i = idx + marker.length - 1;
  let depth = 0;
  let end = -1;

  for (; i < html.length; i += 1) {
    const ch = html[i];
    if (ch === '[') depth += 1;
    if (ch === ']') {
      depth -= 1;
      if (depth === 0) {
        end = i;
        break;
      }
    }
  }

  if (end < 0) return null;
  return html.slice(idx + marker.length - 1, end + 1);
}

function extractAssignedJsonObject(html, varName) {
  const marker = `${varName} = `;
  const assignStart = html.indexOf(marker);
  if (assignStart < 0) return null;

  let i = html.indexOf('{', assignStart + marker.length);
  if (i < 0) return null;

  const start = i;
  let depth = 0;
  let inStr = false;
  let esc = false;

  for (; i < html.length; i += 1) {
    const ch = html[i];

    if (inStr) {
      if (esc) {
        esc = false;
      } else if (ch === '\\') {
        esc = true;
      } else if (ch === '"') {
        inStr = false;
      }
      continue;
    }

    if (ch === '"') {
      inStr = true;
      continue;
    }
    if (ch === '{') {
      depth += 1;
      continue;
    }
    if (ch === '}') {
      depth -= 1;
      if (depth === 0) {
        return html.slice(start, i + 1);
      }
    }
  }

  return null;
}

function extractClsRawList(nextData) {
  if (!nextData || typeof nextData !== 'object') return [];

  const fromInitialReduxState =
    nextData &&
    nextData.props &&
    nextData.props.initialReduxState &&
    nextData.props.initialReduxState.telegraph &&
    Array.isArray(nextData.props.initialReduxState.telegraph.telegraphList)
      ? nextData.props.initialReduxState.telegraph.telegraphList
      : null;

  const fromInitialStateTelegraph =
    nextData &&
    nextData.props &&
    nextData.props.initialState &&
    nextData.props.initialState.telegraph &&
    Array.isArray(nextData.props.initialState.telegraph.telegraphList)
      ? nextData.props.initialState.telegraph.telegraphList
      : null;

  const fromInitialStateRollData =
    nextData &&
    nextData.props &&
    nextData.props.initialState &&
    Array.isArray(nextData.props.initialState.roll_data)
      ? nextData.props.initialState.roll_data
      : null;

  const fromPagePropsRollData =
    nextData &&
    nextData.props &&
    nextData.props.pageProps &&
    Array.isArray(nextData.props.pageProps.roll_data)
      ? nextData.props.pageProps.roll_data
      : null;

  return fromInitialReduxState || fromInitialStateTelegraph || fromInitialStateRollData || fromPagePropsRollData || [];
}

function normalizeItem(source, sourceName, raw) {
  const id = raw.id;
  const ctime = toEpochSeconds(raw.ctime);
  const title = String(raw.title || '').trim();
  const text = String(raw.text || '').trim();

  if (!id || !text) return null;

  return {
    uid: `${source}:${id}`,
    source,
    sourceName,
    id,
    ctime,
    time: raw.time || formatTime(ctime),
    title,
    text,
    author: String(raw.author || '').trim(),
    level: String(raw.level || '').trim(),
    url: String(raw.url || '').trim(),
  };
}

function normalizeNewsForDedupe(text) {
  return String(text || '')
    .toLowerCase()
    .replace(/https?:\/\/\S+/g, ' ')
    .replace(/^【[^】]{2,30}】\s*/g, '')
    .replace(
      /^(财联社|新浪财经|华尔街见闻|同花顺|东方财富)(\d{1,2}月\d{1,2}日)?电[，,:：\s]*/g,
      ''
    )
    .replace(/^[\u4e00-\u9fa5a-z0-9%]{0,16}电[，,:：\s]*/g, '')
    .replace(/[^\u4e00-\u9fa5a-z0-9%]+/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function buildStrongContentKey(item) {
  const t1 = normalizeNewsForDedupe(item && item.title);
  const t2 = normalizeNewsForDedupe(item && item.text);
  if (!t1 && !t2) return '';
  const key = `${t1}|${t2}`;
  return key.length > 1200 ? key.slice(0, 1200) : key;
}

function extractNumberTokens(text) {
  const m = String(text || '').match(/-?\d+(?:\.\d+)?%?/g) || [];
  const uniq = [];
  const seen = new Set();
  for (const n of m) {
    const v = String(n).trim();
    if (!v || seen.has(v)) continue;
    seen.add(v);
    uniq.push(v);
    if (uniq.length >= 12) break;
  }
  return uniq;
}

function numberTokensCompatible(a, b) {
  const A = Array.isArray(a) ? a : [];
  const B = Array.isArray(b) ? b : [];
  if (!A.length && !B.length) return true;
  if (!A.length || !B.length) return false;

  const setA = new Set(A);
  const setB = new Set(B);
  const smaller = setA.size <= setB.size ? setA : setB;
  const larger = setA.size <= setB.size ? setB : setA;

  let hit = 0;
  for (const x of smaller) {
    if (larger.has(x)) hit += 1;
  }
  return hit / Math.max(1, smaller.size) >= 0.7;
}

function buildBigrams(text) {
  const s = String(text || '');
  if (s.length < 2) return new Set();
  const out = new Set();
  for (let i = 0; i < s.length - 1; i += 1) {
    out.add(s.slice(i, i + 2));
  }
  return out;
}

function diceSimilarity(aSet, bSet) {
  if (!aSet.size || !bSet.size) return 0;
  let inter = 0;
  const smaller = aSet.size <= bSet.size ? aSet : bSet;
  const larger = aSet.size <= bSet.size ? bSet : aSet;
  for (const t of smaller) {
    if (larger.has(t)) inter += 1;
  }
  return (2 * inter) / (aSet.size + bSet.size);
}

function dedupeByStrongContent(items) {
  const seen = new Set();
  const result = [];

  for (const item of items) {
    const key = buildStrongContentKey(item);
    if (key && seen.has(key)) continue;
    if (key) seen.add(key);
    result.push(item);
  }

  return result;
}

function normalizeTitleForDedupe(title) {
  return String(title || '')
    .toLowerCase()
    .replace(/[^\u4e00-\u9fa5a-z0-9%]+/gi, '')
    .trim();
}

function dedupeByExactTitle(items, windowSec = 1800) {
  const kept = [];
  const recentByTitle = new Map();

  for (const item of items) {
    const titleKey = normalizeTitleForDedupe(item && item.title);
    const ctime = Number(item && item.ctime) || 0;

    if (!titleKey || titleKey.length < 8) {
      kept.push(item);
      continue;
    }

    const prev = recentByTitle.get(titleKey);
    if (!prev) {
      recentByTitle.set(titleKey, { ctime, uid: item.uid });
      kept.push(item);
      continue;
    }

    // Drop duplicate headlines from different sources in a recent window.
    // Keep the newest one (items are already sorted by ctime desc before this stage).
    const delta = Math.abs(ctime - prev.ctime);
    if (delta <= windowSec || !ctime || !prev.ctime) {
      continue;
    }

    recentByTitle.set(titleKey, { ctime, uid: item.uid });
    kept.push(item);
  }

  return kept;
}

function dedupeByFuzzyContent(items, windowSec = 600, similarityThreshold = 0.88) {
  const kept = [];
  const meta = [];

  for (const item of items) {
    const normalized = normalizeNewsForDedupe(`${item.title || ''} ${item.text || ''}`);
    const ctime = Number(item.ctime) || 0;

    // Too short texts are easy to误杀; only use fuzzy dedupe for richer texts.
    if (normalized.length < 22 || !ctime) {
      kept.push(item);
      meta.push(null);
      continue;
    }

    const nums = extractNumberTokens(`${item.title || ''} ${item.text || ''}`);
    const shortNorm = normalized.length > 260 ? normalized.slice(0, 260) : normalized;
    const grams = buildBigrams(shortNorm);

    let duplicated = false;

    for (let i = 0; i < kept.length; i += 1) {
      const m = meta[i];
      if (!m) continue;

      const dt = Math.abs(ctime - m.ctime);
      if (dt > windowSec) continue;

      const lenMax = Math.max(shortNorm.length, m.shortNorm.length);
      const lenMin = Math.min(shortNorm.length, m.shortNorm.length);
      if (!lenMin || lenMax / lenMin > 1.8) continue;

      if (!numberTokensCompatible(nums, m.nums)) continue;

      const sim = diceSimilarity(grams, m.grams);
      if (sim >= similarityThreshold) {
        duplicated = true;
        break;
      }
    }

    if (!duplicated) {
      kept.push(item);
      meta.push({ ctime, nums, shortNorm, grams });
    }
  }

  return kept;
}

function parseFirstJsonObject(text) {
  const source = String(text || '').trim();
  if (!source) throw new Error('ai_empty_response');

  const fenced = source.match(/```(?:json)?\s*([\s\S]*?)\s*```/i);
  const plain = fenced ? fenced[1].trim() : source;
  if (plain.startsWith('{') && plain.endsWith('}')) {
    return JSON.parse(plain);
  }

  const start = source.indexOf('{');
  if (start < 0) throw new Error('ai_json_not_found');

  let depth = 0;
  let inStr = false;
  let esc = false;

  for (let i = start; i < source.length; i += 1) {
    const ch = source[i];
    if (inStr) {
      if (esc) esc = false;
      else if (ch === '\\') esc = true;
      else if (ch === '"') inStr = false;
      continue;
    }
    if (ch === '"') {
      inStr = true;
      continue;
    }
    if (ch === '{') depth += 1;
    if (ch === '}') {
      depth -= 1;
      if (depth === 0) return JSON.parse(source.slice(start, i + 1));
    }
  }
  throw new Error('ai_json_unclosed');
}

function normalizeStringArray(arr, limit = 3) {
  if (!Array.isArray(arr)) return [];
  const out = [];
  for (const x of arr) {
    const s = String(x || '').trim();
    if (!s) continue;
    out.push(s.slice(0, 120));
    if (out.length >= limit) break;
  }
  return out;
}

function splitTargetsByDirection(targets) {
  const bullish = [];
  const bearish = [];
  for (const raw of Array.isArray(targets) ? targets : []) {
    const text = String(raw || '').trim();
    if (!text) continue;
    if (/利好|看多|受益|上涨|走强|受益于|弹性/.test(text)) {
      bullish.push(text);
      continue;
    }
    if (/利空|看空|承压|下跌|走弱|受损|风险/.test(text)) {
      bearish.push(text);
    }
  }
  return {
    bullish: normalizeStringArray(bullish, 4),
    bearish: normalizeStringArray(bearish, 4),
  };
}

function normalizeAiResult(raw) {
  const sentimentRaw = String(raw && raw.sentiment ? raw.sentiment : '').trim().toLowerCase();
  let sentiment = 'neutral';
  if (['bullish', 'positive', '利好', '看多'].includes(sentimentRaw)) sentiment = 'bullish';
  if (['bearish', 'negative', '利空', '看空'].includes(sentimentRaw)) sentiment = 'bearish';

  const score = Math.round(clampNumber(raw && raw.score, -100, 100));
  const confidence = Math.round(clampNumber(raw && raw.confidence, 0, 1) * 100) / 100;

  const bullishTargets = normalizeStringArray(raw && raw.bullish_targets, 4);
  const bearishTargets = normalizeStringArray(raw && raw.bearish_targets, 4);
  const impactTargets = normalizeStringArray(raw && raw.impact_targets, 6);
  const fallbackSplit = splitTargetsByDirection(impactTargets);

  return {
    sentiment,
    score,
    confidence,
    horizon: String((raw && raw.horizon) || 'short_term').trim().slice(0, 24) || 'short_term',
    summary: String((raw && raw.summary) || '').trim().slice(0, 240),
    positive_factors: normalizeStringArray(raw && raw.positive_factors, 3),
    negative_factors: normalizeStringArray(raw && raw.negative_factors, 3),
    bullish_targets: bullishTargets.length ? bullishTargets : fallbackSplit.bullish,
    bearish_targets: bearishTargets.length ? bearishTargets : fallbackSplit.bearish,
    impact_targets: impactTargets,
    model: aiConfig.model,
    analyzedAt: new Date().toISOString(),
  };
}

function normalizeProviderName(input) {
  const value = String(input || '').trim().toLowerCase();
  if (!value) return 'deepseek';
  if (AI_PROVIDER_PRESETS[value]) return value;
  return 'custom';
}

function resolveAiRuntimeConfig(body) {
  const aiBody = body && typeof body.ai === 'object' && body.ai ? body.ai : {};
  const provider = normalizeProviderName(aiBody.provider || body.provider || aiConfig.provider);
  const preset = AI_PROVIDER_PRESETS[provider] || AI_PROVIDER_PRESETS.custom;

  const apiKey = String(aiBody.apiKey || body.apiKey || aiConfig.apiKey || '').trim();
  const apiBase = String(aiBody.apiBase || body.apiBase || preset.apiBase || aiConfig.apiBase || '').trim();
  const model = String(aiBody.model || body.model || preset.model || aiConfig.model || '').trim();

  return {
    provider,
    apiKey,
    apiBase,
    model,
  };
}

function listAiProviders() {
  const providers = Object.entries(AI_PROVIDER_PRESETS).map(([id, meta]) => ({
    id,
    label: meta.label,
    defaultApiBase: meta.apiBase,
    defaultModel: meta.model,
  }));

  return {
    providers,
    defaults: {
      provider: normalizeProviderName(aiConfig.provider),
      apiBase: aiConfig.apiBase,
      model: aiConfig.model,
      hasApiKey: Boolean(aiConfig.apiKey),
    },
  };
}

function normalizeDeviceToken(raw) {
  const token = String(raw || '')
    .trim()
    .replace(/[^0-9a-f]/gi, '')
    .toLowerCase();
  if (token.length < 32) return '';
  return token;
}

function normalizeKeywordList(raw) {
  const input = Array.isArray(raw) ? raw : [];
  const seen = new Set();
  const out = [];

  for (const item of input) {
    const keyword = String(item || '').trim().toLowerCase();
    if (!keyword || seen.has(keyword)) continue;
    seen.add(keyword);
    out.push(keyword.slice(0, 48));
    if (out.length >= 80) break;
  }

  return out;
}

function normalizeSourceList(raw) {
  const input = Array.isArray(raw) ? raw : [];
  const seen = new Set();
  const out = [];

  for (const item of input) {
    const source = String(item || '').trim().toLowerCase();
    if (!source || seen.has(source)) continue;
    if (!ALLOWED_SOURCE_SET.has(source)) continue;
    seen.add(source);
    out.push(source);
  }

  return out;
}

function maskToken(token) {
  const raw = String(token || '');
  if (raw.length <= 10) return raw;
  return `${raw.slice(0, 6)}...${raw.slice(-4)}`;
}

function upsertDeviceRegistration(body, accountId = '') {
  const deviceToken = normalizeDeviceToken(body && body.deviceToken);
  if (!deviceToken) throw new Error('invalid_device_token');

  const keywords = normalizeKeywordList(body && body.keywords);
  const sources = normalizeSourceList(body && body.sources);
  const now = new Date().toISOString();
  const current = deviceRegistry.get(deviceToken);
  const pushPolicyInput = body && typeof body.pushPolicy === 'object' ? body.pushPolicy : {};
  const fallbackSources = sources.length ? sources : SOURCE_TASKS.map((x) => x.source);
  const pushPolicy = sanitizePushPolicy({
    ...pushPolicyInput,
    sources: Array.isArray(pushPolicyInput.sources) ? pushPolicyInput.sources : fallbackSources,
  });

  const record = {
    deviceToken,
    platform: String((body && body.platform) || 'ios').trim().toLowerCase() || 'ios',
    bundleId: String((body && body.bundleId) || '').trim().slice(0, 120),
    appVersion: String((body && body.appVersion) || '').trim().slice(0, 40),
    pushEnabled: Boolean(body && body.pushEnabled),
    keywords,
    sources,
    accountId: String(accountId || '').trim().slice(0, 80),
    pushPolicy,
    pushHistory: Array.isArray(current && current.pushHistory) ? current.pushHistory.slice(-300) : [],
    updatedAt: now,
    createdAt: (current && current.createdAt) || now,
  };

  deviceRegistry.set(deviceToken, record);
  persistDeviceRegistry();
  return {
    created: !current,
    record,
  };
}

function removeDeviceRegistration(body) {
  const deviceToken = normalizeDeviceToken(body && body.deviceToken);
  if (!deviceToken) throw new Error('invalid_device_token');
  const removed = deviceRegistry.delete(deviceToken);
  if (removed) {
    persistDeviceRegistry();
  }
  return removed;
}

function listRegisteredDevices() {
  return Array.from(deviceRegistry.values()).map((x) => ({
    token: maskToken(x.deviceToken),
    accountId: String(x.accountId || ''),
    platform: x.platform,
    bundleId: x.bundleId,
    appVersion: x.appVersion,
    pushEnabled: x.pushEnabled,
    keywordCount: Array.isArray(x.keywords) ? x.keywords.length : 0,
    sourceCount: Array.isArray(x.sources) ? x.sources.length : 0,
    pushMode: x.pushPolicy && x.pushPolicy.mode ? x.pushPolicy.mode : 'all',
    tradingHoursOnly: Boolean(x.pushPolicy && x.pushPolicy.tradingHoursOnly),
    dndEnabled: Boolean(x.pushPolicy && x.pushPolicy.dndEnabled),
    rateLimitPerHour: Number((x.pushPolicy && x.pushPolicy.rateLimitPerHour) || 8),
    pushHistory1h: Array.isArray(x.pushHistory)
      ? x.pushHistory.filter((ts) => Number(ts) > Date.now() - 60 * 60 * 1000).length
      : 0,
    updatedAt: x.updatedAt,
    createdAt: x.createdAt,
  }));
}

function buildSilentPushTargets(items) {
  if (!Array.isArray(items) || !items.length) return [];
  const out = [];
  const now = new Date();
  const nowMs = Date.now();
  const currentMinute = now.getHours() * 60 + now.getMinutes();
  const day = now.getDay(); // 0 Sun, 6 Sat
  const isWeekday = day >= 1 && day <= 5;
  const inTradingHours =
    isWeekday &&
    ((currentMinute >= 9 * 60 + 30 && currentMinute <= 11 * 60 + 30) ||
      (currentMinute >= 13 * 60 && currentMinute <= 15 * 60));

  for (const device of deviceRegistry.values()) {
    if (!device.pushEnabled) continue;

    const policy = sanitizePushPolicy(device.pushPolicy || {});
    const interestedSources =
      Array.isArray(policy.sources) && policy.sources.length
        ? new Set(policy.sources)
        : (Array.isArray(device.sources) && device.sources.length ? new Set(device.sources) : null);
    const keywords = normalizeKeywordList(device.keywords || []);
    const history = Array.isArray(device.pushHistory)
      ? device.pushHistory.map((x) => Number(x) || 0).filter((x) => x > 0)
      : [];

    if (policy.tradingHoursOnly && !inTradingHours) {
      continue;
    }

    if (policy.dndEnabled) {
      const startParts = policy.dndStart.split(':').map((x) => Number(x));
      const endParts = policy.dndEnd.split(':').map((x) => Number(x));
      const startMinute = startParts.length === 2 ? startParts[0] * 60 + startParts[1] : 22 * 60 + 30;
      const endMinute = endParts.length === 2 ? endParts[0] * 60 + endParts[1] : 7 * 60 + 30;
      const inDnd =
        startMinute <= endMinute
          ? currentMinute >= startMinute && currentMinute < endMinute
          : currentMinute >= startMinute || currentMinute < endMinute;
      if (inDnd) {
        continue;
      }
    }

    const oneHourAgo = nowMs - 60 * 60 * 1000;
    const sentInHour = history.filter((ts) => ts >= oneHourAgo).length;
    if (sentInHour >= policy.rateLimitPerHour) {
      continue;
    }

    let matchedCount = 0;
    let matchedKeywordCount = 0;
    let hasPriorityHit = false;
    const matchedSources = new Set();
    for (const item of items) {
      if (interestedSources && !interestedSources.has(item.source)) continue;
      const haystack = `${item.title || ''} ${item.text || ''}`.toLowerCase();
      const keywordHit = keywords.some((k) => k && haystack.includes(k));
      const level = String(item && item.level ? item.level : '').trim().toUpperCase();
      const priorityHit = level === 'A' || level === 'B';

      let accepted = false;
      if (policy.mode === 'keywordsOnly') {
        accepted = keywordHit;
      } else if (policy.mode === 'highPriorityOnly') {
        accepted = priorityHit;
      } else {
        accepted = true;
      }

      if (accepted) {
        matchedCount += 1;
        if (keywordHit) matchedKeywordCount += 1;
        if (priorityHit) hasPriorityHit = true;
        if (item.source) matchedSources.add(String(item.source));
      }
    }

    if (matchedCount > 0) {
      out.push({
        deviceToken: device.deviceToken,
        reason: 'keyword_or_source_match',
        matchedCount,
        matchedKeywordCount,
        hasPriorityHit,
        matchedSources: Array.from(matchedSources),
        policy: {
          mode: policy.mode,
          tradingHoursOnly: policy.tradingHoursOnly,
          dndEnabled: policy.dndEnabled,
          rateLimitPerHour: policy.rateLimitPerHour,
        },
      });
    }
  }

  return out;
}

function appendSilentPushAudit(entry) {
  silentPushAudit.push(entry);
  if (silentPushAudit.length > 200) {
    silentPushAudit.splice(0, silentPushAudit.length - 200);
  }
  persistPushAudit();
}

function base64Url(input) {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(String(input || ''), 'utf8');
  return buf
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function resolveApnsPrivateKey() {
  if (apnsConfig.keyBase64) {
    try {
      return Buffer.from(apnsConfig.keyBase64, 'base64').toString('utf8');
    } catch (_) {
      return '';
    }
  }
  if (apnsConfig.keyPath) {
    try {
      return fs.readFileSync(apnsConfig.keyPath, 'utf8');
    } catch (_) {
      return '';
    }
  }
  return '';
}

function apnsConfigStatus() {
  const privateKey = resolveApnsPrivateKey();
  return {
    configured: Boolean(apnsConfig.teamId && apnsConfig.keyId && apnsConfig.bundleId && privateKey),
    endpoint: apnsConfig.useProduction ? 'production' : 'sandbox',
    teamIdSet: Boolean(apnsConfig.teamId),
    keyIdSet: Boolean(apnsConfig.keyId),
    bundleIdSet: Boolean(apnsConfig.bundleId),
    keyMaterialSet: Boolean(privateKey),
    keyPathSet: Boolean(apnsConfig.keyPath),
    maxConcurrency: apnsConfig.maxConcurrency,
    timeoutMs: apnsConfig.timeoutMs,
  };
}

function createApnsJWT() {
  const now = Date.now();
  const privateKey = resolveApnsPrivateKey();
  const fingerprint = `${apnsConfig.teamId}|${apnsConfig.keyId}|${privateKey.slice(0, 32)}`;
  if (apnsJwtCache.token && apnsJwtCache.expireAt > now + 30 * 1000 && apnsJwtCache.keyFingerprint === fingerprint) {
    return apnsJwtCache.token;
  }

  if (!apnsConfig.teamId || !apnsConfig.keyId || !privateKey) {
    throw new Error('apns_config_missing');
  }

  const iat = Math.floor(now / 1000);
  const header = base64Url(JSON.stringify({ alg: 'ES256', kid: apnsConfig.keyId, typ: 'JWT' }));
  const payload = base64Url(JSON.stringify({ iss: apnsConfig.teamId, iat }));
  const unsigned = `${header}.${payload}`;
  const signature = crypto.sign('sha256', Buffer.from(unsigned), {
    key: privateKey,
    dsaEncoding: 'ieee-p1363',
  });
  const token = `${unsigned}.${base64Url(signature)}`;

  apnsJwtCache.token = token;
  apnsJwtCache.expireAt = now + apnsConfig.tokenTtlSec * 1000;
  apnsJwtCache.keyFingerprint = fingerprint;
  return token;
}

function mapWithConcurrency(items, limit, worker) {
  return new Promise((resolve) => {
    const list = Array.isArray(items) ? items : [];
    const size = Math.max(1, Number(limit) || 1);
    const out = new Array(list.length);
    let next = 0;
    let active = 0;

    const launch = () => {
      while (active < size && next < list.length) {
        const idx = next++;
        active += 1;
        Promise.resolve(worker(list[idx], idx))
          .then((value) => {
            out[idx] = value;
          })
          .catch((error) => {
            out[idx] = { ok: false, error: error && error.message ? error.message : 'worker_failed' };
          })
          .finally(() => {
            active -= 1;
            if (next >= list.length && active === 0) {
              resolve(out);
              return;
            }
            launch();
          });
      }
    };

    if (!list.length) {
      resolve([]);
      return;
    }
    launch();
  });
}

function sendApnsRequest(session, options) {
  return new Promise((resolve) => {
    const {
      deviceToken,
      jwt,
      payload,
      topic,
      collapseId,
      timeoutMs,
    } = options || {};

    const headers = {
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      authorization: `bearer ${jwt}`,
      'apns-topic': topic,
      'apns-push-type': 'background',
      'apns-priority': '5',
      'apns-expiration': '0',
    };
    if (collapseId) {
      headers['apns-collapse-id'] = collapseId;
    }

    const req = session.request(headers);
    let responseStatus = 0;
    let responseHeaders = null;
    let responseBody = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { req.close(); } catch (_) {}
      resolve({
        ok: false,
        status: 0,
        reason: 'timeout',
        apnsId: '',
      });
    }, Math.max(1500, timeoutMs || 8000));

    req.setEncoding('utf8');
    req.on('response', (headersResp) => {
      responseHeaders = headersResp;
      responseStatus = Number(headersResp[':status']) || 0;
    });
    req.on('data', (chunk) => {
      responseBody += String(chunk || '');
      if (responseBody.length > 2000) {
        responseBody = responseBody.slice(0, 2000);
      }
    });
    req.on('error', (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({
        ok: false,
        status: responseStatus || 0,
        reason: err && err.message ? err.message : 'request_error',
        apnsId: '',
      });
    });
    req.on('end', () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      let body = {};
      try {
        body = responseBody ? JSON.parse(responseBody) : {};
      } catch (_) {
        body = {};
      }
      const apnsId = String((responseHeaders && responseHeaders['apns-id']) || '').trim();
      const reason = String((body && body.reason) || '').trim();
      resolve({
        ok: responseStatus >= 200 && responseStatus < 300,
        status: responseStatus,
        reason: reason || (responseStatus >= 200 && responseStatus < 300 ? '' : 'apns_failed'),
        apnsId,
      });
    });

    try {
      req.end(JSON.stringify(payload || {}));
    } catch (err) {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        resolve({
          ok: false,
          status: responseStatus || 0,
          reason: err && err.message ? err.message : 'write_failed',
          apnsId: '',
        });
      }
    }
  });
}

async function dispatchSilentPush(targets, options = {}) {
  const list = Array.isArray(targets) ? targets : [];
  if (!list.length) {
    return { sent: 0, success: 0, failed: 0, results: [] };
  }

  const status = apnsConfigStatus();
  if (!status.configured) {
    throw new Error('apns_config_missing');
  }

  const jwt = createApnsJWT();
  const host = apnsConfig.useProduction ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com';
  const session = http2.connect(host);
  const collapseBase = String((options && options.reason) || 'telegraph').trim().slice(0, 40) || 'telegraph';
  const topic = apnsConfig.bundleId;
  const payload = {
    aps: {
      'content-available': 1,
    },
    reason: String((options && options.reason) || 'manual').slice(0, 80),
    fetchedAt: new Date().toISOString(),
  };

  const results = [];
  let sessionError = null;
  session.on('error', (err) => {
    sessionError = err;
  });

  try {
    const parallel = await mapWithConcurrency(list, apnsConfig.maxConcurrency, async (target, index) => {
      const response = await sendApnsRequest(session, {
        deviceToken: target.deviceToken,
        jwt,
        payload,
        topic,
        collapseId: `${collapseBase}-${index % 9}`,
        timeoutMs: apnsConfig.timeoutMs,
      });

      if (response.ok) {
        const current = deviceRegistry.get(target.deviceToken);
        if (current) {
          const history = Array.isArray(current.pushHistory) ? current.pushHistory.slice(-300) : [];
          history.push(Date.now());
          current.pushHistory = history.slice(-300);
        }
      }

      if (!response.ok && ['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic'].includes(response.reason)) {
        const removed = deviceRegistry.delete(target.deviceToken);
        if (removed) {
          persistDeviceRegistry();
        }
      }

      return {
        token: target.deviceToken,
        matchedCount: target.matchedCount || 0,
        ok: response.ok,
        status: response.status,
        reason: response.reason || '',
        apnsId: response.apnsId || '',
      };
    });
    results.push(...parallel);
    persistDeviceRegistry();
  } finally {
    try {
      session.close();
    } catch (_) {
      // ignore close failure
    }
  }

  if (sessionError && results.every((x) => !x.ok)) {
    throw new Error(`apns_session_error:${sessionError.message || 'unknown'}`);
  }

  const success = results.filter((x) => x.ok).length;
  const failed = results.length - success;
  return {
    sent: results.length,
    success,
    failed,
    results,
  };
}

function buildAiCacheKey(input, runtimeConfig) {
  const uid = String((input && input.uid) || '').trim();
  const providerPart = String((runtimeConfig && runtimeConfig.provider) || 'deepseek').trim();
  const modelPart = String((runtimeConfig && runtimeConfig.model) || '').trim();
  const basePart = String((runtimeConfig && runtimeConfig.apiBase) || '')
    .trim()
    .replace(/\/+$/, '');

  if (uid) {
    return `uid:${uid}|provider:${providerPart}|model:${modelPart}|base:${basePart}`;
  }

  const t = String((input && input.title) || '').trim().slice(0, 120);
  const x = String((input && input.text) || '').trim().slice(0, 300);
  return `content:${t}|${x}|provider:${providerPart}|model:${modelPart}|base:${basePart}`;
}

function getAiCached(key) {
  const hit = aiCache.get(key);
  if (!hit) return null;
  if (Date.now() - hit.ts > aiConfig.cacheTtlMs) {
    aiCache.delete(key);
    return null;
  }
  return hit.value;
}

function setAiCached(key, value) {
  aiCache.set(key, { ts: Date.now(), value });
  if (aiCache.size <= aiConfig.cacheMax) return;
  const overflow = aiCache.size - aiConfig.cacheMax;
  const keys = aiCache.keys();
  for (let i = 0; i < overflow; i += 1) {
    const k = keys.next();
    if (k.done) break;
    aiCache.delete(k.value);
  }
}

async function analyzeTelegraphWithModel(input, runtimeConfig) {
  if (!runtimeConfig || !runtimeConfig.apiKey) {
    throw new Error('ai_not_configured_set_api_key');
  }
  if (!runtimeConfig.apiBase) {
    throw new Error('ai_not_configured_set_api_base');
  }
  if (!runtimeConfig.model) {
    throw new Error('ai_not_configured_set_model');
  }

  const title = String((input && input.title) || '').trim();
  const text = String((input && input.text) || '').trim();
  if (!title && !text) throw new Error('ai_empty_input');

  const payload = {
    model: runtimeConfig.model,
    temperature: 0.15,
    messages: [
      {
        role: 'system',
        content:
          '你是资深A股/港股/宏观快讯分析师。任务是“分析这条新闻对市场可能产生的影响”，并给出简要说明。' +
          '请先识别新闻类型（宏观/行业/公司/地缘/商品/政策），再判断影响方向与影响路径（例如：供需变化、风险偏好、估值、盈利预期、资金面）。' +
          '评分与结论时，优先考虑未来1~2个交易日的情绪冲击与资金流影响：短期交易性影响权重约70%，中期基本面影响权重约30%。' +
          '若短期与中期信号冲突，优先按短期给出sentiment和score，并在summary里点明冲突来源。' +
          '必须只输出JSON，不要输出任何额外文本。' +
          'JSON字段: sentiment(bullish|bearish|neutral), score(-100~100), confidence(0~1), horizon(short_term|mid_term), summary, positive_factors(array), negative_factors(array), bullish_targets(array), bearish_targets(array), impact_targets(array)。' +
          'summary要求: 1~2句、简洁、可读，说明“为什么偏利好/偏利空/中性”；长度尽量控制在80字以内。' +
          'positive_factors/negative_factors各最多3条，每条一句短语。' +
          'bullish_targets/bearish_targets要求给出具体方向：优先写板块或个股名称，能定位个股时可附股票代码（如“中海油服(601808)”）；每个数组0~4条。' +
          'impact_targets可作为总览补充（0~6条），不要与bullish_targets/bearish_targets完全重复。' +
          '当信息不足或新闻真假不明时，用neutral并降低confidence，score靠近0。',
      },
      {
        role: 'user',
        content: JSON.stringify(
          {
            task: '请分析这条快讯的潜在市场影响，并给出简要说明。',
            source: input.source || '',
            time: input.time || '',
            title,
            text,
          },
          null,
          2
        ),
      },
    ],
  };

  const apiBase = String(runtimeConfig.apiBase || '').replace(/\/+$/, '');
  const resp = await fetch(`${apiBase}/chat/completions`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${runtimeConfig.apiKey}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify(payload),
  });

  const rawText = await resp.text();
  if (!resp.ok) {
    throw new Error(`ai_http_${resp.status}:${rawText.slice(0, 200)}`);
  }

  let data;
  try {
    data = JSON.parse(rawText);
  } catch (_) {
    throw new Error('ai_non_json_response');
  }

  const content =
    data &&
    data.choices &&
    data.choices[0] &&
    data.choices[0].message &&
    data.choices[0].message.content
      ? data.choices[0].message.content
      : '';

  const parsed = parseFirstJsonObject(content);
  const normalized = normalizeAiResult(parsed);
  normalized.model = runtimeConfig.model;
  normalized.provider = runtimeConfig.provider || 'custom';
  return normalized;
}

async function fetchText(url, extraHeaders = {}) {
  const resp = await fetch(url, {
    method: 'GET',
    headers: {
      'User-Agent': UA,
      Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      Referer: 'https://www.baidu.com/',
      Connection: 'keep-alive',
      ...extraHeaders,
    },
    redirect: 'follow',
  });

  const text = await resp.text();
  if (!resp.ok) throw new Error(`http_${resp.status}`);
  if (text.includes('访问被拦截') || text.includes('The access is blocked')) {
    throw new Error('waf_blocked');
  }

  return text;
}

async function fetchClsItems(limit) {
  const attempts = [
    {
      name: 'desktop',
      url: endpoints.cls,
      headers: { Referer: 'https://www.cls.cn/' },
    },
    {
      name: 'desktop_slash',
      url: `${endpoints.cls}/`,
      headers: { Referer: 'https://www.cls.cn/' },
    },
    {
      name: 'mobile_fallback',
      url: endpoints.clsMobile,
      headers: { Referer: 'https://m.cls.cn/' },
    },
  ];

  let lastError = null;

  for (const attempt of attempts) {
    try {
      const html = await fetchText(attempt.url, attempt.headers);
      const jsonText = extractNextDataJson(html);
      if (!jsonText) throw new Error('next_data_not_found');

      let data;
      try {
        data = JSON.parse(jsonText);
      } catch (err) {
        throw new Error(`next_data_parse_failed:${err.message}`);
      }

      const rawList = extractClsRawList(data);
      if (!Array.isArray(rawList) || rawList.length === 0) {
        throw new Error('cls_raw_list_empty');
      }

      const items = [];
      const seen = new Set();

      for (const row of rawList) {
        const id = Number(row && row.id);
        if (!Number.isFinite(id) || id <= 0 || seen.has(id)) continue;
        seen.add(id);

        const content = stripTags(row.content || row.brief || row.title || '');
        if (!content) continue;

        const item = normalizeItem('cls', '财联社', {
          id,
          ctime: Number(row.ctime) || Number(row.modified_time) || Number(row.sort_score) || 0,
          title: String(row.title || '').trim(),
          text: content,
          author: String(row.author || '').trim(),
          level: String(row.level || '').trim() || 'B',
          url: String(row.shareurl || '').trim(),
        });

        if (item) items.push(item);
      }

      if (items.length > 0) {
        items.sort((a, b) => b.ctime - a.ctime || String(b.id).localeCompare(String(a.id)));
        return items.slice(0, limit);
      }

      throw new Error('cls_items_empty');
    } catch (err) {
      const reason = err && err.message ? err.message : 'unknown_error';
      lastError = new Error(`${attempt.name}:${reason}`);
    }
  }

  throw lastError || new Error('cls_fetch_failed');
}

async function fetchEastmoneyItems(limit) {
  const trace = `${Date.now()}_${Math.random().toString(16).slice(2, 10)}`;
  const url = endpoints.eastmoney
    .replace('{{limit}}', String(Math.min(100, Math.max(20, limit))))
    .replace('{{trace}}', trace);

  const jsonp = await fetchText(url, {
    Referer: 'https://kuaixun.eastmoney.com/',
    Accept: '*/*',
  });

  const data = parseJsonp(jsonp);
  const list = data && data.data && Array.isArray(data.data.fastNewsList) ? data.data.fastNewsList : [];

  const items = [];
  for (const row of list) {
    const id = String(row.code || row.realSort || '').trim();
    const summary = stripTags(row.summary || row.title || '');
    const ctime = toEpochSeconds(row.realSort) || toEpochSeconds(row.showTime);

    const item = normalizeItem('eastmoney', '东方财富', {
      id,
      ctime,
      time: String(row.showTime || '').slice(-8),
      title: String(row.title || '').trim(),
      text: summary,
      author: '东方财富',
      level: Number(row.titleColor) === 1 ? 'B' : 'C',
      url: row.code ? `https://finance.eastmoney.com/a/${row.code}.html` : 'https://kuaixun.eastmoney.com/',
    });

    if (item) items.push(item);
  }

  items.sort((a, b) => b.ctime - a.ctime || String(b.id).localeCompare(String(a.id)));
  return items.slice(0, limit);
}

async function fetchSinaItems(limit) {
  const url = endpoints.sina.replace('{{limit}}', String(Math.min(80, Math.max(20, limit))));
  const jsonp = await fetchText(url, {
    Referer: 'https://finance.sina.com.cn/7x24/',
    Accept: '*/*',
  });

  const data = parseJsonp(jsonp);
  const list =
    data && data.result && data.result.data && data.result.data.feed && Array.isArray(data.result.data.feed.list)
      ? data.result.data.feed.list
      : [];

  const items = [];

  for (const row of list) {
    const content = stripTags(row.rich_text || row.content || '');
    if (!content) continue;

    const bracket = content.match(/^【([^】]{2,40})】/);
    const title = bracket ? bracket[1] : '';

    const item = normalizeItem('sina', '新浪财经', {
      id: Number(row.id) || String(row.id || ''),
      ctime: toEpochSeconds(row.create_time),
      time: String(row.create_time || '').slice(-8),
      title,
      text: content,
      author: row.creator || row.anchor_nick || '新浪财经',
      level: Number(row.top_value || 0) > 0 ? 'B' : 'C',
      url: row.id ? `https://finance.sina.com.cn/7x24/${row.id}.shtml` : 'https://finance.sina.com.cn/7x24/',
    });

    if (item) items.push(item);
  }

  items.sort((a, b) => b.ctime - a.ctime || String(b.id).localeCompare(String(a.id)));
  return items.slice(0, limit);
}

async function fetchWscnItems(limit) {
  const html = await fetchText(endpoints.wscn, {
    Referer: 'https://wallstreetcn.com/live',
    // Full desktop Chrome UA often returns only SPA shell (no lives payload) in Node fetch.
    // A generic UA returns SSR payload with `lives` data more reliably.
    'User-Agent': 'Mozilla/5.0',
  });

  let rows = null;

  const arrayText = extractJsonArrayByKey(html, 'lives');
  if (arrayText) {
    try {
      rows = JSON.parse(arrayText);
    } catch (err) {
      throw new Error(`lives_parse_failed:${err.message}`);
    }
  }

  if (!rows || !Array.isArray(rows) || rows.length === 0) {
    const ssrJsonText = extractAssignedJsonObject(html, '__SSR__');
    if (ssrJsonText) {
      try {
        const ssr = JSON.parse(ssrJsonText);
        const ssrLives =
          ssr &&
          ssr.state &&
          ssr.state.default &&
          ssr.state.default.children &&
          ssr.state.default.children.default &&
          ssr.state.default.children.default.data &&
          Array.isArray(ssr.state.default.children.default.data.lives)
            ? ssr.state.default.children.default.data.lives
            : null;

        if (Array.isArray(ssrLives) && ssrLives.length > 0) {
          rows = ssrLives;
        }
      } catch (err) {
        throw new Error(`wscn_ssr_parse_failed:${err.message}`);
      }
    }
  }

  if (!Array.isArray(rows) || rows.length === 0) {
    throw new Error('wscn_lives_not_found');
  }

  const items = [];

  for (const row of rows) {
    const content = stripTags(row.content_text || row.content || row.title || '');
    if (!content) continue;

    let level = 'C';
    const score = Number(row.score || 0);
    if (score >= 3) level = 'A';
    else if (score >= 2) level = 'B';

    const item = normalizeItem('wscn', '华尔街见闻', {
      id: Number(row.id) || String(row.id || ''),
      ctime: toEpochSeconds(row.display_time),
      title: String(row.title || '').trim(),
      text: content,
      author: row.author && row.author.display_name ? row.author.display_name : '华尔街见闻',
      level,
      url: String(row.uri || '').trim(),
    });

    if (item) items.push(item);
  }

  items.sort((a, b) => b.ctime - a.ctime || String(b.id).localeCompare(String(a.id)));
  return items.slice(0, limit);
}

async function fetchThsItems(limit) {
  const html = await fetchText(endpoints.ths, {
    Referer: 'https://www.10jqka.com.cn/',
  });

  const arrayText = extractEscapedJsonArrayByKey(html, 'initialNewsList');
  if (!arrayText) throw new Error('initial_news_list_not_found');

  const decoded = arrayText
    .replace(/\\"/g, '"')
    .replace(/\\\//g, '/')
    .replace(/\\n/g, '\n')
    .replace(/\\r/g, '\r')
    .replace(/\\t/g, '\t')
    .replace(/\\u0026/g, '&');

  let rows;
  try {
    rows = JSON.parse(decoded);
  } catch (err) {
    throw new Error(`initial_news_list_parse_failed:${err.message}`);
  }

  const items = [];

  for (const row of rows) {
    const content = stripTags(row.summary || row.title || '');
    if (!content) continue;

    const item = normalizeItem('ths', '同花顺', {
      id: Number(row.id) || String(row.seq || row.id || ''),
      ctime: toEpochSeconds(row.createTime),
      title: String(row.title || '').trim(),
      text: content,
      author: '同花顺',
      level: Number(row.type) === 1 ? 'B' : 'C',
      url: String(row.url || '').trim() || String(row.shareUrl || '').trim(),
    });

    if (item) items.push(item);
  }

  items.sort((a, b) => b.ctime - a.ctime || String(b.id).localeCompare(String(a.id)));
  return items.slice(0, limit);
}

function summarizeSources(sourceResults) {
  return sourceResults.map((s) => {
    if (s.ok) {
      return {
        source: s.source,
        sourceName: s.sourceName,
        ok: true,
        count: s.count,
      };
    }

    return {
      source: s.source,
      sourceName: s.sourceName,
      ok: false,
      count: 0,
      error: s.error,
    };
  });
}

function buildTelegraphResponse(basePayload, limit, cursorPoint, cached) {
  const allItems = Array.isArray(basePayload && basePayload.allItems) ? basePayload.allItems : [];
  const filtered = cursorPoint ? allItems.filter((item) => isAfterCursor(item, cursorPoint)) : allItems;
  const visible = filtered.slice(0, limit);
  const nextCursor =
    (visible.length && encodeCursor(visible[0].ctime, visible[0].uid)) ||
    (cursorPoint && cursorPoint.token) ||
    (allItems.length && encodeCursor(allItems[0].ctime, allItems[0].uid)) ||
    null;

  return {
    ok: true,
    source: 'multi',
    sourceName: '多源聚合',
    fetchedAt: basePayload.fetchedAt,
    count: visible.length,
    totalCount: allItems.length,
    items: visible,
    selectedSources: basePayload.selectedSources,
    sources: basePayload.sources,
    dedupe: basePayload.dedupe,
    cursor: cursorPoint ? cursorPoint.token : null,
    nextCursor,
    incremental: Boolean(cursorPoint),
    cached,
  };
}

async function fetchAggregated(limit, selectedSources, cursorPoint = null) {
  const normalizedSources = Array.isArray(selectedSources) && selectedSources.length
    ? SOURCE_TASKS.map((task) => task.source).filter((s) => selectedSources.includes(s))
    : SOURCE_TASKS.map((task) => task.source);
  if (!normalizedSources.length) throw new Error('invalid_sources');

  const cacheKey = `${normalizedSources.join(',')}|${limit}`;
  const now = Date.now();
  if (cache.payload && cache.key === cacheKey && now - cache.ts <= cache.ttlMs) {
    return buildTelegraphResponse(cache.payload, limit, cursorPoint, true);
  }

  const perSourceLimit = Math.max(20, Math.min(180, Math.ceil(limit * 1.4)));

  const sourceSet = new Set(normalizedSources);
  const sourceTasks = SOURCE_TASKS.filter((task) => sourceSet.has(task.source));

  const settled = await Promise.allSettled(sourceTasks.map((task) => task.fn(perSourceLimit)));

  const merged = [];
  const sourceResults = [];

  for (let i = 0; i < sourceTasks.length; i += 1) {
    const task = sourceTasks[i];
    const result = settled[i];

    if (result.status === 'fulfilled') {
      const list = Array.isArray(result.value) ? result.value : [];
      merged.push(...list);
      sourceResults.push({
        source: task.source,
        sourceName: task.sourceName,
        ok: true,
        count: list.length,
      });
    } else {
      sourceResults.push({
        source: task.source,
        sourceName: task.sourceName,
        ok: false,
        error: result.reason && result.reason.message ? result.reason.message : 'unknown_error',
      });
    }
  }

  const availableCount = sourceResults.filter((s) => s.ok).length;
  if (availableCount === 0) {
    const reason = sourceResults.map((s) => `${s.source}:${s.error || 'failed'}`).join(',');
    throw new Error(`all_sources_failed:${reason}`);
  }

  const seen = new Set();
  const uniqueByUid = [];

  for (const item of merged) {
    if (!item || !item.uid) continue;
    if (seen.has(item.uid)) continue;
    seen.add(item.uid);
    uniqueByUid.push(item);
  }

  uniqueByUid.sort((a, b) => b.ctime - a.ctime || String(b.uid).localeCompare(String(a.uid)));

  const uniqueByStrong = dedupeByStrongContent(uniqueByUid);
  const uniqueByTitle = dedupeByExactTitle(uniqueByStrong, 30 * 60);
  const uniqueByFuzzy = dedupeByFuzzyContent(uniqueByTitle, 10 * 60, 0.88);

  const payload = {
    fetchedAt: new Date().toISOString(),
    allItems: uniqueByFuzzy,
    selectedSources: normalizedSources,
    sources: summarizeSources(sourceResults),
    dedupe: {
      before: merged.length,
      afterUid: uniqueByUid.length,
      afterStrong: uniqueByStrong.length,
      afterTitle: uniqueByTitle.length,
      afterFuzzy: uniqueByFuzzy.length,
    },
  };

  cache.key = cacheKey;
  cache.ts = now;
  cache.payload = payload;

  return buildTelegraphResponse(payload, limit, cursorPoint, false);
}

bootstrapRuntimeStores();
bootstrapAccountStore();

const server = http.createServer(async (req, res) => {
  try {
    const base = `http://${req.headers.host || `127.0.0.1:${PORT}`}`;
    const requestUrl = new URL(req.url || '/', base);
    const method = String(req.method || 'GET').toUpperCase();

    if (method === 'OPTIONS') {
      sendJson(res, 200, { ok: true });
      return;
    }

    if (requestUrl.pathname === '/' || requestUrl.pathname === '/index.html') {
      sendFile(res, INDEX_FILE, 'text/html; charset=utf-8');
      return;
    }

    if (requestUrl.pathname === '/health') {
      const pushStatus = apnsConfigStatus();
      sendJson(res, 200, {
        ok: true,
        service: 'telegraph-multi-source-proxy',
        time: new Date().toISOString(),
        deviceCount: deviceRegistry.size,
        pushConfigured: pushStatus.configured,
        pushEndpoint: pushStatus.endpoint,
        accountCount: accountStore.accounts.size,
        activeSessions: accountStore.sessions.size,
      });
      return;
    }

    if (requestUrl.pathname === '/api/auth/phone/request' && method === 'POST') {
      const body = await readJsonBody(req);
      const phone = normalizePhone(body && body.phone);
      if (!phone) {
        sendJson(res, 400, { ok: false, error: 'invalid_phone' });
        return;
      }
      const issued = issuePhoneCode(phone);
      sendJson(res, 200, {
        ok: true,
        expiresInSec: Math.max(1, Math.floor((issued.expireAt - Date.now()) / 1000)),
        debugCode: authConfig.debugReturnCode ? issued.code : undefined,
      });
      return;
    }

    if (requestUrl.pathname === '/api/auth/phone/verify' && method === 'POST') {
      const body = await readJsonBody(req);
      try {
        verifyPhoneCode(body && body.phone, body && body.code);
      } catch (err) {
        sendJson(res, 400, {
          ok: false,
          error: err && err.message ? err.message : 'verify_failed',
        });
        return;
      }

      const account = upsertPhoneAccount(body && body.phone);
      const session = createSession(account, {
        deviceId: body && body.deviceId,
        deviceName: body && body.deviceName,
      });
      sendJson(res, 200, {
        ok: true,
        session: buildSessionResponse(session, account),
      });
      return;
    }

    if (requestUrl.pathname === '/api/auth/apple' && method === 'POST') {
      const body = await readJsonBody(req);
      const appleUserId = String((body && body.appleUserId) || '').trim();
      if (!appleUserId) {
        sendJson(res, 400, { ok: false, error: 'invalid_apple_user' });
        return;
      }

      const account = upsertAppleAccount(appleUserId);
      const session = createSession(account, {
        deviceId: body && body.deviceId,
        deviceName: body && body.deviceName,
      });
      sendJson(res, 200, {
        ok: true,
        session: buildSessionResponse(session, account),
      });
      return;
    }

    if (requestUrl.pathname === '/api/auth/logout' && method === 'POST') {
      const auth = String(req.headers.authorization || '').trim();
      const token = auth.toLowerCase().startsWith('bearer ') ? auth.slice(7).trim() : '';
      if (token) {
        accountStore.sessions.delete(token);
        persistAccountStore();
      }
      sendJson(res, 200, { ok: true });
      return;
    }

    if (requestUrl.pathname === '/api/account/me' && method === 'GET') {
      const resolved = requireSession(req, res);
      if (!resolved) return;
      sendJson(res, 200, {
        ok: true,
        account: buildAccountProfile(resolved.account),
        expiresAt: new Date(resolved.session.expireAt).toISOString(),
      });
      return;
    }

    if (requestUrl.pathname === '/api/account/sync/pull' && method === 'GET') {
      const resolved = requireSession(req, res);
      if (!resolved) return;
      const cloudState = sanitizeCloudState(resolved.account.cloudState || {});
      sendJson(res, 200, {
        ok: true,
        cloudState,
        serverUpdatedAt: resolved.account.updatedAt || nowISO(),
      });
      return;
    }

    if (requestUrl.pathname === '/api/account/sync/push' && method === 'POST') {
      const resolved = requireSession(req, res);
      if (!resolved) return;
      const body = await readJsonBody(req);
      const payload = body && typeof body.cloudState === 'object' ? body.cloudState : {};
      const cloudState = updateAccountCloudState(resolved.account, payload);
      sendJson(res, 200, {
        ok: true,
        cloudState,
        serverUpdatedAt: resolved.account.updatedAt || nowISO(),
      });
      return;
    }

    if (requestUrl.pathname === '/api/telegraph' && method === 'GET') {
      const limit = parseLimit(requestUrl.searchParams);
      let selectedSources;
      try {
        selectedSources = parseSources(requestUrl.searchParams);
      } catch (_) {
        sendJson(res, 400, { ok: false, error: 'invalid_sources' });
        return;
      }
      let cursorPoint = null;
      try {
        cursorPoint = parseCursor(requestUrl.searchParams);
      } catch (_) {
        sendJson(res, 400, { ok: false, error: 'invalid_cursor' });
        return;
      }

      const data = await fetchAggregated(limit, selectedSources, cursorPoint);
      sendJson(res, 200, data);
      return;
    }

    if (requestUrl.pathname === '/api/device/register' && method === 'POST') {
      const body = await readJsonBody(req);
      let result;
      try {
        const resolved = resolveSession(req);
        const accountId = resolved && resolved.account ? resolved.account.id : '';
        result = upsertDeviceRegistration(body, accountId);
      } catch (err) {
        sendJson(res, 400, {
          ok: false,
          error: err && err.message ? err.message : 'bad_request',
        });
        return;
      }

      sendJson(res, 200, {
        ok: true,
        created: result.created,
        deviceCount: deviceRegistry.size,
        updatedAt: result.record.updatedAt,
      });
      return;
    }

    if (requestUrl.pathname === '/api/device/unregister' && method === 'POST') {
      const body = await readJsonBody(req);
      let removed = false;
      try {
        removed = removeDeviceRegistration(body);
      } catch (err) {
        sendJson(res, 400, {
          ok: false,
          error: err && err.message ? err.message : 'bad_request',
        });
        return;
      }

      sendJson(res, 200, {
        ok: true,
        removed,
        deviceCount: deviceRegistry.size,
      });
      return;
    }

    if (requestUrl.pathname === '/api/device/list' && method === 'GET') {
      sendJson(res, 200, {
        ok: true,
        count: deviceRegistry.size,
        devices: listRegisteredDevices(),
      });
      return;
    }

    if (requestUrl.pathname === '/api/push/config' && method === 'GET') {
      const status = apnsConfigStatus();
      sendJson(res, 200, {
        ok: true,
        ...status,
      });
      return;
    }

    if (requestUrl.pathname === '/api/push/audit' && method === 'GET') {
      const limit = clampNumber(requestUrl.searchParams.get('limit') || 40, 1, 200);
      sendJson(res, 200, {
        ok: true,
        count: silentPushAudit.length,
        records: silentPushAudit.slice(-limit),
      });
      return;
    }

    if (requestUrl.pathname === '/api/push/silent/send' && method === 'POST') {
      const body = await readJsonBody(req);
      const reason = String((body && body.reason) || 'manual').trim().slice(0, 80) || 'manual';
      const sourceItems =
        body && Array.isArray(body.items) && body.items.length
          ? body.items
          : ((cache.payload && cache.payload.allItems) || []).slice(0, 80);
      const targets = buildSilentPushTargets(sourceItems);
      const dryRun = parseBoolean(
        body && Object.prototype.hasOwnProperty.call(body, 'dryRun') ? body.dryRun : requestUrl.searchParams.get('dryRun'),
        true
      );

      let dispatchResult = null;
      let dispatchError = '';
      if (!dryRun && targets.length > 0) {
        try {
          dispatchResult = await dispatchSilentPush(targets, { reason });
        } catch (err) {
          dispatchError = err && err.message ? err.message : 'dispatch_failed';
        }
      }

      appendSilentPushAudit({
        at: new Date().toISOString(),
        reason,
        targetCount: targets.length,
        deviceCount: deviceRegistry.size,
        dryRun,
        sent: dispatchResult ? dispatchResult.sent : 0,
        success: dispatchResult ? dispatchResult.success : 0,
        failed: dispatchResult ? dispatchResult.failed : (dryRun ? 0 : targets.length),
        error: dispatchError || '',
      });

      if (dispatchError) {
        sendJson(res, 502, {
          ok: false,
          dryRun,
          reason,
          targetCount: targets.length,
          error: dispatchError,
          config: apnsConfigStatus(),
          recent: silentPushAudit.slice(-20),
        });
        return;
      }

      sendJson(res, 200, {
        ok: true,
        dryRun,
        reason,
        targetCount: targets.length,
        targets: targets.map((x) => ({
          token: maskToken(x.deviceToken),
          matchedCount: x.matchedCount,
          matchedKeywordCount: x.matchedKeywordCount,
          hasPriorityHit: x.hasPriorityHit,
          matchedSources: x.matchedSources,
          policy: x.policy,
        })),
        sent: dispatchResult ? dispatchResult.sent : 0,
        success: dispatchResult ? dispatchResult.success : 0,
        failed: dispatchResult ? dispatchResult.failed : 0,
        delivery: dispatchResult
          ? dispatchResult.results.map((row) => ({
              token: maskToken(row.token),
              ok: row.ok,
              status: row.status,
              reason: row.reason,
              apnsId: row.apnsId,
              matchedCount: row.matchedCount,
            }))
          : [],
        config: apnsConfigStatus(),
        recent: silentPushAudit.slice(-20),
      });
      return;
    }

    if (requestUrl.pathname === '/api/ai/providers' && method === 'GET') {
      sendJson(res, 200, { ok: true, ...listAiProviders() });
      return;
    }

    if (requestUrl.pathname === '/api/analyze' && method === 'POST') {
      const body = await readJsonBody(req);
      const input = {
        uid: String((body && body.uid) || '').trim(),
        source: String((body && body.source) || '').trim(),
        time: String((body && body.time) || '').trim(),
        title: String((body && body.title) || '').trim(),
        text: String((body && body.text) || '').trim(),
      };

      if (!input.title && !input.text) {
        sendJson(res, 400, { ok: false, error: 'missing_title_or_text' });
        return;
      }

      const runtimeConfig = resolveAiRuntimeConfig(body);
      if (!runtimeConfig.apiKey) {
        sendJson(res, 400, { ok: false, error: 'missing_ai_api_key' });
        return;
      }
      if (!runtimeConfig.apiBase) {
        sendJson(res, 400, { ok: false, error: 'missing_ai_api_base' });
        return;
      }
      if (!runtimeConfig.model) {
        sendJson(res, 400, { ok: false, error: 'missing_ai_model' });
        return;
      }
      const cacheKey = buildAiCacheKey(input, runtimeConfig);
      const cached = getAiCached(cacheKey);
      if (cached) {
        sendJson(res, 200, { ok: true, cached: true, analysis: cached });
        return;
      }

      const analysis = await analyzeTelegraphWithModel(input, runtimeConfig);
      setAiCached(cacheKey, analysis);
      sendJson(res, 200, { ok: true, cached: false, analysis });
      return;
    }

    sendJson(res, 404, { ok: false, error: 'not_found' });
  } catch (err) {
    sendJson(res, 502, {
      ok: false,
      error: err && err.message ? err.message : 'unknown_error',
      fetchedAt: new Date().toISOString(),
    });
  }
});

server.listen(PORT, HOST, () => {
  // eslint-disable-next-line no-console
  console.log(`Multi-source telegraph proxy running at http://127.0.0.1:${PORT}`);
});
