"""Spec v4.1 seam tests: ProactiveTaskLedger, ZeroDisturbHostLauncher, DesktopCdpBridge, RelayCdp."""

import base64
import hashlib
import json
import time
from datetime import datetime, timezone
import os
import socket
import struct
import sys
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
sys.path.insert(0, os.path.dirname(__file__))
import McpReadOnlyShield as shield
import RelayCdp
from fake_chatgpt_page import FakeChatGptPage
import test_shield_hub as _hub

OLD_CONV = "11111111-1111-4111-8111-111111111111"
BOUND_CONV = "22222222-2222-4222-8222-222222222222"


class V41Base(unittest.TestCase):
    setUp = _hub.ShieldHubSeamTests.setUp
    tearDown = _hub.ShieldHubSeamTests.tearDown
    _post_json = _hub.ShieldHubSeamTests._post_json
    _get_json = _hub.ShieldHubSeamTests._get_json
    _write_task = _hub.ShieldHubSeamTests._write_task

    def _wb(self):
        with shield._WEB_BRIDGE_LOCK:
            return shield._load_web_bridge_state(self.wb_state_path)

    def _read_task(self, task_id):
        with open(os.path.join(self.tasks_root, f"{task_id}.json"), "r", encoding="utf-8") as fh:
            return json.load(fh)

    def _bind(self, key, profile=None, conv=None):
        if profile:
            self._post_json("/studio/action", {"action": "set_task_composer_config", "session_key": key, "browser_profile": profile})
        if conv:
            self._post_json("/studio/action", {"action": "bind_session", "session_key": key, "conv_uuid": conv})

    def _mcp(self, name, arguments, rpc_id="rpc-1"):
        return self._post_json("/mcp", {"jsonrpc": "2.0", "id": rpc_id, "method": "tools/call", "params": {"name": name, "arguments": arguments}})


