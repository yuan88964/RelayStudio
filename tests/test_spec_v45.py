# -*- coding: utf-8 -*-
"""Spec v4.5 Realistic Business Scenario Seam Tests (S1 ~ S4):
- S1: 4 concurrent -thinking tasks + switch away during handover + >90s deep-thinking background drawer promotion + Open Web navigation
- S2: Consecutive new-window handovers on the same task + stale dataset.relayActiveConvUuid decontamination + batch follow
- S3: Switching carrier from Desktop to Chrome under heavy Desktop load (no false kill/restart + Package Identity launch + Cloudflare challenge backoff)
- S4: 1:1 replay of the 20:31 live incident snapshot (self-healing corrupted draft UUID ea5a01b0-... -> real UUID 6ae5dee7-...)
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

import McpReadOnlyShield as shield
import RelayCdp


class MultiDrawerDesktopCabinetHarness:
    """Executes real RelayCdp JavaScript scripts inside Node.js against a realistic multi-drawer ChatGPT.exe DOM
    (blank home drawer + multiple 0x0 hidden React <Activity> drawers + hidden Codex work drawer + 10-item sidebar)."""

    def __init__(self, initial_scenario: dict):
        self.state_doc = json.loads(json.dumps(initial_scenario))
        self.calls = []

    def evaluate(self, expression: str, kind: str = "main_page"):
        self.calls.append(expression[:40])
        runner_js = r"""
const fs = require("fs");
const input = JSON.parse(fs.readFileSync(0, "utf8"));
const docState = input.state_doc;
const expr = input.expression;

function makeFiberChain(drawer) {
  let top = {
    memoizedProps: {
      scrollStateConversationId: drawer.real_conv_uuid || "",
      conversationId: drawer.real_conv_uuid || (drawer.draft_id ? ("local-chatgpt:" + drawer.draft_id) : ""),
      entries: (drawer.turns || []).map((t, idx) => ({ turnKey: "turn_" + idx, text: t })),
    },
    return: null,
  };
  for (let i = 0; i < 15; i++) {
    top = { memoizedProps: { fillerTop: i }, return: top };
  }
  top = {
    memoizedProps: {
      dockThreadKey: drawer.draft_id ? ("local-chatgpt:" + drawer.draft_id) : (drawer.real_conv_uuid || "new"),
      isHidden: true,
    },
    return: top,
  };
  for (let i = 0; i < 15; i++) {
    top = { memoizedProps: { fillerBottom: i }, return: top };
  }
  top = {
    memoizedProps: {
      isWorkConversation: Boolean(drawer.is_work),
      isSubmitting: Boolean(drawer.is_submitting),
      isStreaming: Boolean(drawer.is_streaming),
      isTurnActive: Boolean(drawer.is_streaming || drawer.is_submitting),
      canQueueNativeAnswerSubmission: Boolean(drawer.can_steer),
      conversationId: drawer.draft_id ? ("local-chatgpt:" + drawer.draft_id) : (drawer.real_conv_uuid || ""),
      selectedModel: { slug: drawer.model || "gpt-5-4-thinking", thinkingEffort: drawer.effort || "extended", versionId: "latest" },
      onModelChange: (next) => {
        if (next && next.slug) drawer.model = next.slug;
        if (next && next.thinkingEffort) drawer.effort = next.thinkingEffort;
      },
      composerController: {
        getText: () => String(drawer.composer_text || ""),
        setText: (val) => { drawer.composer_text = String(val || ""); },
      },
    },
    return: top,
  };
  return top;
}

