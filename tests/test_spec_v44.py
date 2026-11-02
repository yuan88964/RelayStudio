# -*- coding: utf-8 -*-
"""Spec v4.4 Seam Tests:
- Seam 1: Studio Hub HTTP / Queue / Binding Transfer / Deferred Stop-Wait Handover
- Seam 2: Desktop Bridge Agent Active Drawer Resolution & Web Probe DOM Inspector
- Seam 3: Studio Panel Launchpad $PID safety & Interactive Desktop Spawning
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

import McpReadOnlyShield as shield
import RelayCdp


class TestSpecV44Seam1HubAndQueue(unittest.TestCase):
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

    def _write_task(self, task_id: str, title: str = "测试任务"):
        doc = {
            "id": task_id,
            "title": title,
            "goal": title,
            "status": "in_progress",
            "summary": "已完成第一阶段分析",
            "updated_at": "2026-10-31T03:30:00Z",
            "steps": [{"id": "S1", "title": "步骤1", "status": "completed"}],
            "checkpoints": [],
        }
        with open(os.path.join(self.tasks_root, f"{task_id}.json"), "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False)

    def test_per_task_target_mode_does_not_pollute_global_or_other_tasks(self):
        """Setting target_mode='new_window' on task A must keep task A in 'new_window' without mutating global default or task B."""
        self._write_task("tsk_aaa1111111111111", "任务A")
        self._write_task("tsk_bbb2222222222222", "任务B")

        res_a = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "set_composer_config",
                "session_key": "tsk_aaa1111111111111",
                "target_mode": "new_window",
            },
        )
        self.assertTrue(res_a.get("ok"))

        state = shield._load_web_bridge_state(self.wb_path)
        self.assertEqual(state["session_bindings"]["tsk_aaa1111111111111"]["target_mode"], "new_window")
        self.assertEqual(state["auto_resend_config"].get("target_mode", "follow_window"), "follow_window")

        # Enqueue a message on task B (which already has a bound conv_uuid and never set target_mode='new_window')
        state["session_bindings"]["tsk_bbb2222222222222"] = shield._ensure_binding_entry(
            {"conv_uuid": "6ae55a76-bce4-83e8-bf49-f97e485f45b0", "browser_profile": "Chrome:Profile 1"},
            default_cfg=state["auto_resend_config"],
        )
        shield._save_web_bridge_state(self.wb_path, state)

        enq_b = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": "tsk_bbb2222222222222",
                "user_text": "继续推进任务B",
                "browser_profile": "Chrome:Profile 1",
            },
        )
        self.assertTrue(enq_b.get("ok"))
        self.assertEqual(enq_b["message"]["mode"], "custom_message")

    def test_batch_follow_queueing_in_new_window_mode_preserves_fifo_and_follows_new_room(self):
        """In new_window mode, sending 3 consecutive messages must NOT supersede earlier user messages:
        - 1st message is new_window_handover pioneer;
        - 2nd and 3rd messages queue as custom_message behind it;
        - Once 1st message delivers and binds the new conv_uuid, 2nd and 3rd messages follow that new conv_uuid;
        - Task's target_mode remains 'new_window' for future post-turn handovers."""
        task_id = "tsk_7ca77de353c94c50"
        old_conv = "6ae55f99-ac98-83e8-baaf-4fc46253b333"
        new_conv = "6ae561e7-e6fc-83e8-b042-04b0feba5640"
        self._write_task(task_id, "一首简单的歌让你的心情快乐是什么意思")

        shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "bind_session",
                "session_key": task_id,
                "conv_uuid": old_conv,
                "tab_id": "101",
                "browser": "Chrome",
                "browser_profile": "Chrome:Profile 1",
            },
        )
        shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "set_composer_config",
                "session_key": task_id,
                "target_mode": "new_window",
            },
        )

        # User sends 3 messages in a row while in new_window mode
        r1 = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": task_id,
                "mode": "new_window_handover",
                "user_text": "第一句指令",
                "display_text": "第一句指令",
                "manual_send": True,
                "browser_profile": "Chrome:Profile 1",
            },
        )
        r2 = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": task_id,
                "mode": "new_window_handover",
                "user_text": "第二句追问",
                "display_text": "第二句追问",
                "manual_send": True,
                "browser_profile": "Chrome:Profile 1",
            },
        )
        r3 = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": task_id,
                "mode": "new_window_handover",
                "user_text": "第三句补充",
                "display_text": "第三句补充",
                "manual_send": True,
                "browser_profile": "Chrome:Profile 1",
            },
        )

        state = shield._load_web_bridge_state(self.wb_path)
        q_msgs = [m for m in state["queue"] if m.get("session_key") == task_id]
        self.assertEqual(len(q_msgs), 3)
        self.assertEqual([m["status"] for m in q_msgs], ["pending", "pending", "pending"])
        self.assertEqual(q_msgs[0]["mode"], "new_window_handover")
        self.assertIn("第一句指令", q_msgs[0]["prompt"])
        self.assertEqual(q_msgs[1]["mode"], "custom_message")
        self.assertEqual(q_msgs[1]["prompt"], "第二句追问")
        self.assertEqual(q_msgs[2]["mode"], "custom_message")
        self.assertEqual(q_msgs[2]["prompt"], "第三句补充")

        # Clicking "新建网页交接" with empty user_text while pioneer r1 is already pending must idempotently reuse r1
        r_empty = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": task_id,
                "mode": "new_window_handover",
                "user_text": "",
                "manual_send": True,
                "browser_profile": "Chrome:Profile 1",
            },
        )
        self.assertTrue(r_empty.get("ok"))
        self.assertEqual(r_empty["message_id"], r1["message_id"])
        state_after_empty = shield._load_web_bridge_state(self.wb_path)
        self.assertEqual(len([m for m in state_after_empty["queue"] if m.get("session_key") == task_id]), 3)

        # 1st poll claims only the pioneer (r1) to open the new window
        poll1 = shield.handle_web_bridge_poll(
            self.wb_path,
            self.tasks_root,
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Profile 1",
                "browser_instance_id": "inst_19",
                "tabs": [
                    {
                        "tab_id": "101",
                        "conv_uuid": old_conv,
                        "url": f"https://chatgpt.com/c/{old_conv}",
                        "is_generating": False,
                        "sse_active": False,
                    }
                ],
            },
        )
        self.assertEqual(len(poll1["dispatches"]), 1)
        self.assertEqual(poll1["dispatches"][0]["msg_id"], r1["message_id"])
        self.assertTrue(poll1["dispatches"][0]["open_new_tab"])

        # Pioneer r1 is delivered into new tab 202 with new_conv
        ack1 = shield.handle_web_bridge_ack_deliver(
            self.wb_path,
            {
                "msg_id": r1["message_id"],
                "tab_id": "202",
                "conv_uuid": new_conv,
            },
        )
        self.assertTrue(ack1.get("ok"))

        state_after_ack1 = shield._load_web_bridge_state(self.wb_path)
        binding = state_after_ack1["session_bindings"][task_id]
        self.assertEqual(binding["conv_uuid"], new_conv)
        self.assertIn(old_conv, binding["retired_uuids"])
        # Target mode remains 'new_window' as a persistent per-task mode
        self.assertEqual(binding["target_mode"], "new_window")

        # 2nd poll: new tab 202 (new_conv) finishes first turn (is_generating=False) -> r2 is dispatched in-place to tab 202!
        poll2 = shield.handle_web_bridge_poll(
            self.wb_path,
            self.tasks_root,
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Profile 1",
                "browser_instance_id": "inst_19",
                "tabs": [
                    {
                        "tab_id": "202",
                        "conv_uuid": new_conv,
                        "url": f"https://chatgpt.com/c/{new_conv}",
                        "is_generating": False,
                        "sse_active": False,
                        "turn_seq": 1,
                    }
                ],
            },
        )
        self.assertEqual(len(poll2["dispatches"]), 1)
        self.assertEqual(poll2["dispatches"][0]["msg_id"], r2["message_id"])
        self.assertFalse(poll2["dispatches"][0]["open_new_tab"])
        self.assertEqual(poll2["dispatches"][0]["tab_id"], "202")
        self.assertEqual(poll2["dispatches"][0]["conv_uuid"], new_conv)

    def test_defer_until_stopped_releases_when_turn_stops_or_old_tab_closes(self):
        """A defer_until_stopped handover must hold while old tab is generating, and fire immediately once old tab stops OR closes."""
        task_id = "tsk_defer11111111111"
        old_conv = "6ae55f99-ac98-83e8-baaf-4fc46253b333"
        self._write_task(task_id, "延迟交接测试")

        shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "bind_session",
                "session_key": task_id,
                "conv_uuid": old_conv,
                "tab_id": "101",
                "browser": "Chrome",
                "browser_profile": "Chrome:Profile 1",
            },
        )

        enq = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": task_id,
                "mode": "new_window_handover",
                "user_text": "等停稳后换新窗",
                "defer_until_stopped": True,
                "manual_send": True,
                "browser_profile": "Chrome:Profile 1",
            },
        )
        self.assertTrue(enq.get("ok"))

        # Poll while old tab is still generating -> held
        poll_live = shield.handle_web_bridge_poll(
            self.wb_path,
            self.tasks_root,
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Profile 1",
                "browser_instance_id": "inst_19",
                "tabs": [
                    {
                        "tab_id": "101",
                        "conv_uuid": old_conv,
                        "url": f"https://chatgpt.com/c/{old_conv}",
                        "is_generating": True,
                        "sse_active": True,
                    }
                ],
            },
        )
        self.assertEqual(len(poll_live["dispatches"]), 0)

        # Poll when user closes the old tab (tabs=[]) -> must release immediately instead of waiting forever!
        poll_closed = shield.handle_web_bridge_poll(
            self.wb_path,
            self.tasks_root,
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Profile 1",
                "browser_instance_id": "inst_19",
                "tabs": [],
            },
        )
        self.assertEqual(len(poll_closed["dispatches"]), 1)
        self.assertEqual(poll_closed["dispatches"][0]["msg_id"], enq["message_id"])
        self.assertTrue(poll_closed["dispatches"][0]["open_new_tab"])

        # Desktop defer_until_stopped must also hold while an MCP tool call is in_flight in shield-activity.json
        from tests.fake_chatgpt_page import FakeChatGptPage
        desk_task = "tsk_defer_desk01"
        self._write_task(desk_task, "桌面端延迟交接工具保护")
        enq_desk = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": desk_task,
                "mode": "new_window_handover",
                "user_text": "等工具跑完换新窗",
                "defer_until_stopped": True,
                "manual_send": True,
                "browser_profile": "Desktop:ChatGPT",
            },
        )
        act_path = os.path.join(self.logs_dir, "shield-activity.json")
        with open(act_path, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "calls": {
                        "rpc_1": {
                            "task_id": desk_task,
                            "in_flight": True,
                            "started_at": shield._utc_now_iso(),
                        }
                    }
                },
                fh,
            )
        desk_page = FakeChatGptPage(conv_uuid=old_conv, new_conv_uuid="88888888-8888-4888-8888-888888888888")
        res_in_flight = shield.DesktopAppBridge.tick(
            self.wb_path, self.tasks_root, eval_fn=desk_page.evaluate, sleep_fn=lambda _: None
        )
        self.assertEqual(res_in_flight["processed"], 0, "Desktop defer_until_stopped must hold while MCP tool is in_flight")
        with open(act_path, "w", encoding="utf-8") as fh:
            json.dump({"calls": {"rpc_1": {"task_id": desk_task, "in_flight": False}}}, fh)
        res_done = shield.DesktopAppBridge.tick(
            self.wb_path, self.tasks_root, eval_fn=desk_page.evaluate, sleep_fn=lambda _: None
        )
        self.assertEqual(res_done["processed"], 1, "Desktop defer_until_stopped must release once MCP tool finishes")
        self.assertEqual(enq_desk["ok"], True)