class ProactiveTaskLedgerTests(V41Base):
    def test_t24_app_side_mint_single_pane_replace_and_preset_inheritance(self):
        self._write_task("tsk_old_a", "旧任务A")
        self._bind("tsk_old_a", conv=OLD_CONV)
        self._post_json("/studio/action", {"action": "set_task_composer_config", "session_key": "__new_task__", "browser_profile": "Edge:Profile 1"})
        user_text = "帮我排查 D:\\project_alpha 的登录超时问题，顺便看看日志"
        res = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "__new_task__",
            "mode": "new_window_handover",
            "user_text": user_text,
            "is_single_pane_replace": True,
        })
        self.assertTrue(res["ok"] and res["created_task"])
        tid = res["task_id"]
        self.assertRegex(tid, r"^tsk_[0-9a-f]{16}$")
        self.assertEqual(res["session_key"], tid)

        doc = self._read_task(tid)
        self.assertTrue(doc["app_initiated"] and doc["waiting_cloud_steps"])
        self.assertEqual(doc["status"], "active")
        self.assertEqual(doc["steps"][0]["status"], "in_progress")
        self.assertEqual(doc["goal"], user_text)
        self.assertEqual(doc["title"], user_text[:18] + "…")

        msg = res["message"]
        self.assertEqual(msg["mode"], "new_window_handover")
        self.assertTrue(msg["app_initiated"])
        self.assertEqual(msg["session_key"], tid)
        self.assertEqual(msg["display_text"], user_text)
        self.assertIn(f"【本机已立项任务契约：{tid}】", msg["prompt"])
        self.assertTrue(msg["prompt"].startswith(user_text))

        overrides, _ = shield.load_task_archives(self.data_root)
        self.assertNotIn("tsk_old_a", overrides, "Spec v4.2 Q3/Q4: '+' new task preserves existing active tasks side-by-side")
        wb = self._wb()
        self.assertEqual(wb["retire_actions"], [])
        binding = wb["session_bindings"][tid]
        self.assertEqual(binding["browser_profile"], "Edge:Profile 1")
        self.assertEqual(binding["target_mode"], "follow_window")
        self.assertEqual(binding["conv_uuid"], "")
        self.assertEqual(wb["breakers"][tid]["retry_count"], 0)

        snap = self._get_json("/studio/snapshot")
        card = next(s for s in snap["sessions"] if s["SessionKey"] == tid)
        self.assertEqual(card["SentWebMessages"][0]["Text"], user_text, "UI bubble shows the clean user text only")
        self.assertIn("tsk_old_a", [s["SessionKey"] for s in snap["sessions"]])

    def test_t24b_multi_pane_keeps_old_tasks_and_respects_cap(self):
        self._write_task("tsk_keep_a", "并排任务A", updated_at="2026-10-29T01:00:00Z")
        res = self._post_json("/studio/action", {
            "action": "enqueue_message", "session_key": "__new_task__", "user_text": "第二个并排任务", "is_single_pane_replace": False,
        })
        overrides, _ = shield.load_task_archives(self.data_root)
        self.assertNotIn("tsk_keep_a", overrides)
        self.assertTrue(res["created_task"])

        self._write_task("tsk_keep_b", "并排任务B", updated_at="2026-10-29T02:00:00Z")
        self._write_task("tsk_keep_c", "并排任务C", updated_at="2026-10-29T03:00:00Z")
        self._post_json("/studio/action", {
            "action": "enqueue_message", "session_key": "__new_task__", "user_text": "第三个并排任务", "is_single_pane_replace": False,
        })
        overrides, _ = shield.load_task_archives(self.data_root)
        archived = sorted(k for k, v in overrides.items() if v == "archived")
        self.assertEqual(archived, [], "Spec v4.2 Q3/Q4: '+' preserves existing active unfinished tasks without forced eviction")

    def test_t24c_create_task_action_without_text_uses_default(self):
        res = self._post_json("/studio/action", {"action": "create_task"})
        self.assertTrue(res["ok"] and res["created_task"])
        doc = self._read_task(res["task_id"])
        self.assertEqual(doc["title"], "App 新建任务")
        self.assertIn("本机 MCP 工具", doc["goal"])
        self.assertNotIn("local codex", doc["goal"].lower())

    def test_t25_cloud_create_is_absorbed_into_app_minted_task(self):
        res = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "__new_task__", "user_text": "整理仓库结构"})
        tid = res["task_id"]
        out = self._mcp("task_manage", {
            "action": "create",
            "title": "仓库结构整理（正式工单）",
            "goal": "把仓库目录整理成清晰分层",
            "steps": ["盘点目录", {"id": "s2", "title": "拆分模块", "status": "pending"}, "回归测试"],
        })
        text = out["result"]["content"][0]["text"]
        self.assertIn("本机预立项任务已接管", text)
        self.assertIn(tid, text)
        self.assertEqual(self.upstream.task_create_count, 0, "no twin task may reach the engine")
        doc = self._read_task(tid)
        self.assertEqual(doc["title"], "仓库结构整理（正式工单）")
        self.assertEqual([s["title"] for s in doc["steps"]], ["盘点目录", "拆分模块", "回归测试"])
        self.assertEqual(doc["steps"][0]["status"], "in_progress")
        self.assertFalse(doc["waiting_cloud_steps"])
        self.assertEqual(len([n for n in os.listdir(self.tasks_root) if n.startswith("tsk_") and n.endswith(".json")]), 1)

    def test_t25b_update_clears_waiting_flag_and_ttl_blocks_stale_absorption(self):
        res = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "__new_task__", "user_text": "任务甲"})
        tid = res["task_id"]
        self._mcp("task_manage", {"action": "update", "task_id": tid, "title": "任务甲正式名"})
        self.assertFalse(self._read_task(tid)["waiting_cloud_steps"])

        res2 = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "__new_task__", "user_text": "任务乙", "is_single_pane_replace": False})
        tid2 = res2["task_id"]
        with shield._WEB_BRIDGE_LOCK:  # forget the 90s "a handover just happened" dedupe window
            wb = shield._load_web_bridge_state(self.wb_state_path)
            for key in (tid, tid2):
                wb["breakers"][key]["handover_sent_at"] = ""
            shield._save_web_bridge_state(self.wb_state_path, wb)
        stale = self._read_task(tid2)
        stale["created_at"] = "2026-10-29T00:00:00Z"
        with open(os.path.join(self.tasks_root, f"{tid2}.json"), "w", encoding="utf-8") as fh:
            json.dump(stale, fh, ensure_ascii=False)
        cr_unrel = self._mcp("task_manage", {"action": "create", "title": "完全无关的全新工作 zzz", "goal": "与上面无关"}, rpc_id="rpc-2")
        new_unrel_tid = cr_unrel["result"]["structuredContent"]["task_id"]
        self.assertEqual(self.upstream.task_create_count, 0, "Spec v4.6: create executes natively on :8766")
        self.assertNotIn(new_unrel_tid, (tid, tid2), "an expired waiting task must not swallow an unrelated create")
        self.assertEqual(self._read_task(tid2)["title"], stale["title"])

    def test_t25c_omitted_replace_flag_keeps_peers_and_two_waiting_tasks_do_not_guess(self):
        r1 = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "__new_task__", "user_text": "并发甲任务"})
        r2 = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "__new_task__", "user_text": "并发乙任务"})
        overrides, _ = shield.load_task_archives(self.data_root)
        self.assertNotIn(r1["task_id"], overrides, "omitting is_single_pane_replace defaults to multi-pane safe (keep peers)")
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            for key in (r1["task_id"], r2["task_id"]):
                wb["breakers"][key]["handover_sent_at"] = ""
            shield._save_web_bridge_state(self.wb_state_path, wb)
        cr_ambig = self._mcp("task_manage", {"action": "create", "title": "毫不相干的第三件事 qwerty", "goal": "无 task_id 指引"}, rpc_id="rpc-ambig")
        ambig_tid = cr_ambig["result"]["structuredContent"]["task_id"]
        self.assertEqual(self.upstream.task_create_count, 0, "Spec v4.6: create executes natively on :8766")
        self.assertNotIn(ambig_tid, (r1["task_id"], r2["task_id"]), "with 2 waiting App tasks, an unattributed create must never guess")