const forms = docState.drawers.map((d, idx) => {
  const isVisible = (idx === docState.active_drawer_idx) && !d.is_work;
  const parentChain = isVisible
    ? { nodeType: 1, hidden: false, style: { display: "block", visibility: "visible" }, getAttribute: () => null, parentElement: null }
    : { nodeType: 1, hidden: false, style: { display: "none", visibility: "visible" }, getAttribute: () => null, parentElement: null };

  const submitBtn = {
    disabled: false,
    hidden: !isVisible,
    style: { display: isVisible ? "block" : "none", visibility: "visible" },
    hasAttribute: () => false,
    getAttribute: (k) => k === "data-testid" ? "send-button" : null,
    closest: () => null,
    getBoundingClientRect: () => isVisible ? ({ width: 32, height: 32 }) : ({ width: 0, height: 0 }),
    click: () => {
      if (!isVisible) throw new Error("Clicked hidden submit button on drawer " + idx);
      const submittedText = String(d.composer_text || "");
      d.composer_text = "";
      d.turns = d.turns || [];
      d.turns.push(submittedText);
      d.is_submitting = true;
      d.is_streaming = true;
      if (!d.real_conv_uuid && !d.draft_id && docState.next_mint_draft_id) {
        d.draft_id = docState.next_mint_draft_id;
        docState.sidebar_rows.unshift({
          key: "chatgpt:conversation:local-chatgpt:" + d.draft_id,
          title: "新对话思考中",
          active: true,
          error: false,
        });
        for (let i = 1; i < docState.sidebar_rows.length; i++) {
          docState.sidebar_rows[i].active = false;
        }
      }
    },
  };

  return {
    nodeType: 1,
    hidden: false,
    style: { display: "", visibility: "visible" },
    parentElement: parentChain,
    hasAttribute: () => false,
    getAttribute: (k) => (k === "data-codex-composer" && d.is_work) ? "true" : null,
    closest: () => null,
    getBoundingClientRect: () => isVisible ? ({ width: 592, height: 104 }) : ({ width: 0, height: 0 }),
    querySelector: (sel) => (sel.includes("submit") || sel.includes("send")) ? submitBtn : null,
    querySelectorAll: (sel) => {
      if (sel.includes("message") || sel.includes("bubble") || sel.includes("markdown")) {
        return (d.turns || []).map((t) => ({
          nodeType: 1,
          textContent: t,
          getBoundingClientRect: () => isVisible ? ({ width: 500, height: 40 }) : ({ width: 0, height: 0 }),
        }));
      }
      return [];
    },
    requestSubmit: (btn) => (btn || submitBtn).click(),
    __reactFiber$drawer: makeFiberChain(d),
  };
});

const sidebarDomRows = (docState.sidebar_rows || []).map((r) => {
  const innerBtn = {
    click: () => {
      for (const sr of docState.sidebar_rows) sr.active = false;
      r.active = true;
      docState.clicked_sidebar_keys = docState.clicked_sidebar_keys || [];
      docState.clicked_sidebar_keys.push(r.key);
      const m = r.key.match(/([0-9a-fA-F-]{36})$/);
      if (m) {
        const targetId = m[1];
        const foundIdx = docState.drawers.findIndex(
          (d) => d.real_conv_uuid === targetId || d.draft_id === targetId
        );
        if (foundIdx >= 0) docState.active_drawer_idx = foundIdx;
      }
    },
  };
  return {
    getAttribute: (k) => {
      if (k === "data-sidebar-chatgpt-conversation-key") return r.key;
      if (k === "data-sidebar-indicator") return r.error ? "error" : "idle";
      return null;
    },
    querySelector: (sel) => {
      if (sel.includes("aria-current")) return r.active ? { getAttribute: () => "page" } : null;
      return innerBtn;
    },
    click: () => innerBtn.click(),
  };
});

const newChatButton = {
  innerText: "新聊天",
  textContent: "新聊天",
  getAttribute: (k) => k === "aria-label" ? "新聊天" : null,
  closest: () => null,
  click: () => {
    for (const sr of docState.sidebar_rows) sr.active = false;
    let blankIdx = docState.drawers.findIndex((d) => !d.is_work && !d.real_conv_uuid && !d.draft_id && (!d.turns || d.turns.length === 0));
    if (blankIdx < 0) {
      docState.drawers.unshift({
        id: "drawer_blank",
        real_conv_uuid: "",
        draft_id: "",
        turns: [],
        composer_text: "",
        is_submitting: false,
        is_streaming: false,
      });
      blankIdx = 0;
    }
    docState.active_drawer_idx = blankIdx;
  },
  __reactFiber$btn: {
    memoizedProps: {
      projectless: true,
      onStartChat: () => newChatButton.click(),
    },
    return: null,
  },
};

const chatModeTab = {
  innerText: "聊天",
  textContent: "聊天",
  getAttribute: (k) => k === "aria-selected" ? "true" : null,
  click: () => {},
};

const turnNodes = [];
docState.drawers.forEach((d, idx) => {
  const isVisible = (idx === docState.active_drawer_idx) && !d.is_work;
  const parentChain = isVisible
    ? { nodeType: 1, hidden: false, style: { display: "block", visibility: "visible" }, getAttribute: () => null, parentElement: null }
    : { nodeType: 1, hidden: false, style: { display: "none", visibility: "visible" }, getAttribute: () => null, parentElement: null };
  for (const t of (d.turns || [])) {
    turnNodes.push({
      nodeType: 1,
      hidden: false,
      style: { display: "", visibility: "visible" },
      parentElement: parentChain,
      hasAttribute: () => false,
      getAttribute: () => null,
      closest: () => null,
      getBoundingClientRect: () => isVisible ? ({ width: 520, height: 60 }) : ({ width: 0, height: 0 }),
      textContent: t,
    });
  }
});

