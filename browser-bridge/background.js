/**
 * 【组块 B1】RelayStudio Browser Bridge Service Worker (MV3)
 * - 2 秒按浏览器聚合班车（将同浏览器内所有 ChatGPT 标签页合并为 1 次批量心跳）
 * - 自动为已打开但未缓存的 ChatGPT 标签页注入 bridge-page-hook.js (MAIN) 与 bridge-content.js
 * - 汇总账号真实模型与思考强度目录 (available_models) 同步至本地 :8766
 * - 静默后台打开换窗交接标签页（保留 /g/g-p-... 项目前缀，active: false 不抢焦点）
 * - 同浏览器多标签页 1 秒错峰下发填词指令
 */

const BRIDGE_BASE = "http://127.0.0.1:8766";
const SHUTTLE_INTERVAL_MS = 2000;
const STAGGER_DISPATCH_MS = 1000;
const TAB_CACHE_STALE_MS = 4000;
const TAB_PROBE_TIMEOUT_MS = 1200;

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
let effectiveBrowserProfile = IS_CODEX_IN_APP ? "CodexInApp:Default" : `${BROWSER_NAME}:Default`;
let browserInstanceId =
  "inst_" +
  BROWSER_NAME.toLowerCase() +
  "_" +
  Math.random().toString(36).slice(2, 10) +
  "_" +
  Date.now().toString(36);

if (!IS_CODEX_IN_APP && typeof chrome !== "undefined" && chrome.storage && chrome.storage.local) {
  try {
    chrome.storage.local.get(["relay_browser_instance_id", "relay_bound_profile_key"], (items) => {
      if (items && items.relay_browser_instance_id) {
        browserInstanceId = String(items.relay_browser_instance_id);
      } else {
        try {
          chrome.storage.local.set({ relay_browser_instance_id: browserInstanceId });
        } catch (_) {}
      }
      if (items && items.relay_bound_profile_key) {
        effectiveBrowserProfile = String(items.relay_bound_profile_key);
      }
    });
  } catch (_) {}
}

const tabStateCache = new Map();
const injectedTabIds = new Set();
const openedHandoverMsgIds = new Set();
const completedRetireIds = new Set();
const inFlightDispatchTabs = new Set();
let cachedAvailableModels = [];
let shuttleBusy = false;

function extractConvUuidFromUrl(url) {
  const m = String(url || "").match(/\/c\/([0-9a-fA-F-]{36})/);
  return m ? m[1] : "";
}

function extractProjectPrefixFromUrl(url) {
  const m = String(url || "").match(/^(https:\/\/chatgpt\.com\/g\/g-p-[a-zA-Z0-9_-]+)/);
  return m ? m[1] : "";
}

function extractHandoverMsgIdFromUrl(url) {
  try {
    const u = new URL(String(url || ""));
    return u.searchParams.get("msg_id") || "";
  } catch (_) {
    return "";
  }
}

function upsertTabStateCache(tabIdStr, state, tabMeta) {
  const s = state || {};
  const meta = tabMeta || {};
  const tabModels = Array.isArray(s.available_models) ? s.available_models : [];
  if (tabModels.length > 0) {
    cachedAvailableModels = tabModels;
  }
  const sseActive = Boolean(s.sse_active);
  const domGenerating = Boolean(s.is_generating);
  const turnSeqNum = Number(s.turn_seq || 0);
  const entry = {
    tab_id: tabIdStr,
    conv_uuid: s.conv_uuid || extractConvUuidFromUrl(meta.url),
    project_prefix: s.project_prefix || extractProjectPrefixFromUrl(meta.url),
    url: s.url || meta.url || "",
    title: s.title || meta.title || "",
    handover_msg_id: s.handover_msg_id || extractHandoverMsgIdFromUrl(meta.url),
    page_hints: Array.isArray(s.page_hints) ? s.page_hints : [],
    sse_active: sseActive,
    turn_seq: Number.isFinite(turnSeqNum) && turnSeqNum >= 0 ? turnSeqNum : 0,
    is_generating: Boolean(sseActive || domGenerating),
    is_dispatching: Boolean(s.is_dispatching),
    has_user_draft: Boolean(s.has_user_draft),
    has_error: Boolean(s.has_error),
    current_model: String(s.current_model || ""),
    current_effort: String(s.current_effort || ""),
    available_models: tabModels.length > 0 ? tabModels : cachedAvailableModels,
    updated_at: Date.now(),
  };
  tabStateCache.set(tabIdStr, entry);
  return entry;
}

