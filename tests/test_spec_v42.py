"""Spec v4.2 seam tests (T15 ~ T20):
- T15: DesktopCdpBridge Plan C exact app://-/index.html targeting, React Fiber duck-typing & Codex composer isolation
- T16: .codex-global-state.json zero-write read-only model pre-warm & CodexInApp isolation
- T17: Pure '+' task creation (keep peers), task_manage(action='update'), & zero cross-task fuzzy merge
- T18: 4-probe VitalSignsAggregator, STOPPED-origin timer (incl. 30s tier), per-call call_seq_id, & UNKNOWN no-fire
- T19: Self-healing single-flight relay loop (90s AWAITING_WAKEUP, turn_seq reset, retired_uuids lock, new-window promotion, 2-dead-window Tripped)
- T20: Single-flight controllable FIFO pending queue (move/delete/release-claim), draft yield, exact open-tab focus, & activity reconciliation
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
sys.path.insert(0, os.path.dirname(__file__))

import McpReadOnlyShield as shield
import RelayCdp
import test_shield_hub as _hub
from fake_chatgpt_page import FakeChatGptPage

CONV_A = "11111111-1111-4111-8111-111111111111"
CONV_B = "22222222-2222-4222-8222-222222222222"
CONV_C = "33333333-3333-4333-8333-333333333333"


class V42Base(unittest.TestCase):
    setUp = _hub.ShieldHubSeamTests.setUp
    tearDown = _hub.ShieldHubSeamTests.tearDown
    _post_json = _hub.ShieldHubSeamTests._post_json
    _get_json = _hub.ShieldHubSeamTests._get_json
    _write_task = _hub.ShieldHubSeamTests._write_task

    def _wb(self):
        with shield._WEB_BRIDGE_LOCK:
            return shield._load_web_bridge_state(self.wb_state_path)

    def _read_task(self, task_id: str) -> dict:
        with open(os.path.join(self.tasks_root, f"{task_id}.json"), "r", encoding="utf-8") as fh:
            return json.load(fh)

    def _bind(self, key: str, profile: str | None = None, conv: str | None = None):
        if profile:
            self._post_json("/studio/action", {"action": "set_task_composer_config", "session_key": key, "browser_profile": profile})
        if conv:
            self._post_json("/studio/action", {"action": "bind_session", "session_key": key, "conv_uuid": conv})

    def _mcp(self, name: str, arguments: dict, rpc_id="0"):
        return self._post_json("/mcp", {"jsonrpc": "2.0", "id": rpc_id, "method": "tools/call", "params": {"name": name, "arguments": arguments}})


class T15DesktopPlanCSeamTests(V42Base):
    """T15: Plan C exact app://-/index.html target selection, Fiber duck-typed JS isolation, and DesktopAppBridge lifecycle."""

    def setUp(self):
        super().setUp()
        for attr, value in (("_cached_port", None), ("_last_launch_at", 0.0), ("_last_restart_at", 0.0), ("_last_probe_at", 0.0)):
            setattr(shield.DesktopAppBridge, attr, value)

    def test_t15a_pick_targets_locks_only_clean_app_index_and_excludes_pricing_hotkey_and_sandbox(self):
        targets = [
            {
                "id": "HOTKEY",
                "type": "page",
                "title": "ChatGPT Hotkey",
                "url": "app://-/index.html?hostId=local&initialRoute=%2Fhotkey-window",
                "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/HOTKEY",
            },
            {
                "id": "DETACHED",
                "type": "page",
                "title": "Detached",
                "url": "app://-/detached-window.html",
                "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/DETACHED",
            },
            {
                "id": "PRICING_WV",
                "type": "webview",
                "title": "ChatGPT 方案",
                "url": "https://chatgpt.com/?source=codex_app_embedded#pricing",
                "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/PRICING_WV",
            },
            {
                "id": "SANDBOX_WV",
                "type": "webview",
                "title": "Sandbox",
                "url": "codex-sandbox://local/frame.html",
                "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/SANDBOX_WV",
            },
            {
                "id": "MAIN_APP",
                "type": "page",
                "title": "ChatGPT",
                "url": "app://-/index.html",
                "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/MAIN_APP",
            },
        ]
        picked = RelayCdp.pick_targets(targets)
        self.assertIsNotNone(picked.get("main_page"), "Plan C must expose picked['main_page']")
        self.assertEqual(picked["main_page"]["id"], "MAIN_APP")
        self.assertEqual(picked["shell"]["id"], "MAIN_APP")
        self.assertIsNone(picked["webview"], "#pricing embedded webview must never be picked")

        # Without the clean main_page, auxiliary targets alone must NOT be adopted as a valid ChatGPT endpoint.
        aux_only = [t for t in targets if t["id"] != "MAIN_APP"]
        picked_aux = RelayCdp.pick_targets(aux_only)
        self.assertIsNone(picked_aux.get("main_page"))
        ep_aux = RelayCdp.find_cdp_endpoint(
            None,
            probe_fn=lambda: {"running": True, "main_pid": 100, "cmd_ports": [9222], "listen_ports": []},
            http_fn=lambda url: aux_only,
        )
        self.assertIsNone(ep_aux["port"], "endpoint without clean app://-/index.html must not be adopted")

    def test_t15b_native_js_scripts_drive_visible_cloud_fiber_and_strictly_isolate_codex_and_hidden_panels(self):
        """Execute RelayCdp's actual Plan C JS probes in Node against a multi-panel React Fiber DOM."""
        harness = r"""
const fs = require("fs");
const scripts = JSON.parse(fs.readFileSync(0, "utf8"));

const state = {
  codexText: "const x = 1; // local codex draft",
  codexSubmitted: 0,
  hiddenCloudText: "stale hidden cloud draft",
  hiddenSubmitted: 0,
  activeCloudText: "",
  activeSubmitted: 0,
  selectedModel: { slug: "gpt-6-thinking", thinkingEffort: "standard", versionId: "latest" },
  modelChanges: [],
  convId: "11111111-1111-4111-8111-111111111111",
  entries: [{ turnKey: "turn_1", turn: { status: "complete" } }],
  isSubmitting: false,
  isStreaming: false,
  errorMessage: "",
  archived: [],
  startedNewChat: 0,
  navigatedTo: "",
  stopped: 0,
  inCodexView: true,
};

function makeNode(tag, attrs = {}, extra = {}) {
  return Object.assign({
    tagName: tag.toUpperCase(),
    attributes: Object.assign({}, attrs),
    dataset: {},
    style: { display: extra.display || "block", visibility: "visible" },
    disabled: Boolean(extra.disabled),
    innerText: extra.innerText || "",
    textContent: extra.textContent || extra.innerText || "",
    value: extra.value || "",
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k); },
    closest(sel) { return extra.closest ? extra.closest(sel) : null; },
    querySelector(sel) { return extra.querySelector ? extra.querySelector(sel) : null; },
    querySelectorAll(sel) { return extra.querySelectorAll ? extra.querySelectorAll(sel) : []; },
    getBoundingClientRect() { return extra.display === "none" ? { width: 0, height: 0 } : { width: 600, height: 80 }; },
    click() { if (extra.onClick) extra.onClick(); },
    focus() { throw new Error("Zero-Focus-Stealing violation: .focus() must NOT be called on native Plan C!"); },
  }, extra);
}

// 1) Local Codex composer (must NEVER be read, overwritten, or submitted)
const codexForm = makeNode("FORM", { "data-codex-composer": "true" }, {
  __reactFiber$codex: {
    memoizedProps: {
      isHidden: false,
      isWorkConversation: true,
      composerController: {
        getText: () => state.codexText,
        setText: () => { throw new Error("Touched Codex composerController!"); },
      },
    },
    return: null,
  },
  requestSubmit() { state.codexSubmitted++; throw new Error("Submitted Codex form!"); },
});

// 2) Cached hidden cloud composer (React 19 <Activity> hidden tab: isHidden === true)
const hiddenCloudForm = makeNode("FORM", { "data-chatgpt-composer": "" }, {
  display: "none",
  __reactFiber$hidden: {
    memoizedProps: {
      isHidden: true,
      isWorkConversation: false,
      conversationId: "99999999-9999-4999-8999-999999999999",
      composerController: {
        getText: () => state.hiddenCloudText,
        setText: () => { throw new Error("Touched hidden cloud composer!"); },
      },
    },
    return: null,
  },
  requestSubmit() { state.hiddenSubmitted++; },
});

// 3) Active visible cloud composer (deep ancestor props, no fixed level assumptions)
const activeSubmitBtn = makeNode("BUTTON", { type: "submit", "aria-label": "发送" }, {
  disabled: false,
  onClick() {
    state.activeSubmitted++;
    state.activeCloudText = "";
    state.isStreaming = true;
    if (!state.convId) state.convId = "22222222-2222-4222-8222-222222222222";
    state.entries = state.entries.concat([{ turnKey: "turn_" + (state.entries.length + 1), turn: { status: "streaming" } }]);
  },
});

const activeCloudForm = makeNode("FORM", { "data-chatgpt-composer": "" }, {
  querySelector(sel) {
    if (sel.includes('type="submit"') || sel.includes("send")) return activeSubmitBtn;
    return null;
  },
  querySelectorAll(sel) {
    if (sel.includes('type="submit"') || sel.includes("send")) return [activeSubmitBtn];
    return [];
  },
  requestSubmit(btn) {
    (btn || activeSubmitBtn).click();
  },
});

// Chain 9 arbitrary intermediate fibers so no hardcoded level number can accidentally match
let fiberChain = {
  memoizedProps: {
    conversationId: state.convId,
    get entries() { return state.entries; },
    get isSubmitting() { return state.isSubmitting; },
    get isStreaming() { return state.isStreaming; },
    get errorMessage() { return state.errorMessage; },
    onStop: () => { state.stopped++; state.isStreaming = false; },
  },
  return: null,
};
for (let i = 0; i < 5; i++) fiberChain = { memoizedProps: { filler: i }, return: fiberChain };
fiberChain = {
  memoizedProps: {
    isHidden: false,
    isWorkConversation: false,
    get selectedModel() { return state.selectedModel; },
    models: {
      modelConfigBySlug: {
        "gpt-6-thinking": { title: "GPT-6 Thinking", isWorkModeModel: false, thinkingEfforts: ["min", "standard", "extended", "max"] },
        "gpt-6": { title: "GPT-6 Instant", isWorkModeModel: false, thinkingEfforts: [] },
        "gpt-6.1-sol-wm": { title: "GPT-6.1 Sol WM", isWorkModeModel: true, thinkingEfforts: ["standard"] },
        "reserved_gate_internal": { title: "Hidden Gate", isHidden: true },
      },
    },
    onModelChange: (next) => {
      state.modelChanges.push(next);
      state.selectedModel = Object.assign({}, state.selectedModel, next);
    },
    composerController: {
      getText: () => state.activeCloudText,
      setText: (txt) => { state.activeCloudText = String(txt); },
      hasText: () => state.activeCloudText.length > 0,
    },
  },
  return: fiberChain,
};
for (let i = 0; i < 3; i++) fiberChain = { memoizedProps: { wrap: i }, return: fiberChain };
activeCloudForm.__reactFiber$active = fiberChain;

// Sidebar rows + global New Chat button + Back to ChatGPT button
const backBtn = makeNode("BUTTON", { "aria-label": "返回 ChatGPT" }, {
  onClick() { state.inCodexView = false; },
});
const projectNewChatBtn = makeNode("BUTTON", { "aria-label": "在 RelayStudio 项目中开始新聊天" }, {
  innerText: "新聊天",
  onClick() { throw new Error("Clicked project-scoped new chat!"); },
});
const globalNewChatBtn = makeNode("BUTTON", { "aria-label": "新聊天" }, {
  innerText: "新聊天",
  __reactFiber$new: {
    memoizedProps: { projectless: true, onStartChat: () => { state.startedNewChat++; state.convId = ""; state.entries = []; } },
    return: null,
  },
  onClick() { state.startedNewChat++; state.convId = ""; state.entries = []; },
});

function makeSidebarRow(uuid) {
  const innerBtn = makeNode("DIV", {
    role: "button",
    "data-sidebar-cycle-item": "",
    "aria-current": state.convId === uuid ? "page" : "false",
  }, {
    onClick() { state.navigatedTo = uuid; state.convId = uuid; },
  });
  return makeNode("DIV", { "data-sidebar-chatgpt-conversation-key": "chatgpt:conversation:" + uuid }, {
    querySelector(sel) {
      if (sel.includes("aria-current") && state.convId === uuid) return innerBtn;
      if (sel.includes('role="button"') || sel.includes("data-sidebar-cycle-item")) return innerBtn;
      return null;
    },
    __reactFiber$row: {
      memoizedProps: { label: "Row " + uuid },
      return: {
        memoizedProps: {
          onArchive: async () => { state.archived.push(uuid); return true; },
        },
        return: null,
      },
    },
  });
}

// Spec v4.3: the whole page text is never scanned; only the tail of the last turns is peeked at while no task number is known.
const turnEl = makeNode("DIV", { "data-message-author-role": "assistant" }, { textContent: "任务契约 tsk_15b_demo 正在执行" });
const mainEl = makeNode("MAIN", {}, { textContent: "整页旧内容 tsk_main_only_scan 不应被扫描" });

global.window = global;
global.location = { href: "app://-/index.html", protocol: "app:", pathname: "/index.html" };
global.getComputedStyle = (el) => el.style || { display: "block", visibility: "visible" };
global.document = {
  title: "ChatGPT",
  documentElement: { dataset: {} },
  body: mainEl,
  querySelector(sel) {
    if (sel === "main") return mainEl;
    const all = this.querySelectorAll(sel);
    return all.length ? all[0] : null;
  },
  querySelectorAll(sel) {
    if (sel.includes("data-chatgpt-composer")) return [hiddenCloudForm, activeCloudForm];
    if (sel.includes("data-sidebar-chatgpt-conversation-key")) {
      const rows = [makeSidebarRow("11111111-1111-4111-8111-111111111111"), makeSidebarRow("33333333-3333-4333-8333-333333333333")];
      const m = sel.match(/chatgpt:conversation:([0-9a-f-]{36})/i);
      return m ? rows.filter(r => r.getAttribute("data-sidebar-chatgpt-conversation-key").endsWith(m[1])) : rows;
    }
    if (sel.includes("data-message-author-role")) return [turnEl];
    if (sel.includes("create-new-chat-button")) return [];
    if (sel.includes("返回 ChatGPT")) return state.inCodexView ? [backBtn] : [];
    if (sel.includes("button")) return (state.inCodexView ? [backBtn] : []).concat([projectNewChatBtn, globalNewChatBtn, activeSubmitBtn]);
    return [];
  },
};

(async () => {
  const modeRes = eval(scripts.ensure_chat_mode);
  const st1 = eval(scripts.state);
  const navConvRes = eval(scripts.nav_conv);
  // Keep fiberChain root conversationId synced with state.convId
  let root = activeCloudForm.__reactFiber$active;
  while (root.return) root = root.return;
  Object.defineProperty(root.memoizedProps, "conversationId", { get: () => state.convId });

  const navNewRes = eval(scripts.nav_new_chat);
  const stBlank = eval(scripts.state);
  const fillRes = eval(scripts.fill);
  const textAfterFill = state.activeCloudText;
  const sendRes = eval(scripts.send);
  const receiptRes = eval(scripts.dispatch_status);
  const stStreaming = eval(scripts.state);
  const stopRes = eval(scripts.stop);
  const archRes = await eval(scripts.archive);

  console.log(JSON.stringify({
    modeRes,
    st1,
    navConvRes,
    navNewRes,
    stBlankConv: stBlank.conv_uuid,
    fillRes,
    textAfterFill,
    modelChanges: state.modelChanges,
    sendRes,
    receiptRes,
    stStreamingSse: stStreaming.sse_active,
    stopRes,
    archRes,
    archived: state.archived,
    codexText: state.codexText,
    codexSubmitted: state.codexSubmitted,
    hiddenSubmitted: state.hiddenSubmitted,
  }));
})();
"""
        payload = json.dumps({
            "ensure_chat_mode": RelayCdp.script_ensure_chat_mode(),
            "state": RelayCdp.script_state(),
            "nav_conv": RelayCdp.script_nav_conv(CONV_C),
            "nav_new_chat": RelayCdp.script_nav_new_chat(),
            "fill": RelayCdp.script_fill("msg_t15", "请执行 v4.2 自检", "gpt-6-thinking", "最高"),
            "send": RelayCdp.script_send(),
            "dispatch_status": RelayCdp.script_dispatch_status("msg_t15"),
            "stop": RelayCdp.script_stop(),
            "archive": RelayCdp.script_archive(CONV_A),
        })
        proc = subprocess.run(
            ["node", "-e", harness],
            input=payload,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=10,
        )
        self.assertEqual(proc.returncode, 0, msg=f"Node harness failed: {proc.stderr}")
        out = json.loads(proc.stdout.strip())

        self.assertTrue(out["modeRes"]["switched"], "must click 返回 ChatGPT when inside Codex view")
        self.assertTrue(out["st1"]["has_composer"])
        self.assertEqual(out["st1"]["conv_uuid"], CONV_A)
        self.assertEqual(out["st1"]["url"], f"https://chatgpt.com/c/{CONV_A}")
        self.assertEqual(out["st1"]["composer_text"], "", "must read active cloud composer, not Codex or hidden cloud draft")
        self.assertIn("tsk_15b_demo", out["st1"]["page_hints"])
        self.assertNotIn("tsk_main_only_scan", out["st1"]["page_hints"], "Spec v4.3: the full page text must not be scanned")
        self.assertIn("can_steer", out["st1"])

        slugs = [m["slug"] for m in out["st1"]["available_models"]]
        self.assertIn("gpt-6-thinking", slugs)
        self.assertIn("gpt-6", slugs)
        self.assertNotIn("gpt-6.1-sol-wm", slugs, "must filter -wm work models")
        self.assertNotIn("reserved_gate_internal", slugs, "must filter hidden models")

        self.assertTrue(out["navConvRes"]["found"])
        self.assertTrue(out["navNewRes"]["clicked"])
        self.assertEqual(out["stBlankConv"], "")

        self.assertTrue(out["fillRes"]["composer"] and out["fillRes"]["filled"])
        self.assertEqual(out["textAfterFill"], "请执行 v4.2 自检")
        self.assertTrue(len(out["modelChanges"]) >= 1)
        self.assertEqual(out["modelChanges"][-1]["slug"], "gpt-6-thinking")
        self.assertEqual(out["modelChanges"][-1]["thinkingEffort"], "max")

        self.assertTrue(out["sendRes"]["clicked"])
        self.assertEqual(out["receiptRes"]["status"], "accepted")
        self.assertEqual(out["receiptRes"]["conv_uuid"], CONV_B)
        self.assertTrue(out["stStreamingSse"], "isStreaming on Fiber must report sse_active=True")
        self.assertTrue(out["stopRes"]["ok"])
        self.assertTrue(out["archRes"]["ok"])
        self.assertEqual(out["archived"], [CONV_A])
        self.assertEqual(out["codexText"], "const x = 1; // local codex draft")
        self.assertEqual(out["codexSubmitted"], 0)
        self.assertEqual(out["hiddenSubmitted"], 0)


