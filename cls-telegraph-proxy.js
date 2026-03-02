'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const HOST = '0.0.0.0';
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

const cache = {
  ts: 0,
  payload: null,
  ttlMs: 3000,
};

function sendJson(res, code, data) {
  const body = JSON.stringify(data);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
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

async function fetchAggregated(limit) {
  const now = Date.now();
  if (cache.payload && now - cache.ts <= cache.ttlMs) {
    return {
      ...cache.payload,
      cached: true,
    };
  }

  const perSourceLimit = Math.max(20, Math.min(180, Math.ceil(limit * 1.4)));

  const sourceTasks = [
    { source: 'cls', sourceName: '财联社', fn: fetchClsItems },
    { source: 'eastmoney', sourceName: '东方财富', fn: fetchEastmoneyItems },
    { source: 'sina', sourceName: '新浪财经', fn: fetchSinaItems },
    { source: 'wscn', sourceName: '华尔街见闻', fn: fetchWscnItems },
    { source: 'ths', sourceName: '同花顺', fn: fetchThsItems },
  ];

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

  cache.ts = now;
  cache.payload = payload;

  return payload;
}

const server = http.createServer(async (req, res) => {
  try {
    const base = `http://${req.headers.host || `127.0.0.1:${PORT}`}`;
    const requestUrl = new URL(req.url || '/', base);

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

    if (requestUrl.pathname === '/api/telegraph') {
      const limit = parseLimit(requestUrl.searchParams);
      const data = await fetchAggregated(limit);
      sendJson(res, 200, data);
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
