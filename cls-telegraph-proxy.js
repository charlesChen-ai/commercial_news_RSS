'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
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

async function fetchAggregated(limit, selectedSources) {
  const normalizedSources = Array.isArray(selectedSources) && selectedSources.length
    ? SOURCE_TASKS.map((task) => task.source).filter((s) => selectedSources.includes(s))
    : SOURCE_TASKS.map((task) => task.source);
  if (!normalizedSources.length) throw new Error('invalid_sources');

  const cacheKey = `${normalizedSources.join(',')}|${limit}`;
  const now = Date.now();
  if (cache.payload && cache.key === cacheKey && now - cache.ts <= cache.ttlMs) {
    return {
      ...cache.payload,
      cached: true,
    };
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
    ok: true,
    source: 'multi',
    sourceName: '多源聚合',
    fetchedAt: new Date().toISOString(),
    count: uniqueByFuzzy.length,
    items: uniqueByFuzzy.slice(0, limit),
    selectedSources: normalizedSources,
    sources: summarizeSources(sourceResults),
    dedupe: {
      before: merged.length,
      afterUid: uniqueByUid.length,
      afterStrong: uniqueByStrong.length,
      afterTitle: uniqueByTitle.length,
      afterFuzzy: uniqueByFuzzy.length,
    },
    cached: false,
  };

  cache.key = cacheKey;
  cache.ts = now;
  cache.payload = payload;

  return payload;
}

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
      sendJson(res, 200, {
        ok: true,
        service: 'telegraph-multi-source-proxy',
        time: new Date().toISOString(),
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
      const data = await fetchAggregated(limit, selectedSources);
      sendJson(res, 200, data);
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