class T16CodexReadOnlyPrewarmTests(V42Base):
    """T16a: .codex-global-state.json cold-start read-only model pre-warm with zero file mutation."""

    def test_t16a_read_codex_cached_models_filters_wm_and_hidden_with_zero_file_writes(self):
        sample = {
            "electron-persisted-atom-state": {
                "chatgpt-last-selected-model-v1": {
                    "slug": "gpt-6-thinking",
                    "thinkingEffort": "max",
                    "versionId": "latest",
                },
                "composer-recent-model-configurations-v1": [
                    {"model": "gpt-6.1-sol", "reasoningEffort": "xhigh", "serviceTier": None},
                    {"model": "gpt-6.1-sol-wm", "reasoningEffort": "standard", "serviceTier": None},
                ],
                "chatgpt-work-models-v1/user-test/acct-1": {
                    "fetchedAt": 1793284495731,
                    "response": {
                        "models": [
                            {
                                "slug": "gpt-6.1-sol-wm",
                                "title": "GPT-6.1 Sol",
                                "description": "适合编程和日常工作",
                                "is_work_mode_model": True,
                                "thinking_efforts": [
                                    {"thinking_effort": "min"},
                                    {"thinking_effort": "standard"},
                                    {"thinking_effort": "extended"},
                                    {"thinking_effort": "xhigh"},
                                    {"thinking_effort": "max"},
                                ],
                            },
                            {
                                "slug": "gpt-6-instant",
                                "title": "GPT-6 Instant",
                                "description": "快速响应",
                                "thinking_efforts": [],
                            },
                            {
                                "slug": "reserved_gate_secret",
                                "title": "Secret",
                                "is_hidden": True,
                            },
                        ]
                    },
                },
            }
        }
        with tempfile.TemporaryDirectory() as tmp:
            state_file = os.path.join(tmp, ".codex-global-state.json")
            raw_bytes = json.dumps(sample, ensure_ascii=False, indent=2).encode("utf-8")
            with open(state_file, "wb") as fh:
                fh.write(raw_bytes)
            past_ns = 1_700_000_000_000_000_000
            os.utime(state_file, ns=(past_ns, past_ns))
            before_stat = os.stat(state_file)

            models = RelayCdp.read_codex_cached_models(state_file)
            after_stat = os.stat(state_file)
            with open(state_file, "rb") as fh:
                after_bytes = fh.read()

            self.assertEqual(after_stat.st_mtime_ns, before_stat.st_mtime_ns, "mtime must not change (strictly read-only)")
            self.assertEqual(after_bytes, raw_bytes, "bytes must not change")

            slugs = [m["slug"] for m in models]
            self.assertIn("gpt-6-thinking", slugs)
            self.assertIn("gpt-6-instant", slugs)
            self.assertIn("gpt-6.1-sol", slugs)
            self.assertFalse(any(s.endswith("-wm") for s in slugs), "no -wm work-mode slug may leak")
            self.assertNotIn("reserved_gate_secret", slugs)

            sol = next(m for m in models if m["slug"] == "gpt-6.1-sol")
            self.assertEqual(sol["title"], "GPT-6.1 Sol")
            self.assertIn("xhigh", sol["efforts"])

            # Verify snapshot pre-warms available_models when live bridge has not reported any models yet
            with mock.patch.object(shield, "_CODEX_GLOBAL_STATE_PATH", state_file):
                snap = self._get_json("/studio/snapshot")
                snap_slugs = [m["slug"] for m in snap["web_bridge"]["available_models"]]
                self.assertIn("gpt-6-thinking", snap_slugs)
                self.assertFalse(any(s.endswith("-wm") for s in snap_slugs))

    def test_t16b_codex_in_app_poll_is_strictly_isolated_from_chrome_default(self):
        self._write_task("tsk_16b_chrome", "外部 Chrome 正常任务")
        self._bind("tsk_16b_chrome", profile="Chrome:Default", conv=CONV_A)
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "browser_instance_id": "inst_real_chrome",
            "tabs": [{
                "tab_id": "101",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "title": "外部 Chrome 页",
                "is_generating": False,
                "state_known": True,
            }],
        })
        enq = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_16b_chrome",
            "user_text": "只发给外部 Chrome",
        })
        self.assertTrue(enq["ok"])

        codex_poll = self._post_json("/web-bridge/poll", {
            "browser": "CodexInApp",
            "browser_profile": "Chrome:Default",
            "is_codex_in_app_browser": True,
            "browser_instance_id": "inst_codex_webview",
            "tabs": [{
                "tab_id": "999",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "title": "Codex 内置浏览器",
                "is_generating": False,
                "state_known": True,
            }],
        })
        self.assertTrue(codex_poll["ok"])
        self.assertTrue(codex_poll.get("isolated"))
        self.assertEqual(codex_poll["dispatches"], [])
        self.assertEqual(codex_poll["retire_actions"], [])

        wb = self._wb()
        self.assertNotIn("inst_codex_webview", wb["browser_instances"])
        self.assertNotIn("999", wb["tabs"])
        self.assertIn("101", wb["tabs"])
        msg = next(m for m in wb["queue"] if m["id"] == enq["message_id"])
        self.assertEqual(msg["status"], "pending", "CodexInApp must never claim Chrome:Default messages")