class TestSpecV44Seam2DesktopAndProbe(unittest.TestCase):
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

    def test_relay_cdp_active_drawer_resolution_ignores_hidden_activity_drawers_and_dock_is_hidden(self):
        """RelayCdp scripts must skip 0x0 React 19 <Activity> hidden drawers (even when form.style.display is empty),
        must NOT reject the active visible drawer when step 89 dockThreadKey has isHidden=true,
        must extract 36-char UUID from scrollStateConversationId, and must scan desktop message bubbles for tsk_ hints."""
        harness = r"""
const fs = require("fs");
const scripts = JSON.parse(fs.readFileSync(0, "utf8"));

const state = {
  activeText: "",
  activeSubmitted: 0,
  hiddenTouched: 0,
};

function makeHiddenDrawerForm(idx) {
  let parentChain = { style: { display: "none", visibility: "visible" }, parentElement: null };
  for (let d = 0; d < 13; d++) {
    parentChain = { style: { display: "", visibility: "visible" }, parentElement: parentChain };
  }
  const submitBtn = {
    disabled: false,
    getAttribute: () => null,
    closest: () => null,
    getBoundingClientRect: () => ({ width: 0, height: 0 }),
    click: () => { state.hiddenTouched++; throw new Error("Clicked hidden drawer button " + idx); },
  };
  return {
    nodeType: 1,
    style: { display: "", visibility: "visible" },
    parentElement: parentChain,
    hasAttribute: () => false,
    getAttribute: () => null,
    closest: () => null,
    getBoundingClientRect: () => ({ width: 0, height: 0 }),
    querySelector: () => submitBtn,
    requestSubmit: () => { state.hiddenTouched++; throw new Error("Submitted hidden drawer " + idx); },
    __reactFiber$hidden: {
      memoizedProps: {
        isHidden: false,
        isWorkConversation: false,
        conversationId: `00000000-0000-4000-8000-00000000000${idx}`,
        composerController: {
          getText: () => "hidden draft " + idx,
          setText: () => { state.hiddenTouched++; throw new Error("Touched hidden drawer " + idx); },
        },
      },
      return: null,
    },
  };
}

const workDrawerForm = {
  nodeType: 1,
  style: { display: "", visibility: "visible" },
  parentElement: null,
  hasAttribute: () => false,
  getAttribute: () => null,
  closest: () => null,
  getBoundingClientRect: () => ({ width: 592, height: 56 }),
  querySelector: () => null,
  __reactFiber$work: {
    memoizedProps: {
      isWorkConversation: true,
      conversationId: "22222222-2222-4222-8222-222222222222",
      composerController: {
        getText: () => "work draft",
        setText: () => { state.hiddenTouched++; throw new Error("Touched work drawer"); },
      },
    },
    return: null,
  },
};

const activeSubmitBtn = {
  disabled: false,
  getAttribute: () => null,
  closest: () => null,
  getBoundingClientRect: () => ({ width: 32, height: 32 }),
  click: () => { state.activeSubmitted++; state.activeText = ""; },
};

// Build 120-step Fiber chain on forms[4] matching real ChatGPT.exe:
// step 6: composerController + local-chatgpt:draft-1
// step 89: { dockThreadKey: "local-chatgpt:draft-1", isHidden: true } (mini-dock hidden!)
// step 119: { scrollStateConversationId: "6ae561e7-e6fc-83e8-b042-04b0feba5640" }
let fChain = {
  memoizedProps: {
    scrollStateConversationId: "6ae561e7-e6fc-83e8-b042-04b0feba5640",
    entries: [{ turnKey: "t1" }, { turnKey: "t2" }],
  },
  return: null,
};
for (let i = 0; i < 29; i++) {
  fChain = { memoizedProps: { stepFillerA: i }, return: fChain };
}
fChain = {
  memoizedProps: {
    dockThreadKey: "local-chatgpt:draft-1",
    isHidden: true,
  },
  return: fChain,
};
for (let i = 0; i < 82; i++) {
  fChain = { memoizedProps: { stepFillerB: i }, return: fChain };
}
fChain = {
  memoizedProps: {
    conversationId: "00000000-0000-4000-8000-000000000000",
    composerController: {
      getText: () => state.activeText,
      setText: (t) => { state.activeText = String(t); },
    },
  },
  return: fChain,
};
for (let i = 0; i < 5; i++) {
  fChain = { memoizedProps: { stepFillerC: i }, return: fChain };
}

const activeDrawerForm = {
  nodeType: 1,
  style: { display: "", visibility: "visible" },
  parentElement: null,
  hasAttribute: () => false,
  getAttribute: () => null,
  closest: () => null,
  getBoundingClientRect: () => ({ width: 592, height: 56 }),
  querySelector: (sel) => (sel.includes("submit") || sel.includes("send")) ? activeSubmitBtn : null,
  requestSubmit: (btn) => (btn || activeSubmitBtn).click(),
  __reactFiber$active: fChain,
};

const forms = [
  makeHiddenDrawerForm(0),
  makeHiddenDrawerForm(1),
  makeHiddenDrawerForm(2),
  makeHiddenDrawerForm(3),
  workDrawerForm,
  activeDrawerForm,
];

const hiddenTurn = {
  nodeType: 1,
  style: { display: "" },
  parentElement: null,
  hasAttribute: () => false,
  getAttribute: () => null,
  closest: () => null,
  getBoundingClientRect: () => ({ width: 0, height: 0 }),
  textContent: "旧抽屉任务 tsk_hidden_drawer_wrong",
};
const activeTurn = {
  nodeType: 1,
  style: { display: "" },
  parentElement: null,
  hasAttribute: () => false,
  getAttribute: () => null,
  closest: () => null,
  getBoundingClientRect: () => ({ width: 560, height: 120 }),
  textContent: "当前活动抽屉任务 tsk_active_drawer_right",
};

global.window = global;
global.location = { href: "app://-/index.html", protocol: "app:", pathname: "/index.html" };
global.getComputedStyle = (el) => el.style || { display: "block", visibility: "visible" };
global.document = {
  title: "ChatGPT",
  documentElement: { dataset: {} },
  querySelector: () => null,
  querySelectorAll: (sel) => {
    if (sel.includes("data-chatgpt-composer")) return forms;
    if (sel.includes("data-user-message-bubble") || sel.includes("data-markdown-text-style")) {
      return [hiddenTurn, activeTurn];
    }
    return [];
  },
};

const st = eval(scripts.state);
const fillRes = eval(scripts.fill);
const filledText = state.activeText;
const sendRes = eval(scripts.send);
console.log(JSON.stringify({ st, fillRes, filledText, sendRes, state }));
"""
        payload = json.dumps({
            "state": RelayCdp.script_state(),
            "fill": RelayCdp.script_fill("msg_v44", "测试指令", "", ""),
            "send": RelayCdp.script_send(),
        })
        proc = subprocess.run(
            ["node", "-e", harness],
            input=payload,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=10,
        )
        self.assertEqual(proc.returncode, 0, msg=f"Node failed: {proc.stderr}")
        out = json.loads(proc.stdout.strip())
        self.assertTrue(out["st"]["has_composer"])
        self.assertEqual(out["st"]["conv_uuid"], "6ae561e7-e6fc-83e8-b042-04b0feba5640")
        self.assertIn("tsk_active_drawer_right", out["st"]["page_hints"])
        self.assertNotIn("tsk_hidden_drawer_wrong", out["st"]["page_hints"])
        self.assertTrue(out["fillRes"]["composer"] and out["fillRes"]["filled"] and out["fillRes"]["native"])
        self.assertEqual(out["filledText"], "测试指令")
        self.assertTrue(out["sendRes"]["clicked"])
        self.assertEqual(out["state"]["activeSubmitted"], 1)
        self.assertEqual(out["state"]["hiddenTouched"], 0)

    def test_desktop_two_phase_binding_transfer_retires_old_conv_even_before_uuid_minted_and_promotes_when_ready(self):
        """When Desktop new_window_handover is accepted while conv_uuid is still '' (local-chatgpt: draft during thinking),
        Phase 1 must immediately retire old_conv and clear binding.conv_uuid so it never points back to old_conv;
        Phase 2 must automatically promote binding.conv_uuid when the 36-char UUID appears on a subsequent tick."""
        from tests.fake_chatgpt_page import FakeChatGptPage

        task_id = "tsk_desk_handover01"
        old_conv = "11111111-1111-4111-8111-111111111111"
        minted_conv = "6ae561e7-e6fc-83e8-b042-04b0feba5640"

        shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "bind_session",
                "session_key": task_id,
                "conv_uuid": old_conv,
                "tab_id": shield.DesktopAppBridge.TAB_ID,
                "browser": "Desktop",
                "browser_profile": "Desktop:ChatGPT",
            },
        )
        enq = shield.handle_studio_action(
            self.data_root,
            self.tasks_root,
            self.wb_path,
            {
                "action": "enqueue_message",
                "session_key": task_id,
                "mode": "new_window_handover",
                "user_text": "换新窗继续",
                "browser_profile": "Desktop:ChatGPT",
            },
        )
        self.assertTrue(enq.get("ok"))

        # Tick 1: ChatGPT.exe accepts the message in a new chat, but new_conv_uuid is still "" (thinking in local-chatgpt: draft)
        page = FakeChatGptPage(conv_uuid=old_conv, new_conv_uuid="", dispatch_status="accepted")
        shield.DesktopAppBridge.tick(
            self.wb_path,
            self.tasks_root,
            eval_fn=page.evaluate,
            sleep_fn=lambda _: None,
        )

        st1 = shield._load_web_bridge_state(self.wb_path)
        b1 = st1["session_bindings"][task_id]
        self.assertIn(old_conv, b1["retired_uuids"], "Phase 1 must immediately retire old_conv even when new conv_uuid is still empty")
        self.assertEqual(b1["conv_uuid"], "", "Phase 1 must clear old_conv so clicking Open Web never jumps back to old_conv")
        self.assertTrue(b1.get("desktop_handover_pending_uuid"))

        # Tick 2: ChatGPT.exe finishes minting the 36-char UUID on the active drawer
        page.conv_uuid = minted_conv
        shield.DesktopAppBridge.tick(
            self.wb_path,
            self.tasks_root,
            eval_fn=page.evaluate,
            sleep_fn=lambda _: None,
        )

        st2 = shield._load_web_bridge_state(self.wb_path)
        b2 = st2["session_bindings"][task_id]
        self.assertEqual(b2["conv_uuid"], minted_conv, "Phase 2 must automatically promote binding.conv_uuid to the minted 36-char UUID")
        self.assertFalse(b2.get("desktop_handover_pending_uuid"))

    def test_bridge_content_is_generating_state_ignores_hidden_or_non_composer_stop_buttons(self):
        """bridge-content.js must NOT report is_generating=True when sse_active=False and only a hidden stop button
        or a non-composer audio 'Stop reading aloud' button exists in the DOM (including inside composerForm or when form is absent)."""
        bridge_js_path = os.path.join(REPO_ROOT, "browser-bridge", "bridge-content.js")
        harness = r"""
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");

// Extract helper functions up to buildLocalTabState
let activeComposerStop = null;
let hasForm = true;
const audioStopBtn = {
  disabled: false,
  hidden: false,
  style: { display: "block", visibility: "visible" },
  hasAttribute: () => false,
  getAttribute: (k) => k === "aria-label" ? "Stop reading aloud" : null,
  closest: () => null,
  getBoundingClientRect: () => ({ width: 24, height: 24 }),
};
const hiddenStopBtn = {
  disabled: false,
  hidden: false,
  style: { display: "", visibility: "visible" },
  hasAttribute: () => false,
  getAttribute: (k) => k === "data-testid" ? "stop-button" : null,
  closest: () => null,
  getBoundingClientRect: () => ({ width: 0, height: 0 }),
};
const composerForm = {
  hidden: false,
  style: { display: "block", visibility: "visible" },
  hasAttribute: () => false,
  getAttribute: () => null,
  closest: () => null,
  getBoundingClientRect: () => ({ width: 592, height: 56 }),
  querySelectorAll: () => [audioStopBtn, hiddenStopBtn].concat(activeComposerStop ? [activeComposerStop] : []),
  querySelector: () => activeComposerStop || audioStopBtn,
};
const composerInput = {
  tagName: "DIV",
  offsetParent: {},
  closest: (sel) => (sel === "form" && hasForm) ? composerForm : null,
};

let polledPayloads = [];
global.window = {
  location: { href: "https://chatgpt.com/c/6ae55f99-ac98-83e8-baaf-4fc46253b333", pathname: "/c/6ae55f99-ac98-83e8-baaf-4fc46253b333", search: "" },
  addEventListener: () => {},
  dispatchEvent: () => {},
  getComputedStyle: (el) => el.style || { display: "block", visibility: "visible" },
  setInterval: () => 1,
  setTimeout: () => 1,
};
global.setInterval = () => 1;
global.setTimeout = () => 1;
global.location = global.window.location;
global.CustomEvent = function() {};
global.localStorage = { getItem: () => null, setItem: () => {} };
global.sessionStorage = { getItem: () => "tab_test", setItem: () => {} };
let messageListener = null;
global.chrome = {
  runtime: {
    sendMessage: () => {},
    onMessage: { addListener: (fn) => { messageListener = fn; } },
  },
};
global.document = {
  title: "Test Chat",
  documentElement: { dataset: { relaySseActive: "0", relayTurnSeq: "2" } },
  body: { appendChild: () => {} },
  createElement: () => ({ style: {}, setAttribute: () => {}, appendChild: () => {} }),
  querySelectorAll: (sel) => {
    if (sel.includes("#prompt-textarea")) return [composerInput];
    if (sel.includes("stop")) return [audioStopBtn, hiddenStopBtn].concat(activeComposerStop ? [activeComposerStop] : []);
    return [];
  },
  querySelector: (sel) => {
    if (sel.includes("#prompt-textarea")) return composerInput;
    if (sel.includes("form")) return hasForm ? composerForm : null;
    if (sel.includes("stop")) return activeComposerStop || audioStopBtn;
    if (sel.includes(".result-streaming")) return null;
    return null;
  },
};

eval(src);

let stateWhenIdleWithAudioAndHiddenStop = null;
messageListener({ type: "RELAY_COLLECT_TAB_STATE" }, {}, (res) => {
  stateWhenIdleWithAudioAndHiddenStop = res;
});

activeComposerStop = {
  disabled: false,
  hidden: false,
  style: { display: "block", visibility: "visible" },
  hasAttribute: () => false,
  getAttribute: (k) => k === "data-testid" ? "stop-button" : (k === "aria-label" ? "Stop streaming" : null),
  closest: () => null,
  getBoundingClientRect: () => ({ width: 32, height: 32 }),
};
let stateWhenComposerStopVisible = null;
messageListener({ type: "RELAY_COLLECT_TAB_STATE" }, {}, (res) => {
  stateWhenComposerStopVisible = res;
});

hasForm = false;
let stateWhenFormAbsent = null;
messageListener({ type: "RELAY_COLLECT_TAB_STATE" }, {}, (res) => {
  stateWhenFormAbsent = res;
});

console.log(JSON.stringify({
  idleGen: stateWhenIdleWithAudioAndHiddenStop.state.is_generating,
  activeGen: stateWhenComposerStopVisible.state.is_generating,
  noFormGen: stateWhenFormAbsent.state.is_generating,
}));
"""
        proc = subprocess.run(
            ["node", "-e", harness, bridge_js_path],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=10,
        )
        self.assertEqual(proc.returncode, 0, msg=f"Node failed: {proc.stderr}")
        out = json.loads(proc.stdout.strip())
        self.assertFalse(out["idleGen"], "Must NOT report is_generating=True when only audio/hidden stop buttons exist")
        self.assertTrue(out["activeGen"], "Must report is_generating=True when composer stop-button is visible and enabled")
        self.assertFalse(out["noFormGen"], "Must NOT fall back to document stop buttons when composer form is absent")