global.window = global;
global.window.__RELAYSTUDIO_PAGE_HOOK_INSTALLED__ = true;
global.window.__relayDesktopDispatch = docState.dispatch_tracker || null;
global.location = { href: "app://-/index.html", protocol: "app:", pathname: "/index.html" };
global.getComputedStyle = (el) => (el && el.style) || { display: "block", visibility: "visible" };
global.document = {
  title: "ChatGPT",
  documentElement: { dataset: docState.dataset || {} },
  querySelector: (sel) => {
    if (sel.includes("data-sidebar-chatgpt-conversation-key=")) {
      const m = sel.match(/data-sidebar-chatgpt-conversation-key="([^"]+)"/);
      if (m) return sidebarDomRows.find((r) => r.getAttribute("data-sidebar-chatgpt-conversation-key") === m[1]) || null;
    }
    if (sel.includes("create-new-chat-button")) return newChatButton;
    return null;
  },
  querySelectorAll: (sel) => {
    if (sel.includes("data-chatgpt-composer")) return forms;
    if (sel.includes("data-sidebar-chatgpt-conversation-key")) {
      if (sel.includes("=")) {
        const m = sel.match(/data-sidebar-chatgpt-conversation-key="([^"]+)"/);
        return m ? sidebarDomRows.filter((r) => r.getAttribute("data-sidebar-chatgpt-conversation-key") === m[1]) : [];
      }
      return sidebarDomRows;
    }
    if (sel.includes("data-user-message-bubble") || sel.includes("data-markdown-text-style") || sel.includes("data-message-author-role")) {
      return turnNodes;
    }
    if (sel.includes("button")) return [newChatButton, chatModeTab];
    return [];
  },
};