async function ensureTabScriptsInjected(tabId) {
  const tabKey = String(tabId);
  if (injectedTabIds.has(tabKey)) {
    return;
  }
  injectedTabIds.add(tabKey);
  if (!chrome.scripting || typeof chrome.scripting.executeScript !== "function") {
    return;
  }
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ["bridge-page-hook.js"],
      world: "MAIN",
    });
  } catch (_) {}
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ["bridge-content.js"],
    });
  } catch (_) {}
}

function probeTabStateWithTimeout(tabId, timeoutMs = TAB_PROBE_TIMEOUT_MS) {
  return new Promise((resolve) => {
    if (!chrome.tabs || typeof chrome.tabs.sendMessage !== "function") {
      resolve(null);
      return;
    }
    let settled = false;
    const finish = (val) => {
      if (settled) return;
      settled = true;
      if (timerId && typeof clearTimeout === "function") {
        try {
          clearTimeout(timerId);
        } catch (_) {}
      }
      resolve(val);
    };
    const timerId = setTimeout(() => finish(null), timeoutMs);
    try {
      chrome.tabs.sendMessage(tabId, { type: "RELAY_COLLECT_TAB_STATE" }, (resp) => {
        const hasErr = Boolean(chrome.runtime && chrome.runtime.lastError);
        if (hasErr || !resp || !resp.ok || !resp.state) {
          finish(null);
          return;
        }
        finish(resp);
      });
    } catch (_) {
      finish(null);
    }
  });
}