class TestSpecV44Seam3PowerShellAndWindowStation(unittest.TestCase):
    def test_ps1_launchpad_click_handler_never_assigns_readonly_pid_variable(self):
        """连接管理.ps1 must preserve UTF-8 with BOM and must never assign to the read-only automatic variable $PID / $pId."""
        ps1_path = os.path.join(REPO_ROOT, "连接管理.ps1")
        with open(ps1_path, "rb") as fh:
            raw = fh.read()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"), "连接管理.ps1 must have UTF-8 BOM")
        txt = raw.decode("utf-8-sig")
        import re
        matches = re.findall(r"(?i)\$pid\s*=", txt)
        self.assertEqual(matches, [], "Must never assign to $PID / $pId in PowerShell")
        self.assertIn("$targetPaneId", txt)

    def test_psm1_spawns_background_daemons_in_interactive_desktop_without_wmi_win32_process_create(self):
        """ConnectionManager.psm1 must preserve UTF-8 with BOM and spawn background services via ProcessStartInfo
        in the interactive desktop (WinSta0\\Default) instead of WMI Win32_Process.Create (Service-0x0-...$)."""
        psm1_path = os.path.join(REPO_ROOT, "ConnectionManager.psm1")
        with open(psm1_path, "rb") as fh:
            raw = fh.read()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"), "ConnectionManager.psm1 must have UTF-8 BOM")
        txt = raw.decode("utf-8-sig")
        self.assertNotIn("Invoke-CimMethod -ClassName Win32_Process -MethodName Create", txt)
        self.assertIn("Start-InteractiveHiddenCmd", txt)
        self.assertIn("CreateNoWindow", txt)


if __name__ == "__main__":
    unittest.main()