class T17ProactiveTaskLedgerV42Tests(V42Base):
    """T17: Pure '+' task creation (preserve active peers), task_manage(action='update'), & zero cross-task fuzzy merge."""

    def test_t17a_plus_new_task_keeps_existing_active_tasks_side_by_side_without_retire_action(self):
        self._write_task("tsk_active_old", "RelayStudio 架构升级")
        self._bind("tsk_active_old", profile="Chrome:Profile 1", conv=CONV_A)

        res = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "__new_task__",
            "user_text": "排查另一个独立模块的问题",
            "is_single_pane_replace": True,  # Even legacy single-pane flag must NOT archive active peers in v4.2
        })
        self.assertTrue(res["ok"] and res["created_task"])
        new_tid = res["task_id"]
        self.assertEqual(res["superseded"], [])

        overrides, _ = shield.load_task_archives(self.data_root)
        self.assertNotIn("tsk_active_old", overrides, "existing active task must not be auto-archived by '+'")

        wb = self._wb()
        self.assertEqual(wb["retire_actions"], [], "existing active task window must not be retired by '+'")
        self.assertEqual(wb["session_bindings"]["tsk_active_old"]["conv_uuid"], CONV_A)

        snap = self._get_json("/studio/snapshot")
        active_keys = [s["SessionKey"] for s in snap["sessions"]]
        self.assertIn("tsk_active_old", active_keys)
        self.assertIn(new_tid, active_keys)

    def test_t17b_tools_list_exposes_update_and_task_manage_update_promotes_card_preserving_user_alias(self):
        list_resp = self._post_json("/mcp", {"jsonrpc": "2.0", "id": "list-1", "method": "tools/list", "params": {}})
        tools = list_resp["result"]["tools"]
        tm_tool = next(t for t in tools if t["name"] == "task_manage")
        props = tm_tool["inputSchema"]["properties"]
        self.assertIn("update", props["action"]["enum"])
        for field in ("task_id", "title", "goal", "steps", "summary"):
            self.assertIn(field, props)

        # Mint a 0/1 placeholder card via '+'
        enq = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "__new_task__",
            "user_text": "帮我完成 v4.2 增量开发",
        })
        tid = enq["task_id"]

        # User sets a custom locked alias on this card
        self._post_json("/studio/action", {
            "action": "set_alias",
            "session_key": tid,
            "title": "我的置顶开发别名",
        })

        # Cloud model calls task_manage(action="update") to replace the placeholder step list & title
        upd = self._mcp("task_manage", {
            "action": "update",
            "task_id": tid,
            "title": "RelayStudio Spec v4.2 全量实现",
            "goal": "实现 Q1~Q13 并通过 T15~T20 测试",
            "steps": [
                {"id": "s1", "title": "桌面端方案 C", "status": "completed"},
                {"id": "s2", "title": "生命体征仲裁器", "status": "in_progress"},
                {"id": "s3", "title": "单飞待发队列", "status": "pending"},
            ],
            "summary": "已完成方案 C 并切入生命体征模块",
        }, rpc_id="upd-1")
        self.assertIn("result", upd)
        self.assertFalse(any(c["tool"] == "task_manage" and c["args"].get("action") == "update" for c in self.upstream.calls),
                         ":8766 must handle action='update' natively without forwarding to :8765")

        doc = self._read_task(tid)
        self.assertFalse(doc.get("waiting_cloud_steps"))
        self.assertEqual(doc["title"], "RelayStudio Spec v4.2 全量实现")
        self.assertEqual(doc["goal"], "实现 Q1~Q13 并通过 T15~T20 测试")
        self.assertEqual(len(doc["steps"]), 3)
        self.assertEqual(doc["steps"][0]["status"], "completed")
        self.assertEqual(doc["steps"][1]["status"], "in_progress")

        snap = self._get_json("/studio/snapshot")
        card = next(s for s in snap["sessions"] if s["SessionKey"] == tid)
        self.assertEqual(card["TotalStepCount"], 3)
        self.assertEqual(card["CompletedStepCount"], 1)
        self.assertEqual(card["Title"], "我的置顶开发别名", "custom user alias must remain locked on display")
        self.assertEqual(card["RawTitle"], "RelayStudio Spec v4.2 全量实现")

    def test_t17c_independent_create_with_shared_prefix_and_continue_keyword_creates_separate_task(self):
        self._write_task("tsk_relay_old", "RelayStudio 架构升级 (D:\\tool\\RelayStudio)")
        self._bind("tsk_relay_old", profile="Chrome:Profile 1", conv=CONV_A)

        # Shares 11-char prefix 'RelayStudio' AND workspace AND '继续' keyword, yet is a brand-new task!
        resp = self._mcp("task_manage", {
            "action": "create",
            "title": "RelayStudio 新模块测试 (D:\\tool\\RelayStudio)",
            "goal": "继续编写新模块的专项压测脚本",
        }, rpc_id="new-1")
        self.assertEqual(self.upstream.task_create_count, 0, "Spec v4.6: native create on :8766 without upstream forwarding")
        new_tid = resp["result"]["structuredContent"]["task_id"]
        self.assertTrue(new_tid.startswith("tsk_") and new_tid != "tsk_relay_old")
        self.assertTrue(os.path.isfile(os.path.join(self.tasks_root, f"{new_tid}.json")))

        # Old task must ALSO remain active (no auto-supersede)
        overrides, _ = shield.load_task_archives(self.data_root)
        self.assertNotIn("tsk_relay_old", overrides)


class T18VitalSignsAndStoppedTimerTests(V42Base):
    """T18: 4-probe VitalSignsAggregator, STOPPED-origin timer, UNKNOWN no-fire, call_seq_id, & 30s tier."""

    @staticmethod
    def _iso_at(ep: float) -> str:
        from datetime import datetime, timezone
        return datetime.fromtimestamp(ep, tz=timezone.utc).isoformat().replace("+00:00", "Z")

    def test_t18a_pure_thinking_sse_active_keeps_live_and_resets_stopped_timer_from_zero(self):
        base_now = time.time()
        old_tool_iso = self._iso_at(base_now - 240.0)
        self._write_task("tsk_18_think", "长程纯思考推理任务", updated_at=old_tool_iso)
        self._bind("tsk_18_think", profile="Chrome:Profile 1", conv=CONV_A)

        # DOM stop button flickers False, but SSE stream is still open (sse_active=True)!
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "201",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "title": "纯思考会话",
                "sse_active": True,
                "is_generating": False,
                "state_known": True,
            }],
        })

        snap_live = self._get_json("/studio/snapshot")
        card_live = next(s for s in snap_live["sessions"] if s["SessionKey"] == "tsk_18_think")
        self.assertEqual(card_live["VitalState"], "LIVE")
        self.assertEqual(card_live["StoppedElapsedSeconds"], 0)
        self.assertFalse(card_live["IsStalled"])

        tick_live = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(tick_live["actions"], [], "Guardian must NEVER fire while sse_active=True even if LastToolCall > 240s")

        # Backdate last_live_at by 1.0s and close SSE stream -> STOPPED timer must start from ~1s, NOT jump to 241s!
        t_live_1s_ago = self._iso_at(time.time() - 1.0)
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            wb["tabs"]["201"]["last_live_at"] = t_live_1s_ago
            wb["tabs"]["201"]["sse_active"] = False
            wb["tabs"]["201"]["is_generating"] = False
            wb["tabs"]["201"]["last_seen_at"] = self._iso_at(time.time())
            brk = shield._ensure_breaker_entry(wb["breakers"].get("tsk_18_think"), session_key="tsk_18_think")
            brk["last_live_at"] = t_live_1s_ago
            wb["breakers"]["tsk_18_think"] = brk
            shield._save_web_bridge_state(self.wb_state_path, wb)

        snap_stopped = self._get_json("/studio/snapshot")
        card_stopped = next(s for s in snap_stopped["sessions"] if s["SessionKey"] == "tsk_18_think")
        self.assertEqual(card_stopped["VitalState"], "STOPPED")
        self.assertLessEqual(card_stopped["StoppedElapsedSeconds"], 5, "STOPPED timer must count from 0 at last_live_at, not 241s")
        self.assertGreaterEqual(card_stopped["StoppedElapsedSeconds"], 1)
        self.assertFalse(card_stopped["IsStalled"])

    def test_t18b_missing_or_state_unknown_tab_reports_unknown_and_blocks_guardian(self):
        old_iso = self._iso_at(time.time() - 300.0)
        self._write_task("tsk_18_unknown", "后台被冻结标签任务", updated_at=old_iso)
        self._bind("tsk_18_unknown", profile="Chrome:Profile 1", conv=CONV_A)

        # Case 1: Bound conv_uuid has NO fresh tab report at all
        snap1 = self._get_json("/studio/snapshot")
        card1 = next(s for s in snap1["sessions"] if s["SessionKey"] == "tsk_18_unknown")
        self.assertEqual(card1["VitalState"], "UNKNOWN")
        self.assertFalse(card1["IsStalled"])
        self.assertIn("核实网页运行状态", card1["VitalHintText"])
        self.assertEqual(shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)["actions"], [])

        # Case 2: Fresh tab report arrives, but active probe timed out (state_known=False)
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "202",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "title": "失联页",
                "is_generating": False,
                "state_known": False,
            }],
        })
        snap2 = self._get_json("/studio/snapshot")
        card2 = next(s for s in snap2["sessions"] if s["SessionKey"] == "tsk_18_unknown")
        self.assertEqual(card2["VitalState"], "UNKNOWN")
        self.assertFalse(card2["IsStalled"])
        self.assertEqual(shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)["actions"], [])

    def test_t18c_concurrent_rpc_id_zero_calls_preserve_mcp_in_flight_via_unique_call_seq_id(self):
        self._write_task("tsk_18_rpc0", "并发零号 RPC 工具任务", updated_at=self._iso_at(time.time() - 250.0))
        self._bind("tsk_18_rpc0", profile="Chrome:Profile 1", conv=CONV_A)
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "203",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "is_generating": False,
                "state_known": True,
            }],
        })

        req1 = json.dumps({
            "jsonrpc": "2.0", "id": "0", "method": "tools/call",
            "params": {"name": "exec_command", "arguments": {"cmd": "pytest suite_a", "task_id": "tsk_18_rpc0"}},
        }).encode("utf-8")
        req2 = json.dumps({
            "jsonrpc": "2.0", "id": "0", "method": "tools/call",
            "params": {"name": "exec_command", "arguments": {"cmd": "pytest suite_b", "task_id": "tsk_18_rpc0"}},
        }).encode("utf-8")

        e1 = shield.record_shield_activity(self.activity_path, req1)
        e2 = shield.record_shield_activity(self.activity_path, req2)
        self.assertNotEqual(e1.get("call_seq_id"), e2.get("call_seq_id"))
        self.assertTrue(e1.get("call_seq_id") and e2.get("call_seq_id"))

        # Complete call #1 while call #2 (also rpc_id="0") is still running!
        shield.complete_shield_activity(self.activity_path, e1, b'{"result":{"ok":true}}')
        snap_mid = self._get_json("/studio/snapshot")
        self.assertEqual(snap_mid["in_flight_count"], 1)
        card_mid = next(s for s in snap_mid["sessions"] if s["SessionKey"] == "tsk_18_rpc0")
        self.assertTrue(card_mid["McpInFlight"])
        self.assertEqual(card_mid["VitalState"], "LIVE")

        # Complete call #2 -> in_flight drops cleanly to 0
        shield.complete_shield_activity(self.activity_path, e2, b'{"result":{"ok":true}}')
        snap_done = self._get_json("/studio/snapshot")
        self.assertEqual(snap_done["in_flight_count"], 0)
        card_done = next(s for s in snap_done["sessions"] if s["SessionKey"] == "tsk_18_rpc0")
        self.assertFalse(card_done["McpInFlight"])

    def test_t18d_thirty_second_stall_tier_fires_at_31s_not_29s(self):
        t_29 = self._iso_at(time.time() - 29.0)
        self._write_task("tsk_18_30s", "30秒快速守护档任务", updated_at=t_29)
        self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_18_30s",
            "browser_profile": "Chrome:Profile 1",
            "conv_uuid": CONV_A,
            "stall_seconds": 30,
            "max_retries": 1,
        })
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "204",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "is_generating": False,
                "sse_active": False,
                "state_known": True,
            }],
        })

        # At 29s STOPPED -> must NOT fire
        tick_29 = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(tick_29["actions"], [])

        # At 31s STOPPED -> MUST fire in_place_wakeup
        t_31 = self._iso_at(time.time() - 31.0)
        self._write_task("tsk_18_30s", "30秒快速守护档任务", updated_at=t_31)
        tick_31 = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(len(tick_31["actions"]), 1)
        self.assertEqual(tick_31["actions"][0]["action"], "in_place_wakeup")


