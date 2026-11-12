(() => {
  "use strict";

  if (window.__RELAYSTUDIO_BRIDGE_CONTENT_INSTALLED__) {
    return;
  }
  window.__RELAYSTUDIO_BRIDGE_CONTENT_INSTALLED__ = true;

  const host = new URL(window.location.href).hostname;
  const PROVIDER = host === 'gemini.google.com' ? 'gemini' : host === 'claude.ai' ? 'claude' : 'chatgpt';
  if (!['gemini.google.com', 'claude.ai', 'chatgpt.com', 'chat.openai.com'].includes(host)) return;
  const SITE = {
    chatgpt: {room: /\/c\/([0-9a-fA-F-]{36})(?:[/?#]|$)/, user: '[data-message-author-role="user"]'},
    gemini: {
      room: /^\/(?:u\/\d+\/)?(?:app|gem\/[a-zA-Z0-9_-]+)\/([a-zA-Z0-9_-]+)\/?$/,
      user: 'user-query, [data-testid="user-query"]',
      composer: 'rich-textarea [contenteditable="true"]',
      send: 'button.send-button',
      stop: 'button[aria-label*="Stop response"], button[aria-label*="停止回答"], button[aria-label*="Stop generating"], button[aria-label*="停止生成"], button.stop-button, input-area-v2 button[aria-label*="Stop"], .input-area button[aria-label*="Stop"], .input-area-container button[aria-label*="Stop"], .text-input-field button[aria-label*="Stop"]',
    },
    claude: {room: /\/chat\/([a-zA-Z0-9_-]+)(?:[/?#]|$)/, user: '[data-testid="user-message"]', composer: 'div.ProseMirror[contenteditable="true"]', send: 'button[aria-label="Send message"]', stop: 'button[aria-label="Stop response"], button[aria-label="停止响应"]'},
  }[PROVIDER];
  const BRIDGE_BASE = "http://127.0.0.1:8766";
  const POLL_INTERVAL_MS = 2200;
  const MODELS_CACHE_KEY = "__relaystudio_models_cache__";
  const TAB_ID = "tab_" + Math.random().toString(36).slice(2, 10) + "_" + Date.now().toString(36);

  function detectCodexInAppBrowser() {
    const ua = String((typeof navigator !== "undefined" && navigator.userAgent) || "");
    if (/\b(Codex|CodexInApp|Electron)\b/i.test(ua)) {
      return true;
    }
    try {
      const brands =
        typeof navigator !== "undefined" &&
        navigator.userAgentData &&
        Array.isArray(navigator.userAgentData.brands)
          ? navigator.userAgentData.brands
          : [];
      if (brands.length > 0) {
        const hasRealBrowserBrand = brands.some((b) =>
          /Google Chrome|Microsoft Edge|Brave|Opera|Vivaldi/i.test(String((b && b.brand) || ""))
        );
        const hasStandardExtApis = Boolean(
          typeof chrome !== "undefined" && (chrome.sidePanel || chrome.tabGroups)
        );
        if (!hasRealBrowserBrand && !hasStandardExtApis) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  const IS_CODEX_IN_APP = detectCodexInAppBrowser();
  const BROWSER_NAME = IS_CODEX_IN_APP
    ? "CodexInApp"
    : /Edg\//i.test((typeof navigator !== "undefined" && navigator.userAgent) || "")
      ? "Edge"
      : "Chrome";
  const initialUrlParams = new URLSearchParams(window.location.search || "");
  let BROWSER_PROFILE = IS_CODEX_IN_APP
    ? "CodexInApp:Default"
    : initialUrlParams.get("relay_profile") || `${BROWSER_NAME}:Default`;
  if (!IS_CODEX_IN_APP && typeof chrome !== "undefined" && chrome.storage && chrome.storage.local) {
    try {
      if (initialUrlParams.get("relay_profile")) {
        chrome.storage.local.set({ relay_bound_profile_key: BROWSER_PROFILE });
      } else {
        chrome.storage.local.get(["relay_bound_profile_key"], (items) => {
          if (items && items.relay_bound_profile_key) {
            BROWSER_PROFILE = String(items.relay_bound_profile_key);
          }
        });
      }
    } catch (_) {}
  }

  let stickyHandoverMsgId = initialUrlParams.get("msg_id") || "";
  const deliveredMsgIds = new Set();
  const resolvedHandoverMsgIds = new Set();

  let isBusySending = false;
  let busySendStartedAtMs = 0;
  let lastInjectedText = "";
  let lastHintsScanAt = 0;
  let cachedPageHints = [];
  let shuttleConnected = false;

  function getConvUuid() {
    const m = String(window.location.pathname || "").match(SITE.room);
    return m ? m[1] : "";
  }

  function getProjectPrefix() {
    const href = String(window.location.href || "");
    if (PROVIDER === "gemini") {
      const gemMatch = href.match(/^(https:\/\/gemini\.google\.com\/(?:u\/\d+\/)?gem\/[a-zA-Z0-9_-]+)(?:[/?#]|$)/);
      if (gemMatch) return gemMatch[1];
      const uAppMatch = href.match(/^(https:\/\/gemini\.google\.com\/u\/\d+)\/app(?:[/?#]|$)/);
      if (uAppMatch) return `${uAppMatch[1]}/app`;
      const uBareMatch = href.match(/^(https:\/\/gemini\.google\.com\/u\/\d+)\/?(?:[?#]|$)/);
      if (uBareMatch) return `${uBareMatch[1]}/app`;
      return "";
    }
    const m = href.match(/^(https:\/\/chatgpt\.com\/g\/g-p-[a-zA-Z0-9_-]+)/);
    return m ? m[1] : "";
  }

  const TURN_MESSAGE_SELECTOR =
    PROVIDER === "gemini"
      ? "user-query, model-response"
      : PROVIDER === "claude"
        ? '[data-testid="user-message"], .font-claude-message, [data-is-streaming]'
        : "[data-message-author-role]";

  function queryConversationTurns() {
    if (!document || typeof document.querySelectorAll !== "function") return [];
    const raw = Array.from(document.querySelectorAll(TURN_MESSAGE_SELECTOR) || []);
    if (raw.length <= 1 || PROVIDER === "chatgpt") return raw;
    // Deduplicate nested matches (e.g. .font-claude-message inside [data-is-streaming]) while preserving DOM order.
    return raw.filter(
      (el) => !raw.some((other) => other !== el && other && typeof other.contains === "function" && other.contains(el))
    );
  }

  function isUserTurnNode(node) {
    if (!node) return false;
    if (PROVIDER === "chatgpt") {
      const role = String((typeof node.getAttribute === "function" && node.getAttribute("data-message-author-role")) || "");
      return role === "user";
    }
    if (PROVIDER === "gemini") {
      const tag = String(node.tagName || "").toUpperCase();
      if (tag === "USER-QUERY") return true;
      if (typeof node.getAttribute === "function" && node.getAttribute("data-testid") === "user-query") return true;
      if (typeof node.matches === "function") {
        try {
          return Boolean(node.matches(SITE.user));
        } catch (_) {}
      }
      return false;
    }
    if (PROVIDER === "claude") {
      if (typeof node.getAttribute === "function" && node.getAttribute("data-testid") === "user-message") return true;
      if (typeof node.matches === "function") {
        try {
          return Boolean(node.matches(SITE.user));
        } catch (_) {}
      }
      return false;
    }
    return false;
  }

  function maybeClearResolvedHandoverUrl() {
    if (!stickyHandoverMsgId) return;
    if (!deliveredMsgIds.has(stickyHandoverMsgId)) return;
    const convUuid = getConvUuid();
    if (!convUuid) return;
    resolvedHandoverMsgIds.add(stickyHandoverMsgId);
    stickyHandoverMsgId = "";
    try {
      const cleanUrl = new URL(window.location.href);
      if (cleanUrl.searchParams.has("relay_handover") || cleanUrl.searchParams.has("msg_id")) {
        cleanUrl.searchParams.delete("relay_handover");
        cleanUrl.searchParams.delete("msg_id");
        window.history.replaceState({}, document.title, cleanUrl.toString());
      }
    } catch (_) {}
  }

  function getHandoverMsgId() {
    maybeClearResolvedHandoverUrl();
    const params = new URLSearchParams(window.location.search || "");
    const fromUrl = params.get("msg_id") || "";
    if (fromUrl && !resolvedHandoverMsgIds.has(fromUrl)) {
      stickyHandoverMsgId = fromUrl;
    }
    return stickyHandoverMsgId;
  }

  let lastTailPeekAt = 0;

  function scanPageTaskHints() {
    const now = Date.now();
    if (now - lastHintsScanAt < 4500 && cachedPageHints.length > 0) {
      return cachedPageHints;
    }
    lastHintsScanAt = now;
    const hints = new Set();
    const convUuid = getConvUuid();
    if (convUuid) {
      hints.add(convUuid);
    }
    try {
      const dsHints =
        document.documentElement && document.documentElement.dataset
          ? String(document.documentElement.dataset.relayTaskHints || "")
          : "";
      if (dsHints) {
        for (const part of dsHints.split(",")) {
          const clean = part.trim();
          if (clean) hints.add(clean);
        }
      }
      // Spec v4.3: the page hook registers task numbers where they enter the page (stream / request / loaded conversation),
      // so the page text is NOT scanned any more (it used to read textContent AND innerText of the whole thread every few
      // seconds, which forces a layout pass and gets slower the longer the chat is). Only while no task number is known
      // yet, peek at the tail of the last two turns once in a while - bounded and cheap.
      const hasTaskHint = Array.from(hints).some((h) => /^(tsk|wfr)_/.test(h));
      const peekIntervalMs = PROVIDER === "chatgpt" ? 20000 : 4500;
      if (!hasTaskHint && now - lastTailPeekAt > peekIntervalMs) {
        const turns = queryConversationTurns();
        if (turns.length > 0) {
          lastTailPeekAt = now;
          for (let i = Math.max(0, turns.length - 4); i < turns.length; i++) {
            const tail = String(turns[i].textContent || turns[i].innerText || "").slice(-4000);
            for (const m of tail.match(/\btsk_[0-9a-fA-F_]{6,32}\b/g) || []) hints.add(m);
            for (const w of tail.match(/\bwfr_[0-9a-fA-F_]{8,40}\b/g) || []) hints.add(w);
          }
        }
      }
    } catch (_) {}
    cachedPageHints = Array.from(hints).slice(0, 16);
    return cachedPageHints;
  }

  function isSseActive() {
    try {
      return Boolean(
        document.documentElement &&
          document.documentElement.dataset &&
          document.documentElement.dataset.relaySseActive === "1"
      );
    } catch (_) {
      return false;
    }
  }

  function getTurnSeq() {
    try {
      const ds = (document.documentElement && document.documentElement.dataset) || {};
      const completedRounds = Number(ds.relayTurnSeq || 0);
      const acceptedPosts = Number(ds.relayAcceptedPostSeq || 0);
      const safeCompleted = Number.isFinite(completedRounds) && completedRounds >= 0 ? completedRounds : 0;
      const safeAccepted = Number.isFinite(acceptedPosts) && acceptedPosts >= 0 ? acceptedPosts : 0;
      // Entry-level turn_seq parity with Desktop entries.length:
      // +1 when outgoing user POST is accepted, +1 when assistant SSE finishes cleanly (+2 per full round-trip).
      const hookEntries = safeCompleted * 2 + Math.max(0, safeAccepted - safeCompleted);
      let domEntries = 0;
      const nodes = queryConversationTurns();
      if (nodes && typeof nodes.length === "number") domEntries = nodes.length;
      return Math.max(hookEntries, domEntries);
    } catch (_) {
      return 0;
    }
  }

  function isVisibleDomElement(el) {
    if (!el) return false;
    if (el.hidden || (typeof el.hasAttribute === "function" && el.hasAttribute("hidden"))) return false;
    if (typeof el.getAttribute === "function" && el.getAttribute("aria-hidden") === "true") return false;
    if (typeof el.closest === "function" && el.closest('[hidden], [aria-hidden="true"]')) return false;
    if (typeof el.getBoundingClientRect === "function") {
      const r = el.getBoundingClientRect();
      if (r && r.width === 0 && r.height === 0) {
        const child = el.firstElementChild;
        const cr = child && typeof child.getBoundingClientRect === "function" ? child.getBoundingClientRect() : null;
        if (!cr || (cr.width === 0 && cr.height === 0)) return false;
      }
    }
    try {
      const st =
        el.style && el.style.display
          ? el.style
          : typeof window.getComputedStyle === "function"
            ? window.getComputedStyle(el)
            : null;
      if (st && (st.display === "none" || st.visibility === "hidden")) return false;
    } catch (_) {}
    return true;
  }

  function isUsableStopButton(btn) {
    if (!btn || btn.disabled) return false;
    if (typeof btn.getAttribute === "function" && btn.getAttribute("aria-disabled") === "true") return false;
    const aria = String((typeof btn.getAttribute === "function" && btn.getAttribute("aria-label")) || "");
    if (/read(ing)?\s+aloud|aloud|朗读|voice|语音|audio|microphone|麦克风/i.test(aria)) return false;
    return isVisibleDomElement(btn);
  }

  function findActiveStopButton() {
    if (PROVIDER !== "chatgpt") {
      const candidates = Array.from(document.querySelectorAll(SITE.stop) || []);
      const direct = candidates.find((btn) => isUsableStopButton(btn));
      if (direct) return direct;
      if (PROVIDER === "gemini") {
        const composer = findComposerElement();
        const composerScope =
          (composer &&
            typeof composer.closest === "function" &&
            composer.closest("input-area-v2, .input-area-container, .input-area, .text-input-field, form")) ||
          (composer && composer.parentElement) ||
          null;
        if (composerScope && typeof composerScope.querySelectorAll === "function") {
          const scoped = Array.from(
            composerScope.querySelectorAll('button[aria-label*="Stop"], button[aria-label*="停止"], button.stop-button') || []
          );
          const hit = scoped.find((btn) => isUsableStopButton(btn));
          if (hit) return hit;
        }
      }
      return null;
    }
    const composer = findComposerElement();
    const formScope =
      (composer && typeof composer.closest === "function" && composer.closest("form")) ||
      document.querySelector("form[data-chatgpt-composer], main form");
    if (!formScope || !isVisibleDomElement(formScope)) return null;
    const stopSel =
      'button[data-testid="stop-button"], button[data-testid="composer-stop-button"], button[aria-label*="Stop streaming"], button[aria-label*="Stop generating"], button[aria-label="Stop"], button[aria-label*="停止生成"], button[aria-label="停止"]';
    const candidates =
      typeof formScope.querySelectorAll === "function"
        ? Array.from(formScope.querySelectorAll(stopSel))
        : typeof formScope.querySelector === "function"
          ? [formScope.querySelector(stopSel)].filter(Boolean)
          : [];
    for (const btn of candidates) {
      if (!btn || btn.disabled || (typeof btn.getAttribute === "function" && btn.getAttribute("aria-disabled") === "true")) {
        continue;
      }
      const aria = String((typeof btn.getAttribute === "function" && btn.getAttribute("aria-label")) || "");
      if (/read(ing)?\s+aloud|aloud|朗读|voice|语音|audio/i.test(aria)) continue;
      if (!isVisibleDomElement(btn)) continue;
      return btn;
    }
    return null;
  }

  function isGeneratingState() {
    return Boolean(findActiveStopButton());
  }

  function readComposerCleanText() {
    try {
      const el = findComposerElement();
      if (!el) return "";
      const isField = el.tagName === "TEXTAREA" || el.tagName === "INPUT";
      const raw = String(
        isField && typeof el.value === "string"
          ? el.value
          : el.innerText || el.textContent || el.value || ""
      );
      return raw.replace(/[\u200B-\u200D\uFEFF]/g, "").trim();
    } catch (_) {
      return "";
    }
  }

  function hasUserDraftRaw() {
    const clean = readComposerCleanText();
    if (!clean) {
      lastInjectedText = "";
      return false;
    }
    if (lastInjectedText && clean === lastInjectedText) {
      return false;
    }
    return true;
  }

  function hasUserDraft() {
    if (isBusySending) return false;
    return hasUserDraftRaw();
  }

  // Spec v4.7 1.2: generic outer error text (Cloudflare / timeout / "no reply" banners, any wording). Answer bodies,
  // code blocks, user bubbles and the composer are never read, so quoted error words in a reply cannot trip it.
  const UI_ERROR_SELECTOR =
    '[data-testid*="conversation-error"], [data-testid*="error"], div[role="alert"], [role="status"], button[data-testid*="regenerate"], main [class*="error" i]';
  const UI_ERROR_EXCLUDE_BASE =
    '.markdown, pre, code, [data-user-message-bubble="true"], [data-message-author-role="user"], textarea, #prompt-textarea';
  const UI_ERROR_EXCLUDE =
    PROVIDER === "gemini"
      ? `${UI_ERROR_EXCLUDE_BASE}, user-query, model-response, rich-textarea, .cdk-live-announcer-element, .cdk-visually-hidden, [aria-live="polite"]`
      : UI_ERROR_EXCLUDE_BASE;

  function isExcludedGeminiStatusNode(node) {
    if (!node || PROVIDER !== "gemini") return false;
    const tag = String(node.tagName || "").toUpperCase();
    if (tag === "USER-QUERY" || tag === "MODEL-RESPONSE" || tag === "RICH-TEXTAREA") return true;
    const cls = String(node.className || "");
    if (/\bcdk-live-announcer-element\b|\bcdk-visually-hidden\b/i.test(cls)) return true;
    const ariaLive = String((typeof node.getAttribute === "function" && node.getAttribute("aria-live")) || "").toLowerCase();
    if (ariaLive === "polite") return true;
    return false;
  }

  function extractUiErrorText() {
    try {
      if (!document || typeof document.querySelectorAll !== "function") return "";
      const nodes = Array.from(document.querySelectorAll(UI_ERROR_SELECTOR) || []);
      for (const node of nodes) {
        if (!node) continue;
        if (isExcludedGeminiStatusNode(node)) continue;
        if (typeof node.closest === "function" && node.closest(UI_ERROR_EXCLUDE)) continue;
        if (!isVisibleDomElement(node)) continue;
        let source = node;
        if (typeof node.cloneNode === "function") {
          try {
            const clone = node.cloneNode(true);
            if (clone && typeof clone.querySelectorAll === "function") {
              const stripSel =
                PROVIDER === "gemini"
                  ? '.markdown, pre, code, user-query, model-response, rich-textarea, .cdk-live-announcer-element, .cdk-visually-hidden, [aria-live="polite"]'
                  : ".markdown, pre, code";
              Array.from(clone.querySelectorAll(stripSel) || []).forEach((n) => {
                try {
                  n.remove();
                } catch (_) {}
              });
            }
            if (clone) source = clone;
          } catch (_) {}
        }
        const txt = String(source.innerText || source.textContent || "").replace(/\s+/g, " ").trim();
        if (txt) return txt.slice(0, 240);
      }
    } catch (_) {}
    return "";
  }

  // Spec v4.7 1.2: one question, one answer. An idle page whose last turn never closed (stream cut, sentinel /
  // prepare failure, or a lone user bubble with no reply below it) is an unfinished turn.
  function checkTurnIncomplete() {
    try {
      if (isSseActive() || isGeneratingState() || isBusySending) return false;
      const ds = (document.documentElement && document.documentElement.dataset) || {};
      if (ds.relayStreamIncomplete === "1" || ds.relayTurnIncomplete === "1") return true;
      const nodes = queryConversationTurns();
      if (nodes.length === 0) return false;
      for (let i = nodes.length - 1; i >= 0; i--) {
        const n = nodes[i];
        if (!isVisibleDomElement(n)) continue;
        return isUserTurnNode(n);
      }
    } catch (_) {}
    return false;
  }

  function hasErrorState() {
    return Boolean(extractUiErrorText() || checkTurnIncomplete());
  }

  function readAvailableModelsCatalog() {
    if (PROVIDER !== "chatgpt") {
      // Only observed model-picker options qualify; never infer a catalog from chat text.
      const models = [];
      const seen = new Set();
      const selectors = '[role="option"][data-model-id], [role="menuitemradio"], button[data-model-id], [data-testid*="model-selector"] [role="option"], model-selector [role="option"]';
      for (const node of document.querySelectorAll(selectors)) {
        if (!isVisibleDomElement(node)) continue;
        const title = String(node.innerText || node.textContent || '').trim();
        const declared = String(node.getAttribute('data-model-id') || '').trim();
        if (!title || title.length > 120 || (!declared && !/^(?:Gemini|Claude|Sonnet|Opus|Haiku|Pro|Flash|Fast|Thinking)\b/i.test(title))) continue;
        const slug = declared || title;
        if (seen.has(slug)) continue;
        seen.add(slug);
        models.push({slug, title});
      }
      return models;
    }
    try {
      const dsRaw =
        document.documentElement && document.documentElement.dataset
          ? document.documentElement.dataset.relayModelsCatalog
          : "";
      if (dsRaw) {
        const parsed = JSON.parse(dsRaw);
        if (Array.isArray(parsed) && parsed.length > 0) {
          return parsed;
        }
      }
    } catch (_) {}
    try {
      const raw = localStorage.getItem(MODELS_CACHE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        const list = Array.isArray(parsed)
          ? parsed
          : parsed && Array.isArray(parsed.models)
            ? parsed.models
            : [];
        if (list.length > 0) {
          return list;
        }
      }
    } catch (_) {}
    return [];
  }

  function resolveModelDisplayName(slugOrTitle, catalog) {
    const raw = String(slugOrTitle || "").trim();
    if (!raw) {
      return "";
    }
    if (Array.isArray(catalog)) {
      const hit = catalog.find(
        (m) =>
          m &&
          (String(m.slug || "").toLowerCase() === raw.toLowerCase() ||
            String(m.title || "").toLowerCase() === raw.toLowerCase())
      );
      if (hit && hit.title) {
        const t = String(hit.title).trim();
        const s = String(hit.slug || "").trim();
        if (s && !t.toLowerCase().includes(`(${s.toLowerCase()})`)) {
          return `${t} (${s})`;
        }
        return t;
      }
    }
    return raw;
  }

  function cleanGeminiModelBadgeText(rawText) {
    let s = String(rawText || "")
      .replace(/[\u200B-\u200D\uFEFF]/g, "")
      .replace(/\s+/g, " ")
      .trim();
    if (!s) return "";
    for (let i = 0; i < 4; i++) {
      const next = s
        .replace(
          /^(?:keyboard_arrow_down|keyboard_arrow_up|arrow_drop_down|arrow_drop_up|expand_more|expand_less|chevron_down|chevron_up|auto_awesome|spark|check_circle|check)\s+/i,
          ""
        )
        .replace(
          /(?:\s*|(?:(?=[a-z_])))(?:keyboard_arrow_down|keyboard_arrow_up|arrow_drop_down|arrow_drop_up|expand_more|expand_less|chevron_down|chevron_up|auto_awesome|spark|check_circle|check)$/i,
          ""
        )
        .replace(/[\s⌄▾▼∨⌃▴▲]+$/g, "")
        .trim();
      if (next === s) break;
      s = next;
    }
    return s;
  }

  function detectCurrentModel(catalog) {
    try {
      const ds = (document.documentElement && document.documentElement.dataset) || {};
      if (ds.relayLiveModelSlug) {
        return resolveModelDisplayName(ds.relayLiveModelSlug, catalog);
      }
      const curConv = getConvUuid();
      const activeConv = String(ds.relayActiveConvUuid || "").trim();
      if (ds.relayActiveModel && (!activeConv || !curConv || activeConv === curConv)) {
        return resolveModelDisplayName(ds.relayActiveModel, catalog);
      }
    } catch (_) {}

    try {
      const u = new URL(window.location.href);
      const urlModel = String(u.searchParams.get("model") || "").trim();
      if (urlModel) {
        return resolveModelDisplayName(urlModel, catalog);
      }
    } catch (_) {}

    if (PROVIDER === "gemini") {
      try {
        const geminiBadgeSelectors = [
          "bard-mode-switcher button",
          '[data-test-id="bard-mode-menu-button"]',
          '[data-test-id*="bard-mode"]',
          '[data-testid*="bard-mode"]',
          'bard-mode-switcher [role="button"]',
          '[data-test-id*="model-selector"] button',
          '[data-testid*="model-selector"] button',
          "model-selector button",
        ];
        for (const sel of geminiBadgeSelectors) {
          const nodes = document.querySelectorAll(sel);
          for (const btn of nodes) {
            if (!isVisibleDomElement(btn)) continue;
            let rawTxt = String(btn.innerText || btn.textContent || "");
            if (typeof btn.cloneNode === "function") {
              try {
                const clone = btn.cloneNode(true);
                if (clone && typeof clone.querySelectorAll === "function") {
                  Array.from(clone.querySelectorAll('mat-icon, .mat-icon, .google-symbols, [aria-hidden="true"]') || []).forEach(
                    (ic) => {
                      try {
                        ic.remove();
                      } catch (_) {}
                    }
                  );
                }
                const cloneTxt = String((clone && (clone.innerText || clone.textContent)) || "").trim();
                if (cloneTxt) rawTxt = cloneTxt;
              } catch (_) {}
            }
            const cleaned = cleanGeminiModelBadgeText(rawTxt);
            if (
              cleaned &&
              cleaned.length <= 64 &&
              !/^(menu|菜单|switch model|切换模型|select model|选择模型)$/i.test(cleaned)
            ) {
              return resolveModelDisplayName(cleaned, catalog);
            }
          }
        }
      } catch (_) {}
    }

    try {
      const selectors = [
        'button[data-testid="model-switcher-dropdown-button"]',
        'button[data-testid*="model-switcher"]',
        'button[aria-label*="Model selector"]',
        'button[aria-label*="模型选择器"]',
        'header button[aria-haspopup="menu"]',
        'main form button[aria-haspopup="menu"]',
      ];
      for (const sel of selectors) {
        const nodes = document.querySelectorAll(sel);
        for (const btn of nodes) {
          const txt = (btn.innerText || btn.textContent || "").replace(/\s+/g, " ").trim();
          if (
            txt &&
            txt.length <= 42 &&
            (/gpt|o1|o3|o4|auto|thinking|pro|mini|plus|gemini|flash|claude|sonnet|opus|haiku/i.test(txt) ||
              (Array.isArray(catalog) &&
                catalog.some(
                  (m) =>
                    m &&
                    m.title &&
                    txt.toLowerCase().includes(String(m.title).toLowerCase())
                )))
          ) {
            return resolveModelDisplayName(txt, catalog);
          }
        }
      }
    } catch (_) {}

    return "";
  }

  function findCatalogModelEntry(modelKey, catalog) {
    if (!Array.isArray(catalog) || catalog.length === 0) return null;
    const raw = String(modelKey || "").trim();
    if (!raw) return null;
    const low = raw.toLowerCase();
    const parenMatch = raw.match(/\(([^()]+)\)\s*$/);
    const parenSlug = parenMatch ? parenMatch[1].trim().toLowerCase() : "";
    return (
      catalog.find(
        (m) =>
          m &&
          (String(m.slug || "").toLowerCase() === low ||
            (parenSlug && String(m.slug || "").toLowerCase() === parenSlug) ||
            String(m.title || "").toLowerCase() === low)
      ) || null
    );
  }

  function cleanEffortPillText(rawText) {
    return String(rawText || "")
      .replace(/\s+/g, " ")
      .replace(/^(?:思考强度|推理强度|Reasoning)[:：\s]*/i, "")
      .replace(/[\s⌄▾▼∨⌃▴▲]+$/g, "")
      .trim();
  }

  function findThinkingSiblingEntry(entry, hint, catalog) {
    if (!Array.isArray(catalog) || catalog.length === 0) return null;
    const rawSlug = String((entry && entry.slug) || hint || "").trim().toLowerCase();
    const m = rawSlug.match(/^(gpt-\d+(?:-\d+)?)(?:-instant)?$/);
    if (!m) return null;
    const want = `${m[1]}-thinking`;
    return catalog.find((it) => it && String(it.slug || "").trim().toLowerCase() === want) || null;
  }

  function resolveRawEffortId(rawEffort, catalog, currentModelHint) {
    const clean = cleanEffortPillText(rawEffort);
    if (!clean) return "";
    const low = clean.toLowerCase();
    if (["none", "instant", "未开启思考", "无", "即时"].includes(low)) return "none";

    const activeEntry = findCatalogModelEntry(currentModelHint, catalog);
    const siblingEntry = findThinkingSiblingEntry(activeEntry, currentModelHint, catalog);
    const primaryEntries = [activeEntry, siblingEntry].filter(Boolean);
    const allEntries = primaryEntries.length > 0
      ? [...primaryEntries, ...(Array.isArray(catalog) ? catalog : [])]
      : Array.isArray(catalog) ? catalog : [];

    for (const m of allEntries) {
      if (!m) continue;
      if (Array.isArray(m.efforts)) {
        for (const eid of m.efforts) {
          const normId = String(eid || "").trim().toLowerCase();
          if (normId && normId === low) return normId;
        }
      }
      if (Array.isArray(m.effort_items)) {
        for (const it of m.effort_items) {
          if (!it) continue;
          const itId = String(it.id || "").trim().toLowerCase();
          if (itId && itId === low) return itId;
        }
      }
    }

    for (const m of primaryEntries) {
      if (!m || !Array.isArray(m.effort_items)) continue;
      for (const it of m.effort_items) {
        if (!it) continue;
        const itId = String(it.id || "").trim().toLowerCase();
        const itLbl = String(it.label || "").trim().toLowerCase();
        const itFull = String(it.full_label || "").trim().toLowerCase();
        if (itId && (itLbl === low || (itFull && itFull === low))) {
          return itId;
        }
      }
    }

    const declaredSource =
      (activeEntry && Array.isArray(activeEntry.efforts) && activeEntry.efforts.length > 0 && activeEntry) ||
      (siblingEntry && Array.isArray(siblingEntry.efforts) && siblingEntry.efforts.length > 0 && siblingEntry) ||
      null;
    const declared = declaredSource
      ? declaredSource.efforts.map((e) => String(e || "").trim().toLowerCase()).filter(Boolean)
      : [];

    const tierPrefsByAlias = {
      低: ["min", "light", "low", "minimal"],
      轻度: ["min", "light", "low", "minimal"],
      极简: ["minimal", "min", "light", "low"],
      快速思考: ["min", "light", "low", "minimal"],
      中: ["standard", "medium"],
      标准: ["standard", "medium"],
      思考中: ["standard", "medium"],
      高: ["extended", "high"],
      深度: ["extended", "high"],
      进阶思考: ["extended", "high"],
      极高: ["xhigh", "max", "ultra"],
      最高: ["max", "xhigh", "ultra"],
      深入: ["max", "ultra", "xhigh"],
      超强: ["ultra", "max", "xhigh"],
      深度思考: ["max", "xhigh", "ultra"],
    };
    const prefs = tierPrefsByAlias[clean] || tierPrefsByAlias[low];
    if (prefs) {
      for (const cand of prefs) {
        if (declared.includes(cand)) return cand;
      }
      return prefs[0] === "xhigh" && declared.length === 0 ? "max" : prefs[0];
    }

    for (const m of allEntries) {
      if (!m || !Array.isArray(m.effort_items)) continue;
      for (const it of m.effort_items) {
        if (!it) continue;
        const itId = String(it.id || "").trim().toLowerCase();
        const itLbl = String(it.label || "").trim().toLowerCase();
        const itFull = String(it.full_label || "").trim().toLowerCase();
        if (itId && (itLbl === low || (itFull && itFull === low))) {
          return itId;
        }
      }
    }

    return /^[a-z0-9_-]+$/i.test(clean) ? low : "";
  }

  function detectCurrentEffort(catalog, currentModelHint) {
    // 0. Live React Fiber selectedModel.thinkingEffort synced from MAIN world hook
    try {
      const ds = (document.documentElement && document.documentElement.dataset) || {};
      if (ds.relayLiveEffortId) {
        const liveResolved = resolveRawEffortId(ds.relayLiveEffortId, catalog, currentModelHint);
        if (liveResolved) return liveResolved;
      }
    } catch (_) {}

    const knownLabels = new Set();
    if (Array.isArray(catalog)) {
      for (const m of catalog) {
        if (m && Array.isArray(m.effort_items)) {
          for (const it of m.effort_items) {
            if (it && it.label) knownLabels.add(String(it.label).trim().toLowerCase());
            if (it && it.full_label) knownLabels.add(String(it.full_label).trim().toLowerCase());
            if (it && it.id) knownLabels.add(String(it.id).trim().toLowerCase());
          }
        }
      }
    }

    // 1. Live composer effort button on the page (e.g. "极高 ⌄" / "高 ⌄"), normalized to raw official English ID
    try {
      const selectors = [
        'button[data-testid*="reasoning"]',
        'button[data-testid*="effort"]',
        'button[data-testid*="thinking"]',
        'button[aria-label*="Reasoning"]',
        'button[aria-label*="推理"]',
        'button[aria-label*="思考"]',
        'main form button[aria-haspopup="menu"]',
      ];
      for (const sel of selectors) {
        const nodes = document.querySelectorAll(sel);
        for (const btn of nodes) {
          const rawTxt = (btn.innerText || btn.textContent || btn.getAttribute("aria-label") || "").trim();
          const cleaned = cleanEffortPillText(rawTxt);
          if (
            cleaned &&
            cleaned.length <= 28 &&
            (knownLabels.has(cleaned.toLowerCase()) ||
              /^(none|instant|min|light|standard|extended|max|xhigh|minimal|low|medium|high|ultra|低|中|高|极高|轻度|标准|深度|最高|深入|超强|极简|即时|未开启思考|快速思考|思考中|进阶思考|深度思考)$/i.test(
                cleaned
              ))
          ) {
            const resolved = resolveRawEffortId(cleaned, catalog, currentModelHint);
            if (resolved) return resolved;
          }
        }
      }
    } catch (_) {}

    // 2. Fallback to latest conversation/POST metadata when composer pill is hidden or absent
    try {
      const ds = (document.documentElement && document.documentElement.dataset) || {};
      const curConv = getConvUuid();
      const activeConv = String(ds.relayActiveConvUuid || "").trim();
      if (ds.relayActiveEffort && (!activeConv || !curConv || activeConv === curConv)) {
        return resolveRawEffortId(ds.relayActiveEffort, catalog, currentModelHint);
      }
    } catch (_) {}

    return "";
  }

  function setOutgoingFetchOverrides(targetModel, reasoningEffort) {
    try {
      if (!document || !document.documentElement) {
        return;
      }
      const catalog = readAvailableModelsCatalog();
      const cleanModel = String(targetModel || "").trim();
      const cleanEffort = String(reasoningEffort || "").trim();

      let resolvedSlug = "";
      if (cleanModel && cleanModel.toLowerCase() !== "inherit") {
        const matched = findCatalogModelEntry(cleanModel, catalog);
        resolvedSlug = matched ? String(matched.slug) : cleanModel;
        document.documentElement.dataset.relayOverrideModel = resolvedSlug;
      } else {
        delete document.documentElement.dataset.relayOverrideModel;
      }

      if (cleanEffort && cleanEffort.toLowerCase() !== "inherit" && cleanEffort.toLowerCase() !== "auto") {
        const lowEffort = cleanEffort.toLowerCase();
        // Check model-specific effort_items first so 5-tier models distinguish 极高 (xhigh) vs 深入 (max)
        let targetForEffort = resolvedSlug || String((document.documentElement.dataset || {}).relayActiveModel || "");
        if (/^(gpt-6|gpt-6-instant)$/i.test(targetForEffort) && !/^(instant|none|即时|未开启思考)$/i.test(cleanEffort)) {
          targetForEffort = "gpt-6-thinking";
        } else if (/^(gpt-5-6|gpt-5-6-instant)$/i.test(targetForEffort) && !/^(instant|none|即时|未开启思考)$/i.test(cleanEffort)) {
          targetForEffort = "gpt-5-6-thinking";
        }
        let exactItemId = "";
        const targetEntry = findCatalogModelEntry(targetForEffort, catalog);
        if (targetEntry && Array.isArray(targetEntry.effort_items)) {
          const hitItem = targetEntry.effort_items.find(
            (it) =>
              it &&
              (String(it.id || "").trim().toLowerCase() === lowEffort ||
                String(it.label || "").trim().toLowerCase() === lowEffort ||
                String(it.full_label || "").trim().toLowerCase() === lowEffort)
          );
          if (hitItem && hitItem.id) {
            exactItemId = String(hitItem.id).trim().toLowerCase();
          }
        }
        const effortSlugMap = {
          即时: "instant",
          未开启思考: "none",
          轻度: "light",
          标准: "standard",
          深度: "extended",
          极高: "max",
          深入: "max",
          超强: "ultra",
          最高: "max",
          极简: "minimal",
          低: "low",
          中: "medium",
          高: "high",
          xhigh: "xhigh",
          min: "min",
          heavy: "max",
          deep: "extended",
        };
        const mappedEffort =
          exactItemId ||
          effortSlugMap[cleanEffort] ||
          effortSlugMap[lowEffort] ||
          lowEffort;
        document.documentElement.dataset.relayOverrideEffort = mappedEffort;
      } else {
        delete document.documentElement.dataset.relayOverrideEffort;
      }
    } catch (_) {}
  }

  function findComposerElement() {
    const selectors = [
      ...(SITE.composer ? [SITE.composer] : []),
      "#prompt-textarea",
      'div#prompt-textarea[contenteditable="true"]',
      'div.ProseMirror[contenteditable="true"]',
      'textarea[data-id="root"]',
      'textarea[placeholder*="Message"]',
      'textarea[placeholder*="询问"]',
      'textarea[placeholder*="发消息"]',
      'div[contenteditable="true"][role="textbox"]',
    ];
    let fallbackEl = null;
    for (const sel of selectors) {
      const nodes =
        typeof document.querySelectorAll === "function"
          ? Array.from(document.querySelectorAll(sel))
          : [];
      for (const node of nodes) {
        if (node && node.offsetParent !== null && isVisibleDomElement(node)) {
          return node;
        }
        if (node && !fallbackEl) {
          fallbackEl = node;
        }
      }
      const single = document.querySelector(sel);
      if (single && single.offsetParent !== null && isVisibleDomElement(single)) {
        return single;
      }
      if (single && !fallbackEl) {
        fallbackEl = single;
      }
    }
    return PROVIDER === "chatgpt" ? fallbackEl : null;
  }

  function findSendButton() {
    const selectors = [
      ...(SITE.send ? [SITE.send] : []),
      'button[data-testid="send-button"]',
      'button[data-testid*="send"]',
      'button[aria-label*="Send prompt"]',
      'button[aria-label*="Send message"]',
      'button[aria-label*="发送提示"]',
      'button[aria-label*="发送"]',
      'form button[type="submit"]',
    ];
    for (const sel of selectors) {
      const nodes = document.querySelectorAll(sel);
      for (const btn of nodes) {
        if (!btn || btn.disabled || !isVisibleDomElement(btn)) continue;
        if (typeof btn.getAttribute === "function" && btn.getAttribute("aria-disabled") === "true") continue;
        if (PROVIDER !== "chatgpt") {
          const cls = String(btn.className || "");
          const aria = String((typeof btn.getAttribute === "function" && btn.getAttribute("aria-label")) || "");
          if (/\bstop(?:-button)?\b/i.test(cls) || /\bstop\b|停止/i.test(aria)) continue;
        }
        return btn;
      }
    }
    return null;
  }

  function collapseReceiptWhitespace(raw) {
    return String(raw || "")
      .replace(/[\u200B-\u200D\uFEFF]/g, "")
      .replace(/\s+/g, " ")
      .trim();
  }

  function stripUserNodeChrome(raw, expectedNorm) {
    let s = collapseReceiptWhitespace(raw);
    if (!s) return "";
    if (expectedNorm && s === expectedNorm) return s;
    // Strip Gemini screen-reader prefixes ("You said", "你说过", "你说", etc.)
    s = s.replace(/^(?:you\s+said|你说过|你说|你說過|你說)\s*[:：]?\s*/i, "").trim();
    if (expectedNorm && s === expectedNorm) return s;
    // Strip trailing Angular <mat-icon> ligatures / action button text
    const tailRe =
      /(?:\s+|(?<=[^\w]))(?:edit|expand_more|expand_less|keyboard_arrow_down|keyboard_arrow_up|chevron_down|chevron_up|content_copy|more_vert|more_horiz|pen_spark|keep_pin|push_pin|编辑|修改|复制|展开|收起)\s*$/i;
    for (let i = 0; i < 6; i++) {
      const next = s.replace(tailRe, "").trim();
      if (next === s) break;
      s = next;
      if (expectedNorm && s === expectedNorm) return s;
    }
    return s;
  }

  function matchesInjectedUserNode(node, injectedRaw) {
    if (!node) return false;
    const expectedNorm = collapseReceiptWhitespace(injectedRaw);
    if (!expectedNorm) return false;
    const candidates = [];
    if (typeof node.innerText === "string" && node.innerText) candidates.push(node.innerText);
    if (typeof node.textContent === "string" && node.textContent && node.textContent !== node.innerText) {
      candidates.push(node.textContent);
    }
    if (typeof node.querySelector === "function") {
      try {
        const qt = node.querySelector(".query-text, [data-test-id*='query-text'], .user-query-bubble-with-background");
        if (qt) {
          const qtTxt = qt.innerText || qt.textContent || "";
          if (qtTxt) candidates.push(qtTxt);
        }
      } catch (_) {}
    }
    for (const raw of candidates) {
      const collapsed = collapseReceiptWhitespace(raw);
      if (!collapsed) continue;
      if (collapsed === expectedNorm) return true;
      const stripped = stripUserNodeChrome(raw, expectedNorm);
      if (stripped === expectedNorm) return true;
      if (expectedNorm.length >= 20) {
        if (collapsed.includes(expectedNorm) || stripped.includes(expectedNorm)) return true;
        const fpLen = Math.min(24, Math.floor(expectedNorm.length / 2));
        const head = expectedNorm.slice(0, fpLen);
        const tail = expectedNorm.slice(-fpLen);
        if (stripped.length >= fpLen && stripped.startsWith(head) && stripped.endsWith(tail)) {
          return true;
        }
      }
    }
    return false;
  }

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async function waitForDispatchAcceptance(dispatchId) {
    // Only a correlated HTTP-success conversation POST proves transport acceptance.
    // Cold-start background tabs may take 15-25s for Sentinel PoW + /prepare before POST /conversation.
    // Spec v4.7 1.2: loop cap AND wall clock - Chrome's intensive throttling can stretch each 120ms sleep to ~60s.
    const deadline = Date.now() + 25000;
    for (let attempt = 0; attempt < 209 && Date.now() < deadline; attempt++) {
      const ds = document.documentElement && document.documentElement.dataset;
      if (!ds || ds.relayDispatchId !== dispatchId) return "unconfirmed";
      if (ds.relayDispatchStatus === "accepted") return "accepted";
      if (ds.relayDispatchStatus === "failed") return "failed";
      await sleep(120);
    }
    return "unconfirmed";
  }

  // Spec v4.3 Q2: after a live-steering send, wait (max ~6 s) for either a correlated accepted POST, a failure, or proof
  // that the page consumed the text (composer emptied). Text still sitting in the composer = nothing was sent.
  async function waitForSteerAcceptance(dispatchId, injected) {
    const probe = String(injected || "").slice(0, 24);
    const deadline = Date.now() + 6500;
    for (let i = 0; i < 50 && Date.now() < deadline; i++) {
      const ds = document.documentElement && document.documentElement.dataset;
      if (!ds || ds.relayDispatchId !== dispatchId) return "unconfirmed";
      if (ds.relayDispatchStatus === "accepted") return "accepted";
      if (ds.relayDispatchStatus === "failed") return "failed";
      if (i >= 8) {
        const left = readComposerCleanText();
        if (!left || !probe || left.indexOf(probe) < 0) return "accepted";
      }
      await sleep(120);
    }
    return "not_taken";
  }

  function showBridgeToast(text) {
    try {
      let toast = document.getElementById("relaystudio-bridge-toast");
      if (!toast) {
        toast = document.createElement("div");
        toast.id = "relaystudio-bridge-toast";
        Object.assign(toast.style, {
          position: "fixed",
          top: "14px",
          right: "18px",
          zIndex: "2147483647",
          background: "#0F172A",
          color: "#F8FAFC",
          padding: "8px 14px",
          borderRadius: "999px",
          fontSize: "12.5px",
          fontWeight: "600",
          fontFamily: "system-ui, -apple-system, 'Microsoft YaHei UI', sans-serif",
          boxShadow: "0 10px 25px rgba(15, 23, 42, 0.25)",
          border: "1px solid rgba(56, 189, 248, 0.4)",
          transition: "opacity 0.22s ease, transform 0.22s ease",
          pointerEvents: "none",
        });
        document.body.appendChild(toast);
      }
      toast.textContent = "⚡ RelayStudio · " + text;
      toast.style.opacity = "1";
      toast.style.transform = "translateY(0)";
      clearTimeout(toast._hideTimer);
      toast._hideTimer = setTimeout(() => {
        toast.style.opacity = "0";
        toast.style.transform = "translateY(-6px)";
      }, 3200);
    } catch (_) {}
  }

  function setInputText(el, text) {
    el.focus();
    const isContentEditable =
      el.isContentEditable || el.getAttribute("contenteditable") === "true";

    if (!isContentEditable && (el.tagName === "TEXTAREA" || el.tagName === "INPUT")) {
      const proto =
        el.tagName === "TEXTAREA"
          ? window.HTMLTextAreaElement.prototype
          : window.HTMLInputElement.prototype;
      const nativeSetter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
      if (nativeSetter) {
        nativeSetter.call(el, text);
      } else {
        el.value = text;
      }
      el.dispatchEvent(new InputEvent("input", { bubbles: true, data: text, inputType: "insertText" }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
      return;
    }

    try {
      const sel = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(el);
      sel.removeAllRanges();
      sel.addRange(range);
      document.execCommand("delete", false, null);
    } catch (_) {}

    let inserted = false;
    try {
      const dt = new DataTransfer();
      dt.setData("text/plain", text);
      const pasteEvent = new ClipboardEvent("paste", {
        bubbles: true,
        cancelable: true,
        clipboardData: dt,
      });
      el.dispatchEvent(pasteEvent);
      if ((el.innerText || "").trim().length >= Math.min(4, text.trim().length)) {
        inserted = true;
      }
    } catch (_) {}

    if (!inserted) {
      try {
        inserted = document.execCommand("insertText", false, text);
      } catch (_) {}
    }

    if (!inserted || (el.innerText || "").trim().length === 0) {
      el.innerHTML = "";
      const lines = text.split(/\r?\n/);
      for (const line of lines) {
        const p = document.createElement("p");
        p.textContent = line || "\u200B";
        el.appendChild(p);
      }
      el.dispatchEvent(
        new InputEvent("input", {
          bubbles: true,
          cancelable: true,
          inputType: "insertText",
          data: text,
        })
      );
    }
  }

  async function fillAndSendMessage(msg) {
    if (!msg || !msg.text) return false;
    if (msg.provider && String(msg.provider).toLowerCase().replace('openai', 'chatgpt') !== PROVIDER) return {ok:false,retry_safe:true,reason:'provider_mismatch'};
    const priorUserNodes = new Set(Array.from(document.querySelectorAll(SITE.user)));
    const msgId = String(msg.id || "");
    if (msgId && deliveredMsgIds.has(msgId)) {
      return { ok: true, model_switch_skipped: false };
    }
    // Spec v4.3 Q1/Q3: a manual follow-window instruction (typed in the panel) may steer a running turn live and takes
    // priority over a hand-typed draft. Every automatic message keeps the original idle-only, draft-polite rules.
    const manualSteer = msg.manual_send === true && msg.mode === "custom_message";
    // Spec v4.3 Q2 "judge on arrival, 0 s": an archived conversation has no composer at all -> stop-loss immediately.
    if (isConvArchivedPage()) {
      return { ok: false, retry_safe: true, reason: "conv_archived" };
    }
    if (isBusySending) {
      return { ok: false, retry_safe: true, reason: "busy_or_draft" };
    }
    if (!manualSteer && hasUserDraftRaw()) {
      return { ok: false, retry_safe: true, reason: "busy_or_draft" };
    }

    const dispatchId = msgId || "relay_dispatch_" + Date.now().toString(36);
    let sentAttempted = false;
    let acceptanceOutcome = "aborted";
    let steerMode = false;
    isBusySending = true;
    busySendStartedAtMs = Date.now();
    const myBusyStartedAt = busySendStartedAtMs;
    try {
      if (!manualSteer) {
        // Wait at most 3s (6 * 500ms) for a brief tail end of generation; NEVER force-type into a busy turn!
        for (let waitGen = 0; waitGen < 6; waitGen++) {
          if (!isSseActive() && !isGeneratingState()) break;
          await sleep(500);
        }
        if (isSseActive() || isGeneratingState() || hasUserDraftRaw()) {
          return { ok: false, retry_safe: true, reason: "busy_or_draft" };
        }
      }

      let composer = null;
      for (let attempt = 0; attempt < 30; attempt++) {
        composer = findComposerElement();
        if (composer) break;
        if (attempt === 2 && isConvArchivedPage()) {
          return { ok: false, retry_safe: true, reason: "conv_archived" };
        }
        await sleep(350);
      }
      if (!composer) {
        // No send action was attempted; the caller may retry this preflight failure.
        return { ok: false, retry_safe: true };
      }
      if (!manualSteer && (isSseActive() || isGeneratingState() || hasUserDraftRaw())) {
        return { ok: false, retry_safe: true, reason: "busy_or_draft" };
      }
      steerMode = manualSteer && (isSseActive() || isGeneratingState());

      showBridgeToast(
        msg.mode === "new_window_handover"
          ? "正在自动填入新窗口接力指令并发送…"
          : "正在自动填入唤醒消息并发送…"
      );

      // Correlate this click with a real conversation POST, not just a DOM button event.
      document.documentElement.dataset.relayDispatchId = dispatchId;
      document.documentElement.dataset.relayDispatchStatus = "waiting";

      // Mechanism 2: Set MAIN-world fetch JSON body overrides without any DOM menu clicking!
      if (PROVIDER === 'chatgpt') setOutgoingFetchOverrides(
        msg.target_model || msg.model,
        msg.reasoning_effort || msg.effort
      );

      lastInjectedText = String(msg.text || "").replace(/[\u200B-\u200D\uFEFF]/g, "").trim();

      try {
        if (document.documentElement && document.documentElement.dataset) {
          delete document.documentElement.dataset.relayComposerFilled;
        }
        window.dispatchEvent(
          new CustomEvent("relaystudio:fill-composer", {
            detail: { text: msg.text },
          })
        );
      } catch (_) {}
      const filledByHook =
        document.documentElement &&
        document.documentElement.dataset &&
        document.documentElement.dataset.relayComposerFilled === "1";
      if (!filledByHook) {
        setInputText(composer, msg.text);
      }
      await sleep(280);

      let sent = false;
      for (let i = 0; i < 16; i++) {
        const sendBtn = findSendButton();
        if (sendBtn) {
          sentAttempted = true;
          sendBtn.click();
          sent = true;
          break;
        }
        // Spec v4.7 1.2: refill only an empty composer - never stack a second copy onto text that is still there.
        if (i === 5 && !sentAttempted && readComposerCleanText().length === 0) {
          try {
            window.dispatchEvent(
              new CustomEvent("relaystudio:fill-composer", {
                detail: { text: msg.text },
              })
            );
          } catch (_) {}
          const filledRetry =
            document.documentElement &&
            document.documentElement.dataset &&
            document.documentElement.dataset.relayComposerFilled === "1";
          if (!filledRetry) {
            setInputText(composer, msg.text);
          }
        }
        await sleep(180);
      }

      if (!sent) {
        sentAttempted = true;
        composer.focus();
        const enterDown = new KeyboardEvent("keydown", {
          key: "Enter",
          code: "Enter",
          keyCode: 13,
          which: 13,
          bubbles: true,
          cancelable: true,
        });
        composer.dispatchEvent(enterDown);
        try {
          const parentForm = composer.closest("form");
          if (parentForm && typeof parentForm.requestSubmit === "function") {
            parentForm.requestSubmit();
          }
        } catch (_) {}
        sent = true;
      }

      if (sent && PROVIDER !== 'chatgpt') {
        // Third-party adapters confirm a NEW rendered user turn plus consumed composer.
        // Merely clicking Send or clearing the editor is not a delivery receipt.
        // On a fresh Gemini /app or /gem/<slug> handover tab, history.pushState(/app/<id>) can lag 1-3s behind
        // the rendered user bubble and streaming start; wait up to ~3.5s for conv_uuid, then accept if confirmed.
        const deadline = Date.now() + 25000;
        acceptanceOutcome = 'unconfirmed';
        let confirmedBubbleAt = 0;
        let postConfirmPolls = 0;
        for (let attempt = 0; attempt < 209 && Date.now() < deadline; attempt++) {
          const nodes = Array.from(document.querySelectorAll(SITE.user));
          const found =
            nodes.length > priorUserNodes.size &&
            nodes.some((node) => !priorUserNodes.has(node) && matchesInjectedUserNode(node, lastInjectedText));
          const composerCleared = !readComposerCleanText();
          if (found && composerCleared) {
            if (getConvUuid()) {
              acceptanceOutcome = 'accepted';
              break;
            }
            if (!confirmedBubbleAt) {
              confirmedBubbleAt = Date.now();
            }
            postConfirmPolls += 1;
            if (Date.now() - confirmedBubbleAt >= 3500 || postConfirmPolls >= 30) {
              acceptanceOutcome = 'accepted';
              break;
            }
          } else if (confirmedBubbleAt && composerCleared && (found || isGeneratingState() || isSseActive())) {
            if (getConvUuid()) {
              acceptanceOutcome = 'accepted';
              break;
            }
            postConfirmPolls += 1;
            if (Date.now() - confirmedBubbleAt >= 3500 || postConfirmPolls >= 30) {
              acceptanceOutcome = 'accepted';
              break;
            }
          }
          await sleep(120);
        }
      } else if (sent && steerMode) {
        // Live steering: the page may take the text without a classic conversation POST we can correlate. The clock for the
        // judgement starts when the text is in the composer and the send was triggered (never from the panel click).
        acceptanceOutcome = await waitForSteerAcceptance(dispatchId, lastInjectedText);
        if (acceptanceOutcome === "not_taken") {
          try {
            setInputText(composer, "");
          } catch (_) {}
          showBridgeToast("原对话当前无法接收实时引导，将自动换新窗口继续");
          return { ok: false, retry_safe: true, reason: "steer_unavailable" };
        }
      } else {
        acceptanceOutcome = sent ? await waitForDispatchAcceptance(dispatchId) : "unconfirmed";
      }
      if (acceptanceOutcome !== "accepted") {
        // Spec v4.7 1.2: remove only our own leftover draft (exactly the injected text), never a hand-written one.
        try {
          const residual = readComposerCleanText();
          if (residual && lastInjectedText && residual === lastInjectedText) {
            try {
              window.dispatchEvent(new CustomEvent("relaystudio:fill-composer", { detail: { clear: true, text: "" } }));
            } catch (_) {}
            if (readComposerCleanText()) {
              setInputText(composer, "");
            }
            lastInjectedText = "";
          }
        } catch (_) {}
        showBridgeToast("未确认网页已接收消息，本次不标记为已发送");
        // Once the UI was submitted, an unobserved response could still succeed
        // later. Never invite an automatic second click on the same message.
        return { ok: false, uncertain_delivery: true, model_switch_skipped: false };
      }

      if (msgId) deliveredMsgIds.add(msgId);
      maybeClearResolvedHandoverUrl();

      await sleep(600);
      showBridgeToast("已自动发送指令到当前网页会话 ✓");
      return { ok: true, model_switch_skipped: false };
    } finally {
      const ds = document.documentElement && document.documentElement.dataset;
      if (ds && ds.relayDispatchId === dispatchId) {
        delete ds.relayDispatchId;
        delete ds.relayDispatchStatus;
        if (!sentAttempted || acceptanceOutcome === "accepted" || acceptanceOutcome === "failed" || acceptanceOutcome === "not_taken") {
          delete ds.relayOverrideModel;
          delete ds.relayOverrideEffort;
        } else {
          setTimeout(() => {
            try {
              const curDs = document.documentElement && document.documentElement.dataset;
              if (curDs && !curDs.relayDispatchId) {
                delete curDs.relayOverrideModel;
                delete curDs.relayOverrideEffort;
              }
            } catch (_) {}
          }, 35000);
        }
      }
      // A dispatch force-released by the 30s watchdog must not clear the busy flag of a newer dispatch.
      if (busySendStartedAtMs === myBusyStartedAt || busySendStartedAtMs === 0) {
        isBusySending = false;
        busySendStartedAtMs = 0;
      }
    }
  }

  // Spec v4.3 Q5: an archived conversation has no composer, only an "unarchive" control. Cheap checks only:
  // (a) the page hook saw is_archived on the loaded conversation, (b) no composer + a short "unarchive" button.
  function isConvArchivedPage() {
    try {
      const convUuid = getConvUuid();
      const ds = document.documentElement && document.documentElement.dataset;
      if (convUuid && ds && ds.relayArchivedConv === convUuid) return true;
      if (findComposerElement()) return false;
      const btns = document.querySelectorAll("main button");
      const limit = Math.min(btns.length, 200);
      for (let i = 0; i < limit; i++) {
        const t = (btns[i].innerText || btns[i].textContent || "").replace(/\s+/g, " ").trim();
        if (t && t.length <= 24 && /^(取消归档|撤销归档|恢复对话|unarchive( chat)?|restore chat)$/i.test(t)) return true;
      }
    } catch (_) {}
    return false;
  }

  function buildLocalTabState() {
    // Spec v4.7 1.2: a send stuck longer than 30s (throttled background timers) must not report is_dispatching forever.
    if (isBusySending && busySendStartedAtMs > 0 && Date.now() - busySendStartedAtMs > 30000) {
      isBusySending = false;
      busySendStartedAtMs = 0;
    }
    try {
      if (typeof CustomEvent === "function" && window && typeof window.dispatchEvent === "function") {
        window.dispatchEvent(new CustomEvent("relaystudio:sync-live-state"));
      }
    } catch (_) {}
    const convUuid = getConvUuid();
    const projectPrefix = getProjectPrefix();
    const handoverMsgId = getHandoverMsgId();
    const pageHints = scanPageTaskHints();
    const availableModels = readAvailableModelsCatalog();
    const curModel = detectCurrentModel(availableModels);
    const sseActive = isSseActive();
    const domGenerating = isGeneratingState();
    const ds = document.documentElement && document.documentElement.dataset;
    const uiErrorText = String(extractUiErrorText() || "");
    const turnIncomplete = Boolean(checkTurnIncomplete());
    const hasComposer = Boolean(findComposerElement());
    return {
      tab_id: TAB_ID,
      provider: PROVIDER,
      conv_uuid: convUuid,
      project_prefix: projectPrefix,
      url: window.location.href,
      title: document.title || "",
      browser: BROWSER_NAME,
      browser_profile: BROWSER_PROFILE,
      is_codex_in_app_browser: IS_CODEX_IN_APP,
      handover_msg_id: handoverMsgId,
      page_hints: pageHints,
      sse_active: sseActive,
      turn_seq: getTurnSeq(),
      is_generating: Boolean(sseActive || domGenerating),
      is_dispatching: Boolean(isBusySending),
      has_user_draft: hasUserDraft(),
      has_error: hasErrorState(),
      is_archived: isConvArchivedPage(),
      can_steer_live: hasComposer,
      has_composer: hasComposer,
      turn_incomplete: turnIncomplete,
      stream_incomplete: Boolean(ds && ds.relayStreamIncomplete === "1"),
      ui_error_text: uiErrorText,
      current_model: curModel,
      current_effort: detectCurrentEffort(availableModels, curModel),
      available_models: availableModels,
    };
  }

  async function stopActiveGenerationIfAny() {
    try {
      const stopBtn = findActiveStopButton();
      if (stopBtn && !stopBtn.disabled && typeof stopBtn.click === "function") {
        stopBtn.click();
      }
      for (let i = 0; i < 16; i++) {
        if (!isSseActive() && !isGeneratingState()) {
          return true;
        }
        await sleep(150);
      }
    } catch (_) {}
    return !isSseActive() && !isGeneratingState();
  }

  if (typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.onMessage) {
    chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
      if (!msg || typeof msg !== "object") return false;
      if (msg.type === "RELAY_EXECUTE_DISPATCH" && msg.message) {
        fillAndSendMessage(msg.message).then((res) => {
          const isOk = typeof res === "object" && res !== null ? Boolean(res.ok) : Boolean(res);
          const skipped = typeof res === "object" && res !== null ? Boolean(res.model_switch_skipped) : false;
          const retrySafe = typeof res === "object" && res !== null ? res.retry_safe === true : false;
          const uncertain = typeof res === "object" && res !== null ? res.uncertain_delivery === true : false;
          const reason = typeof res === "object" && res !== null && res.reason ? String(res.reason) : "";
          sendResponse({
            ok: isOk,
            delivered: isOk,
            uncertain_delivery: uncertain,
            retry_safe: retrySafe,
            reason,
            provider: PROVIDER,
            conv_uuid: getConvUuid(),
            project_prefix: getProjectPrefix(),
            model_switch_skipped: skipped,
          });
        }).catch(() => {
          // An exception after clicking Send does not prove the server rejected it.
          sendResponse({ ok: false, delivered: false, uncertain_delivery: true,
            retry_safe: false, conv_uuid: getConvUuid(), project_prefix: getProjectPrefix() });
        });
        return true;
      }
      if (msg.type === "RELAY_COLLECT_TAB_STATE") {
        sendResponse({ ok: true, state: buildLocalTabState() });
        return false;
      }
      if (msg.type === "RELAY_STOP_GENERATION") {
        stopActiveGenerationIfAny().then((stopped) => {
          sendResponse({ ok: true, stopped: Boolean(stopped), conv_uuid: getConvUuid() });
        }).catch(() => {
          sendResponse({ ok: false, stopped: false, conv_uuid: getConvUuid() });
        });
        return true;
      }
      if (msg.type === "RELAY_ARCHIVE_CONVERSATION" && msg.conv_uuid) {
        const targetUuid = String(msg.conv_uuid).trim();
        const operation = String(msg.operation || "archive").trim().toLowerCase();
        let responded = false;
        const finishArchive = (okVal) => {
          if (responded) return;
          responded = true;
          try {
            window.removeEventListener("relaystudio:archive-conversation-done", onDone);
          } catch (_) {}
          sendResponse({ ok: Boolean(okVal), conv_uuid: targetUuid, operation });
        };
        const onDone = (ev) => {
          const det = (ev && ev.detail) || {};
          if (!det.conv_uuid || String(det.conv_uuid) === targetUuid) {
            finishArchive(Boolean(det.ok === true));
          }
        };
        try {
          window.addEventListener("relaystudio:archive-conversation-done", onDone);
          window.dispatchEvent(
            new CustomEvent("relaystudio:archive-conversation", {
              detail: { conv_uuid: targetUuid, operation },
            })
          );
          setTimeout(() => finishArchive(false), 2500);
        } catch (_) {
          finishArchive(false);
        }
        return true;
      }
      return false;
    });
  }

  async function directPollFallback(localState) {
    if (isBusySending || IS_CODEX_IN_APP) {
      return;
    }
    if (!localState.conv_uuid && !localState.handover_msg_id) {
      return;
    }
    try {
      const resp = await fetch(`${BRIDGE_BASE}/web-bridge/poll`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(localState),
      });
      if (!resp.ok) return;
      const data = await resp.json();
      if (!data || !Array.isArray(data.messages) || data.messages.length === 0) {
        return;
      }
      for (const msg of data.messages) {
        const result = await fillAndSendMessage(msg);
        if (result && result.ok && msg.id) {
          await fetch(`${BRIDGE_BASE}/web-bridge/ack-deliver`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              msg_id: String(msg.id),
              tab_id: localState.tab_id,
              provider: PROVIDER,
              conv_uuid: getConvUuid(),
              project_prefix: getProjectPrefix(),
            }),
          });
        }
      }
    } catch (_) {}
  }

  async function reportStateAndPollIfNeeded() {
    // Report tab state continuously even while isBusySending is true (is_dispatching: true)!
    const localState = buildLocalTabState();

    // Always prefer reporting to background.js shuttle; only fallback to direct poll if runtime.sendMessage fails!
    if (typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.sendMessage) {
      try {
        chrome.runtime.sendMessage(
          { type: "RELAY_TAB_STATE_REPORT", state: localState },
          (resp) => {
            if (chrome.runtime.lastError || !resp || !resp.shuttle_active) {
              shuttleConnected = false;
              directPollFallback(localState);
            } else {
              shuttleConnected = true;
            }
          }
        );
        return;
      } catch (_) {}
    }

    await directPollFallback(localState);
  }

  setInterval(reportStateAndPollIfNeeded, POLL_INTERVAL_MS);
  setTimeout(reportStateAndPollIfNeeded, 700);
})();