class ZeroDisturbHostLauncherTests(V41Base):
    def setUp(self):
        super().setUp()
        self.launches = []

        def fake_launch(url, browser="Chrome", profile="Chrome:Profile 1", minimize_no_activate=False):
            self.launches.append({"url": url, "browser": browser, "profile": profile, "minimize": minimize_no_activate})
            return True

        self._patches = [
            mock.patch.object(shield, "_HOST_SIDE_EFFECTS_ENABLED", True),
            mock.patch.object(shield, "launch_browser_url", fake_launch),
            mock.patch.object(shield.DesktopAppBridge, "tick", staticmethod(lambda *a, **k: {"ok": True})),
        ]
        for p in self._patches:
            p.start()

    def tearDown(self):
        for p in self._patches:
            p.stop()
        super().tearDown()

    def test_t26_closed_chrome_cold_starts_minimized_into_bound_conversation(self):
        self._write_task("tsk_z1", "冷启动任务")
        self._bind("tsk_z1", profile="Chrome:Profile 1")
        self._bind("tsk_z1", conv=BOUND_CONV)
        res = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_z1", "user_text": "继续推进"})
        self.assertEqual(res["message"]["mode"], "custom_message")
        self.assertEqual(len(self.launches), 1)
        job = self.launches[0]
        self.assertTrue(job["minimize"], "automatic cold start must never take focus")
        self.assertTrue(job["url"].startswith(f"https://chatgpt.com/c/{BOUND_CONV}?relay_profile="))
        self.assertEqual(job["profile"], "Chrome:Profile 1")

        again = shield.cold_start_pending_hosts(self.wb_state_path, tasks_root=self.tasks_root)
        self.assertEqual(again, [], "cold start is idempotent inside the retry window")
        later = shield.cold_start_pending_hosts(self.wb_state_path, tasks_root=self.tasks_root, now_epoch=__import__("time").time() + 200)
        self.assertEqual(len(later), 1)

    def test_t26b_closed_host_without_bound_conversation_becomes_handover(self):
        self._write_task("tsk_z2", "无会话任务")
        self._bind("tsk_z2", profile="Edge:Profile 1")
        res = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_z2", "user_text": "继续"})
        self.assertEqual(res["message"]["mode"], "new_window_handover")
        self.assertIn("tsk_z2", res["message"]["prompt"])
        self.assertEqual(len(self.launches), 1)
        self.assertIn("relay_handover=1", self.launches[0]["url"])
        self.assertEqual(self.launches[0]["browser"], "Edge")

    def test_t26c_desktop_cold_start_and_online_host_is_left_alone(self):
        self._write_task("tsk_z3", "桌面任务")
        self._bind("tsk_z3", profile="Desktop:ChatGPT")
        self._bind("tsk_z3", conv=BOUND_CONV)
        self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_z3", "user_text": "桌面继续"})
        self.assertEqual([j["browser"] for j in self.launches], ["Desktop"])
        self.assertTrue(self.launches[0]["minimize"])

        self.launches.clear()
        self._write_task("tsk_z4", "在线浏览器任务")
        self._bind("tsk_z4", profile="Chrome:Profile 1")
        self._bind("tsk_z4", conv=OLD_CONV)
        poll = {"browser": "Chrome", "browser_profile": "Chrome:Profile 1", "browser_instance_id": "inst_t26", "tabs": []}
        self._post_json("/web-bridge/poll", poll)
        self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_z4", "user_text": "在线继续"})
        self.assertEqual(self.launches, [], "a browser that is polling is online: no process is started")
        out = self._post_json("/web-bridge/poll", poll)
        reopen = [d for d in out["dispatches"] if d.get("open_new_tab")]
        self.assertEqual(len(reopen), 1)
        self.assertTrue(reopen[0]["handover_url"].startswith(f"https://chatgpt.com/c/{OLD_CONV}"))
        again = self._post_json("/web-bridge/poll", poll)
        self.assertEqual([d for d in again["dispatches"] if d.get("open_new_tab")], [])

    def test_t26d_open_tab_is_the_only_foreground_path(self):
        self._write_task("tsk_z5", "手动打开")
        self._bind("tsk_z5", profile="Chrome:Profile 1")
        self._post_json("/web-bridge/open-tab", {"session_key": "tsk_z5", "browser": "Chrome", "browser_profile": "Chrome:Profile 1"})
        self.assertEqual(len(self.launches), 1)
        self.assertFalse(self.launches[0]["minimize"])

    def test_t26f_online_browser_without_bound_conversation_continues_as_handover(self):
        self._write_task("tsk_z7", "在线未绑定")
        self._bind("tsk_z7", profile="Chrome:Profile 1")
        poll = {"browser": "Chrome", "browser_profile": "Chrome:Profile 1", "browser_instance_id": "inst_t26f", "tabs": []}
        self._post_json("/web-bridge/poll", poll)
        res = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_z7", "user_text": "继续吧", "mode": "custom_message"})
        self.assertEqual(res["message"]["mode"], "custom_message")
        self.assertEqual(self.launches, [])
        out = self._post_json("/web-bridge/poll", poll)
        self.assertEqual(out["dispatches"], [], "too fresh: still waiting for a conversation of its own")
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            for m in wb["queue"]:
                if m["id"] == res["message_id"]:
                    m["created_at"] = "2026-10-29T10:00:00Z"
            shield._save_web_bridge_state(self.wb_state_path, wb)
        self._post_json("/web-bridge/poll", poll)
        out = self._post_json("/web-bridge/poll", poll)
        self.assertEqual(self._wb()["queue"][-1]["mode"], "new_window_handover")
        opened = [d for d in out["dispatches"] if d.get("open_new_tab")]
        self.assertEqual(len(opened), 1)
        self.assertIn("relay_handover=1", opened[0]["handover_url"])
        self.assertIn("tsk_z7", self._wb()["queue"][-1]["prompt"])

    def test_t26g_manual_send_still_pumps_host_work_when_auto_resend_is_off(self):
        self._post_json("/studio/action", {"action": "update_resend_config", "enabled": False})
        with mock.patch.object(shield, "_run_host_maintenance") as maint:
            shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(maint.call_count, 1)

    def test_t26e_flag_off_keeps_tests_off_the_real_machine(self):
        with mock.patch.object(shield, "_HOST_SIDE_EFFECTS_ENABLED", False):
            self._write_task("tsk_z6", "无副作用")
            self._bind("tsk_z6", profile="Chrome:Profile 1")
            self._bind("tsk_z6", conv=BOUND_CONV)
            self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_z6", "user_text": "x"})
        self.assertEqual(self.launches, [])

    def test_t26h_async_cold_start_and_open_tab_never_hold_bridge_lock_or_block_http(self):
        gate = threading.Event()
        entered = threading.Event()
        lock_held_during_launch = []

        def slow_launch(url, browser="Chrome", profile="Chrome:Profile 1", minimize_no_activate=False):
            lock_held_during_launch.append(shield._WEB_BRIDGE_LOCK.locked())
            entered.set()
            gate.wait(2.0)
            self.launches.append({"url": url, "browser": browser, "profile": profile, "minimize": minimize_no_activate})
            return True

        self._write_task("tsk_z8", "异步冷启动")
        self._bind("tsk_z8", profile="Chrome:Profile 1")
        self._bind("tsk_z8", conv=BOUND_CONV)
        with mock.patch.object(shield, "_ASYNC_COLD_START_ON_ENQUEUE", True), mock.patch.object(shield, "launch_browser_url", slow_launch):
            t0 = __import__("time").monotonic()
            res = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_z8", "user_text": "异步出发"})
            elapsed = __import__("time").monotonic() - t0
            self.assertTrue(res["ok"])
            self.assertLess(elapsed, 0.8, "/studio/action must return before slow cold-start finishes")
            self.assertTrue(entered.wait(1.5))
            gate.set()
            for _ in range(30):
                if self.launches:
                    break
                __import__("time").sleep(0.02)
            self.assertEqual(len(self.launches), 1)
            self._post_json("/web-bridge/open-tab", {"session_key": "tsk_z8", "browser": "Chrome", "browser_profile": "Chrome:Profile 1"})
        self.assertTrue(all(not held for held in lock_held_during_launch), "_WEB_BRIDGE_LOCK must be released before launching any host")

    def test_t26i_cold_start_uses_binding_conv_uuid_fallback(self):
        self._write_task("tsk_z9", "绑定兜底")
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            wb["session_bindings"]["tsk_z9"] = shield._ensure_binding_entry({"browser_profile": "Chrome:Profile 1", "conv_uuid": BOUND_CONV})
            wb["queue"].append({
                "id": "msg_bind_fallback",
                "session_key": "tsk_z9",
                "conv_uuid": "",
                "mode": "custom_message",
                "display_text": "继续",
                "prompt": "继续",
                "text": "继续",
                "browser": "Chrome",
                "browser_profile": "Chrome:Profile 1",
                "status": "pending",
                "created_at": shield._utc_now_iso(),
            })
            shield._save_web_bridge_state(self.wb_state_path, wb)
        jobs = shield.cold_start_pending_hosts(self.wb_state_path, only_msg_id="msg_bind_fallback", tasks_root=self.tasks_root)
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0]["mode"], "custom_message")
        self.assertIn(f"/c/{BOUND_CONV}", jobs[0]["url"])