class T19SelfHealingRelayLoopTests(V42Base):
    """T19: 90s AWAITING_WAKEUP lock (zero 3.14s double-fire), turn_seq reset, retired_uuids lock, CONV_B promotion, & 2-dead-window Tripped."""

    @staticmethod
    def _iso_at(ep: float) -> str:
        from datetime import datetime, timezone
        return datetime.fromtimestamp(ep, tz=timezone.utc).isoformat().replace("+00:00", "Z")

    def test_t19a_awaiting_wakeup_lock_blocks_3s_double_fire_and_turn_seq_growth_resets_retry_count(self):
        t_old = self._iso_at(time.time() - 220.0)
        self._write_task("tsk_19a", "防3.14秒双发与回合重置任务", updated_at=t_old)
        self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_19a",
            "browser_profile": "Chrome:Profile 1",
            "conv_uuid": CONV_A,
            "stall_seconds": 180,
            "max_retries": 1,
        })
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "301",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "sse_active": False,
                "is_generating": False,
                "turn_seq": 3,
                "state_known": True,
            }],
        })

        # T=0s: Guardian sends in_place_wakeup (1/1)
        tick_0 = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(len(tick_0["actions"]), 1)
        self.assertEqual(tick_0["actions"][0]["action"], "in_place_wakeup")
        wakeup_msg_id = tick_0["actions"][0]["msg_id"]

        # T=0.2s: Browser polls and claims wakeup_msg_id (status -> 'claimed')
        poll_claim = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "301",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "sse_active": False,
                "is_generating": False,
                "turn_seq": 3,
                "state_known": True,
            }],
        })
        self.assertEqual(len(poll_claim["dispatches"]), 1)
        self.assertEqual(poll_claim["dispatches"][0]["msg_id"], wakeup_msg_id)

        # T=3.1s: Guardian ticks again while message is claimed -> MUST NOT escalate to new_window_handover!
        tick_3s_claimed = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(tick_3s_claimed["actions"], [], "AWAITING_WAKEUP must block 3.14s escalation while claimed")

        # T=4.0s: Message is delivered, still within 90s observation window -> MUST NOT escalate!
        ack = self._post_json("/web-bridge/ack-deliver", {"msg_id": wakeup_msg_id, "tab_id": "301", "conv_uuid": CONV_A})
        self.assertTrue(ack["ok"])
        tick_5s_delivered = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(tick_5s_delivered["actions"], [], "AWAITING_WAKEUP must hold for 90s after delivery")

        # T=12s: Spec v4.6 Decision 6: +1 turn_seq (3 -> 4, outgoing user message only) MUST NOT reset retry_count;
        # full user+assistant round-trip (+2: 3 -> 5, no error) resets retry_count to 0!
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "tabs": [{
                "tab_id": "301",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "sse_active": False,
                "is_generating": False,
                "turn_seq": 4,
                "state_known": True,
            }],
        })
        self.assertEqual(self._wb()["breakers"]["tsk_19a"]["retry_count"], 1, "Spec v4.6: turn_seq +1 self-echo must NOT reset retry_count")

        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "tabs": [{
                "tab_id": "301",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "sse_active": False,
                "is_generating": False,
                "turn_seq": 5,
                "state_known": True,
            }],
        })
        tick_reset = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(tick_reset["actions"], [], "turn_seq +2 resets STOPPED timer to 0s without immediate re-fire")
        wb_after_turn = self._wb()
        brk = wb_after_turn["breakers"]["tsk_19a"]
        self.assertEqual(brk["retry_count"], 0, "turn_seq +2 (full user+assistant round-trip) resets retry_count to 0")
        self.assertEqual(brk["consecutive_dead_handovers"], 0)

        # When CONV_A later stalls >180s again, it fires in_place_wakeup (1/1) again instead of escalating to handover!
        iso_190s_ago = self._iso_at(time.time() - 190.0)
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            wb["tabs"]["301"]["last_live_at"] = iso_190s_ago
            wb["breakers"]["tsk_19a"]["last_live_at"] = iso_190s_ago
            shield._save_web_bridge_state(self.wb_state_path, wb)
        tick_next_stall = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(len(tick_next_stall["actions"]), 1)
        self.assertEqual(tick_next_stall["actions"][0]["action"], "in_place_wakeup")

    def test_t19b_90s_dead_wakeup_escalates_locks_retired_conv_a_and_promotes_conv_b_to_follow_window(self):
        t_old = self._iso_at(time.time() - 300.0)
        self._write_task("tsk_19b", "真死换新窗与满血转正任务", updated_at=t_old)
        self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_19b",
            "browser_profile": "Chrome:Profile 1",
            "conv_uuid": CONV_A,
            "stall_seconds": 30,
            "max_retries": 1,
        })
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "311",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "page_hints": ["tsk_19b"],
                "sse_active": False,
                "is_generating": False,
                "turn_seq": 2,
                "state_known": True,
            }],
        })

        # Step 1: First wakeup sent & delivered, then 95s elapse with 0 progress
        tick1 = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(tick1["actions"][0]["action"], "in_place_wakeup")
        w_id = tick1["actions"][0]["msg_id"]
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "311", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "turn_seq": 2, "state_known": True}],
        })
        self._post_json("/web-bridge/ack-deliver", {"msg_id": w_id, "tab_id": "311", "conv_uuid": CONV_A})

        iso_95s_ago = self._iso_at(time.time() - 95.0)
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            for m in wb["queue"]:
                if m["id"] == w_id:
                    m["delivered_at"] = iso_95s_ago
            wb["breakers"]["tsk_19b"]["wakeup_sent_at"] = iso_95s_ago
            wb["breakers"]["tsk_19b"]["last_sent_at"] = iso_95s_ago
            shield._save_web_bridge_state(self.wb_state_path, wb)

        # Step 2: Guardian escalates to new_window_handover & locks CONV_A in retired_uuids immediately
        tick2 = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(len(tick2["actions"]), 1)
        self.assertEqual(tick2["actions"][0]["action"], "new_window_handover")
        h_id = tick2["actions"][0]["msg_id"]

        wb_escalated = self._wb()
        self.assertIn(CONV_A, wb_escalated["session_bindings"]["tsk_19b"]["retired_uuids"])
        self.assertTrue(any(r["conv_uuid"] == CONV_A for r in wb_escalated["retire_actions"]))

        # Step 3: Even if retired CONV_A reports is_generating=True & sse_active=True, it MUST NOT reclaim binding!
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "311",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "page_hints": ["tsk_19b"],
                "sse_active": True,
                "is_generating": True,
                "turn_seq": 9,
                "state_known": True,
            }],
        })
        self.assertNotEqual(self._wb()["session_bindings"]["tsk_19b"]["conv_uuid"], CONV_A,
                            "Retired CONV_A must never hijack binding back even when is_generating=True")

        # Step 4: New window CONV_B opens, claims & delivers handover, and completes a turn (turn_seq=1)
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "312",
                "conv_uuid": "",
                "url": f"https://chatgpt.com/?relay_handover=1&msg_id={h_id}",
                "handover_msg_id": h_id,
                "sse_active": False,
                "is_generating": False,
                "state_known": True,
            }],
        })
        self._post_json("/web-bridge/ack-deliver", {"msg_id": h_id, "tab_id": "312", "conv_uuid": CONV_B})
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "312",
                "conv_uuid": CONV_B,
                "url": f"https://chatgpt.com/c/{CONV_B}",
                "page_hints": ["tsk_19b"],
                "sse_active": True,
                "is_generating": True,
                "turn_seq": 1,
                "state_known": True,
            }],
        })

        # Guardian tick while CONV_B is LIVE promotes CONV_B with retry_count=0 & target_mode='follow_window'
        shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        wb_promoted = self._wb()
        b_prom = wb_promoted["session_bindings"]["tsk_19b"]
        brk_prom = wb_promoted["breakers"]["tsk_19b"]
        self.assertEqual(b_prom["conv_uuid"], CONV_B)
        self.assertEqual(b_prom["target_mode"], "follow_window")
        self.assertEqual(brk_prom["retry_count"], 0)
        self.assertEqual(brk_prom["consecutive_dead_handovers"], 0)
        self.assertFalse(brk_prom["tripped"])

        # Step 5: CONV_B later finishes and stalls past 30s -> Guardian performs in_place_wakeup on CONV_B (not Tripped!)
        t_35s_ago = self._iso_at(time.time() - 35.0)
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            wb["tabs"]["312"]["sse_active"] = False
            wb["tabs"]["312"]["is_generating"] = False
            wb["tabs"]["312"]["last_live_at"] = t_35s_ago
            wb["tabs"]["312"]["last_seen_at"] = self._iso_at(time.time())
            wb["breakers"]["tsk_19b"]["last_live_at"] = t_35s_ago
            shield._save_web_bridge_state(self.wb_state_path, wb)

        tick_b_stall = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(len(tick_b_stall["actions"]), 1)
        self.assertEqual(tick_b_stall["actions"][0]["action"], "in_place_wakeup")
        msg_b_wake = next(m for m in self._wb()["queue"] if m["id"] == tick_b_stall["actions"][0]["msg_id"])
        self.assertEqual(msg_b_wake["conv_uuid"], CONV_B)

    def test_t19c_two_consecutive_dead_handovers_trip_circuit_breaker_and_manual_send_clears_trip(self):
        t_old = self._iso_at(time.time() - 400.0)
        self._write_task("tsk_19c", "连续2死窗熔断任务", updated_at=t_old)
        self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_19c",
            "browser_profile": "Chrome:Profile 1",
            "conv_uuid": CONV_A,
            "stall_seconds": 30,
            "max_retries": 1,
        })
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "321", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "turn_seq": 0, "state_known": True}],
        })

        # 1) Wakeup -> 95s dead
        w_act = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)["actions"][0]
        self.assertEqual(w_act["action"], "in_place_wakeup")
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome", "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "321", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "turn_seq": 0, "state_known": True}],
        })
        self._post_json("/web-bridge/ack-deliver", {"msg_id": w_act["msg_id"], "tab_id": "321", "conv_uuid": CONV_A})
        iso_95 = self._iso_at(time.time() - 95.0)
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            for m in wb["queue"]:
                if m["id"] == w_act["msg_id"]:
                    m["delivered_at"] = iso_95
            wb["breakers"]["tsk_19c"]["wakeup_sent_at"] = iso_95
            wb["breakers"]["tsk_19c"]["last_sent_at"] = iso_95
            shield._save_web_bridge_state(self.wb_state_path, wb)

        # 2) Handover #1 (CONV_B) -> delivered, 95s dead (0 turns, 0 commands)
        h1_act = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)["actions"][0]
        self.assertEqual(h1_act["action"], "new_window_handover")
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome", "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "322", "conv_uuid": "", "url": f"https://chatgpt.com/?relay_handover=1&msg_id={h1_act['msg_id']}", "handover_msg_id": h1_act["msg_id"], "turn_seq": 0, "state_known": True}],
        })
        self._post_json("/web-bridge/ack-deliver", {"msg_id": h1_act["msg_id"], "tab_id": "322", "conv_uuid": CONV_B})
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome", "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "322", "conv_uuid": CONV_B, "url": f"https://chatgpt.com/c/{CONV_B}", "turn_seq": 0, "state_known": True}],
        })
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            for m in wb["queue"]:
                if m["id"] == h1_act["msg_id"]:
                    m["delivered_at"] = iso_95
            wb["breakers"]["tsk_19c"]["handover_sent_at"] = iso_95
            wb["breakers"]["tsk_19c"]["last_sent_at"] = iso_95
            shield._save_web_bridge_state(self.wb_state_path, wb)

        # 3) Handover #2 (CONV_C) -> delivered, 95s dead (0 turns, 0 commands)
        h2_act = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)["actions"][0]
        self.assertEqual(h2_act["action"], "new_window_handover")
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome", "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "323", "conv_uuid": "", "url": f"https://chatgpt.com/?relay_handover=1&msg_id={h2_act['msg_id']}", "handover_msg_id": h2_act["msg_id"], "turn_seq": 0, "state_known": True}],
        })
        self._post_json("/web-bridge/ack-deliver", {"msg_id": h2_act["msg_id"], "tab_id": "323", "conv_uuid": CONV_C})
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome", "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "323", "conv_uuid": CONV_C, "url": f"https://chatgpt.com/c/{CONV_C}", "turn_seq": 0, "state_known": True}],
        })
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            for m in wb["queue"]:
                if m["id"] == h2_act["msg_id"]:
                    m["delivered_at"] = iso_95
            wb["breakers"]["tsk_19c"]["handover_sent_at"] = iso_95
            wb["breakers"]["tsk_19c"]["last_sent_at"] = iso_95
            shield._save_web_bridge_state(self.wb_state_path, wb)

        # 4) 2nd dead handover expires -> MUST trip circuit breaker and NOT open a 3rd window!
        tick_trip = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(tick_trip["actions"], [])
        brk_tripped = self._wb()["breakers"]["tsk_19c"]
        self.assertTrue(brk_tripped["tripped"])
        self.assertEqual(brk_tripped["stage"], "Tripped")
        self.assertGreaterEqual(brk_tripped["consecutive_dead_handovers"], 2)

        # 5) Manual send immediately clears Tripped state
        self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_19c",
            "user_text": "网络已恢复，手动继续",
        })
        self.assertFalse(self._wb()["breakers"]["tsk_19c"]["tripped"])


