// ==UserScript==
// @name         CLS Telegraph Stream UI Enhancer
// @namespace    https://www.cls.cn/
// @version      1.0.0
// @description  财联社电报持续推送 + UI优化（实时捕获、通知、过滤、视觉增强）
// @author       codex
// @match        https://www.cls.cn/telegraph*
// @grant        GM_addStyle
// @run-at       document-idle
// ==/UserScript==

(function () {
  'use strict';

  const APP_ID = 'cls-telegraph-enhancer';
  const FEED_ID = `${APP_ID}-feed`;
  const TOOLBAR_ID = `${APP_ID}-toolbar`;
  const TOAST_ID = `${APP_ID}-toast`;

  const state = {
    paused: false,
    notifyEnabled: true,
    soundEnabled: false,
    compactMode: false,
    panelVisible: true,
    keyword: '',
    maxItems: 120,
    seen: new Set(),
    feed: [],
    observer: null,
  };

  const selectors = {
    listCandidates: [
      '.telegraph-main',
      '.telegraph-list',
      '.telegraph-content-box',
      '.subject-content',
      '[class*="telegraph"][class*="list"]',
      '.news-list',
      '.list',
      'main',
    ],
    itemCandidates: [
      '.telegraph-item',
      '.telegraph-content-item',
      '.subject-item',
      '.news-item',
      '[class*="telegraph"][class*="item"]',
      'li',
      'article',
      '.clearfix',
    ],
  };

  function injectStyles() {
    const css = `
      :root {
        --cte-bg: linear-gradient(135deg, #f5f7fb 0%, #e9eef7 45%, #f8fafc 100%);
        --cte-surface: rgba(255, 255, 255, 0.86);
        --cte-surface-strong: #ffffff;
        --cte-text: #19212d;
        --cte-subtext: #667085;
        --cte-brand: #0f62fe;
        --cte-brand-soft: rgba(15, 98, 254, 0.12);
        --cte-green: #0e9f6e;
        --cte-red: #d92d20;
        --cte-border: rgba(17, 24, 39, 0.08);
        --cte-shadow: 0 12px 40px rgba(15, 23, 42, 0.08);
      }

      body {
        background: var(--cte-bg) !important;
        color: var(--cte-text) !important;
      }

      body.cte-has-panel {
        padding-right: 442px;
      }

      #${TOOLBAR_ID} {
        position: sticky;
        top: 10px;
        z-index: 9999;
        margin: 10px auto 14px;
        max-width: 1280px;
        padding: 10px 14px;
        background: var(--cte-surface);
        border: 1px solid var(--cte-border);
        border-radius: 14px;
        backdrop-filter: blur(12px);
        -webkit-backdrop-filter: blur(12px);
        box-shadow: var(--cte-shadow);
        display: flex;
        align-items: center;
        gap: 8px;
        flex-wrap: wrap;
      }

      #${TOOLBAR_ID} .cte-title {
        font-weight: 700;
        margin-right: 8px;
        letter-spacing: 0.2px;
      }

      #${TOOLBAR_ID} .cte-tag {
        font-size: 12px;
        color: var(--cte-subtext);
        background: #f8fafc;
        border: 1px solid var(--cte-border);
        border-radius: 999px;
        padding: 2px 8px;
      }

      #${TOOLBAR_ID} button,
      #${TOOLBAR_ID} input {
        border: 1px solid var(--cte-border);
        border-radius: 10px;
        background: #fff;
        color: var(--cte-text);
        padding: 7px 10px;
        font-size: 13px;
        line-height: 1;
      }

      #${TOOLBAR_ID} button {
        cursor: pointer;
        transition: all .18s ease;
      }

      #${TOOLBAR_ID} button:hover {
        border-color: #adc6ff;
        transform: translateY(-1px);
      }

      #${TOOLBAR_ID} button[data-active="true"] {
        background: var(--cte-brand-soft);
        color: var(--cte-brand);
        border-color: #94b5ff;
      }

      #${TOOLBAR_ID} input {
        min-width: 180px;
      }

      #${FEED_ID} {
        position: fixed;
        top: 76px;
        right: 12px;
        bottom: 12px;
        width: 420px;
        z-index: 9998;
      }

      .cte-pane {
        background: var(--cte-surface);
        border: 1px solid var(--cte-border);
        border-radius: 14px;
        box-shadow: var(--cte-shadow);
        height: 100%;
        display: flex;
        flex-direction: column;
      }

      .cte-pane-head {
        position: sticky;
        top: 0;
        z-index: 2;
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 8px;
        padding: 10px 12px;
        background: linear-gradient(180deg, rgba(255,255,255,0.98), rgba(255,255,255,0.85));
        border-bottom: 1px solid var(--cte-border);
        border-radius: 14px 14px 0 0;
      }

      .cte-pane-head h3 {
        margin: 0;
        font-size: 14px;
      }

      .cte-stream {
        flex: 1;
        overflow: auto;
        padding: 10px;
      }

      body.cte-hide-panel #${FEED_ID} {
        display: none;
      }

      body.cte-hide-panel {
        padding-right: 0;
      }

      .telegraph-item,
      .telegraph-content-item,
      .subject-item,
      .news-item,
      [class*="telegraph"][class*="item"] {
        border: 1px solid var(--cte-border) !important;
        background: rgba(255, 255, 255, 0.92) !important;
        border-radius: 12px !important;
        box-shadow: 0 8px 20px rgba(15, 23, 42, 0.05) !important;
        margin-bottom: 10px !important;
        padding: 10px 12px !important;
      }

      .cte-card {
        border: 1px solid var(--cte-border);
        border-radius: 12px;
        background: var(--cte-surface-strong);
        box-shadow: 0 8px 24px rgba(15, 23, 42, 0.06);
        padding: 10px 12px;
        margin-bottom: 10px;
      }

      .cte-card:last-child {
        margin-bottom: 0;
      }

      .cte-card-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 10px;
        margin-bottom: 8px;
      }

      .cte-card-time {
        font-size: 12px;
        color: var(--cte-subtext);
        white-space: nowrap;
      }

      .cte-card-index {
        font-size: 11px;
        color: var(--cte-brand);
        background: var(--cte-brand-soft);
        border-radius: 999px;
        padding: 1px 8px;
      }

      .cte-card-body {
        font-size: 14px;
        line-height: 1.62;
        color: var(--cte-text);
        white-space: pre-wrap;
        word-break: break-word;
      }

      .cte-card-body mark {
        background: #fff1b8;
        color: #222;
        padding: 0 2px;
        border-radius: 4px;
      }

      .cte-compact .cte-card {
        padding: 8px 10px;
        margin-bottom: 8px;
      }

      .cte-compact .cte-card-body {
        font-size: 13px;
        line-height: 1.45;
      }

      .cte-toast {
        position: fixed;
        right: 18px;
        bottom: 18px;
        z-index: 99999;
        padding: 10px 12px;
        background: #111827;
        color: #fff;
        border-radius: 10px;
        font-size: 13px;
        box-shadow: 0 12px 28px rgba(0,0,0,0.24);
        opacity: 0;
        transform: translateY(8px);
        pointer-events: none;
        transition: all .22s ease;
        max-width: min(440px, calc(100vw - 40px));
      }

      .cte-toast.show {
        opacity: 1;
        transform: translateY(0);
      }

      .cte-badge-live {
        width: 7px;
        height: 7px;
        border-radius: 999px;
        background: var(--cte-green);
        box-shadow: 0 0 0 0 rgba(14,159,110,0.65);
        animation: ctePulse 1.65s infinite;
        display: inline-block;
        margin-right: 6px;
      }

      @keyframes ctePulse {
        0% { box-shadow: 0 0 0 0 rgba(14,159,110,0.65); }
        75% { box-shadow: 0 0 0 10px rgba(14,159,110,0); }
        100% { box-shadow: 0 0 0 0 rgba(14,159,110,0); }
      }

      @media (max-width: 980px) {
        body.cte-has-panel {
          padding-right: 0;
        }

        #${FEED_ID} {
          position: static;
          width: auto;
          margin: 10px 12px 16px;
          height: 44vh;
        }

        .cte-stream {
          max-height: 100%;
        }
      }
    `;

    if (typeof GM_addStyle === 'function') {
      GM_addStyle(css);
    } else {
      const style = document.createElement('style');
      style.textContent = css;
      document.head.appendChild(style);
    }
  }

  function createToolbar() {
    const toolbar = document.createElement('div');
    toolbar.id = TOOLBAR_ID;
    toolbar.innerHTML = `
      <span class="cte-title"><span class="cte-badge-live"></span>CLS 实时电报流</span>
      <span class="cte-tag" id="${APP_ID}-count">0 条</span>
      <button id="${APP_ID}-pause">暂停推送</button>
      <button id="${APP_ID}-notify" data-active="true">桌面通知: 开</button>
      <button id="${APP_ID}-sound" data-active="false">提示音: 关</button>
      <button id="${APP_ID}-compact" data-active="false">紧凑模式</button>
      <button id="${APP_ID}-panel" data-active="true">侧栏: 显示</button>
      <input id="${APP_ID}-keyword" type="text" placeholder="关键词过滤（逗号分隔）" />
      <button id="${APP_ID}-clear">清空流</button>
    `;

    document.body.prepend(toolbar);

    const pauseBtn = toolbar.querySelector(`#${APP_ID}-pause`);
    const notifyBtn = toolbar.querySelector(`#${APP_ID}-notify`);
    const soundBtn = toolbar.querySelector(`#${APP_ID}-sound`);
    const compactBtn = toolbar.querySelector(`#${APP_ID}-compact`);
    const panelBtn = toolbar.querySelector(`#${APP_ID}-panel`);
    const keywordInput = toolbar.querySelector(`#${APP_ID}-keyword`);
    const clearBtn = toolbar.querySelector(`#${APP_ID}-clear`);

    pauseBtn.addEventListener('click', () => {
      state.paused = !state.paused;
      pauseBtn.textContent = state.paused ? '恢复推送' : '暂停推送';
    });

    notifyBtn.addEventListener('click', async () => {
      state.notifyEnabled = !state.notifyEnabled;
      if (state.notifyEnabled && 'Notification' in window && Notification.permission === 'default') {
        try {
          await Notification.requestPermission();
        } catch (_) {}
      }
      notifyBtn.dataset.active = String(state.notifyEnabled);
      notifyBtn.textContent = `桌面通知: ${state.notifyEnabled ? '开' : '关'}`;
    });

    soundBtn.addEventListener('click', () => {
      state.soundEnabled = !state.soundEnabled;
      soundBtn.dataset.active = String(state.soundEnabled);
      soundBtn.textContent = `提示音: ${state.soundEnabled ? '开' : '关'}`;
      if (state.soundEnabled) beep(660, 0.05, 0.03);
    });

    compactBtn.addEventListener('click', () => {
      state.compactMode = !state.compactMode;
      compactBtn.dataset.active = String(state.compactMode);
      document.body.classList.toggle('cte-compact', state.compactMode);
    });

    panelBtn.addEventListener('click', () => {
      state.panelVisible = !state.panelVisible;
      panelBtn.dataset.active = String(state.panelVisible);
      panelBtn.textContent = `侧栏: ${state.panelVisible ? '显示' : '隐藏'}`;
      document.body.classList.toggle('cte-hide-panel', !state.panelVisible);
    });

    keywordInput.addEventListener('input', () => {
      state.keyword = keywordInput.value.trim();
      renderFeed();
    });

    clearBtn.addEventListener('click', () => {
      state.feed = [];
      state.seen.clear();
      renderFeed();
      showToast('已清空电报流缓存');
    });
  }

  function createLayout() {
    document.body.classList.add('cte-has-panel');
    const host = document.createElement('aside');
    host.id = FEED_ID;
    host.innerHTML = `
      <div class="cte-pane">
        <div class="cte-pane-head">
          <h3>实时推送流</h3>
          <span class="cte-tag" id="${APP_ID}-status">监听中</span>
        </div>
        <div class="cte-stream" id="${APP_ID}-stream"></div>
      </div>
    `;

    const toolbar = document.getElementById(TOOLBAR_ID);
    if (toolbar && toolbar.nextSibling) {
      document.body.insertBefore(host, toolbar.nextSibling);
    } else {
      document.body.appendChild(host);
    }
  }

  function updateCount() {
    const countEl = document.getElementById(`${APP_ID}-count`);
    if (countEl) countEl.textContent = `${state.feed.length} 条`;
  }

  function sanitizeText(text) {
    return String(text || '').replace(/\s+/g, ' ').trim();
  }

  function parseItem(el) {
    const raw = sanitizeText(el.innerText || el.textContent || '');
    if (!raw || raw.length < 12) return null;

    const timeMatch = raw.match(/\b(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?\b/);
    if (!timeMatch) return null;
    const time = timeMatch[0];

    let text = raw;
    text = text.replace(/^\d{1,2}:\d{2}(?::\d{2})?\s*/, '');

    if (text.length > 600) text = `${text.slice(0, 600)}...`;
    const id = `${time}|${text.slice(0, 80)}`;

    return { id, time, text, ts: Date.now() };
  }

  function getListContainer() {
    for (const selector of selectors.listCandidates) {
      const el = document.querySelector(selector);
      if (el && el.children && el.children.length > 0) return el;
    }
    return document.body;
  }

  function collectFromDOM(limit = 60) {
    const container = getListContainer();
    const candidates = [];

    for (const s of selectors.itemCandidates) {
      container.querySelectorAll(s).forEach((el) => {
        if (!el || !el.innerText) return;
        if (el.closest(`#${FEED_ID}`) || el.closest(`#${TOOLBAR_ID}`) || el.id === TOAST_ID) return;
        const txt = sanitizeText(el.innerText);
        if (txt.length < 12 || txt.length > 2400) return;
        candidates.push(el);
      });
      if (candidates.length > limit * 2) break;
    }

    const uniqueNodes = Array.from(new Set(candidates));
    const items = [];

    for (const el of uniqueNodes.slice(0, limit * 2)) {
      const item = parseItem(el);
      if (!item) continue;
      if (state.seen.has(item.id)) continue;
      items.push(item);
    }

    items.sort((a, b) => a.ts - b.ts);
    return items.slice(-limit);
  }

  function shouldPassFilter(text) {
    const keyword = state.keyword.trim();
    if (!keyword) return true;
    const parts = keyword
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    if (parts.length === 0) return true;
    return parts.some((k) => text.includes(k));
  }

  function highlight(text) {
    const keyword = state.keyword.trim();
    if (!keyword) return escapeHTML(text);

    let output = escapeHTML(text);
    const parts = keyword
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
      .sort((a, b) => b.length - a.length);

    for (const p of parts) {
      const safe = p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const reg = new RegExp(safe, 'gi');
      output = output.replace(reg, (m) => `<mark>${m}</mark>`);
    }
    return output;
  }

  function escapeHTML(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function renderFeed() {
    const stream = document.getElementById(`${APP_ID}-stream`);
    if (!stream) return;

    const filtered = state.feed.filter((i) => shouldPassFilter(i.text));
    stream.innerHTML = filtered
      .slice(0, state.maxItems)
      .map((item, idx) => {
        return `
          <article class="cte-card">
            <div class="cte-card-head">
              <span class="cte-card-index">#${filtered.length - idx}</span>
              <span class="cte-card-time">${escapeHTML(item.time)}</span>
            </div>
            <div class="cte-card-body">${highlight(item.text)}</div>
          </article>
        `;
      })
      .join('');

    updateCount();
  }

  function pushItems(newItems) {
    if (!newItems.length) return;

    const statusEl = document.getElementById(`${APP_ID}-status`);
    if (statusEl) statusEl.textContent = state.paused ? '已暂停' : `监听中 +${newItems.length}`;

    for (const item of newItems) {
      if (state.seen.has(item.id)) continue;
      state.seen.add(item.id);
      state.feed.unshift(item);
      if (state.feed.length > state.maxItems) {
        state.feed.length = state.maxItems;
      }

      if (!state.paused && shouldPassFilter(item.text)) {
        showToast(`${item.time} ${item.text.slice(0, 72)}${item.text.length > 72 ? '...' : ''}`);
        sendNotification(item);
        if (state.soundEnabled) beep();
      }
    }

    renderFeed();
  }

  function showToast(text) {
    let toast = document.getElementById(TOAST_ID);
    if (!toast) {
      toast = document.createElement('div');
      toast.id = TOAST_ID;
      toast.className = 'cte-toast';
      document.body.appendChild(toast);
    }
    toast.textContent = text;
    toast.classList.add('show');

    window.clearTimeout(showToast._timer);
    showToast._timer = window.setTimeout(() => {
      toast.classList.remove('show');
    }, 1900);
  }

  function sendNotification(item) {
    if (!state.notifyEnabled) return;
    if (!('Notification' in window)) return;
    if (document.hasFocus()) return;

    if (Notification.permission === 'granted') {
      new Notification('财联社新电报', {
        body: `${item.time} ${item.text.slice(0, 90)}`,
        tag: 'cls-telegraph-stream',
      });
    }
  }

  function beep(freq = 820, duration = 0.07, volume = 0.04) {
    try {
      const audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      const osc = audioCtx.createOscillator();
      const gain = audioCtx.createGain();
      osc.type = 'sine';
      osc.frequency.value = freq;
      gain.gain.value = volume;
      osc.connect(gain);
      gain.connect(audioCtx.destination);
      osc.start();
      osc.stop(audioCtx.currentTime + duration);
    } catch (_) {}
  }

  function setupObserver() {
    const container = getListContainer();
    if (!container) return;

    if (state.observer) {
      state.observer.disconnect();
    }

    state.observer = new MutationObserver((mutations) => {
      if (state.paused) return;

      let hasNewNodes = false;
      for (const m of mutations) {
        if (m.addedNodes && m.addedNodes.length > 0) {
          hasNewNodes = true;
          break;
        }
      }

      if (hasNewNodes) {
        const items = collectFromDOM(12);
        pushItems(items);
      }
    });

    state.observer.observe(container, {
      childList: true,
      subtree: true,
    });
  }

  function setupPolling() {
    window.setInterval(() => {
      if (state.paused) return;
      const items = collectFromDOM(8);
      pushItems(items);
    }, 4500);
  }

  function bootstrap() {
    injectStyles();
    createToolbar();
    createLayout();

    const warmup = collectFromDOM(40);
    pushItems(warmup);

    setupObserver();
    setupPolling();

    if ('Notification' in window && Notification.permission === 'default') {
      Notification.requestPermission().catch(() => {});
    }

    showToast('CLS 电报增强脚本已启动');
  }

  const ready = () => {
    if (!document.body) {
      setTimeout(ready, 50);
      return;
    }
    if (document.getElementById(TOOLBAR_ID)) return;
    bootstrap();
  };

  ready();
})();