function releaseClaimToHub(msgIdStr, tabIdStr, reasonStr) {
  if (!msgIdStr) return;
  fetch(`${BRIDGE_BASE}/web-bridge/release-claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      msg_id: msgIdStr,
      tab_id: tabIdStr || "",
      reason: reasonStr || "retry_safe",
    }),
  }).catch(() => {});
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || typeof msg !== "object") {
    return false;
  }

  if (msg.type === "RELAY_TAB_STATE_REPORT" && sender && sender.tab && typeof sender.tab.id === "number") {
    const tabIdStr = String(sender.tab.id);
    injectedTabIds.add(tabIdStr);
    upsertTabStateCache(tabIdStr, msg.state || {}, sender.tab);
    sendResponse({ ok: true, shuttle_active: true, tab_id: tabIdStr });
    return false;
  }

  return false;
});

chrome.tabs.onRemoved.addListener((tabId) => {
  const key = String(tabId);
  tabStateCache.delete(key);
  injectedTabIds.delete(key);
  inFlightDispatchTabs.delete(key);
});

async function collectOpenChatGptTabs() {
  let tabs = [];
  try {
    tabs = await chrome.tabs.query({
      url: ["https://chatgpt.com/*", "https://chat.openai.com/*"],
    });
  } catch (_) {
    return [];
  }

  const payloads = [];
  for (const t of tabs) {
    if (typeof t.id !== "number") continue;
    const tabIdStr = String(t.id);
    let cached = tabStateCache.get(tabIdStr);
    const cacheFresh = Boolean(
      cached &&
        typeof cached.updated_at === "number" &&
        Date.now() - cached.updated_at <= TAB_CACHE_STALE_MS
    );
    let stateKnown = cacheFresh;
    if (!cacheFresh) {
      await ensureTabScriptsInjected(t.id);
      const probed = await probeTabStateWithTimeout(t.id, TAB_PROBE_TIMEOUT_MS);
      if (probed && probed.ok && probed.state) {
        cached = upsertTabStateCache(tabIdStr, probed.state, t);
        stateKnown = true;
      } else {
        stateKnown = false;
      }
    }
    const safeCached = cached || {};
    const url = t.url || safeCached.url || "";
    const models =
      Array.isArray(safeCached.available_models) && safeCached.available_models.length > 0
        ? safeCached.available_models
        : cachedAvailableModels;
    const sseActive = stateKnown ? Boolean(safeCached.sse_active) : false;
    const isGenerating = stateKnown ? Boolean(safeCached.is_generating || sseActive) : false;
    payloads.push({
      tab_id: tabIdStr,
      conv_uuid: extractConvUuidFromUrl(url) || safeCached.conv_uuid || "",
      project_prefix: extractProjectPrefixFromUrl(url) || safeCached.project_prefix || "",
      url,
      title: t.title || safeCached.title || "ChatGPT",
      browser: BROWSER_NAME,
      browser_profile: effectiveBrowserProfile,
      is_codex_in_app_browser: IS_CODEX_IN_APP,
      handover_msg_id: extractHandoverMsgIdFromUrl(url) || safeCached.handover_msg_id || "",
      page_hints: Array.isArray(safeCached.page_hints) ? safeCached.page_hints : [],
      sse_active: sseActive,
      turn_seq: Number(safeCached.turn_seq || 0),
      is_generating: isGenerating,
      is_dispatching: stateKnown ? Boolean(safeCached.is_dispatching) : false,
      has_user_draft: stateKnown ? Boolean(safeCached.has_user_draft) : false,
      has_error: stateKnown ? Boolean(safeCached.has_error) : false,
      current_model: String(safeCached.current_model || ""),
      current_effort: String(safeCached.current_effort || ""),
      available_models: models,
      state_known: stateKnown,
    });
  }
  return payloads;
}

async function handleShuttleDispatches(dispatches) {
  if (!Array.isArray(dispatches) || dispatches.length === 0) return;
  if (IS_CODEX_IN_APP) {
    for (const d of dispatches) {
      const mId = String((d && d.message && d.message.id) || (d && d.msg_id) || "");
      if (mId) releaseClaimToHub(mId, "", "codex_in_app_isolated");
    }
    return;
  }

  let inPlaceIndex = 0;
  const seenBatchTabs = new Set();
  for (const d of dispatches) {
    if (!d || typeof d !== "object") continue;

    if (d.open_new_tab && d.handover_url) {
      const msgId = String(d.msg_id || "");
      if (msgId && openedHandoverMsgIds.has(msgId)) {
        continue;
      }
      if (msgId) {
        openedHandoverMsgIds.add(msgId);
      }
      try {
        await chrome.tabs.create({
          url: d.handover_url,
          active: false,
        });
        await fetch(`${BRIDGE_BASE}/web-bridge/ack-open`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ msg_id: msgId }),
        });
      } catch (_) {}
      continue;
    }

    const targetTabId = Number(d.tab_id);
    const messageObj = d.message;
    if (!Number.isNaN(targetTabId) && targetTabId > 0 && messageObj) {
      const tabKey = String(targetTabId);
      const msgIdStr = String(messageObj.id || d.msg_id || "");
      if (seenBatchTabs.has(tabKey) || inFlightDispatchTabs.has(tabKey)) {
        releaseClaimToHub(msgIdStr, tabKey, "tab_single_flight_locked");
        continue;
      }
      seenBatchTabs.add(tabKey);
      inFlightDispatchTabs.add(tabKey);

      const delayMs = inPlaceIndex * STAGGER_DISPATCH_MS;
      inPlaceIndex += 1;
      // Zero-disturbance rule (Spec v4.1 Q7): background delivery NEVER switches the user's active tab.
      // Single-flight rule (Spec v4.2 Q13): busy_or_draft releases claim back to pending immediately without blind retries.
      const attemptSendToTab = async (attemptNum = 1) => {
        try {
          await ensureTabScriptsInjected(targetTabId);
          chrome.tabs.sendMessage(
            targetTabId,
            {
              type: "RELAY_EXECUTE_DISPATCH",
              message: messageObj,
            },
            (resp) => {
              const hasErr = Boolean(chrome.runtime && chrome.runtime.lastError);
              if (!hasErr && resp && resp.ok) {
                inFlightDispatchTabs.delete(tabKey);
                fetch(`${BRIDGE_BASE}/web-bridge/ack-deliver`, {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({
                    msg_id: msgIdStr,
                    tab_id: tabKey,
                    conv_uuid: String(resp.conv_uuid || d.conv_uuid || ""),
                  }),
                }).catch(() => {});
              } else if (!hasErr && resp && resp.retry_safe === true) {
                const reasonStr = String(resp.reason || "");
                if (
                  reasonStr === "busy_or_draft" ||
                  reasonStr === "steer_unavailable" ||
                  reasonStr === "conv_archived" ||
                  attemptNum >= 2
                ) {
                  inFlightDispatchTabs.delete(tabKey);
                  releaseClaimToHub(msgIdStr, tabKey, reasonStr || "preflight_retry_exhausted");
                } else {
                  // Transient pre-send script injection miss (zero click attempted): retry once, then release if still not ready.
                  injectedTabIds.delete(tabKey);
                  setTimeout(() => {
                    attemptSendToTab(attemptNum + 1);
                  }, 900);
                }
              } else {
                inFlightDispatchTabs.delete(tabKey);
              }
            }
          );
        } catch (_) {
          inFlightDispatchTabs.delete(tabKey);
        }
      };
      setTimeout(() => {
        attemptSendToTab(1);
      }, delayMs);
    }
  }
}

async function handleShuttleRetireActions(retireActions) {
  if (!Array.isArray(retireActions) || retireActions.length === 0 || IS_CODEX_IN_APP) return;

  let openTabs = [];
  try {
    openTabs = await chrome.tabs.query({
      url: ["https://chatgpt.com/*", "https://chat.openai.com/*"],
    });
  } catch (_) {}

  for (const r of retireActions) {
    if (!r || typeof r !== "object") continue;
    const retireId = String(r.id || "");
    const convUuid = String(r.conv_uuid || "").trim();
    const op = String(r.operation || "archive").trim().toLowerCase();
    if (!convUuid || (retireId && completedRetireIds.has(retireId))) {
      continue;
    }

    const matchedTab = openTabs.find((t) => {
      const tabConv = extractConvUuidFromUrl(t.url);
      if (tabConv && tabConv === convUuid) {
        return true;
      }
      if (r.tab_id && String(t.id) === String(r.tab_id) && (!tabConv || tabConv === convUuid)) {
        return true;
      }
      return false;
    });
    const carrierTab = openTabs.find((t) => t !== matchedTab) || matchedTab || openTabs[0];
    if (!carrierTab || typeof carrierTab.id !== "number") {
      continue;
    }

    if (
      (r.stop_before_action === true || r.stop_before_archive === true) &&
      op !== "unarchive" &&
      matchedTab &&
      typeof matchedTab.id === "number"
    ) {
      try {
        await ensureTabScriptsInjected(matchedTab.id);
        await new Promise((resolve) => {
          chrome.tabs.sendMessage(
            matchedTab.id,
            { type: "RELAY_STOP_GENERATION", conv_uuid: convUuid },
            () => resolve()
          );
        });
      } catch (_) {}
    }

    let cloudOk = false;
    if (r.archive_conversation === false && op === "archive") {
      cloudOk = true;
    } else {
      try {
        await ensureTabScriptsInjected(carrierTab.id);
        const archResp = await new Promise((resolve) => {
          chrome.tabs.sendMessage(
            carrierTab.id,
            { type: "RELAY_ARCHIVE_CONVERSATION", conv_uuid: convUuid, operation: op },
            (resp) => {
              const hasErr = Boolean(chrome.runtime && chrome.runtime.lastError);
              resolve(hasErr ? null : resp);
            }
          );
        });
        cloudOk = Boolean(archResp && archResp.ok === true);
      } catch (_) {
        cloudOk = false;
      }
    }

    if (!cloudOk) {
      continue;
    }

    if (r.close_tab !== false && op !== "unarchive" && matchedTab && typeof matchedTab.id === "number") {
      try {
        const winTabs = matchedTab.windowId
          ? await chrome.tabs.query({ windowId: matchedTab.windowId })
          : openTabs;
        if (Array.isArray(winTabs) && winTabs.length <= 1) {
          await chrome.tabs.update(matchedTab.id, { url: "https://chatgpt.com/" });
        } else if (typeof chrome.tabs.remove === "function") {
          await chrome.tabs.remove(matchedTab.id);
          openTabs = openTabs.filter((t) => t.id !== matchedTab.id);
        }
      } catch (_) {}
    }

    if (retireId) {
      completedRetireIds.add(retireId);
    }

    try {
      await fetch(`${BRIDGE_BASE}/web-bridge/ack-retire`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          retire_id: retireId,
          conv_uuid: convUuid,
          operation: op,
          ok: true,
        }),
      });
    } catch (_) {}
  }
}

async function focusRequestedChatGptTab(tabIdStr) {
  if (!tabIdStr || IS_CODEX_IN_APP) return;
  try {
    const openTabs = await chrome.tabs.query({});
    const matched = Array.isArray(openTabs)
      ? openTabs.find((t) => t && String(t.id) === String(tabIdStr))
      : null;
    if (!matched) return;
    if (
      typeof chrome.tabs.highlight === "function" &&
      typeof matched.windowId === "number" &&
      typeof matched.index === "number"
    ) {
      await chrome.tabs.highlight({ windowId: matched.windowId, tabs: matched.index });
    }
    if (
      chrome.windows &&
      typeof chrome.windows.update === "function" &&
      typeof matched.windowId === "number"
    ) {
      // Spec v4.3 Q4: on Windows { focused: true } alone silently fails for a minimized window - restore it first.
      let winState = "";
      try {
        if (typeof chrome.windows.get === "function") {
          const w = await chrome.windows.get(matched.windowId);
          winState = String((w && w.state) || "");
        }
      } catch (_) {}
      if (winState === "minimized") {
        await chrome.windows.update(matched.windowId, { state: "normal", focused: true });
      } else {
        await chrome.windows.update(matched.windowId, { focused: true });
      }
    }
  } catch (_) {}
}

async function runShuttleTick() {
  if (shuttleBusy) return;
  shuttleBusy = true;
  try {
    const tabsPayload = IS_CODEX_IN_APP ? [] : await collectOpenChatGptTabs();
    // Heartbeat even with 0 ChatGPT tabs: the hub must know this browser is alive so it can ask us to open
    // a background tab (active:false) instead of launching a browser process on top of the user's window.
    const resp = await fetch(`${BRIDGE_BASE}/web-bridge/poll`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        browser: BROWSER_NAME,
        browser_profile: effectiveBrowserProfile,
        browser_instance_id: browserInstanceId,
        is_codex_in_app_browser: IS_CODEX_IN_APP,
        available_models: cachedAvailableModels,
        tabs: tabsPayload,
      }),
    });
    if (!resp.ok) return;
    const data = await resp.json();
    if (
      !IS_CODEX_IN_APP &&
      data &&
      data.bound_profile_key &&
      !String(data.bound_profile_key).toLowerCase().endsWith(":default")
    ) {
      effectiveBrowserProfile = String(data.bound_profile_key);
      if (typeof chrome !== "undefined" && chrome.storage && chrome.storage.local) {
        try {
          chrome.storage.local.set({ relay_bound_profile_key: effectiveBrowserProfile });
        } catch (_) {}
      }
    }
    if (!IS_CODEX_IN_APP && data && data.focus_tab_id) {
      await focusRequestedChatGptTab(String(data.focus_tab_id));
    }
    if (!IS_CODEX_IN_APP && data && Array.isArray(data.dispatches) && data.dispatches.length > 0) {
      await handleShuttleDispatches(data.dispatches);
    }
    if (!IS_CODEX_IN_APP && data && Array.isArray(data.retire_actions) && data.retire_actions.length > 0) {
      await handleShuttleRetireActions(data.retire_actions);
    }
  } catch (_) {
    // Local RelayStudio bridge not running or unreachable; stay silent.
  } finally {
    shuttleBusy = false;
  }
}

setInterval(runShuttleTick, SHUTTLE_INTERVAL_MS);
setTimeout(runShuttleTick, 500);
if (typeof chrome !== "undefined" && chrome.alarms && typeof chrome.alarms.create === "function") {
  try {
    chrome.alarms.create("relay-shuttle-keepalive", { periodInMinutes: 0.5 });
    chrome.alarms.onAlarm.addListener((alarm) => {
      if (!alarm || alarm.name === "relay-shuttle-keepalive") {
        runShuttleTick();
      }
    });
  } catch (_) {}
}