class T20SingleFlightQueueAndExactFocusTests(V42Base):
    """T20a: Single-flight FIFO queue (move/delete/release-claim), draft yield, exact _open_session_web_tab, activity reconcile, & defer/stop handover."""

    @staticmethod
    def _iso_at(ep: float) -> str:
        from datetime import datetime, timezone
        return datetime.fromtimestamp(ep, tz=timezone.utc).isoformat().replace("+00:00", "Z")

    def test_t20a_live_fifo_queue_move_delete_draft_yield_single_flight_and_release_claim(self):
        self._write_task("tsk_20q", "单飞可控待发队列任务")
        self._bind("tsk_20q", profile="Chrome:Profile 1", conv=CONV_A)

        # Tab is currently LIVE (sse_active=True)
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "401",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "sse_active": True,
                "is_generating": True,
                "state_known": True,
            }],
        })

        # Enqueue M1, M2, M3 while LIVE -> all 3 MUST stay pending (NOT superseded!)
        m1 = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_20q", "user_text": "第一条追加指令 M1"})["message_id"]
        m2 = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_20q", "user_text": "第二条追加指令 M2"})["message_id"]
        m3 = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_20q", "user_text": "第三条追加指令 M3"})["message_id"]

        # This test pins the idle-only single-flight rules for queued messages that are NOT live-steering candidates
        # (automatic sources). Manual panel instructions steer live (Spec v4.3) and are covered by T24.
        with shield._WEB_BRIDGE_LOCK:
            wb_ns = shield._load_web_bridge_state(self.wb_state_path)
            for qm in wb_ns["queue"]:
                if qm.get("session_key") == "tsk_20q":
                    qm["manual_send"] = False
            shield._save_web_bridge_state(self.wb_state_path, wb_ns)

        snap_q = self._get_json("/studio/snapshot")
        card_q = next(s for s in snap_q["sessions"] if s["SessionKey"] == "tsk_20q")
        self.assertEqual([p["Id"] for p in card_q["PendingQueue"]], [m1, m2, m3])

        # Poll while LIVE -> 0 dispatches!
        poll_live = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "401", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "sse_active": True, "is_generating": True, "state_known": True}],
        })
        self.assertEqual(poll_live["dispatches"], [])

        # Move M3 up ([M1, M3, M2]) and delete M2 -> [M1, M3] (also verify empty msg_id returns ok=True for contract gate)
        self.assertTrue(self._post_json("/studio/action", {"action": "move_queued_message", "session_key": "tsk_20q"})["ok"])
        self.assertTrue(self._post_json("/studio/action", {"action": "delete_queued_message", "session_key": "tsk_20q"})["ok"])
        mv = self._post_json("/studio/action", {"action": "move_queued_message", "session_key": "tsk_20q", "msg_id": m3, "direction": "up"})
        self.assertTrue(mv["ok"] and mv["changed"])
        dl = self._post_json("/studio/action", {"action": "delete_queued_message", "session_key": "tsk_20q", "msg_id": m2})
        self.assertTrue(dl["ok"] and dl["changed"])

        card_after_edit = next(s for s in self._get_json("/studio/snapshot")["sessions"] if s["SessionKey"] == "tsk_20q")
        self.assertEqual([p["Id"] for p in card_after_edit["PendingQueue"]], [m1, m3])
        self.assertFalse(any(sm["Id"] == m2 for sm in card_after_edit["SentWebMessages"]), "cancelled message must not show in SentWebMessages")

        # Settle >3s after LIVE, but user is typing a draft (has_user_draft=True) -> MUST hold queue!
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            wb["tabs"]["401"]["last_live_at"] = self._iso_at(time.time() - 5.0)
            shield._save_web_bridge_state(self.wb_state_path, wb)

        poll_draft = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "401", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "sse_active": False, "is_generating": False, "has_user_draft": True, "state_known": True}],
        })
        self.assertEqual(poll_draft["dispatches"], [], "must never overwrite user draft while has_user_draft=True")

        # User clears draft & tab is STOPPED >= 3s -> first poll MUST release ONLY M1 (single-flight!), keeping M3 pending!
        poll_stop1 = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "401", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "sse_active": False, "is_generating": False, "has_user_draft": False, "state_known": True}],
        })
        self.assertEqual(len(poll_stop1["dispatches"]), 1)
        self.assertEqual(poll_stop1["dispatches"][0]["msg_id"], m1)
        m3_rec = next(m for m in self._wb()["queue"] if m["id"] == m3)
        self.assertEqual(m3_rec["status"], "pending", "M3 must stay pending while M1 is claimed")

        # Second poll while M1 is still claimed -> 0 dispatches!
        poll_while_claimed = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "401", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "sse_active": False, "is_generating": False, "state_known": True}],
        })
        self.assertEqual(poll_while_claimed["dispatches"], [])

        # Extension hits retry_safe (e.g. tab became busy mid-flight) and calls /web-bridge/release-claim -> M1 returns cleanly to pending!
        rel = self._post_json("/web-bridge/release-claim", {"msg_id": m1, "tab_id": "401", "reason": "busy_or_draft"})
        self.assertTrue(rel["ok"])
        wb_rel = self._wb()
        pending_ids = [m["id"] for m in wb_rel["queue"] if m["session_key"] == "tsk_20q" and m["status"] == "pending"]
        self.assertEqual(pending_ids, [m1, m3], "released M1 must remain at head of FIFO pending queue ahead of M3")

    def test_t20b_open_session_web_tab_matches_inflight_handover_tab_rejects_unrelated_fallback_and_routes_desktop_cdp(self):
        # Another unrelated live tab 501 exists in Chrome:Profile 1
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "501",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "title": "旧的无关聊天页",
                "is_generating": False,
                "state_known": True,
            }],
        })

        # Create a brand new task via '+' (no conv_uuid yet!)
        enq_new = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "__new_task__",
            "user_text": "新任务前30秒追焦测试",
            "browser_profile": "Chrome:Profile 1",
        })
        new_tid = enq_new["task_id"]
        new_mid = enq_new["message_id"]

        # Before new handover tab even checks in: open_tab MUST NOT hijack unrelated tab 501!
        open_before = self._post_json("/studio/action", {
            "action": "open_tab",
            "session_key": new_tid,
            "no_launch": True,
        })
        self.assertNotEqual(open_before["tab_id"], "501", "fallback_live_tab must be deleted: never focus an unrelated old tab")
        self.assertNotEqual(open_before["conv_uuid"], CONV_A)

        # Now handover tab 502 checks in on /?relay_handover=1&msg_id=<new_mid> (conv_uuid still "" during first 30s!)
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [
                {
                    "tab_id": "501",
                    "conv_uuid": CONV_A,
                    "url": f"https://chatgpt.com/c/{CONV_A}",
                    "title": "旧的无关聊天页",
                    "state_known": True,
                },
                {
                    "tab_id": "502",
                    "conv_uuid": "",
                    "url": f"https://chatgpt.com/?relay_handover=1&msg_id={new_mid}",
                    "handover_msg_id": new_mid,
                    "title": "ChatGPT",
                    "state_known": True,
                },
            ],
        })
        open_inflight = self._post_json("/studio/action", {
            "action": "open_tab",
            "session_key": new_tid,
            "no_launch": True,
        })
        self.assertEqual(open_inflight["action"], "FocusedExistingTab")
        self.assertEqual(open_inflight["tab_id"], "502", "must hit in-flight handover tab 502 via claimed_tab_id / handover_msg_id")

        # Simulate false 'unconfirmed' timeout on new_mid, then downstream MCP checkpoint arrives -> auto-reconciled to 'delivered'!
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            for m in wb["queue"]:
                if m["id"] == new_mid:
                    m["status"] = "unconfirmed"
            shield._save_web_bridge_state(self.wb_state_path, wb)

        self._mcp("task_manage", {"action": "checkpoint", "task_id": new_tid, "summary": "云端已收到首条指令并开始盘点"}, rpc_id="cp-rec-1")
        msg_reconciled = next(m for m in self._wb()["queue"] if m["id"] == new_mid)
        self.assertEqual(msg_reconciled["status"], "delivered")
        self.assertEqual(msg_reconciled.get("reconciled_by"), "activity")

        # Desktop:ChatGPT task open_tab -> routes through DesktopAppBridge.navigate_to_conversation, never external Chrome!
        self._write_task("tsk_20_desk", "桌面端精准追焦任务")
        self._bind("tsk_20_desk", profile="Desktop:ChatGPT", conv=CONV_C)
        with mock.patch.object(shield.DesktopAppBridge, "start_host", return_value=True) as m_start, \
             mock.patch.object(shield.DesktopAppBridge, "navigate_to_conversation", return_value=True) as m_nav, \
             mock.patch.object(shield, "activate_existing_browser_window", return_value=True) as m_act, \
             mock.patch.object(shield, "launch_browser_url", return_value=True) as m_launch:
            open_desk = self._post_json("/studio/action", {
                "action": "open_tab",
                "session_key": "tsk_20_desk",
            })
            self.assertEqual(open_desk["browser"], "Desktop")
            self.assertEqual(open_desk["browser_profile"], "Desktop:ChatGPT")
            m_start.assert_called_once()
            m_nav.assert_called_once_with(CONV_C)
            m_act.assert_called_once()
            m_launch.assert_not_called()

    def test_t20c_manual_handover_while_live_supports_defer_until_stopped_and_stop_and_retire(self):
        # Branch 1: defer_until_stopped=True waits while CONV_A is LIVE, then opens new window as soon as CONV_A enters STOPPED
        self._write_task("tsk_20_defer", "等停稳再换窗任务")
        self._bind("tsk_20_defer", profile="Chrome:Profile 1", conv=CONV_A)
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "601", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "sse_active": True, "is_generating": True, "state_known": True}],
        })

        enq_defer = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_20_defer",
            "mode": "new_window_handover",
            "user_text": "等这轮跑完换新窗继续",
            "defer_until_stopped": True,
        })
        self.assertTrue(enq_defer["ok"])

        poll_still_live = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "601", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "sse_active": True, "is_generating": True, "state_known": True}],
        })
        self.assertEqual([d for d in poll_still_live["dispatches"] if d.get("open_new_tab")], [],
                         "defer_until_stopped must hold new tab launch while CONV_A is still LIVE")

        poll_now_stopped = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "601", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "sse_active": False, "is_generating": False, "state_known": True}],
        })
        self.assertEqual(len([d for d in poll_now_stopped["dispatches"] if d.get("open_new_tab")]), 1,
                         "defer_until_stopped must launch handover tab immediately once CONV_A reaches STOPPED")
        self.assertTrue(any(r["conv_uuid"] == CONV_A for r in poll_now_stopped["retire_actions"]))

        # Branch 2: stop_and_retire=True immediately enqueues retire_action(stop_before_archive=True) for CONV_B
        self._write_task("tsk_20_stop", "立即停止并换窗任务")
        self._bind("tsk_20_stop", profile="Chrome:Profile 1", conv=CONV_B)
        enq_stop = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_20_stop",
            "mode": "new_window_handover",
            "user_text": "立即停掉旧窗换新窗",
            "stop_and_retire": True,
        })
        self.assertTrue(enq_stop["ok"])
        wb_stop = self._wb()
        ret_b = next(r for r in wb_stop["retire_actions"] if r["conv_uuid"] == CONV_B)
        self.assertTrue(ret_b.get("stop_before_archive"))