class DesktopCdpBridgeTests(V41Base):
    def setUp(self):
        super().setUp()
        for attr, value in (("_cached_port", None), ("_last_launch_at", 0.0), ("_last_restart_at", 0.0), ("_last_probe_at", 0.0)):
            setattr(shield.DesktopAppBridge, attr, value)
        self.sleeps = []

    def _tick(self, page, **kw):
        return shield.DesktopAppBridge.tick(
            self.wb_state_path, self.tasks_root, eval_fn=page.evaluate, sleep_fn=self.sleeps.append, **kw
        )

    def _enqueue_desktop_task(self, text="桌面端首句"):
        return self._post_json("/studio/action", {
            "action": "enqueue_message", "session_key": "__new_task__", "user_text": text, "browser_profile": "Desktop:ChatGPT",
        })

    def test_t27_new_task_delivered_in_background_and_bound(self):
        res = self._enqueue_desktop_task()
        tid = res["task_id"]
        self.assertEqual(res["message"]["browser_profile"], "Desktop:ChatGPT")
        page = FakeChatGptPage(conv_uuid=OLD_CONV, chat_mode_selected=False, hook_installed=False)
        out = self._tick(page)
        self.assertTrue(out["ok"] and out["processed"] >= 1)
        self.assertEqual(page.mode_switches, 1)
        self.assertEqual(page.hook_injections, 0, "Spec v4.2 Plan C drives native app://-/index.html without web fetch hook injection")
        self.assertIn("nav_new_chat", page.ops())
        self.assertIn(f"【本机已立项任务契约：{tid}】", page.filled)
        wb = self._wb()
        msg = next(m for m in wb["queue"] if m["id"] == res["message_id"])
        self.assertEqual(msg["status"], "delivered")
        self.assertEqual(wb["session_bindings"][tid]["conv_uuid"], page.new_conv_uuid)
        self.assertEqual(wb["session_bindings"][tid]["browser_profile"], "Desktop:ChatGPT")
        self.assertIn("inst_desktop_chatgpt", wb["browser_instances"])
        snap = self._get_json("/studio/snapshot")
        self.assertTrue(snap["web_bridge"]["desktop_app_online"])

    def test_t27b_task_created_in_desktop_is_auto_bound_from_page_hints(self):
        self._write_task("tsk_desk_made", "桌面端自己建的任务")
        page = FakeChatGptPage(conv_uuid=BOUND_CONV, page_hints=["tsk_desk_made", BOUND_CONV])
        self._tick(page)
        wb = self._wb()
        self.assertEqual(wb["session_bindings"]["tsk_desk_made"]["conv_uuid"], BOUND_CONV)
        self.assertNotIn(BOUND_CONV, wb["session_bindings"], "a bare conversation id must not become a task binding")
        self.assertEqual(page.ops().count("ensure_chat_mode"), 0, "no idle tick may flip the user's 工作/聊天 switch")

    def test_t27c_follow_window_message_navigates_to_bound_conversation(self):
        self._write_task("tsk_desk_f", "跟随原窗")
        self._bind("tsk_desk_f", profile="Desktop:ChatGPT")
        self._bind("tsk_desk_f", conv=BOUND_CONV)
        res = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_desk_f", "user_text": "接着聊"})
        self.assertEqual(res["message"]["mode"], "custom_message")
        page = FakeChatGptPage(conv_uuid=OLD_CONV, known_convs=[BOUND_CONV])
        self._tick(page)
        self.assertIn("nav_conv", page.ops())
        self.assertEqual(page.conv_uuid, BOUND_CONV)
        self.assertEqual(page.filled, "接着聊")
        self.assertEqual(self._wb()["queue"][-1]["status"], "delivered")

    def test_t27d_missing_conversation_falls_back_to_fresh_chat_handover(self):
        self._write_task("tsk_desk_m", "会话丢失")
        self._bind("tsk_desk_m", profile="Desktop:ChatGPT")
        self._bind("tsk_desk_m", conv=BOUND_CONV)
        self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_desk_m", "user_text": "继续"})
        page = FakeChatGptPage(conv_uuid=OLD_CONV, known_convs=[])
        self._tick(page)
        msg = self._wb()["queue"][-1]
        self.assertEqual((msg["status"], msg["mode"], msg["conv_uuid"]), ("pending", "new_window_handover", ""))
        self.assertIn("tsk_desk_m", msg["prompt"])
        self._tick(page)
        msg = self._wb()["queue"][-1]
        self.assertEqual(msg["status"], "delivered")

    def test_t27e_retry_safe_and_uncertain_outcomes(self):
        self._write_task("tsk_desk_r", "重试")
        self._bind("tsk_desk_r", profile="Desktop:ChatGPT")
        self._bind("tsk_desk_r", conv=BOUND_CONV)
        self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_desk_r", "user_text": "你好"})
        no_composer = FakeChatGptPage(conv_uuid=BOUND_CONV, has_composer=False)
        self._tick(no_composer)
        msg = self._wb()["queue"][-1]
        self.assertEqual(msg["status"], "pending")
        self.assertTrue(msg["last_error"])

        silent = FakeChatGptPage(conv_uuid=BOUND_CONV, dispatch_status="waiting")
        self._tick(silent)
        self.assertTrue(silent.sent)
        self.assertEqual(self._wb()["queue"][-1]["status"], "unconfirmed", "a click without an accepted POST is never auto-retried")

        self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_desk_r", "user_text": "断线测试"})
        dropped_after_click = FakeChatGptPage(conv_uuid=BOUND_CONV, fail_on_op="dispatch_status")
        self._tick(dropped_after_click)
        self.assertTrue(dropped_after_click.sent)
        self.assertEqual(self._wb()["queue"][-1]["status"], "unconfirmed", "a CDP drop after click must be unconfirmed, never retry_safe")

    def test_t27f_retire_actions_archive_in_background(self):
        self._write_task("tsk_desk_t", "归档任务")
        self._bind("tsk_desk_t", profile="Desktop:ChatGPT")
        self._bind("tsk_desk_t", conv=BOUND_CONV)
        self._post_json("/studio/action", {"action": "archive", "session_key": "tsk_desk_t"})
        # Spec Decision 2.1: archiving immediately releases retire_actions with ARCHIVE_UNDO_GRACE_SEC = 0.0 (no 5s undo delay).
        with shield._WEB_BRIDGE_LOCK:
            wb_g = shield._load_web_bridge_state(self.wb_state_path)
            self.assertTrue(all(float(r.get("not_before_epoch") or 0) <= time.time() for r in wb_g["retire_actions"]))
        flaky = FakeChatGptPage(conv_uuid=BOUND_CONV, archive_ok=False)
        self._tick(flaky)
        self.assertTrue(all(r["status"] == "pending" and r.get("attempts") == 1 for r in self._wb()["retire_actions"]))
        page = FakeChatGptPage(conv_uuid=BOUND_CONV, archive_ok=True)
        self._tick(page)
        self.assertEqual(page.archived, [BOUND_CONV])
        self.assertTrue(all(r["status"] == "completed" for r in self._wb()["retire_actions"]))

    def test_t27g_host_recovery_cold_start_and_hot_restart_with_cooldown(self):
        self._enqueue_desktop_task()
        calls = []

        def launcher(minimize_no_activate=True, restart=False):
            calls.append((minimize_no_activate, restart))
            return {"ok": True, "port": 9222}

        shield.DesktopAppBridge.tick(
            self.wb_state_path, self.tasks_root, launcher_fn=launcher,
            endpoint_fn=lambda cached: {"port": None, "targets": [], "running": False},
        )
        self.assertEqual(calls, [(True, False)], "closed app: cold start minimized")

        # Within BOOT_GRACE_SEC after cold start, never kill/restart a process that is still warming up.
        shield.DesktopAppBridge.tick(
            self.wb_state_path, self.tasks_root, launcher_fn=launcher,
            endpoint_fn=lambda cached: {"port": None, "targets": [], "running": True},
        )
        self.assertEqual(len(calls), 1, "BOOT_GRACE_SEC protects a freshly launched ChatGPT.exe")

        shield.DesktopAppBridge._last_launch_at = 0.0
        # If process already carries --remote-debugging-port (booting=True), never hot-restart it either.
        shield.DesktopAppBridge.tick(
            self.wb_state_path, self.tasks_root, launcher_fn=launcher,
            endpoint_fn=lambda cached: {"port": None, "targets": [], "running": True, "booting": True},
        )
        self.assertEqual(len(calls), 1, "booting=True protects an instance that already carries a debug port")

        shield.DesktopAppBridge.tick(
            self.wb_state_path, self.tasks_root, launcher_fn=launcher,
            endpoint_fn=lambda cached: {"port": None, "targets": [], "running": True, "booting": False},
        )
        self.assertEqual(calls[-1], (True, True), "running without a debug port: one hot restart with CDP")
        shield.DesktopAppBridge._last_launch_at = 0.0
        shield.DesktopAppBridge.tick(
            self.wb_state_path, self.tasks_root, launcher_fn=launcher,
            endpoint_fn=lambda cached: {"port": None, "targets": [], "running": True, "booting": False},
        )
        self.assertEqual(len(calls), 2, "hot restart honours its cooldown")

    def test_t27l_user_draft_in_composer_is_never_overwritten(self):
        self._write_task("tsk_desk_d", "草稿保护")
        self._bind("tsk_desk_d", profile="Desktop:ChatGPT")
        self._bind("tsk_desk_d", conv=BOUND_CONV)
        # An automatic / "请继续" wakeup (not typed text) always yields to a hand-typed draft.
        self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_desk_d"})
        drafting = FakeChatGptPage(conv_uuid=BOUND_CONV, composer_text="用户正在手敲的一半问题")
        self._tick(drafting)
        self.assertIsNone(drafting.filled)
        self.assertFalse(drafting.sent)
        msg = self._wb()["queue"][-1]
        self.assertEqual((msg["status"], msg["last_error"]), ("pending", "user_draft"))
        # Spec v4.3 Q3: an instruction typed in the panel and sent by the user takes priority over the draft.
        self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_desk_d", "user_text": "面板亲手发送的新指令"})
        manual_page = FakeChatGptPage(conv_uuid=BOUND_CONV, composer_text="用户正在手敲的一半问题")
        self._tick(manual_page)
        self.assertEqual(manual_page.filled, "面板亲手发送的新指令")
        self.assertEqual(self._wb()["queue"][-1]["status"], "delivered")

    def test_t27h_idle_and_offline_does_nothing(self):
        calls = []
        out = shield.DesktopAppBridge.tick(
            self.wb_state_path if os.path.isfile(self.wb_state_path) else self._touch_state(),
            self.tasks_root,
            launcher_fn=lambda **k: calls.append(k),
            endpoint_fn=lambda cached: {"port": None, "targets": [], "running": True},
        )
        self.assertFalse(out["desktop_online"])
        self.assertEqual(calls, [], "no pending Desktop work: never restart the user's app")

    def test_t27j_stale_desktop_messages_never_restart_the_app(self):
        res = self._enqueue_desktop_task("很久以前的消息")
        with shield._WEB_BRIDGE_LOCK:
            wb = shield._load_web_bridge_state(self.wb_state_path)
            for m in wb["queue"]:
                if m["id"] == res["message_id"]:
                    m["created_at"] = "2026-10-29T10:00:00Z"
            shield._save_web_bridge_state(self.wb_state_path, wb)
        calls = []
        out = shield.DesktopAppBridge.tick(
            self.wb_state_path, self.tasks_root, launcher_fn=lambda **k: calls.append(k),
            endpoint_fn=lambda cached: {"port": None, "targets": [], "running": True},
        )
        self.assertEqual(calls, [], "an hour-old queued message must not hot-restart the user's ChatGPT")
        msg = next(m for m in self._wb()["queue"] if m["id"] == res["message_id"])
        self.assertEqual((msg["status"], msg["last_error"]), ("unconfirmed", "expired_before_delivery"))
        self.assertFalse(out["desktop_online"])

    def test_t27k_in_place_message_never_hijacks_an_unrelated_open_chat(self):
        self._write_task("tsk_desk_h", "不劫持")
        self._bind("tsk_desk_h", profile="Desktop:ChatGPT")
        res = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_desk_h", "user_text": "你好", "mode": "custom_message"})
        self.assertEqual(res["message"]["mode"], "custom_message")
        stranger = FakeChatGptPage(conv_uuid=OLD_CONV, page_hints=[OLD_CONV])
        self._tick(stranger)
        self.assertFalse(stranger.sent or stranger.filled, "nothing may be typed into a chat that does not belong to the task")
        msg = self._wb()["queue"][-1]
        # Spec v4.3: a task that has never claimed its room number waits (follow-window) instead of opening a new chat at once.
        self.assertEqual((msg["status"], msg["mode"], msg["last_error"]), ("pending", "custom_message", "waiting_room_claim"))
        with shield._WEB_BRIDGE_LOCK:
            wb_old = shield._load_web_bridge_state(self.wb_state_path)
            for qm in wb_old["queue"]:
                if qm["id"] == msg["id"]:
                    qm["created_at"] = datetime.fromtimestamp(time.time() - 60.0, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
                    qm["claimed_at"] = ""
            shield._save_web_bridge_state(self.wb_state_path, wb_old)
        self._tick(stranger)
        self.assertFalse(stranger.sent or stranger.filled)
        msg = self._wb()["queue"][-1]
        # A manual instruction that still cannot find its room after the grace period continues in a fresh chat (user is awake).
        self.assertEqual((msg["status"], msg["mode"]), ("pending", "new_window_handover"))
        owner = FakeChatGptPage(conv_uuid=BOUND_CONV, page_hints=["tsk_desk_h", BOUND_CONV])
        self._tick(owner)
        self.assertTrue(owner.sent)
        self.assertEqual(self._wb()["queue"][-1]["status"], "delivered")

    def _touch_state(self):
        self._post_json("/studio/action", {"action": "update_resend_config", "enabled": True})
        return self.wb_state_path

    def test_t27i_extension_poll_never_delivers_desktop_messages(self):
        self._write_task("tsk_desk_p", "桌面不走扩展")
        self._bind("tsk_desk_p", profile="Desktop:ChatGPT")
        self._bind("tsk_desk_p", conv=BOUND_CONV)
        self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "tsk_desk_p", "user_text": "不应被浏览器领走"})
        out = self._post_json("/web-bridge/poll", {
            "browser": "Chrome", "browser_profile": "Chrome:Profile 1", "browser_instance_id": "inst_p",
            "tabs": [{"tab_id": "t1", "conv_uuid": BOUND_CONV, "url": f"https://chatgpt.com/c/{BOUND_CONV}", "state_known": True}],
        })
        self.assertEqual(out["dispatches"], [])
        self.assertEqual(out["messages"], [])