const result = eval(expr);
docState.dataset = global.document.documentElement.dataset;
docState.dispatch_tracker = global.window.__relayDesktopDispatch;
console.log(JSON.stringify({ result, state_doc: docState }));
"""
        proc = subprocess.run(
            ["node", "-e", runner_js],
            input=json.dumps({"state_doc": self.state_doc, "expression": expression}),
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=10,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"Node cabinet harness failed: {proc.stderr}")
        out = json.loads(proc.stdout.strip())
        self.state_doc = out["state_doc"]
        return out["result"]


class TestSpecV45RealisticBusinessScenarios(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = self.temp_dir.name
        self.data_root = os.path.join(self.root, "data")
        self.logs_dir = os.path.join(self.data_root, "logs")
        self.tasks_root = os.path.join(self.root, "engine-data", "tasks")
        os.makedirs(self.logs_dir, exist_ok=True)
        os.makedirs(self.tasks_root, exist_ok=True)
        self.wb_path = os.path.join(self.logs_dir, "web-bridge-state.json")
        self._orig_side_effects = shield._HOST_SIDE_EFFECTS_ENABLED
        shield._HOST_SIDE_EFFECTS_ENABLED = False

    def tearDown(self):
        shield._HOST_SIDE_EFFECTS_ENABLED = self._orig_side_effects
        self.temp_dir.cleanup()

    def _write_task(self, task_id: str, title: str):
        doc = {
            "id": task_id,
            "title": title,
            "goal": title,
            "status": "in_progress",
            "summary": f"正在推进 {title}",
            "updated_at": "2026-10-31T12:25:00Z",
            "steps": [
                {"id": "S1", "title": "步骤1", "status": "completed"},
                {"id": "S2", "title": "步骤2", "status": "completed"},
                {"id": "S3", "title": "步骤3", "status": "in_progress"},
            ],
            "checkpoints": [],
        }
        with open(os.path.join(self.tasks_root, f"{task_id}.json"), "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False)

    def _setup_four_concurrent_tasks(self):
        t1 = ("tsk_8299bc565a9449b8", "比较超级赛亚人4与超级赛亚人之神", "794847a8-6cf4-83eb-a8dc-c1ab1c97a7da", "new_window")
        t2 = ("tsk_8964aaaaaaaaaaaa", "解释\"8964\"的历史含义与背景", "22222222-2222-4222-8222-222222222222", "follow_window")
        t3 = ("tsk_dbzbbbbbbbbbbbbb", "比较《龙珠Z》与《龙珠超》", "33333333-3333-4333-8333-333333333333", "follow_window")
        t4 = ("tsk_jjkccccccccccccc", "解释《咒术回战》的新宿决战", "44444444-4444-4444-8444-444444444444", "follow_window")
        for tid, title, conv, mode in (t1, t2, t3, t4):
            self._write_task(tid, title)
            shield.handle_studio_action(
                self.data_root,
                self.tasks_root,
                self.wb_path,
                {
                    "action": "bind_session",
                    "session_key": tid,
                    "conv_uuid": conv,
                    "tab_id": shield.DesktopAppBridge.TAB_ID,
                    "browser": "Desktop",
                    "browser_profile": "Desktop:ChatGPT",
                    "target_mode": mode,
                    "target_model": "gpt-5-4-thinking",
                    "reasoning_effort": "extended",
                },
            )
        return t1[0], t2[0], t3[0], t4[0]

    def test_s1_four_concurrent_thinking_tasks_switch_away_and_promote_after_95s_without_crosstalk(self):
        """Scenario S1:
        - 4 concurrent -thinking tasks bound to Desktop:ChatGPT.
        - Task 1 initiates New Window Handover; while thinking, sidebar & drawer only have 'local-chatgpt:ea5a01b0-...'.
        - User immediately switches away to Task 2 and then to the blank '今天想聊点什么？' screen.
        - 95 seconds later (>60s), Task 1's hidden background drawer finishes thinking and mints real UUID '6ae5dee7-...'.
        - Tick promotes Task 1 to '6ae5dee7-...' without touching Tasks 2/3/4, and clicking '打开网页 ↗' navigates to '6ae5dee7-...'."""
        t1_id, t2_id, t3_id, t4_id = self._setup_four_concurrent_tasks()
        draft_uuid = "ea5a01b0-6fa6-4f5e-8078-ae23a96ad40d"
        real_new_uuid = "6ae5dee7-9454-83e8-beb6-651808c2f645"

        cabinet = MultiDrawerDesktopCabinetHarness({
            "active_drawer_idx": 1,
            "next_mint_draft_id": draft_uuid,
            "dataset": {"relayActiveConvUuid": "794847a8-6cf4-83eb-a8dc-c1ab1c97a7da"},
            "drawers": [
                {"id": "d_blank", "real_conv_uuid": "", "draft_id": "", "turns": [], "composer_text": ""},
                {"id": "d_t1_old", "real_conv_uuid": "794847a8-6cf4-83eb-a8dc-c1ab1c97a7da", "draft_id": "", "turns": [f"旧对话 {t1_id}"], "composer_text": ""},
                {"id": "d_t2", "real_conv_uuid": "22222222-2222-4222-8222-222222222222", "draft_id": "", "turns": [f"历史含义 {t2_id}"], "composer_text": "", "is_streaming": True},
                {"id": "d_t3", "real_conv_uuid": "33333333-3333-4333-8333-333333333333", "draft_id": "", "turns": [f"龙珠对比 {t3_id}"], "composer_text": "", "is_streaming": True},
                {"id": "d_t4", "real_conv_uuid": "44444444-4444-4444-8444-444444444444", "draft_id": "", "turns": [f"新宿决战 {t4_id}"], "composer_text": ""},
                {"id": "d_work", "is_work": True, "real_conv_uuid": "99999999-9999-4999-8999-999999999999", "draft_id": "", "turns": [], "composer_text": "codex work draft"},
            ],
            "sidebar_rows": [
                {"key": "chatgpt:conversation:794847a8-6cf4-83eb-a8dc-c1ab1c97a7da", "title": "超级赛亚人4对比神", "active": True},
                {"key": "chatgpt:conversation:22222222-2222-4222-8222-222222222222", "title": "解释8964含义", "active": False},
                {"key": "chatgpt:conversation:33333333-3333-4333-8333-333333333333", "title": "龙珠Z超对比", "active": False},
                {"key": "chatgpt:conversation:44444444-4444-4444-8444-444444444444", "title": "解释新宿决战", "active": False},
            ],
        })

        # User initiates New Window Handover on Task 1
        enq = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": t1_id,
                "mode": "new_window_handover",
                "user_text": "比较战斗力大小规律",
                "manual_send": True,
                "browser_profile": "Desktop:ChatGPT",
            },
        )
        self.assertTrue(enq.get("ok"))

        # Tick 1: Delivers handover message into the blank drawer; ChatGPT Desktop creates 'local-chatgpt:ea5a01b0-...' while thinking
        tick1 = shield.DesktopAppBridge.tick(
            self.wb_path,
            self.tasks_root,
            eval_fn=cabinet.evaluate,
            sleep_fn=lambda _: None,
        )
        self.assertEqual(tick1["processed"], 1)
        self.assertTrue(tick1["delivery"]["ok"])

        st_after_send = shield._load_web_bridge_state(self.wb_path)
        b1_after_send = st_after_send["session_bindings"][t1_id]
        # Must NEVER bind the fake draft UUID 'ea5a01b0-...' as formal conv_uuid!
        self.assertNotEqual(
            b1_after_send["conv_uuid"],
            draft_uuid,
            "Must never store client-side local-chatgpt: draft UUID as formal conv_uuid!",
        )
        self.assertEqual(b1_after_send["conv_uuid"], "")
        self.assertIn("794847a8-6cf4-83eb-a8dc-c1ab1c97a7da", b1_after_send["retired_uuids"])

        # User immediately switches away to Task 2 and then clicks "新聊天" so screen sits on a fresh blank drawer!
        # Meanwhile, the handover drawer (now holding draft_uuid) becomes a hidden background drawer!
        cabinet.state_doc["drawers"].insert(
            0,
            {"id": "d_fresh_blank", "real_conv_uuid": "", "draft_id": "", "turns": [], "composer_text": ""},
        )
        cabinet.state_doc["active_drawer_idx"] = 0
        for sr in cabinet.state_doc["sidebar_rows"]:
            sr["active"] = False

        # Simulate 95 seconds passing (> old 60s limit) and the hidden handover drawer finishing thinking & minting real_new_uuid
        for d in cabinet.state_doc["drawers"]:
            if d.get("draft_id") == draft_uuid:
                d["real_conv_uuid"] = real_new_uuid
                d["is_submitting"] = False
                d["is_streaming"] = False
        for sr in cabinet.state_doc["sidebar_rows"]:
            if draft_uuid in sr["key"]:
                sr["key"] = f"chatgpt:conversation:{real_new_uuid}"
                sr["title"] = "比较战斗力大小规律"

        # Backdate desktop_draft_until by 95 seconds to prove >60s deep-thinking turns still promote
        with shield._WEB_BRIDGE_LOCK:
            st_mid = shield._load_web_bridge_state(self.wb_path)
            if st_mid["session_bindings"][t1_id].get("desktop_draft_until"):
                st_mid["session_bindings"][t1_id]["desktop_draft_until"] -= 95.0
            shield._save_web_bridge_state(self.wb_path, st_mid)

        # Tick 2: Screen is STILL on the blank home drawer ("今天想聊点什么？"), yet background drawer has minted real_new_uuid
        shield.DesktopAppBridge.tick(
            self.wb_path,
            self.tasks_root,
            eval_fn=cabinet.evaluate,
            sleep_fn=lambda _: None,
        )

        st_promoted = shield._load_web_bridge_state(self.wb_path)
        self.assertEqual(
            st_promoted["session_bindings"][t1_id]["conv_uuid"],
            real_new_uuid,
            "Must promote Task 1 to real server UUID from hidden background drawer even while blank screen is active after 95s!",
        )
        # Verify zero crosstalk with Tasks 2, 3, 4
        self.assertEqual(st_promoted["session_bindings"][t2_id]["conv_uuid"], "22222222-2222-4222-8222-222222222222")
        self.assertEqual(st_promoted["session_bindings"][t3_id]["conv_uuid"], "33333333-3333-4333-8333-333333333333")
        self.assertEqual(st_promoted["session_bindings"][t4_id]["conv_uuid"], "44444444-4444-4444-8444-444444444444")

        # User clicks "🌐 打开网页 ↗" on Task 1
        open_res = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "open_tab",
                "session_key": t1_id,
                "browser_profile": "Desktop:ChatGPT",
                "no_launch": True,
            },
        )
        self.assertTrue(open_res.get("ok"))
        self.assertEqual(open_res["conv_uuid"], real_new_uuid)
        nav_ok = shield.DesktopAppBridge.navigate_to_conversation(open_res["conv_uuid"], eval_fn=cabinet.evaluate)
        self.assertTrue(nav_ok)
        self.assertIn(f"chatgpt:conversation:{real_new_uuid}", cabinet.state_doc.get("clicked_sidebar_keys", []))

    def test_s2_consecutive_new_window_handovers_with_stale_dataset_uuid_and_batch_follow(self):
        """Scenario S2:
        - Task 1 just finished round 1 ('794847a8-...'), leaving dataset.relayActiveConvUuid='794847a8-...' on <html>.
        - User fires a new handover (M1) and 3 seconds later sends a follow-up question (M2).
        - Clicking '新聊天' must immediately recognize the blank drawer (ignoring stale dataset.relayActiveConvUuid) without 'new_chat_not_ready'.
        - Once M1 mints '6ae5dee7-...', M2 automatically follows into '6ae5dee7-...' without opening a 3rd chat."""
        t1_id, _, _, _ = self._setup_four_concurrent_tasks()
        real_new_uuid = "6ae5dee7-9454-83e8-beb6-651808c2f645"

        cabinet = MultiDrawerDesktopCabinetHarness({
            "active_drawer_idx": 0,
            "next_mint_draft_id": "dddd0002-2222-4222-8222-222222222222",
            "dataset": {"relayActiveConvUuid": "794847a8-6cf4-83eb-a8dc-c1ab1c97a7da"},
            "drawers": [
                {
                    "id": "d_round1",
                    "real_conv_uuid": "794847a8-6cf4-83eb-a8dc-c1ab1c97a7da",
                    "draft_id": "",
                    "turns": [f"第一轮对话 {t1_id}"],
                    "composer_text": "",
                },
            ],
            "sidebar_rows": [
                {"key": "chatgpt:conversation:794847a8-6cf4-83eb-a8dc-c1ab1c97a7da", "title": "超级赛亚人4对比神", "active": True},
            ],
        })

        m1 = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": t1_id,
                "mode": "new_window_handover",
                "user_text": "请总结战斗力膨胀系数",
                "manual_send": True,
                "browser_profile": "Desktop:ChatGPT",
            },
        )
        m2 = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": t1_id,
                "mode": "new_window_handover",
                "user_text": "补充对比自在极意功",
                "manual_send": True,
                "browser_profile": "Desktop:ChatGPT",
            },
        )
        self.assertEqual(m1["message"]["mode"], "new_window_handover")
        self.assertEqual(m2["message"]["mode"], "custom_message")

        # Tick 1: Delivers pioneer M1. Must NOT fail with new_chat_not_ready despite dataset.relayActiveConvUuid!
        t_res1 = shield.DesktopAppBridge.tick(
            self.wb_path,
            self.tasks_root,
            eval_fn=cabinet.evaluate,
            sleep_fn=lambda _: None,
        )
        self.assertEqual(t_res1["processed"], 1, f"Pioneer M1 must deliver without new_chat_not_ready! Got: {t_res1}")
        self.assertTrue(t_res1["delivery"]["ok"])

        # Cloud mints real_new_uuid and finishes generating M1's turn
        active_d = cabinet.state_doc["drawers"][cabinet.state_doc["active_drawer_idx"]]
        active_d["real_conv_uuid"] = real_new_uuid
        active_d["is_submitting"] = False
        active_d["is_streaming"] = False
        cabinet.state_doc["sidebar_rows"].insert(
            0,
            {"key": f"chatgpt:conversation:{real_new_uuid}", "title": "比较战斗力大小规律", "active": True},
        )

        # Tick 2: Promotes binding to real_new_uuid and delivers follow-up M2 in-place into real_new_uuid!
        t_res2 = shield.DesktopAppBridge.tick(
            self.wb_path,
            self.tasks_root,
            eval_fn=cabinet.evaluate,
            sleep_fn=lambda _: None,
        )
        self.assertEqual(t_res2["processed"], 1)
        self.assertTrue(t_res2["delivery"]["ok"])
        active_d_after = cabinet.state_doc["drawers"][cabinet.state_doc["active_drawer_idx"]]
        self.assertIn("补充对比自在极意功", active_d_after["turns"][-1])

    def test_s3_switch_carrier_desktop_to_chrome_under_heavy_load_preserves_desktop_and_avoids_cloudflare_burst(self):
        """Scenario S3:
        - ChatGPT.exe is running with --remote-debugging-port=9222 in its command line, but HTTP probe times out under heavy load.
        - DesktopAppBridge must NEVER kill or restart ChatGPT.exe when has_debug_port/booting is True.
        - ensure_chatgpt_desktop uses Invoke-CommandInDesktopPackage with CODEX_ELECTRON_START_IN_BACKGROUND=1 when minimized.
        - bridge-page-hook.js makes ZERO proactive fetch('/api/auth/session') or fetch('/backend-api/models') calls while on a Cloudflare challenge page."""
        t1_id, _, _, _ = self._setup_four_concurrent_tasks()

        # 1. Verify find_cdp_endpoint & DesktopAppBridge._ensure_host never kill/restart a port-equipped ChatGPT.exe on timeout
        fake_probe = lambda: {
            "running": True,
            "main_pid": 38884,
            "cmd_ports": [9222],
            "listen_ports": [9222],
        }
        fake_http_timeout = lambda url, timeout=1.5: (_ for _ in ()).throw(TimeoutError("CDP busy under thinking load"))
        ep = RelayCdp.find_cdp_endpoint(cached_port=9222, probe_fn=fake_probe, http_fn=fake_http_timeout)
        self.assertTrue(ep["running"])
        self.assertTrue(ep.get("booting") or ep.get("has_debug_port"))

        # Even if a pending Desktop message exists and _last_launch_at was long ago, tick must NOT call launcher(restart=True)
        shield.DesktopAppBridge._last_launch_at = 0.0
        shield.DesktopAppBridge._last_restart_at = 0.0
        shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": t1_id,
                "user_text": "测试繁忙时不重启",
                "browser_profile": "Desktop:ChatGPT",
            },
        )
        launcher_calls = []
        shield.DesktopAppBridge.tick(
            self.wb_path,
            self.tasks_root,
            endpoint_fn=lambda _: ep,
            launcher_fn=lambda **kw: launcher_calls.append(kw) or {"ok": True, "port": 9222},
            sleep_fn=lambda _: None,
        )
        self.assertEqual(launcher_calls, [], "Must NEVER kill or hot-restart ChatGPT.exe when it already has a debug port!")

        # 2. Verify ensure_chatgpt_desktop uses Invoke-CommandInDesktopPackage (Cockpit Tools pattern)
        ps_commands = []
        def fake_run_ps(script: str, timeout: float = 8.0) -> str:
            ps_commands.append(script)
            if "Get-AppxPackage" in script:
                return r"C:\Program Files\WindowsApps\OpenAI.Codex_26.1023.6621.0_x64__2p2nqsd0c76g0"
            if "Invoke-CommandInDesktopPackage" in script:
                return "LAUNCHED_OK"
            return ""

        orig_isfile = os.path.isfile
        try:
            os.path.isfile = lambda p: True if "ChatGPT.exe" in str(p) else orig_isfile(p)
            launch_res = RelayCdp.ensure_chatgpt_desktop(
                minimize_no_activate=True,
                restart=False,
                popen_fn=lambda *a, **kw: True,
                run_ps=fake_run_ps,
                port=9222,
            )
        finally:
            os.path.isfile = orig_isfile
        self.assertTrue(launch_res["ok"])
        self.assertTrue(
            any("Invoke-CommandInDesktopPackage" in cmd and "CODEX_ELECTRON_START_IN_BACKGROUND" in cmd for cmd in ps_commands),
            f"ensure_chatgpt_desktop must launch via Invoke-CommandInDesktopPackage with background env! Got: {ps_commands}",
        )

        # 3. Verify bridge-page-hook.js fires ZERO proactive fetch calls on a Cloudflare challenge page (no composer in DOM)
        hook_js_path = os.path.join(REPO_ROOT, "browser-bridge", "bridge-page-hook.js")
        cf_harness = r"""
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
let proactiveFetches = [];
let scheduledCallbacks = [];