class T22EffortMetadataAndSplitQueueSyncTests(V42Base):
    """T22: Real effort_items metadata pass-through + write-action queue_slice + rev short-circuit & queue-digest."""

    def test_t22a_hub_and_codex_prewarm_preserve_real_effort_items_default_and_configurable(self):
        self._write_task("tsk_22a", "模型档位真实数据透传任务")
        codex_state = os.path.join(self.data_root, "codex-global-state.json")
        with open(codex_state, "w", encoding="utf-8") as fh:
            json.dump({
                "electron-persisted-atom-state": {
                    "chatgpt-models-v1": {
                        "fetchedAt": 1700000000,
                        "response": {
                            "models": [
                                {
                                    "slug": "gpt-6-thinking",
                                    "title": "GPT-6",
                                    "default_thinking_effort": "min",
                                    "configurable_thinking_effort": True,
                                    "thinking_efforts": [
                                        {"thinking_effort": "min", "short_label": "轻度", "full_label": "快速思考"},
                                        {"thinking_effort": "standard", "short_label": "标准", "full_label": "思考中"},
                                        {"thinking_effort": "extended", "short_label": "深度", "full_label": "进阶思考"},
                                        {"thinking_effort": "max", "short_label": "极高", "full_label": "深度思考"},
                                    ],
                                },
                                {
                                    "slug": "research",
                                    "title": "Deep Research",
                                    "configurable_thinking_effort": False,
                                    "thinking_efforts": [],
                                },
                            ]
                        },
                    }
                }
            }, fh, ensure_ascii=False)

        with mock.patch.object(shield, "_CODEX_GLOBAL_STATE_PATH", codex_state):
            snap = self._get_json("/studio/snapshot")
            avail = snap["web_bridge"]["available_models"]
            m_think = next(m for m in avail if m["slug"] == "gpt-6-thinking")
            self.assertEqual(m_think["default_effort"], "min")
            self.assertTrue(m_think["configurable_effort"])
            self.assertEqual(
                [(i["id"], i["label"]) for i in m_think["effort_items"]],
                [("min", "轻度"), ("standard", "标准"), ("extended", "深度"), ("max", "极高")],
            )
            m_res = next(m for m in avail if m["slug"] == "research")
            self.assertFalse(m_res["configurable_effort"])
            self.assertEqual(m_res["effort_items"], [])
            # Session card itself must also carry effective_models (not empty [] when pre-warmed)
            card = next(s for s in snap["sessions"] if s["SessionKey"] == "tsk_22a")
            self.assertTrue(any(m["slug"] == "gpt-6-thinking" for m in card["AvailableModels"]))

    def test_t22b_action_endpoints_return_immediate_queue_slice_and_rev_short_circuits_idle_polls(self):
        self._write_task("tsk_22b", "队列即时回传与版本号门禁任务")
        self._bind("tsk_22b", profile="Chrome:Profile 1", conv=CONV_A)
        # Mark tab LIVE so manual follow_window messages stay queued as pending
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{"tab_id": "701", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "sse_active": True, "is_generating": True, "state_known": True}],
        })

        snap0 = self._get_json("/studio/snapshot")
        rev0 = snap0.get("rev")
        self.assertTrue(rev0, "snapshot must return a non-empty state rev")

        # Repeat poll with matching since_sig must short-circuit with not_modified=True
        snap_idle = self._get_json(f"/studio/snapshot?since_sig={rev0}")
        self.assertTrue(snap_idle["ok"] and snap_idle.get("not_modified") is True)
        self.assertEqual(snap_idle.get("rev"), rev0)

        # Enqueue 2 messages in a row: each response carries live queue_slice immediately
        e1 = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_22b", "user_text": "第一条指令"})
        self.assertEqual(e1["queue_slice"]["PendingQueueCount"], 1)
        e2 = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_22b", "user_text": "第二条指令"})
        self.assertEqual(e2["queue_slice"]["PendingQueueCount"], 2)
        self.assertEqual([x["Text"] for x in e2["queue_slice"]["PendingQueue"]], ["第一条指令", "第二条指令"])

        # Snapshot since rev0 now sees modification and returns full updated snapshot with new rev
        snap1 = self._get_json(f"/studio/snapshot?since_sig={rev0}")
        self.assertFalse(snap1.get("not_modified", False))
        self.assertNotEqual(snap1.get("rev"), rev0)

        # Lightweight queue-digest endpoint supports since_rev short-circuit + active queue detection
        qd1 = self._get_json("/studio/queue-digest")
        self.assertTrue(qd1["ok"] and qd1["has_active_queue"])
        self.assertEqual(qd1["queues"]["tsk_22b"]["PendingQueueCount"], 2)
        qrev1 = qd1["queue_rev"]
        qd_idle = self._get_json(f"/studio/queue-digest?since_rev={qrev1}")
        self.assertTrue(qd_idle["ok"] and qd_idle.get("not_modified") is True)

        # Move second item up -> immediate reordered queue_slice
        mv = self._post_json("/studio/action", {
            "action": "move_queued_message",
            "session_key": "tsk_22b",
            "msg_id": e2["message_id"],
            "direction": "up",
        })
        self.assertTrue(mv["changed"])
        self.assertEqual([x["Text"] for x in mv["queue_slice"]["PendingQueue"]], ["第二条指令", "第一条指令"])

        # Delete both items down to 0 -> final queue_slice has PendingQueueCount=0 AND SentWebMessages has zero 'pending' items!
        d1 = self._post_json("/studio/action", {"action": "delete_queued_message", "session_key": "tsk_22b", "msg_id": e2["message_id"]})
        self.assertEqual(d1["queue_slice"]["PendingQueueCount"], 1)
        d2 = self._post_json("/studio/action", {"action": "delete_queued_message", "session_key": "tsk_22b", "msg_id": e1["message_id"]})
        self.assertEqual(d2["queue_slice"]["PendingQueueCount"], 0)
        self.assertEqual(d2["queue_slice"]["PendingQueue"], [])
        self.assertFalse(any(x.get("Status") == "pending" for x in d2["queue_slice"]["SentWebMessages"]))

        qd_after = self._get_json(f"/studio/queue-digest?since_rev={qrev1}")
        self.assertFalse(qd_after.get("not_modified", False))
        self.assertFalse(qd_after["has_active_queue"])

    def test_t22c_scheme_a_raw_effort_profile_isolation_and_desktop_draft_uuid_promotion(self):
        self._write_task("tsk_chrome_iso", "Chrome 独立模型与原始英文强度任务")
        self._write_task("tsk_desk_iso", "Desktop 独立模型与临时 UUID 转正任务")
        self._bind("tsk_chrome_iso", profile="Chrome:Profile 1", conv=CONV_A)
        self._bind("tsk_desk_iso", profile="Desktop:ChatGPT", conv="")

        chrome_models = [
            {
                "slug": "gpt-6-thinking",
                "title": "GPT-6",
                "efforts": ["min", "standard", "extended", "max"],
                "effort_items": [
                    {"id": "min", "label": "轻度"},
                    {"id": "standard", "label": "标准"},
                    {"id": "extended", "label": "深度"},
                    {"id": "max", "label": "深入"},
                ],
                "configurable_effort": True,
            }
        ]
        desk_models = [
            {
                "slug": "gpt-6-pro",
                "title": "GPT-6 Pro",
                "efforts": ["standard"],
                "effort_items": [{"id": "standard", "label": "标准"}],
                "configurable_effort": True,
            }
        ]
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [{
                "tab_id": "901",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "current_model": "GPT-6 (gpt-6-thinking)",
                "current_effort": "极高 ⌄",
                "available_models": chrome_models,
                "state_known": True,
            }],
        })

        # Enqueue a new Desktop message that first receives an ephemeral draft UUIDv4, then transitions to permanent UUIDv8
        draft_uuid = "4b6add8c-d54d-46b0-9e1d-4fa93a1a2913"
        perm_uuid = "6ae49399-6a18-83ee-a743-3becc0c14d83"
        enq = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_desk_iso",
            "mode": "new_window",
            "browser_profile": "Desktop:ChatGPT",
            "user_text": "探讨人生意义",
        })
        self.assertTrue(enq["ok"])

        class _FakeSession:
            def __init__(self, state_payload, deliver_conv=""):
                self._st = state_payload
                self._dc = deliver_conv
            def read_state(self):
                return dict(self._st)
            def deliver(self, _msg):
                return {"ok": True, "conv_uuid": self._dc}

        with mock.patch.object(shield.RelayCdp, "ChatGptDesktopSession", side_effect=lambda *a, **k: _FakeSession({
            "conv_uuid": draft_uuid,
            "url": f"https://chatgpt.com/c/{draft_uuid}",
            "title": "ChatGPT",
            "current_model": "gpt-6-pro",
            "current_effort": "思考强度中",
            "available_models": desk_models,
            "sse_active": False,
            "is_generating": False,
            "turn_seq": 1,
        }, deliver_conv=draft_uuid)):
            shield.DesktopAppBridge.tick(self.wb_state_path, self.tasks_root, eval_fn=lambda *a: {}, sleep_fn=lambda *_: None)

        # Next tick: OpenAI commits permanent server UUIDv8 (perm_uuid) without tsk_ hint in page text
        with mock.patch.object(shield.RelayCdp, "ChatGptDesktopSession", side_effect=lambda *a, **k: _FakeSession({
            "conv_uuid": perm_uuid,
            "url": f"https://chatgpt.com/c/{perm_uuid}",
            "title": "探讨人生意义",
            "current_model": "gpt-6-pro",
            "current_effort": "思考强度中",
            "available_models": desk_models,
            "sse_active": True,
            "is_generating": True,
            "turn_seq": 2,
        })):
            shield.DesktopAppBridge.tick(self.wb_state_path, self.tasks_root, eval_fn=lambda *a: {}, sleep_fn=lambda *_: None)

        snap = self._get_json("/studio/snapshot")
        c_card = next(s for s in snap["sessions"] if s["SessionKey"] == "tsk_chrome_iso")
        d_card = next(s for s in snap["sessions"] if s["SessionKey"] == "tsk_desk_iso")

        # 1. Pure raw English effort IDs on both cards
        self.assertEqual(c_card["WebCurrentEffort"], "max")
        self.assertEqual(d_card["WebCurrentEffort"], "standard")
        # 2. Per-profile AvailableModels isolation (Desktop did NOT clobber Chrome!)
        self.assertEqual([m["slug"] for m in c_card["AvailableModels"]], ["gpt-6-thinking"])
        self.assertEqual([m["slug"] for m in d_card["AvailableModels"]], ["gpt-6-pro"])
        # 3. Desktop draft UUIDv4 promoted cleanly in place to permanent server UUIDv8 -> VitalState is LIVE (not UNKNOWN!)
        self.assertEqual(d_card["BoundConvUuid"], perm_uuid)
        self.assertEqual(d_card["VitalState"], "LIVE")
        # 4. Model<->effort linkage normalizes instant/即时 to raw English 'none'
        self.assertEqual(shield._resolve_model_effort_linkage("gpt-6-thinking", "即时"), ("gpt-6-instant", "none"))
        self.assertEqual(shield._resolve_model_effort_linkage("gpt-6-thinking", "none"), ("gpt-6-instant", "none"))