class FakeCdpServer:
    """Tiny DevTools endpoint: GET /json/list and a WebSocket that answers Runtime.evaluate."""

    def __init__(self, evaluate_fn, fragment=False):
        outer = self
        self.evaluate_fn = evaluate_fn
        self.fragment = fragment
        self.received = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                return

            def do_GET(self):
                if self.path == "/json/list":
                    port = outer.port
                    body = json.dumps([
                        {"id": "SHELL", "type": "page", "url": "app://-/index.html", "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/page/SHELL"},
                        {"id": "WV", "type": "webview", "url": "https://chatgpt.com/c/abc", "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/page/WV"},
                    ]).encode()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                key = self.headers.get("Sec-WebSocket-Key")
                accept = base64.b64encode(hashlib.sha1((key + RelayCdp._WS_GUID).encode()).digest()).decode()
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept)
                self.end_headers()
                self.wfile.flush()
                outer._serve_ws(self.connection, self.rfile)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    @staticmethod
    def _frame(opcode, payload, fin=True):
        header = bytearray([(0x80 if fin else 0) | opcode])
        n = len(payload)
        if n < 126:
            header.append(n)
        elif n < 65536:
            header.append(126)
            header += struct.pack("!H", n)
        else:
            header.append(127)
            header += struct.pack("!Q", n)
        return bytes(header) + payload

    def _serve_ws(self, conn, rfile):
        def read(n):
            data = rfile.read(n)
            if len(data) < n:
                raise EOFError
            return data

        try:
            b1, b2 = read(2)
            length = b2 & 0x7F
            if length == 126:
                length = struct.unpack("!H", read(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", read(8))[0]
            mask = read(4)
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read(length)))
            req = json.loads(payload.decode("utf-8"))
            self.received.append(req)
            conn.sendall(self._frame(0x9, b"hello"))  # a ping the client must answer, not choke on
            conn.sendall(self._frame(0x1, json.dumps({"method": "Runtime.consoleAPICalled", "params": {}}).encode()))
            result = self.evaluate_fn(req["params"]["expression"])
            body = json.dumps({"id": req["id"], "result": result}).encode()
            if self.fragment:
                half = len(body) // 2
                conn.sendall(self._frame(0x1, body[:half], fin=False) + self._frame(0x0, body[half:], fin=True))
            else:
                conn.sendall(self._frame(0x1, body))
            conn.settimeout(3)
            while rfile.read(1):  # let the client close first, otherwise unread pong data causes an RST
                pass
        except (EOFError, OSError):
            pass