global.window = {
  location: { href: "https://chatgpt.com/?relay_handover=1&msg_id=msg_123", protocol: "https:", pathname: "/" },
  fetch: async (url) => {
    proactiveFetches.push(String(url));
    return { ok: true, json: async () => ({}), clone: function() { return this; } };
  },
  addEventListener: () => {},
  dispatchEvent: () => {},
  setTimeout: (fn) => { scheduledCallbacks.push(fn); return 1; },
};
global.location = global.window.location;
global.setTimeout = global.window.setTimeout;
global.localStorage = { getItem: () => null, setItem: () => {} };
global.document = {
  readyState: "complete",
  title: "Just a moment...",
  documentElement: { dataset: {} },
  addEventListener: () => {},
  querySelector: () => null,
  querySelectorAll: () => [],
};

eval(src);
// Run any timer callbacks that bridge-page-hook scheduled on startup while still on Cloudflare challenge screen
for (const fn of scheduledCallbacks) {
  try { fn(); } catch (_) {}
}
console.log(JSON.stringify({ proactiveFetches }));
"""
        proc = subprocess.run(
            ["node", "-e", cf_harness, hook_js_path],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=10,
        )
        self.assertEqual(proc.returncode, 0, msg=f"Node failed: {proc.stderr}")
        cf_out = json.loads(proc.stdout.strip())
        self.assertEqual(
            cf_out["proactiveFetches"],
            [],
            "bridge-page-hook.js must fire ZERO proactive fetches while on Cloudflare challenge page without composer DOM!",
        )

    def test_s4_live_incident_2031_snapshot_replay_self_heals_corrupted_draft_binding_and_opens_target_chat(self):
        """Scenario S4:
        - Exact 1:1 replay of the 20:31 screenshot state:
          Task 'tsk_8299bc565a9449b8' already has its conv_uuid corrupted to 'ea5a01b0-6fa6-4f5e-8078-ae23a96ad40d',
          desktop_draft_until is 0.0 (expired), active drawer is blank ('今天想聊点什么？'),
          and hidden drawer idx 3 holds both 'local-chatgpt:ea5a01b0-...' and real UUID '6ae5dee7-9454-83e8-beb6-651808c2f645'.
        - One tick + clicking '打开网页 ↗' must self-heal conv_uuid to '6ae5dee7-...' and click that conversation in the sidebar."""
        t1_id = "tsk_8299bc565a9449b8"
        corrupted_draft_uuid = "ea5a01b0-6fa6-4f5e-8078-ae23a96ad40d"
        real_uuid = "6ae5dee7-9454-83e8-beb6-651808c2f645"
        self._write_task(t1_id, "比较超级赛亚人4与超级赛亚人之神")

        # Write the exact corrupted binding from the 20:31 incident
        with shield._WEB_BRIDGE_LOCK:
            state = shield._load_web_bridge_state(self.wb_path)
            b = shield._ensure_binding_entry(None, "Desktop:ChatGPT")
            b["conv_uuid"] = corrupted_draft_uuid
            b["retired_uuids"] = ["794847a8-6cf4-83eb-a8dc-c1ab1c97a7da"]
            b["target_mode"] = "new_window"
            b["desktop_draft_conv"] = ""
            b["desktop_handover_pending_uuid"] = False
            b["desktop_draft_until"] = 0.0
            state["session_bindings"][t1_id] = b
            shield._save_web_bridge_state(self.wb_path, state)

        cabinet = MultiDrawerDesktopCabinetHarness({
            "active_drawer_idx": 0,
            "dataset": {"relayActiveConvUuid": real_uuid},
            "drawers": [
                {"id": "d_blank_0", "real_conv_uuid": "", "draft_id": "", "turns": [], "composer_text": ""},
                {"id": "d_old_1", "real_conv_uuid": "794847a8-6cf4-83eb-a8dc-c1ab1c97a7da", "draft_id": "", "turns": [f"旧轮次 {t1_id}"], "composer_text": ""},
                {
                    "id": "d_target_3",
                    "real_conv_uuid": real_uuid,
                    "draft_id": corrupted_draft_uuid,
                    "turns": [f"【RelayStudio 自动换窗交接单】接力主任务 ID：`{t1_id}` 比较战斗力大小规律"],
                    "composer_text": "",
                },
            ],
            "sidebar_rows": [
                {"key": f"chatgpt:conversation:{real_uuid}", "title": "比较战斗力大小规律", "active": False},
                {"key": "chatgpt:conversation:794847a8-6cf4-83eb-a8dc-c1ab1c97a7da", "title": "超级赛亚人4对比神", "active": False},
            ],
        })

        # Run 1 tick while screen is on blank drawer 0
        shield.DesktopAppBridge.tick(
            self.wb_path,
            self.tasks_root,
            eval_fn=cabinet.evaluate,
            sleep_fn=lambda _: None,
        )

        healed_state = shield._load_web_bridge_state(self.wb_path)
        self.assertEqual(
            healed_state["session_bindings"][t1_id]["conv_uuid"],
            real_uuid,
            "Corrupted draft UUID ea5a01b0-... must self-heal to real server UUID 6ae5dee7-... from hidden drawer idx 3!",
        )

        # Clicking "打开网页 ↗" now resolves and navigates to the healed real UUID
        open_res = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "open_tab",
                "session_key": t1_id,
                "browser_profile": "Desktop:ChatGPT",
                "no_launch": True,
            },
        )
        self.assertEqual(open_res["conv_uuid"], real_uuid)
        nav_ok = shield.DesktopAppBridge.navigate_to_conversation(open_res["conv_uuid"], eval_fn=cabinet.evaluate)
        self.assertTrue(nav_ok)
        self.assertEqual(cabinet.state_doc["active_drawer_idx"], 2, "Must switch active drawer to d_target_3 (比较战斗力大小规律)!")


if __name__ == "__main__":
    unittest.main()