class T23StartupAndOpenWebPageRegressionTests(V42Base):
    """T23: Open-Web require_bound contract, one-shot focus_tab_id, cold-start duplicate-tab guard, and SW_SHOWNORMAL foreground launch."""

    def test_t23a_open_tab_require_bound_returns_unbound_until_bound_or_queued(self):
        self._write_task("tsk_23_unbound", "尚未关联对话的本地任务")
        launches = []
        with mock.patch.object(shield, "launch_browser_url", side_effect=lambda *a, **kw: launches.append((a, kw)) or True):
            resp_chrome = self._post_json("/studio/action", {
                "action": "open_tab",
                "session_key": "tsk_23_unbound",
                "browser_profile": "Chrome:Profile 1",
                "require_bound": True,
                "no_launch": False,
            })
            self.assertTrue(resp_chrome["ok"])
            self.assertEqual(resp_chrome["action"], "UnboundConversation")
            self.assertEqual(resp_chrome["browser_profile"], "Chrome:Profile 1")
            self.assertEqual(resp_chrome["url"], "")

            resp_desktop = self._post_json("/studio/action", {
                "action": "open_tab",
                "session_key": "tsk_23_unbound",
                "browser_profile": "Desktop:ChatGPT",
                "require_bound": True,
                "no_launch": False,
            })
            self.assertTrue(resp_desktop["ok"])
            self.assertEqual(resp_desktop["action"], "UnboundConversation")
            self.assertEqual(resp_desktop["browser"], "Desktop")
            self.assertEqual(launches, [], "UnboundConversation must never launch a browser or Desktop app")

            # Once a new_window_handover message is queued for this task, require_bound=True resolves its handover URL!
            enq = self._post_json("/studio/action", {
                "action": "enqueue_message",
                "session_key": "tsk_23_unbound",
                "mode": "new_window_handover",
                "browser_profile": "Edge:Profile 1",
                "user_text": "首次发起网页任务",
            })
            self.assertTrue(enq["ok"])
            resp_queued = self._post_json("/studio/action", {
                "action": "open_tab",
                "session_key": "tsk_23_unbound",
                "require_bound": True,
                "no_launch": True,
            })
            self.assertTrue(resp_queued["ok"])
            self.assertEqual(resp_queued["action"], "OpenedBrowserUrl")
            self.assertEqual(resp_queued["browser_profile"], "Edge:Profile 1")
            self.assertIn("relay_handover=1", resp_queued["url"])
            self.assertIn(enq["message_id"], resp_queued["url"])

    def test_t23b_focus_tab_id_delivered_once_and_cold_start_prevents_duplicate_tab(self):
        self._write_task("tsk_23_focus", "已打开标签页聚焦任务")
        self._bind("tsk_23_focus", profile="Chrome:Profile 1", conv=CONV_A)
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "browser_instance_id": "inst_chrome_19",
            "tabs": [{
                "tab_id": "702",
                "conv_uuid": CONV_A,
                "url": f"https://chatgpt.com/c/{CONV_A}",
                "title": "目标会话",
                "is_generating": False,
                "state_known": True,
            }],
        })

        open_res = self._post_json("/studio/action", {
            "action": "open_tab",
            "session_key": "tsk_23_focus",
            "require_bound": True,
            "no_launch": True,
        })
        self.assertTrue(open_res["ok"])
        self.assertEqual(open_res["action"], "FocusedExistingTab")
        self.assertEqual(open_res["tab_id"], "702")

        poll1 = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "browser_instance_id": "inst_chrome_19",
            "tabs": [{"tab_id": "702", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "state_known": True}],
        })
        self.assertEqual(poll1.get("focus_tab_id"), "702", "first poll must deliver one-shot focus_tab_id")

        poll2 = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "browser_instance_id": "inst_chrome_19",
            "tabs": [{"tab_id": "702", "conv_uuid": CONV_A, "url": f"https://chatgpt.com/c/{CONV_A}", "state_known": True}],
        })
        self.assertEqual(poll2.get("focus_tab_id", ""), "", "second poll must have cleared focus_tab_id")

        # Closed Edge cold-start marks browser_tab_opened=True so waking extension does not open a 2nd duplicate tab
        self._write_task("tsk_23_cold", "关闭态浏览器冷启动防双开")
        cold_launches = []
        with mock.patch.object(shield, "launch_browser_url", side_effect=lambda url, browser_name="Chrome", profile_spec="Chrome:Profile 1", minimize_no_activate=False: cold_launches.append((profile_spec, url, minimize_no_activate)) or True):
            enq_cold = self._post_json("/studio/action", {
                "action": "enqueue_message",
                "session_key": "tsk_23_cold",
                "mode": "new_window_handover",
                "browser_profile": "Edge:Profile 1",
                "user_text": "冷启动单标签页验证",
            })
            if not cold_launches:
                shield.cold_start_pending_hosts(self.wb_state_path)
        self.assertEqual(len(cold_launches), 1)
        self.assertEqual(cold_launches[0][0], "Edge:Profile 1")
        self.assertTrue(cold_launches[0][2], "background cold-start must keep minimize_no_activate=True")

        wb_after_cold = self._wb()
        cold_msg = next(m for m in wb_after_cold["queue"] if m["id"] == enq_cold["message_id"])
        self.assertTrue(cold_msg.get("browser_tab_opened"), "successful cold-start must mark browser_tab_opened=True")

        edge_wake_poll = self._post_json("/web-bridge/poll", {
            "browser": "Edge",
            "browser_profile": "Edge:Profile 1",
            "browser_instance_id": "inst_edge_1",
            "tabs": [],
        })
        self.assertFalse(any(d.get("open_new_tab") for d in edge_wake_poll.get("dispatches", [])),
                         "extension heartbeat after OS cold-start must not open a duplicate second tab")

    def test_t23c_launch_process_explicitly_sets_sw_shownormal_vs_minnoactive(self):
        captured = []

        def fake_popen(args, **kwargs):
            captured.append((args, kwargs))

        ok_bg = RelayCdp.launch_process(["chrome.exe", "https://chatgpt.com/"], minimize_no_activate=True, popen_fn=fake_popen)
        ok_fg = RelayCdp.launch_process(["chrome.exe", "https://chatgpt.com/"], minimize_no_activate=False, popen_fn=fake_popen)
        self.assertTrue(ok_bg and ok_fg)
        self.assertEqual(len(captured), 2)
        if os.name == "nt":
            si_bg = captured[0][1]["startupinfo"]
            si_fg = captured[1][1]["startupinfo"]
            self.assertTrue(si_bg.dwFlags & subprocess.STARTF_USESHOWWINDOW)
            self.assertEqual(si_bg.wShowWindow, RelayCdp.SW_SHOWMINNOACTIVE)
            self.assertTrue(si_fg.dwFlags & subprocess.STARTF_USESHOWWINDOW)
            self.assertEqual(si_fg.wShowWindow, RelayCdp.SW_SHOWNORMAL,
                             "foreground launch from hidden daemon must explicitly set SW_SHOWNORMAL=1 so child never inherits SW_HIDE=0")