class RelayCdpAdapterTests(unittest.TestCase):
    def test_t28_websocket_evaluate_handles_ping_events_fragments_and_large_frames(self):
        big = "x" * 70000
        server = FakeCdpServer(lambda expr: {"result": {"type": "string", "value": f"len={len(expr)}"}})
        try:
            ws = f"ws://127.0.0.1:{server.port}/devtools/page/WV"
            self.assertEqual(RelayCdp.cdp_evaluate(ws, "1+1"), "len=3")
            self.assertEqual(RelayCdp.cdp_evaluate(ws, big), f"len={len(big)}")
            self.assertTrue(server.received[0]["params"]["awaitPromise"] and server.received[0]["params"]["returnByValue"])
        finally:
            server.close()
        frag = FakeCdpServer(lambda expr: {"result": {"type": "object", "value": {"ok": True, "text": "分片" * 50}}}, fragment=True)
        try:
            out = RelayCdp.cdp_evaluate(f"ws://127.0.0.1:{frag.port}/devtools/page/WV", "x")
            self.assertEqual(out["text"], "分片" * 50)
        finally:
            frag.close()
        boom = FakeCdpServer(lambda expr: {"exceptionDetails": {"text": "Uncaught", "exception": {"description": "ReferenceError: nope"}}})
        try:
            with self.assertRaises(RelayCdp.CdpError):
                RelayCdp.cdp_evaluate(f"ws://127.0.0.1:{boom.port}/devtools/page/WV", "nope")
        finally:
            boom.close()

    def test_t28b_endpoint_discovery_uses_actual_port_not_a_fixed_list(self):
        server = FakeCdpServer(lambda expr: {"result": {"value": 1}})
        try:
            probe = lambda: {"running": True, "main_pid": 4720, "cmd_ports": [server.port], "listen_ports": []}
            ep = RelayCdp.find_cdp_endpoint(None, probe_fn=probe)
            self.assertEqual(ep["port"], server.port)
            picked = RelayCdp.pick_targets(ep["targets"])
            self.assertEqual(picked["shell"]["id"], "SHELL")
            self.assertEqual(picked["webview"]["id"], "WV")
            cached = RelayCdp.find_cdp_endpoint(server.port, probe_fn=lambda: self.fail("cached port must short-circuit the process probe"))
            self.assertEqual(cached["port"], server.port)
        finally:
            server.close()
        dead = RelayCdp.find_cdp_endpoint(None, probe_fn=lambda: {"running": True, "main_pid": 1, "cmd_ports": [], "listen_ports": []})
        self.assertIsNone(dead["port"])
        self.assertTrue(dead["running"], "alive without a reachable port -> caller may hot restart")

    def test_t28c_process_probe_parses_powershell_json_shapes(self):
        one = json.dumps({"procs": {"ProcessId": 4720, "CommandLine": '"C:\\x\\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=64067'}, "ports": 64067})
        info = RelayCdp.probe_chatgpt_host(lambda script: one)
        self.assertEqual((info["running"], info["main_pid"], info["cmd_ports"], info["listen_ports"]), (True, 4720, [64067], [64067]))
        many = json.dumps({"procs": [
            {"ProcessId": 1, "CommandLine": "ChatGPT.exe --type=renderer --remote-debugging-port=9999"},
            {"ProcessId": 2, "CommandLine": "ChatGPT.exe --remote-debugging-port=9222"},
        ], "ports": [9222, 9223]})
        info = RelayCdp.probe_chatgpt_host(lambda script: many)
        self.assertEqual((info["main_pid"], info["cmd_ports"], info["listen_ports"]), (2, [9222], [9222, 9223]))
        self.assertFalse(RelayCdp.probe_chatgpt_host(lambda script: "")["running"])

    def test_t28d_launch_is_minimized_without_activation_and_restart_kills_first(self):
        captured = {}

        def fake_popen(args, **kwargs):
            captured["args"] = args
            captured["kwargs"] = kwargs

        self.assertTrue(RelayCdp.launch_process(["x.exe", "--flag"], True, popen_fn=fake_popen))
        if os.name == "nt":
            si = captured["kwargs"]["startupinfo"]
            self.assertEqual(si.wShowWindow, RelayCdp.SW_SHOWMINNOACTIVE)
            self.assertTrue(si.dwFlags & 1)
        events = []
        res = RelayCdp.ensure_chatgpt_desktop(
            minimize_no_activate=True, restart=True, popen_fn=lambda a, **k: events.append(("start", a)),
            run_ps=lambda s: "", kill_fn=lambda: events.append(("kill",)), port=9333,
        )
        # no installed package on a CI box -> falls back to the AUMID shell launch (no port)
        if res["exe"]:
            self.assertEqual(events[0], ("kill",))
            self.assertIn("--remote-debugging-port=9333", events[1][1])
            self.assertEqual(res["port"], 9333)
        else:
            self.assertTrue(any("shell:AppsFolder" in " ".join(e[1]) for e in events if e[0] == "start"))
        self.assertEqual(RelayCdp.pick_free_port(0) > 0, True)

    def test_t28f_stop_is_graceful_first_and_force_only_as_last_resort(self):
        counts = iter(["2", "2", "0"])
        scripts = []

        def runner(script):
            scripts.append(script)
            return next(counts) if "Measure-Object" in script else ""

        forced = []
        self.assertEqual(RelayCdp.stop_chatgpt_desktop(runner, force_fn=lambda: forced.append(1), sleep_fn=lambda s: None), "graceful")
        self.assertTrue(any("CloseMainWindow" in s for s in scripts))
        self.assertEqual(forced, [])
        stubborn = lambda script: "3" if "Measure-Object" in script else ""
        self.assertEqual(RelayCdp.stop_chatgpt_desktop(stubborn, force_fn=lambda: forced.append(1), sleep_fn=lambda s: None, attempts=2), "forced")
        self.assertEqual(forced, [1])
        self.assertEqual(RelayCdp.stop_chatgpt_desktop(lambda s: "0", force_fn=lambda: forced.append(2), sleep_fn=lambda s: None), "not_running")
        self.assertEqual(forced, [1])

    def test_t28e_session_orchestration_through_the_evaluate_seam(self):
        page = FakeChatGptPage(conv_uuid=OLD_CONV, hook_installed=False)
        session = RelayCdp.ChatGptDesktopSession(page.evaluate, hook_source="/*hook*/", sleep_fn=lambda s: None)
        res = session.deliver({"id": "m1", "mode": "new_window_handover", "text": "你好", "target_model": "gpt-6-thinking", "reasoning_effort": "深度"})
        self.assertTrue(res["ok"])
        self.assertEqual(res["conv_uuid"], page.new_conv_uuid)
        self.assertEqual(page.fill_args["model"], "gpt-6-thinking")
        self.assertEqual(page.fill_args["effort"], "深度")
        self.assertEqual(page.hook_injections, 1)
        busy = FakeChatGptPage(conv_uuid=BOUND_CONV, is_generating=True)
        out = RelayCdp.ChatGptDesktopSession(busy.evaluate, sleep_fn=lambda s: None).deliver({"id": "m2", "mode": "custom_message", "text": "x", "conv_uuid": BOUND_CONV})
        self.assertEqual((out["ok"], out["error"], out["retry_safe"]), (False, "busy_generating", True))
        no_btn = FakeChatGptPage(conv_uuid=OLD_CONV, new_chat_button=False)
        out = RelayCdp.ChatGptDesktopSession(no_btn.evaluate, sleep_fn=lambda s: None).deliver({"id": "m3", "mode": "new_window_handover", "text": "x"})
        self.assertFalse(out["ok"])


if __name__ == "__main__":
    unittest.main()