def _iso_ep(ep: float) -> str:
    from datetime import datetime, timezone
    return datetime.fromtimestamp(ep, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


class T24ZeroLagBindingSteeringArchiveTests(V42Base):
    """T24 (Spec v4.3): live steering for manual follow-window instructions, stop-loss handover, archive handling
    (panel undo grace + ChatGPT-side archive), never-bound tasks staying in follow-window, host adoption on first claim,
    and the user-initiated desktop window wake."""

    def setUp(self):
        super().setUp()
        for attr, value in (("_cached_port", None), ("_last_launch_at", 0.0), ("_last_restart_at", 0.0), ("_last_probe_at", 0.0)):
            setattr(shield.DesktopAppBridge, attr, value)

    def _poll(self, tab_id="501", conv=CONV_A, profile="Chrome:Profile 1", **tab):
        base = {"tab_id": tab_id, "conv_uuid": conv, "url": f"https://chatgpt.com/c/{conv}" if conv else "https://chatgpt.com/", "state_known": True}
        base.update(tab)
        return self._post_json("/web-bridge/poll", {"browser": profile.split(":")[0], "browser_profile": profile, "tabs": [base]})

    def _enqueue(self, key, text=None):
        payload = {"action": "enqueue_message", "session_key": key}
        if text is not None:
            payload["user_text"] = text
        return self._post_json("/studio/action", payload)["message_id"]

    def _edit_queue(self, msg_id, **fields):
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            for m in wb["queue"]:
                if m["id"] == msg_id:
                    m.update(fields)
            shield._save_web_bridge_state(self.wb_state_path, wb)

    def _desk_tick(self, page):
        return shield.DesktopAppBridge.tick(self.wb_state_path, self.tasks_root, eval_fn=page.evaluate, sleep_fn=lambda s: None)

    # ----------------------------------------------------------------------------------------- live steering (browser)
    def test_t24a_manual_instruction_steers_running_turn_queue_head_only_and_beats_draft(self):
        self._write_task("tsk_24a", "实时引导")
        self._bind("tsk_24a", profile="Chrome:Profile 1", conv=CONV_A)
        self._poll(sse_active=True, is_generating=True)
        m1 = self._enqueue("tsk_24a", "第一条引导 M1")
        m2 = self._enqueue("tsk_24a", "第二条引导 M2")

        out = self._poll(sse_active=True, is_generating=True, has_user_draft=True)
        self.assertEqual([d["msg_id"] for d in out["dispatches"]], [m1], "only the queue head steers the running turn; a hand-typed draft does not block it")
        self.assertTrue(out["dispatches"][0]["message"]["manual_send"])

        self._post_json("/web-bridge/ack-deliver", {"msg_id": m1, "tab_id": "501", "conv_uuid": CONV_A})
        out2 = self._poll(sse_active=True, is_generating=True)
        self.assertEqual(out2["dispatches"], [], "M2 waits until M1 had time to take effect")

        self._edit_queue(m1, delivered_at=_iso_ep(time.time() - 40.0))
        out3 = self._poll(sse_active=True, is_generating=True)
        self.assertEqual([d["msg_id"] for d in out3["dispatches"]], [m2])

        # A "请继续" wakeup (not typed text) and a filling-in-progress tab keep the idle-only rules.
        self._write_task("tsk_24a2", "自动唤醒仍守规矩")
        self._bind("tsk_24a2", profile="Chrome:Profile 1", conv=CONV_B)
        self._poll(tab_id="502", conv=CONV_B, sse_active=True, is_generating=True)
        self._enqueue("tsk_24a2")
        out4 = self._poll(tab_id="502", conv=CONV_B, sse_active=True, is_generating=True)
        self.assertEqual(out4["dispatches"], [])

    def test_t24b_steer_unavailable_stops_old_conversation_and_hands_over_to_a_fresh_one(self):
        self._write_task("tsk_24b", "止损机制换新窗")
        self._bind("tsk_24b", profile="Chrome:Profile 1", conv=CONV_A)
        self._poll()
        mid = self._enqueue("tsk_24b", "把方向改成 B")
        out = self._poll()
        self.assertEqual([d["msg_id"] for d in out["dispatches"]], [mid])
        rel = self._post_json("/web-bridge/release-claim", {"msg_id": mid, "tab_id": "501", "reason": "steer_unavailable"})
        self.assertTrue(rel["ok"])
        wb = self._wb()
        msg = next(m for m in wb["queue"] if m["id"] == mid)
        self.assertEqual((msg["status"], msg["mode"], msg["conv_uuid"]), ("pending", "new_window_handover", ""))
        self.assertIn("tsk_24b", msg["prompt"])
        self.assertIn("把方向改成 B", msg["prompt"])
        retire = [r for r in wb["retire_actions"] if r["conv_uuid"] == CONV_A and r["status"] == "pending"]
        self.assertEqual(len(retire), 1)
        self.assertTrue(retire[0]["stop_before_archive"], "the old conversation is stopped first so it cannot keep running in parallel")
        b = wb["session_bindings"]["tsk_24b"]
        self.assertEqual(b["conv_uuid"], "")
        self.assertIn(CONV_A, b["retired_uuids"])

    # ----------------------------------------------------------------------------------------- archive handling
    def test_t24c_chatgpt_side_archive_pauses_auto_resend_and_manual_send_continues_in_fresh_window(self):
        self._write_task("tsk_24c", "ChatGPT 里归档")
        self._bind("tsk_24c", profile="Chrome:Profile 1", conv=CONV_A)
        self._poll(is_archived=True)
        b = self._wb()["session_bindings"]["tsk_24c"]
        self.assertTrue(b["conv_archived"])
        self.assertFalse(b["auto_resend_enabled"], "a finished (archived) task must never come back to life on its own")
        self.assertTrue(b["archive_auto_paused"])
        self.assertFalse(self._wb()["breakers"]["tsk_24c"]["auto_enabled"])

        self._poll(is_archived=False)
        b = self._wb()["session_bindings"]["tsk_24c"]
        self.assertFalse(b["conv_archived"])
        self.assertTrue(b["auto_resend_enabled"], "un-archiving in ChatGPT resumes exactly what we paused")

        self._poll(is_archived=True)
        res = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_24c", "user_text": "我还要继续做"})
        self.assertEqual(res["message"]["mode"], "new_window_handover")
        b = self._wb()["session_bindings"]["tsk_24c"]
        self.assertEqual(b["conv_uuid"], "")
        self.assertIn(CONV_A, b["retired_uuids"])
        self.assertFalse(b["conv_archived"])
        self.assertTrue(b["auto_resend_enabled"])

    def test_t24d_panel_archive_is_undoable_for_a_grace_window_before_the_web_conversation_is_touched(self):
        self._write_task("tsk_24d", "面板归档与抽屉还原闭环")
        self._bind("tsk_24d", profile="Chrome:Profile 1", conv=CONV_A)
        self._poll()
        self.assertEqual(shield.ARCHIVE_UNDO_GRACE_SEC, 0.0)
        self._post_json("/studio/action", {"action": "archive", "session_key": "tsk_24d"})
        wb = self._wb()
        ret = [r for r in wb["retire_actions"] if r["conv_uuid"] == CONV_A and r["status"] == "pending"]
        self.assertEqual(len(ret), 1)
        self.assertEqual(ret[0]["operation"], "archive")
        self.assertEqual(wb["session_bindings"]["tsk_24d"]["conv_uuid"], CONV_A, "room number kept intact on archive")
        due = self._poll()["retire_actions"]
        self.assertEqual([r["conv_uuid"] for r in due], [CONV_A], "archive action is released immediately with 0s grace")

        self._post_json("/studio/action", {"action": "restore", "session_key": "tsk_24d"})
        wb = self._wb()
        self.assertEqual(wb["session_bindings"]["tsk_24d"]["conv_uuid"], CONV_A, "restore preserves primary conv_uuid")
        unarch = [r for r in wb["retire_actions"] if r["conv_uuid"] == CONV_A and r["status"] == "pending"]
        self.assertEqual(len(unarch), 1)
        self.assertEqual(unarch[0]["operation"], "unarchive")
        self.assertFalse(unarch[0]["close_tab"])

    # ----------------------------------------------------------------------------------------- never-bound / host adoption
    def test_t24e_never_bound_auto_wakeup_stays_in_follow_window_but_manual_send_eventually_hands_over(self):
        self._write_task("tsk_24e", "还没认领房间号")
        self._bind("tsk_24e", profile="Chrome:Profile 1")
        mid = self._enqueue("tsk_24e")
        self._edit_queue(mid, is_auto_wakeup=True, created_at=_iso_ep(time.time() - 120.0))
        out = self._post_json("/web-bridge/poll", {"browser": "Chrome", "browser_profile": "Chrome:Profile 1", "tabs": []})
        msg = next(m for m in self._wb()["queue"] if m["id"] == mid)
        self.assertEqual(msg["mode"], "in_place_wakeup", "an automatic wakeup of a never-claimed task must not open a new chat on its own")
        self.assertFalse(any(d.get("open_new_tab") for d in out["dispatches"]))

        mid2 = self._enqueue("tsk_24e", "用户亲手发的")
        self._edit_queue(mid2, created_at=_iso_ep(time.time() - 120.0))
        self._post_json("/web-bridge/poll", {"browser": "Chrome", "browser_profile": "Chrome:Profile 1", "tabs": []})
        msg2 = next(m for m in self._wb()["queue"] if m["id"] == mid2)
        self.assertEqual(msg2["mode"], "new_window_handover")

    def test_t24f_web_initiated_task_adopts_the_host_that_holds_its_conversation_but_app_tasks_keep_theirs(self):
        self._write_task("tsk_24f", "网页里手动发起")
        self._bind("tsk_24f", profile="Desktop:ChatGPT")
        self._poll(conv=CONV_B, page_hints=["tsk_24f"])
        b = self._wb()["session_bindings"]["tsk_24f"]
        self.assertEqual(b["conv_uuid"], CONV_B)
        self.assertEqual(b["browser_profile"], "Chrome:Profile 1", "first claim: follow the host that physically holds the conversation")
        self.assertFalse(b["user_locked_browser"])

        res = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "__new_task__", "user_text": "App 里新建", "browser_profile": "Desktop:ChatGPT"})
        tid = res["task_id"]
        self._poll(tab_id="601", conv=CONV_C, page_hints=[tid])
        b2 = self._wb()["session_bindings"][tid]
        self.assertTrue(b2["app_initiated"])
        self.assertEqual(b2["browser_profile"], "Desktop:ChatGPT", "tasks minted in the App panel keep the host chosen there")

    # ----------------------------------------------------------------------------------------- desktop steering + wake
    def test_t24g_desktop_manual_instruction_steers_when_available_and_falls_back_to_stop_loss(self):
        self._write_task("tsk_24g", "桌面实时引导")
        self._bind("tsk_24g", profile="Desktop:ChatGPT", conv=CONV_A)
        mid = self._enqueue("tsk_24g", "桌面引导 M1")
        steerable = FakeChatGptPage(conv_uuid=CONV_A, is_generating=True, can_steer=True)
        self._desk_tick(steerable)
        self.assertEqual(steerable.filled, "桌面引导 M1")
        self.assertEqual(next(m for m in self._wb()["queue"] if m["id"] == mid)["status"], "delivered")

        self._write_task("tsk_24g2", "桌面无法引导")
        self._bind("tsk_24g2", profile="Desktop:ChatGPT", conv=CONV_B)
        mid2 = self._enqueue("tsk_24g2", "桌面引导 M2")
        stuck = FakeChatGptPage(conv_uuid=CONV_B, is_generating=True, can_steer=False)
        self._desk_tick(stuck)
        self.assertIsNone(stuck.filled)
        self.assertEqual(next(m for m in self._wb()["queue"] if m["id"] == mid2)["last_error"], "busy_generating")

        self._edit_queue(mid2, created_at=_iso_ep(time.time() - 30.0))
        self._desk_tick(stuck)
        msg = next(m for m in self._wb()["queue"] if m["id"] == mid2)
        self.assertEqual((msg["status"], msg["mode"]), ("pending", "new_window_handover"))
        wb = self._wb()
        ret = [r for r in wb["retire_actions"] if r["conv_uuid"] == CONV_B and r["status"] == "pending"]
        self.assertEqual(len(ret), 1)
        self.assertTrue(ret[0]["stop_before_archive"])

        idle = FakeChatGptPage(conv_uuid=CONV_B, is_generating=False, known_convs=[CONV_B])
        self._desk_tick(idle)
        self.assertEqual(idle.stopped, 1)
        self.assertEqual(idle.archived, [CONV_B])
        self.assertEqual(next(m for m in self._wb()["queue"] if m["id"] == mid2)["status"], "delivered")

    def test_t24h_desktop_never_bound_auto_wakeup_waits_instead_of_clicking_new_chat(self):
        self._write_task("tsk_24h", "桌面未认领")
        self._bind("tsk_24h", profile="Desktop:ChatGPT")
        mid = self._enqueue("tsk_24h")
        self._edit_queue(mid, is_auto_wakeup=True, created_at=_iso_ep(time.time() - 120.0))
        page = FakeChatGptPage(conv_uuid=CONV_C, page_hints=[CONV_C])
        self._desk_tick(page)
        msg = next(m for m in self._wb()["queue"] if m["id"] == mid)
        self.assertEqual((msg["status"], msg["mode"], msg["last_error"]), ("pending", "in_place_wakeup", "waiting_room_claim"))
        self.assertNotIn("nav_new_chat", page.ops())
        self.assertIsNone(page.filled)

    def test_t24i_wake_main_window_is_user_initiated_only_and_uses_the_apps_own_command(self):
        res = self._post_json("/studio/action", {"action": "desktop_wake_main_window"})
        self.assertTrue(res["ok"] and res.get("skipped"), "test hubs have host side effects disabled")
        calls = []
        ok = shield.DesktopAppBridge.wake_main_window(eval_fn=lambda expr, kind: calls.append((expr, kind)) or {"ok": True})
        self.assertTrue(ok["ok"])
        self.assertIn("open-current-main-window", calls[0][0])
        self.assertIn("stealFocus:true", calls[0][0])
        bad = shield.DesktopAppBridge.wake_main_window(eval_fn=lambda expr, kind: (_ for _ in ()).throw(RuntimeError("cdp down")))
        self.assertFalse(bad["ok"])
        # Background delivery scripts never ask the app to show / focus its window.
        for script in (RelayCdp.script_state(), RelayCdp.script_fill("m", "t", "", ""), RelayCdp.script_send()):
            self.assertNotIn("open-current-main-window", script)

    def test_t24j_panel_undo_bar_uses_auto_state_and_cancels_the_pending_retire(self):
        self._write_task("tsk_24j", "还原使用 auto 状态并入队 unarchive")
        self._bind("tsk_24j", profile="Chrome:Profile 1", conv=CONV_A)
        self._poll()
        self._post_json("/studio/action", {"action": "set_archive_state", "session_key": "tsk_24j", "state": "archived"})
        self.assertEqual([r["status"] for r in self._wb()["retire_actions"] if r["conv_uuid"] == CONV_A and r["operation"] == "archive"], ["pending"])
        self._post_json("/studio/action", {"action": "set_archive_state", "session_key": "tsk_24j", "state": "auto"})
        wb = self._wb()
        self.assertEqual([r["status"] for r in wb["retire_actions"] if r["conv_uuid"] == CONV_A and r["operation"] == "archive"], ["cancelled"])
        self.assertEqual([r["status"] for r in wb["retire_actions"] if r["conv_uuid"] == CONV_A and r["operation"] == "unarchive"], ["pending"])
        self.assertEqual(wb["session_bindings"]["tsk_24j"]["conv_uuid"], CONV_A)

    def test_t24k_opening_a_pending_handover_page_marks_it_opened_so_no_duplicate_tab_appears(self):
        self._write_task("tsk_24k", "准备中页面点打开网页")
        enq = self._post_json("/studio/action", {
            "action": "enqueue_message", "session_key": "tsk_24k", "mode": "new_window_handover",
            "browser_profile": "Edge:Profile 1", "user_text": "首次发起",
        })
        resp = self._post_json("/studio/action", {"action": "open_tab", "session_key": "tsk_24k", "no_launch": True})
        self.assertEqual(resp["action"], "OpenedBrowserUrl")
        self.assertIn(enq["message_id"], resp["url"], "the page being prepared is opened, never an unrelated old chat")
        msg = next(m for m in self._wb()["queue"] if m["id"] == enq["message_id"])
        self.assertTrue(msg["browser_tab_opened"])
        poll = self._post_json("/web-bridge/poll", {"browser": "Edge", "browser_profile": "Edge:Profile 1", "browser_instance_id": "inst_edge_k", "tabs": []})
        self.assertFalse(any(d.get("open_new_tab") for d in poll["dispatches"]), "the extension must not open a second duplicate tab")


if __name__ == "__main__":
    unittest.main()
