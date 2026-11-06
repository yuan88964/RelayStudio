# -*- coding: utf-8 -*-
"""Spec v4.6 High-Level Seam Tests:
- Seam 1: Studio Hub (:8766) HTTP & MCP Protocol Boundary
  * Slice 1: Zero-residue purge of `evolve` / `final_review` / `complete`, 100% native 7-action `task_manage` engine,
    `quarantined` step status, and One-Step Auto-Closeout (`/__studio__/snapshot` & `run_guardian_tick`).
"""

import datetime
import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

import McpReadOnlyShield as shield
import RelayCdp


class LegacyUpstreamMockHandler(BaseHTTPRequestHandler):
    """Simulates the legacy pre-compiled :8765 binary exposing `evolve`, `final_review`, `complete`, and old context rules."""

    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        payload = json.loads(raw.decode("utf-8"))
        rpc_id = payload.get("id", "1")
        method = payload.get("method", "")
        params = payload.get("params") or {}
        tool_name = params.get("name", "")
        args = params.get("arguments") or {}

        self.server.calls.append({"method": method, "tool": tool_name, "args": args})

        if method == "tools/list":
            resp_obj = {
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": {
                    "tools": [
                        {
                            "name": "evolve",
                            "description": "Cloud self-evolution submission tool",
                            "inputSchema": {"type": "object", "properties": {"action": {"type": "string"}}},
                        },
                        {
                            "name": "task_manage",
                            "description": "凡 2 步以上操作必须调用 task_manage(action='create') 并在结束时调用 final_review 和 complete",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "action": {
                                        "type": "string",
                                        "enum": [
                                            "create",
                                            "list",
                                            "get",
                                            "checkpoint",
                                            "block",
                                            "resume",
                                            "final_review",
                                            "complete",
                                        ],
                                    },
                                    "task_id": {"type": "string"},
                                    "title": {"type": "string"},
                                    "goal": {"type": "string"},
                                    "summary": {"type": "string"},
                                    "completion_conditions": {"type": "array"},
                                    "verified": {"type": "array"},
                                    "risks": {"type": "array"},
                                    "missing_checks": {"type": "array"},
                                    "learning_checks": {"type": "array"},
                                    "guidance_context": {"type": "array"},
                                    "evolution_candidates": {"type": "array"},
                                    "review_revision": {"type": "string"},
                                },
                                "required": ["action"],
                            },
                        },
                        {
                            "name": "exec_command",
                            "description": "Execute local shell command",
                            "inputSchema": {"type": "object", "properties": {"cmd": {"type": "string"}}},
                        },
                    ]
                },
            }
        elif method == "tools/call" and tool_name in ("relay_context", "relaycore_context", "agentdock_context"):
            legacy_rule = "任务执行过程中，在形成有恢复价值的断点时调用 task_manage checkpoint；可用 completed_step_ids/current_step_id 原子批量更新，final_review=pass 不会自动补全未完成步骤。"
            resp_obj = {
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": {
                    "content": [{"type": "text", "text": json.dumps({"workspace": "project_v46", "rules": [legacy_rule]}, ensure_ascii=False)}],
                    "structuredContent": {"workspace": "project_v46", "rules": [legacy_rule]},
                },
            }
        else:
            resp_obj = {
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": {
                    "content": [{"type": "text", "text": json.dumps({"ok": True, "tool": tool_name}, ensure_ascii=False)}],
                    "structuredContent": {"ok": True, "tool": tool_name},
                },
            }

        body = json.dumps(resp_obj, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class SpecV46SeamTests(unittest.TestCase):
    def setUp(self):
        self._prev_side_effects = shield._HOST_SIDE_EFFECTS_ENABLED
        shield._HOST_SIDE_EFFECTS_ENABLED = False

        self.tmp_dir = tempfile.TemporaryDirectory()
        self.root = self.tmp_dir.name
        self.data_root = os.path.join(self.root, "data")
        self.logs_dir = os.path.join(self.data_root, "logs")
        self.tasks_root = os.path.join(self.root, "engine-data", "tasks")
        os.makedirs(self.logs_dir, exist_ok=True)
        os.makedirs(self.tasks_root, exist_ok=True)

        self.activity_path = os.path.join(self.logs_dir, "shield-activity.json")
        self.wb_state_path = os.path.join(self.logs_dir, "web-bridge-state.json")

        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), LegacyUpstreamMockHandler)
        self.upstream.calls = []
        self.upstream_port = self.upstream.server_address[1]
        self.upstream_thread = threading.Thread(target=self.upstream.serve_forever, daemon=True)
        self.upstream_thread.start()

        self.shield_srv = shield.ShieldServer(
            ("127.0.0.1", 0),
            f"http://127.0.0.1:{self.upstream_port}/mcp",
            self.activity_path,
            tasks_root=self.tasks_root,
            data_root=self.data_root,
        )
        self.shield_port = self.shield_srv.server_address[1]
        self.shield_thread = threading.Thread(target=self.shield_srv.serve_forever, daemon=True)
        self.shield_thread.start()

    def tearDown(self):
        shield._HOST_SIDE_EFFECTS_ENABLED = self._prev_side_effects
        self.shield_srv.shutdown()
        self.shield_srv.server_close()
        self.upstream.shutdown()
        self.upstream.server_close()
        self.tmp_dir.cleanup()

    def _post_json(self, path: str, payload: dict) -> dict:
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.shield_port}{path}",
            data=raw,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def _get_json(self, path: str) -> dict:
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.shield_port}{path}",
            method="GET",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def _mcp_call(self, tool_name: str, arguments: dict, rpc_id: str = "rpc_1") -> dict:
        return self._post_json(
            "/mcp",
            {
                "jsonrpc": "2.0",
                "id": rpc_id,
                "method": "tools/call",
                "params": {"name": tool_name, "arguments": arguments},
            },
        )

    def test_slice1_zero_residue_schema_and_native_one_step_closeout(self):
        # 1. tools/list purges `evolve`, `final_review`, `complete`, and all review/evolution properties
        list_resp = self._post_json("/mcp", {"jsonrpc": "2.0", "id": "list_1", "method": "tools/list", "params": {}})
        tools = list_resp["result"]["tools"]
        tool_names = [t["name"] for t in tools]
        self.assertNotIn("evolve", tool_names)
        self.assertIn("task_manage", tool_names)

        tm_tool = next(t for t in tools if t["name"] == "task_manage")
        self.assertNotIn("2 步以上", tm_tool.get("description", ""))
        self.assertNotIn("final_review", tm_tool.get("description", ""))
        self.assertIn("/develop", tm_tool.get("description", ""))
        self.assertEqual(shield._normalize_step_status("two_strike_stop"), "in_progress")
        self.assertEqual(shield._normalize_step_status("two-strike-stop"), "in_progress")
        props = tm_tool["inputSchema"]["properties"]
        self.assertEqual(
            props["action"]["enum"],
            ["create", "update", "checkpoint", "list", "get", "block", "resume"],
        )
        for banned_field in (
            "completion_conditions",
            "verified",
            "risks",
            "missing_checks",
            "learning_checks",
            "guidance_context",
            "evolution_candidates",
            "review_revision",
        ):
            self.assertNotIn(banned_field, props)

        # 2. Calling removed `evolve` or `final_review` / `complete` fails cleanly on :8766 without hitting :8765
        self.upstream.calls.clear()
        ev_err = self._mcp_call("evolve", {"action": "submit"}, rpc_id="err_ev")
        self.assertTrue(ev_err["result"].get("isError"))
        fr_err = self._mcp_call("task_manage", {"action": "final_review", "task_id": "tsk_none"}, rpc_id="err_fr")
        self.assertTrue(fr_err["result"].get("isError"))
        cp_err = self._mcp_call("task_manage", {"action": "complete", "task_id": "tsk_none"}, rpc_id="err_cp")
        self.assertTrue(cp_err["result"].get("isError"))
        self.assertEqual(len(self.upstream.calls), 0, "Removed tools/actions must never forward to :8765")

        # 3. Native 7-action lifecycle (`create`, `get`, `list`, `block`, `resume`, `checkpoint`, `update`) + `quarantined` + 1-Step Auto-Closeout
        create_res = self._mcp_call(
            "task_manage",
            {
                "action": "create",
                "title": "重构自动催工与原生账本引擎",
                "goal": "落地 Spec v4.6",
                "steps": [
                    {"id": "s1", "title": "剥离自进化残留"},
                    {"id": "s2", "title": "隔离超慢外部集成测试"},
                    {"id": "s3", "title": "完成接缝回归"},
                ],
            },
            rpc_id="tm_create",
        )
        self.assertFalse(create_res["result"].get("isError"))
        sc = create_res["result"]["structuredContent"]
        task_id = sc["task_id"]
        self.assertTrue(task_id.startswith("tsk_"))
        self.assertEqual(len(self.upstream.calls), 0, "Native task_manage(create) must not hit :8765")

        get_res = self._mcp_call("task_manage", {"action": "get", "task_id": task_id}, rpc_id="tm_get")
        self.assertEqual(get_res["result"]["structuredContent"]["task"]["id"], task_id)

        list_res = self._mcp_call("task_manage", {"action": "list"}, rpc_id="tm_list")
        self.assertEqual(list_res["result"]["structuredContent"]["count"], 1)

        blk_res = self._mcp_call("task_manage", {"action": "block", "task_id": task_id, "summary": "等待端口释放"}, rpc_id="tm_blk")
        self.assertEqual(blk_res["result"]["structuredContent"]["status"], "blocked")

        res_res = self._mcp_call("task_manage", {"action": "resume", "task_id": task_id, "summary": "端口已释放"}, rpc_id="tm_res")
        self.assertIn(res_res["result"]["structuredContent"]["status"], ("active", "in_progress"))

        # Update action: verify both title/goal update AND step status mutation via action="update"
        upd_res = self._mcp_call(
            "task_manage",
            {
                "action": "update",
                "task_id": task_id,
                "title": "重构自动催工与原生账本引擎（已确认）",
                "summary": "通过 update 同步标题",
            },
            rpc_id="tm_upd1",
        )
        self.assertFalse(upd_res["result"].get("isError"))
        self.assertEqual(upd_res["result"]["structuredContent"]["title"], "重构自动催工与原生账本引擎（已确认）")
        self.assertIn(upd_res["result"]["structuredContent"]["status"], ("active", "in_progress"))

        # Checkpoint s1=completed, s2=quarantined, s3=in_progress -> still running
        cp1 = self._mcp_call(
            "task_manage",
            {
                "action": "checkpoint",
                "task_id": task_id,
                "completed_step_ids": ["s1"],
                "quarantined_step_ids": ["s2"],
                "current_step_id": "s3",
                "summary": "s1 完成，s2 慢测隔离，推进 s3",
            },
            rpc_id="tm_cp1",
        )
        self.assertIn(cp1["result"]["structuredContent"]["status"], ("active", "in_progress"))

        # Update s3=completed via action="update" (or checkpoint) -> all steps in {"completed", "quarantined"} -> 1-Step Auto-Closeout!
        cp2 = self._mcp_call(
            "task_manage",
            {
                "action": "update",
                "task_id": task_id,
                "step_id": "s3",
                "status": "completed",
                "summary": "s3 接缝回归全部通过",
            },
            rpc_id="tm_cp2",
        )
        self.assertEqual(cp2["result"]["structuredContent"]["status"], "completed")
        self.assertTrue(bool(cp2["result"]["structuredContent"]["task"].get("completed_at")))
        self.assertEqual(len(self.upstream.calls), 0, "All 7 task_manage actions must execute natively on :8766")

        # 4. Verify `/__studio__/snapshot` alias & `IsCompleted == True` & `quarantined` UI badge & guardian silent skip
        snap = self._get_json("/__studio__/snapshot")
        self.assertTrue(snap["ok"])
        card = next(s for s in snap["sessions"] if s["SessionKey"] == task_id)
        self.assertTrue(card["IsCompleted"])
        self.assertEqual(card["ProgressPercent"], 100)
        s2_ui = next(st for st in card["Steps"] if st["Id"] == "s2")
        self.assertEqual(s2_ui["Status"], "quarantined")
        self.assertIn("已隔离", s2_ui["StatusLabel"])

        # Simulate elapsed time > stall threshold -> guardian must NOT send any wakeup on a completed task
        task_file = os.path.join(self.tasks_root, f"{task_id}.json")
        with open(task_file, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        old_iso = "2026-11-02T00:00:00Z"
        doc["updated_at"] = old_iso
        with open(task_file, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False, indent=2)

        tick_res = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(tick_res["actions"], [])

    def test_slice2_scenario_separation_daytime_vs_unattended(self):
        # 1. With 0 active tasks, `relaycore_context` must NOT coerce `task_manage(action='create')`,
        #    must NOT leak legacy `final_review=pass`, and must NOT inject `_NO_CONFIRM_DIRECTIVE`
        ctx_resp = self._mcp_call("relaycore_context", {}, rpc_id="ctx_daytime")
        ctx_txt = ctx_resp["result"]["content"][0]["text"]
        ctx_sc = ctx_resp["result"]["structuredContent"]
        self.assertNotIn("task_manage(action='create')", ctx_txt)
        self.assertNotIn("final_review=pass", ctx_txt)
        self.assertFalse(any("final_review=pass" in r for r in ctx_sc.get("rules", [])))
        self.assertNotIn("[RelayStudio Auto-Execution Directive]", ctx_txt)

        # 2. Create an active task, then turn OFF auto-resend (`set_auto_wakeup(enabled=False)`) -> daytime manual mode
        cr = self._mcp_call(
            "task_manage",
            {
                "action": "create",
                "title": "日间交互探讨任务",
                "steps": [{"id": "s1", "title": "步骤一"}, {"id": "s2", "title": "步骤二"}],
            },
            rpc_id="cr_s2",
        )
        tid = cr["result"]["structuredContent"]["task_id"]

        act_off = self._post_json("/__studio__/action", {"action": "set_auto_wakeup", "session_key": tid, "enabled": False})
        self.assertTrue(act_off["ok"])

        exec_manual = self._mcp_call("exec_command", {"cmd": "echo manual"}, rpc_id="exec_manual")
        self.assertNotIn("[RelayStudio Auto-Execution Directive]", exec_manual["result"]["content"][0]["text"])
        self.assertFalse(exec_manual["result"]["structuredContent"].get("auto_execution_authorized", False))

        cp_manual = self._mcp_call(
            "task_manage",
            {"action": "checkpoint", "task_id": tid, "summary": "日间手动推进"},
            rpc_id="cp_manual",
        )
        self.assertNotIn("[RelayStudio Auto-Execution Directive]", cp_manual["result"]["content"][0]["text"])
        self.assertFalse(cp_manual["result"]["structuredContent"].get("auto_execution_authorized", False))

        # 3. Turn ON auto-resend (`set_auto_wakeup(enabled=True)`) -> unattended continuous mode
        act_on = self._post_json("/__studio__/action", {"action": "set_auto_wakeup", "session_key": tid, "enabled": True})
        self.assertTrue(act_on["ok"])

        exec_auto = self._mcp_call("exec_command", {"cmd": "echo auto"}, rpc_id="exec_auto")
        self.assertIn("[RelayStudio Auto-Execution Directive]", exec_auto["result"]["content"][0]["text"])
        self.assertTrue(exec_auto["result"]["structuredContent"]["auto_execution_authorized"])

        cp_auto = self._mcp_call(
            "task_manage",
            {"action": "checkpoint", "task_id": tid, "summary": "夜间自动推进"},
            rpc_id="cp_auto",
        )
        self.assertIn("[RelayStudio Auto-Execution Directive]", cp_auto["result"]["content"][0]["text"])
        self.assertTrue(cp_auto["result"]["structuredContent"]["auto_execution_authorized"])

    def test_slice3_unattributed_inflight_gate_and_heartbeat_attribution(self):
        # 1. Pre-seed an `in_progress` task whose ledger timestamp is 10 minutes old (> 3 min stall threshold)
        tid = "tsk_inflight00000003"
        ten_min_ago = datetime.datetime.fromtimestamp(time.time() - 600, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        now_iso = shield._utc_now_iso()
        task_doc = {
            "schema_version": 1,
            "id": tid,
            "title": "长耗时编译与测试任务",
            "goal": "验证无 task_id 的高频工具在途保护与心跳归集",
            "status": "in_progress",
            "phase": "execute",
            "steps": [{"id": "s1", "title": "执行全量构建", "status": "in_progress", "updated_at": ten_min_ago}],
            "events": [{"type": "created", "summary": "init", "created_at": ten_min_ago}],
            "summary": "正在执行构建",
            "created_at": ten_min_ago,
            "updated_at": ten_min_ago,
        }
        with open(os.path.join(self.tasks_root, f"{tid}.json"), "w", encoding="utf-8") as fh:
            json.dump(task_doc, fh, ensure_ascii=False, indent=2)

        conv_uuid = "33333333-3333-4333-8333-333333333333"
        wb_init = shield._default_web_bridge_state()
        wb_init["session_bindings"][tid] = shield._ensure_binding_entry(
            {"conv_uuid": conv_uuid, "browser_profile": "Desktop:ChatGPT", "auto_resend_enabled": True}
        )
        wb_init["tabs"]["desktop_chatgpt"] = {
            "tab_id": "desktop_chatgpt",
            "browser": "Desktop",
            "browser_profile": "Desktop:ChatGPT",
            "conv_uuid": conv_uuid,
            "is_generating": False,
            "sse_active": False,
            "has_error": False,
            "state_known": True,
            "last_seen_at": now_iso,
        }
        shield._save_web_bridge_state(self.wb_state_path, wb_init)

        snap_before = self._get_json("/__studio__/snapshot")
        base_card = next(s for s in snap_before["sessions"] if s["SessionKey"] == tid)
        prev_cmd_count = base_card["CommandCount"]

        # 2. Record an unattributed in-flight `exec_command` (no `task_id`!)
        shield.record_shield_activity(
            self.activity_path,
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": "inflight_rpc_1",
                    "method": "tools/call",
                    "params": {"name": "exec_command", "arguments": {"cmd": "cargo build --release"}},
                }
            ).encode("utf-8"),
        )
        snap_live = self._get_json("/__studio__/snapshot")
        live_card = next(s for s in snap_live["sessions"] if s["SessionKey"] == tid)
        self.assertEqual(live_card["VitalState"], "LIVE")
        self.assertTrue(live_card["McpInFlight"])
        self.assertFalse(live_card["IsStalled"])
        self.assertEqual(live_card["ElapsedSeconds"], 0)

        # Guardian must NOT enqueue any wakeup while unattributed tool is in-flight
        g_res = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(g_res["actions"], [])

        # DesktopAppBridge.tick must also hold any pending auto `in_place_wakeup` while tool is in-flight
        with shield._WEB_BRIDGE_LOCK:
            st = shield._load_web_bridge_state(self.wb_state_path)
            st["queue"].append(
                {
                    "id": "msg_hold_inflight",
                    "session_key": tid,
                    "conv_uuid": conv_uuid,
                    "mode": "in_place_wakeup",
                    "is_auto_wakeup": True,
                    "browser_profile": "Desktop:ChatGPT",
                    "prompt": "继续",
                    "text": "继续",
                    "status": "pending",
                    "created_at": now_iso,
                }
            )
            shield._save_web_bridge_state(self.wb_state_path, st)

        fill_calls = []

        def fake_eval(expr, kind="main_page"):
            if "/*relay:fill*/" in str(expr):
                fill_calls.append(expr)
            return {
                "url": f"https://chatgpt.com/c/{conv_uuid}",
                "native_url": "app://-/index.html",
                "conv_uuid": conv_uuid,
                "has_composer": True,
                "sse_active": False,
                "is_generating": False,
                "turn_seq": 4,
                "has_error": False,
                "page_hints": [tid],
                "composer_text": "",
                "has_user_draft": False,
            }

        d_res = shield.DesktopAppBridge.tick(
            self.wb_state_path,
            tasks_root=self.tasks_root,
            eval_fn=fake_eval,
            sleep_fn=lambda _: None,
        )
        self.assertEqual(d_res["processed"], 0)
        self.assertEqual(fill_calls, [], "DesktopAppBridge must NOT attempt script_fill while MCP tool is in-flight")
        st_after_hold = shield._load_web_bridge_state(self.wb_state_path)
        held_msg = next(m for m in st_after_hold["queue"] if m["id"] == "msg_hold_inflight")
        self.assertEqual(held_msg["status"], "pending")

        # 3. Finish the in-flight call and run a real unattributed `exec_command` through `/mcp`
        shield.complete_shield_activity(self.activity_path, {"rpc_id": "inflight_rpc_1", "task_id": ""})
        self._mcp_call("exec_command", {"cmd": "pytest -q"}, rpc_id="exec_done_2")

        snap_after = self._get_json("/__studio__/snapshot")
        after_card = next(s for s in snap_after["sessions"] if s["SessionKey"] == tid)
        self.assertGreater(after_card["CommandCount"], prev_cmd_count)
        self.assertGreater(shield._parse_iso_epoch(after_card["LastActivityAt"]), shield._parse_iso_epoch(ten_min_ago))

    def test_slice4_reasoning_effort_zero_touch_and_handover_inheritance(self):
        # 1. Task A explicitly sets effort="high"; Task B is untouched ("inherit") and toggles auto-resend.
        #    Task A must NOT pollute global default_reasoning_effort onto Task B, and setting "inherit" must NOT lock effort!
        cr_a = self._mcp_call("task_manage", {"action": "create", "title": "任务A显式指定档位", "force_new": True}, rpc_id="s4_a")
        tid_a = cr_a["result"]["structuredContent"]["task_id"]
        cr_b = self._mcp_call("task_manage", {"action": "create", "title": "任务B保持原窗档位", "force_new": True}, rpc_id="s4_b")
        tid_b = cr_b["result"]["structuredContent"]["task_id"]

        self._post_json(
            "/__studio__/action",
            {"action": "set_task_composer_config", "session_key": tid_a, "target_model": "gpt-5-4-thinking", "reasoning_effort": "high"},
        )
        # Simulate UI catalog sync re-confirming "inherit" and toggling auto-resend on Task B
        self._post_json(
            "/__studio__/action",
            {"action": "set_task_composer_config", "session_key": tid_b, "reasoning_effort": "inherit"},
        )
        self._post_json("/__studio__/action", {"action": "set_auto_wakeup", "session_key": tid_b, "enabled": False})
        self._post_json("/__studio__/action", {"action": "set_auto_wakeup", "session_key": tid_b, "enabled": True})

        wb_state = self._get_json("/web-bridge/state")
        b_b = wb_state["session_bindings"][tid_b]
        self.assertEqual(b_b["reasoning_effort"], "inherit")
        self.assertFalse(b_b["user_locked_effort"], "Setting 'inherit' or toggling auto-resend must never set user_locked_effort=True")

        # 2. Bind Task B to room `conv_b` where user manually tuned `current_effort="xhigh"`, `current_model="gpt-5-pro"` before sleep
        conv_b = "44444444-4444-4444-8444-444444444444"
        ten_min_ago = datetime.datetime.fromtimestamp(time.time() - 600, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        with open(os.path.join(self.tasks_root, f"{tid_b}.json"), "r+", encoding="utf-8") as fh:
            doc_b = json.load(fh)
            doc_b["updated_at"] = ten_min_ago
            doc_b["created_at"] = ten_min_ago
            doc_b["events"][0]["created_at"] = ten_min_ago
            fh.seek(0)
            json.dump(doc_b, fh, ensure_ascii=False, indent=2)
            fh.truncate()
        act_path = os.path.join(self.data_root, "logs", "shield-activity.json")
        if os.path.isfile(act_path):
            with open(act_path, "r+", encoding="utf-8") as fh:
                act_doc = json.load(fh)
                for c_val in act_doc.get("calls", {}).values():
                    if isinstance(c_val, dict) and (c_val.get("rpc_id") == "s4_b" or c_val.get("task_id") == tid_b):
                        for k_ts in ("time", "started_at", "completed_at"):
                            c_val[k_ts] = ten_min_ago
                fh.seek(0)
                json.dump(act_doc, fh, ensure_ascii=False, indent=2)
                fh.truncate()

        self._post_json("/__studio__/action", {"action": "bind_session", "session_key": tid_b, "conv_uuid": conv_b, "browser_profile": "Chrome:Work"})
        self._post_json(
            "/web-bridge/poll",
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Work",
                "tabs": [
                    {
                        "tab_id": "tab_b1",
                        "url": f"https://chatgpt.com/c/{conv_b}",
                        "conv_uuid": conv_b,
                        "is_generating": False,
                        "sse_active": False,
                        "has_error": False,
                        "turn_seq": 6,
                        "current_model": "gpt-5-pro",
                        "current_effort": "xhigh",
                        "page_hints": [tid_b],
                    }
                ],
            },
        )

        # 2a. Follow-window (`in_place_wakeup`) on Task B: dispatch keeps "inherit" and `RelayCdp.script_fill` makes 0 `onModelChange` calls
        g1 = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(len(g1["actions"]), 1)
        self.assertEqual(g1["actions"][0]["action"], "in_place_wakeup")
        wb_after_w = self._get_json("/web-bridge/state")
        wakeup_msg = next(m for m in wb_after_w["queue"] if m["id"] == g1["actions"][0]["msg_id"])
        self.assertEqual(wakeup_msg["reasoning_effort"], "inherit")
        self.assertEqual(wakeup_msg["target_model"], "inherit")

        fill_js_wakeup = RelayCdp.script_fill(
            wakeup_msg["id"],
            wakeup_msg["text"],
            wakeup_msg["target_model"],
            wakeup_msg["reasoning_effort"],
        )
        # Execute real JS in Node to verify `onModelChange` call count == 0 when inherit
        import subprocess
        node_probe = r"""
const fs = require("fs");
const expr = fs.readFileSync(0, "utf8");
let modelChangeCalls = 0;
const fakeForm = {
  nodeType: 1, hidden: false, style: { display: "block", visibility: "visible" }, parentElement: null,
  hasAttribute: () => false, getAttribute: () => null, closest: () => null,
  getBoundingClientRect: () => ({ width: 500, height: 80 }),
  __reactFiber$test: {
    memoizedProps: {
      isWorkConversation: false,
      conversationId: "44444444-4444-4444-8444-444444444444",
      entries: [],
      selectedModel: { slug: "gpt-5-pro", thinkingEffort: "xhigh", versionId: "latest" },
      onModelChange: () => { modelChangeCalls++; },
      composerController: { text: "", getText() { return this.text; }, setText(v) { this.text = v; } }
    },
    return: null
  }
};
global.window = global;
global.location = { protocol: "app:", pathname: "/", href: "app://-/index.html" };
global.document = {
  title: "Test",
  documentElement: { dataset: {} },
  querySelectorAll: (sel) => sel.includes("form[data-chatgpt-composer]") ? [fakeForm] : [],
  querySelector: () => null
};
const out = eval(expr);
process.stdout.write(JSON.stringify({ out, modelChangeCalls }));
"""
        proc = subprocess.run(["node", "-e", node_probe], input=fill_js_wakeup.encode("utf-8"), capture_output=True, timeout=5)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode("utf-8", errors="replace"))
        probe_res = json.loads(proc.stdout.decode("utf-8"))
        self.assertTrue(probe_res["out"]["filled"])
        self.assertEqual(probe_res["modelChangeCalls"], 0, "follow_window + inherit must make 0 onModelChange calls")

        # 2b. Spec v4.7 Option A: report `has_load_error=True` on `conv_b` so guardian upgrades to `new_window_handover` ->
        #     Handover Dispatch MUST snapshot live `current_effort="xhigh"` & `current_model="gpt-5-pro"`!
        self._post_json(
            "/web-bridge/poll",
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Work",
                "tabs": [
                    {
                        "tab_id": "tab_b1",
                        "url": f"https://chatgpt.com/c/{conv_b}",
                        "conv_uuid": conv_b,
                        "is_generating": False,
                        "sse_active": False,
                        "has_error": True,
                        "has_load_error": True,
                        "turn_seq": 6,
                        "current_model": "gpt-5-pro",
                        "current_effort": "xhigh",
                        "page_hints": [tid_b],
                    }
                ],
            },
        )
        g2 = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertTrue(any(a["action"] in ("upgraded_to_handover", "new_window_handover") for a in g2["actions"]))
        wb_after_h = self._get_json("/web-bridge/state")
        handover_msg = next(m for m in wb_after_h["queue"] if m["session_key"] == tid_b and m["mode"] == "new_window_handover")
        self.assertEqual(handover_msg["reasoning_effort"], "xhigh")
        self.assertEqual(handover_msg["target_model"], "gpt-5-pro")

        # 3. Task A (user explicitly set effort="high") uses "high" on both follow_window and new_window_handover
        enq_a_follow = self._post_json(
            "/__studio__/action",
            {"action": "enqueue_message", "session_key": tid_a, "conv_uuid": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "user_text": ""},
        )
        self.assertEqual(enq_a_follow["message"]["reasoning_effort"], "high")
        enq_a_handover = self._post_json(
            "/__studio__/action",
            {"action": "enqueue_message", "session_key": tid_a, "mode": "new_window_handover", "user_text": ""},
        )
        self.assertEqual(enq_a_handover["message"]["reasoning_effort"], "high")

    def test_slice5_circuit_breaker_downstream_execution_proof(self):
        # Pre-seed an in-progress task with max_retries=2 and stall_seconds=60
        tid = "tsk_breaker000000005"
        ten_min_ago = datetime.datetime.fromtimestamp(time.time() - 600, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        two_min_ago = datetime.datetime.fromtimestamp(time.time() - 120, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        task_doc = {
            "schema_version": 1,
            "id": tid,
            "title": "熔断防假清零验证任务",
            "goal": "验证仅本人投递消息(+1)不重置 retry_count，必须工具增长或完整问答回合(+2)才重置",
            "status": "in_progress",
            "phase": "execute",
            "steps": [{"id": "s1", "title": "执行核心重构", "status": "in_progress", "updated_at": ten_min_ago}],
            "events": [{"type": "created", "summary": "init", "created_at": ten_min_ago}],
            "summary": "正在重构",
            "created_at": ten_min_ago,
            "updated_at": ten_min_ago,
        }
        with open(os.path.join(self.tasks_root, f"{tid}.json"), "w", encoding="utf-8") as fh:
            json.dump(task_doc, fh, ensure_ascii=False, indent=2)

        conv_5 = "55555555-5555-4555-8555-555555555555"
        self._post_json(
            "/__studio__/action",
            {
                "action": "set_task_composer_config",
                "session_key": tid,
                "conv_uuid": conv_5,
                "browser_profile": "Chrome:Work",
                "max_retries": 2,
                "stall_seconds": 60,
            },
        )
        self._post_json(
            "/web-bridge/poll",
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Work",
                "tabs": [
                    {
                        "tab_id": "tab_5",
                        "url": f"https://chatgpt.com/c/{conv_5}",
                        "conv_uuid": conv_5,
                        "is_generating": False,
                        "sse_active": False,
                        "has_error": False,
                        "turn_seq": 4,
                        "page_hints": [tid],
                    }
                ],
            },
        )

        # 1. First stall -> sends in_place_wakeup #1 (retry_count=1, wakeup_baseline_turn_seq=4)
        g1 = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(g1["actions"][0]["action"], "in_place_wakeup")
        msg1_id = g1["actions"][0]["msg_id"]
        wb1 = self._get_json("/web-bridge/state")
        self.assertEqual(wb1["breakers"][tid]["retry_count"], 1)
        self.assertEqual(wb1["breakers"][tid]["wakeup_baseline_turn_seq"], 4)

        # Simulate browser claiming & ACKing msg1, but ONLY the outgoing user bubble was added (turn_seq 4 -> 5, +1 only!)
        with shield._WEB_BRIDGE_LOCK:
            st = shield._load_web_bridge_state(self.wb_state_path)
            for m in st["queue"]:
                if m["id"] == msg1_id:
                    m["status"] = "delivered"
                    m["delivered_at"] = two_min_ago
            st["breakers"][tid]["wakeup_sent_at"] = two_min_ago
            st["breakers"][tid]["last_sent_at"] = two_min_ago
            shield._save_web_bridge_state(self.wb_state_path, st)

        self._post_json(
            "/web-bridge/poll",
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Work",
                "tabs": [
                    {
                        "tab_id": "tab_5",
                        "url": f"https://chatgpt.com/c/{conv_5}",
                        "conv_uuid": conv_5,
                        "is_generating": False,
                        "sse_active": False,
                        "has_error": False,
                        "turn_seq": 5,  # +1 ONLY (wakeup user message itself, model did NOT complete an answer!)
                        "page_hints": [tid],
                    }
                ],
            },
        )
        # Backdate tab last_live_at so 2 minutes of stall have elapsed after the aborted +1 turn
        with shield._WEB_BRIDGE_LOCK:
            st = shield._load_web_bridge_state(self.wb_state_path)
            st["tabs"]["tab_5"]["last_live_at"] = two_min_ago
            st["breakers"][tid]["last_live_at"] = two_min_ago
            shield._save_web_bridge_state(self.wb_state_path, st)

        # 2. Guardian tick #2: turn_seq=5 (+1) with unchanged CommandCount MUST NOT reset retry_count!
        #    retry_count must advance 1 -> 2!
        g2 = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(g2["actions"][0]["action"], "in_place_wakeup")
        msg2_id = g2["actions"][0]["msg_id"]
        wb2 = self._get_json("/web-bridge/state")
        self.assertEqual(wb2["breakers"][tid]["retry_count"], 2, "turn_seq +1 without tool progress must NOT reset retry_count to 0")

        # 2b. Verify that if msg2 is also only echoed (+1: 5 -> 6) and stalls again at retry_count == max_retries (2),
        #     the circuit breaker escalates to new_window_handover instead of spinning forever on in_place_wakeup!
        with shield._WEB_BRIDGE_LOCK:
            st = shield._load_web_bridge_state(self.wb_state_path)
            st_snapshot_before_escalation = json.loads(json.dumps(st))
            for m in st["queue"]:
                if m["id"] == msg2_id:
                    m["status"] = "delivered"
                    m["delivered_at"] = two_min_ago
            st["tabs"]["tab_5"]["turn_seq"] = 6
            st["tabs"]["tab_5"]["last_live_at"] = two_min_ago
            st["breakers"][tid]["last_live_at"] = two_min_ago
            shield._save_web_bridge_state(self.wb_state_path, st)

        g2_escalate = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(g2_escalate["actions"][0]["action"], "new_window_handover")
        self.assertEqual(self._get_json("/web-bridge/state")["breakers"][tid]["stage"], "HandoverSent")

        # Restore pre-escalation state so we can also verify genuine +2 recovery from retry_count=2 -> 0
        with shield._WEB_BRIDGE_LOCK:
            shield._save_web_bridge_state(self.wb_state_path, st_snapshot_before_escalation)

        # 3. Now simulate genuine full user+assistant turn completion (turn_seq 5 -> 7, i.e., >= wakeup_baseline_turn_seq + 2, no error)
        with shield._WEB_BRIDGE_LOCK:
            st = shield._load_web_bridge_state(self.wb_state_path)
            for m in st["queue"]:
                if m["id"] == msg2_id:
                    m["status"] = "delivered"
                    m["delivered_at"] = two_min_ago
            shield._save_web_bridge_state(self.wb_state_path, st)

        self._post_json(
            "/web-bridge/poll",
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Work",
                "tabs": [
                    {
                        "tab_id": "tab_5",
                        "url": f"https://chatgpt.com/c/{conv_5}",
                        "conv_uuid": conv_5,
                        "is_generating": False,
                        "sse_active": False,
                        "has_error": False,
                        "turn_seq": 7,  # +2 from baseline 5 -> genuine assistant response completed!
                        "page_hints": [tid],
                    }
                ],
            },
        )
        g3 = shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        wb3 = self._get_json("/web-bridge/state")
        self.assertEqual(wb3["breakers"][tid]["retry_count"], 0, "Full +2 turn completion without error must reset retry_count=0")
        self.assertEqual(wb3["breakers"][tid]["stage"], "Idle")
        self.assertEqual(g3["actions"], [])

    def test_slice6_powershell_quarantined_badge_and_offline_lock_isolation(self):
        import subprocess
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        tid = "tsk_psslice600000006"
        now_iso = shield._utc_now_iso()
        with open(os.path.join(self.tasks_root, f"{tid}.json"), "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "schema_version": 1,
                    "id": tid,
                    "title": "PowerShell 离线接缝验证",
                    "goal": "验证 quarantined 徽标与离线换窗继承",
                    "status": "in_progress",
                    "steps": [
                        {"id": "1", "title": "已完成步骤", "status": "completed", "updated_at": now_iso},
                        {"id": "2", "title": "已隔离步骤", "status": "quarantined", "updated_at": now_iso},
                        {"id": "3", "title": "进行中步骤", "status": "in_progress", "updated_at": now_iso},
                    ],
                    "created_at": now_iso,
                    "updated_at": now_iso,
                },
                fh,
                ensure_ascii=False,
                indent=2,
            )

        ps_script = f"""
$ErrorActionPreference = 'Stop'
Import-Module '{os.path.join(repo_root, "ConnectionManager.psm1")}' -Force
$ctx = [pscustomobject]@{{
    Isolated = $true
    DataRoot = '{self.data_root}'
    TasksRoot = '{self.tasks_root}'
    HubPort = 59999
}}
$tasks = @(Get-RelayTasks -Context $ctx)
$t = $tasks | Where-Object {{ $_.TaskId -eq '{tid}' }}
if (-not $t) {{ throw 'Task not found' }}
if ($t.CompletedStepCount -ne 2) {{ throw "Expected CompletedStepCount=2, got $($t.CompletedStepCount)" }}
$qStep = $t.Steps | Where-Object {{ $_.Id -eq '2' }}
if ($qStep.StatusLabel -ne '⊘ 已隔离') {{ throw "Expected quarantined label, got $($qStep.StatusLabel)" }}
$sess = [pscustomobject]@{{
    SessionKey = '{tid}'
    Title = $t.Title
    ShortTitle = $t.Title
    Steps = $t.Steps
    ActionText = ''
    LatestSummary = ''
    CommandCount = 3
    ProgressPercent = $t.ProgressPercent
}}
$wakeTxt = New-StallWakeupPrompt -Session $sess
if ($wakeTxt -notmatch '已完成 2 / 3 步') {{ throw "Unexpected wakeup text: $wakeTxt" }}
$handTxt = New-HandoverPrompt -Session $sess
if ($handTxt -notmatch '2 / 3 步') {{ throw "Unexpected handover text: $handTxt" }}

# Offline Set-TaskComposerConfig with inherit must NOT lock effort
[void](Set-TaskComposerConfig -Context $ctx -SessionKey '{tid}' -ConvUuid '66666666-6666-4666-8666-666666666666' -TabId 'tab_ps6' -ReasoningEffort 'inherit')
$st = Get-WebBridgeState -Context $ctx
if ([bool]$st.session_bindings.'{tid}'.user_locked_effort) {{ throw 'inherit must not set user_locked_effort=true' }}
$st | Add-Member -NotePropertyName 'tabs' -NotePropertyValue ([pscustomobject]@{{
    tab_ps6 = [pscustomobject]@{{
        tab_id = 'tab_ps6'
        conv_uuid = '66666666-6666-4666-8666-666666666666'
        current_model = 'gpt-6-thinking'
        current_effort = 'extended'
    }}
}}) -Force
Save-WebBridgeState -Context $ctx -State $st

# Offline StopAndRetire handover must snapshot & inherit live tab model + effort
$res = Send-WebBridgeMessage -Context $ctx -Session $sess -Mode 'new_window_handover' -StopAndRetire
if ($res.TargetModel -ne 'gpt-6-thinking' -or $res.ReasoningEffort -ne 'extended') {{
    throw "Expected inherited gpt-6-thinking/extended, got $($res.TargetModel)/$($res.ReasoningEffort)"
}}
Write-Output 'SLICE6_PS_OK'
"""
        import base64
        enc_cmd = base64.b64encode(ps_script.encode("utf-16-le")).decode("ascii")
        proc = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", enc_cmd],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=25,
        )
        self.assertEqual(proc.returncode, 0, f"PowerShell failed:\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")
        self.assertIn("SLICE6_PS_OK", proc.stdout)

    def test_slice7_pure_two_stage_lifecycle_archive_restore_purge_and_handover_retire(self):
        tid = "tsk_lifecycle0000007"
        now_iso = shield._utc_now_iso()
        with open(os.path.join(self.tasks_root, f"{tid}.json"), "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "schema_version": 1,
                    "id": tid,
                    "title": "两段式生命周期与全链路云端同步测试",
                    "goal": "验证交接退居、归档全扫、还原当前、双端彻底删除",
                    "status": "in_progress",
                    "steps": [{"id": "1", "title": "步骤一", "status": "in_progress", "updated_at": now_iso}],
                    "created_at": now_iso,
                    "updated_at": now_iso,
                },
                fh,
                ensure_ascii=False,
                indent=2,
            )

        conv_1 = "71111111-1111-4111-8111-111111111111"
        conv_2 = "72222222-2222-4222-8222-222222222222"
        conv_3 = "73333333-3333-4333-8333-333333333333"
        conv_4 = "74444444-4444-4444-8444-444444444444"

        # Bind initial conv_1
        self._post_json(
            "/studio/action",
            {
                "action": "bind_session",
                "session_key": tid,
                "provider": "chatgpt",
                "carrier": "Chrome:Work",
                "conv_uuid": conv_1,
                "tab_id": "tab_c1",
            },
        )

        # Handover Path 1: ?msg_id token transfer in _update_tab_and_bindings (conv_1 -> conv_2)
        with shield._WEB_BRIDGE_LOCK:
            st = shield._load_web_bridge_state(self.wb_state_path)
            st["queue"].append({"id": "msg_h1", "session_key": tid, "mode": "new_window_handover", "status": "claimed"})
            shield._save_web_bridge_state(self.wb_state_path, st)

        self._post_json(
            "/web-bridge/poll",
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Work",
                "tabs": [
                    {
                        "tab_id": "tab_c2",
                        "url": f"https://chatgpt.com/c/{conv_2}?relay_handover=1&msg_id=msg_h1",
                        "conv_uuid": conv_2,
                        "handover_msg_id": "msg_h1",
                        "is_generating": True,
                        "sse_active": True,
                        "page_hints": [tid],
                    }
                ],
            },
        )
        wb1 = self._get_json("/web-bridge/state")
        self.assertEqual(wb1["session_bindings"][tid]["conv_uuid"], conv_2)
        self.assertIn(conv_1, wb1["session_bindings"][tid]["retired_uuids"])
        self.assertTrue(
            any(r["conv_uuid"] == conv_1 and r["operation"] == "archive" and r["status"] == "pending" for r in wb1["retire_actions"]),
            "Handover ?msg_id transfer must enqueue operation='archive' for superseded conv_1",
        )

        # Handover Path 2: Manual active-work transfer in _update_tab_and_bindings (conv_2 idle -> conv_3 generating)
        self._post_json(
            "/web-bridge/poll",
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Work",
                "tabs": [
                    {
                        "tab_id": "tab_c2",
                        "url": f"https://chatgpt.com/c/{conv_2}",
                        "conv_uuid": conv_2,
                        "is_generating": False,
                        "sse_active": False,
                        "page_hints": [tid],
                    },
                    {
                        "tab_id": "tab_c3",
                        "url": f"https://chatgpt.com/c/{conv_3}",
                        "conv_uuid": conv_3,
                        "is_generating": True,
                        "sse_active": True,
                        "page_hints": [tid],
                    },
                ],
            },
        )
        wb2 = self._get_json("/web-bridge/state")
        self.assertEqual(wb2["session_bindings"][tid]["conv_uuid"], conv_3)
        self.assertTrue(
            any(r["conv_uuid"] == conv_2 and r["operation"] == "archive" and r["status"] == "pending" for r in wb2["retire_actions"]),
            "Manual active-work transfer must enqueue operation='archive' for superseded conv_2",
        )

        # Handover Path 3: bind_session rebind (conv_3 -> conv_4)
        self._post_json(
            "/studio/action",
            {
                "action": "bind_session",
                "session_key": tid,
                "conv_uuid": conv_4,
                "tab_id": "tab_c4",
            },
        )
        wb3 = self._get_json("/web-bridge/state")
        self.assertEqual(wb3["session_bindings"][tid]["conv_uuid"], conv_4)
        self.assertTrue(
            any(r["conv_uuid"] == conv_3 and r["operation"] == "archive" and r["status"] == "pending" for r in wb3["retire_actions"]),
            "Session rebind must enqueue operation='archive' for superseded conv_3",
        )

        # Mark historical retire_actions completed and add a pending queue message before testing archive full sweep
        with shield._WEB_BRIDGE_LOCK:
            st = shield._load_web_bridge_state(self.wb_state_path)
            for r in st["retire_actions"]:
                r["status"] = "completed"
            st["queue"].append({"id": "msg_pending_before_arch", "session_key": tid, "mode": "custom_message", "status": "pending"})
            shield._save_web_bridge_state(self.wb_state_path, st)

        # Archive task -> must cancel pending queue message, keep conv_4 bound, and enqueue archive for conv_4 + conv_1..3
        self._post_json("/studio/action", {"action": "archive", "session_key": tid})
        wb_arch = self._get_json("/web-bridge/state")
        self.assertEqual(wb_arch["session_bindings"][tid]["conv_uuid"], conv_4)
        q_msg = next(m for m in wb_arch["queue"] if m["id"] == "msg_pending_before_arch")
        self.assertEqual(q_msg["status"], "cancelled")
        pending_arch_uuids = {r["conv_uuid"] for r in wb_arch["retire_actions"] if r["status"] == "pending" and r["operation"] == "archive"}
        self.assertEqual(pending_arch_uuids, {conv_1, conv_2, conv_3, conv_4})

        # Restore task ('↺ 还原') -> must keep conv_4 bound, cancel pending archive for conv_4, and enqueue unarchive ONLY for conv_4
        self._post_json("/studio/action", {"action": "restore", "session_key": tid})
        wb_rest = self._get_json("/web-bridge/state")
        self.assertEqual(wb_rest["session_bindings"][tid]["conv_uuid"], conv_4)
        pending_unarch_uuids = {r["conv_uuid"] for r in wb_rest["retire_actions"] if r["status"] == "pending" and r["operation"] == "unarchive"}
        self.assertEqual(pending_unarch_uuids, {conv_4}, "Restore must only unarchive the primary conv_uuid, never retired_sessions")

        # Purge task ('🗑️ 彻底删除') -> must delete tsk_*.json, remove binding, and enqueue operation='delete' for ALL conv_1..4
        purge_res = self._post_json("/studio/action", {"action": "purge", "session_key": tid})
        self.assertTrue(purge_res["ok"])
        self.assertFalse(os.path.exists(os.path.join(self.tasks_root, f"{tid}.json")))
        wb_purge = self._get_json("/web-bridge/state")
        self.assertNotIn(tid, wb_purge["session_bindings"])
        pending_del_uuids = {r["conv_uuid"] for r in wb_purge["retire_actions"] if r["status"] == "pending" and r["operation"] == "delete"}
        self.assertEqual(pending_del_uuids, {conv_1, conv_2, conv_3, conv_4})

    def test_slice8_completed_auto_archive_modes_and_ledger_1_task_registry(self):
        now_ep = time.time()
        four_days_ago = datetime.datetime.fromtimestamp(now_ep - 4 * 86400, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        two_days_ago = datetime.datetime.fromtimestamp(now_ep - 2 * 86400, datetime.timezone.utc).isoformat().replace("+00:00", "Z")

        # 1. Unfinished task idle for 4 days (> 24h) must NEVER auto-archive
        tid_unfin = "tsk_unfinished_4d001"
        with open(os.path.join(self.tasks_root, f"{tid_unfin}.json"), "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "schema_version": 1,
                    "id": tid_unfin,
                    "title": "未完工闲置4天任务",
                    "status": "in_progress",
                    "steps": [{"id": "1", "title": "进行中", "status": "in_progress", "updated_at": four_days_ago}],
                    "created_at": four_days_ago,
                    "updated_at": four_days_ago,
                },
                fh,
                ensure_ascii=False,
                indent=2,
            )

        # 2. Completed task finished 2 days ago (under default '3d' threshold) -> stays in main sessions list
        tid_comp = "tsk_completed_auto02"
        conv_comp = "82222222-2222-4222-8222-222222222222"
        with open(os.path.join(self.tasks_root, f"{tid_comp}.json"), "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "schema_version": 1,
                    "id": tid_comp,
                    "title": "已完工2天任务",
                    "status": "completed",
                    "completed_at": two_days_ago,
                    "steps": [{"id": "1", "title": "已完成", "status": "completed", "updated_at": two_days_ago}],
                    "created_at": four_days_ago,
                    "updated_at": two_days_ago,
                },
                fh,
                ensure_ascii=False,
                indent=2,
            )
        self._post_json(
            "/studio/action",
            {
                "action": "bind_session",
                "session_key": tid_comp,
                "provider": "chatgpt",
                "carrier": "Chrome:Default",
                "conv_uuid": conv_comp,
            },
        )

        snap_3d = self._get_json("/studio/snapshot")
        active_keys_3d = [s["SessionKey"] for s in snap_3d["sessions"]]
        arch_keys_3d = [s["SessionKey"] for s in snap_3d["archived_sessions"]]
        self.assertIn(tid_unfin, active_keys_3d, "Unfinished task idle for 4 days must remain active")
        self.assertIn(tid_comp, active_keys_3d, "Completed task at 2d must remain visible when mode is default 3d")
        self.assertEqual(arch_keys_3d, [])

        # Verify Ledger ① (data/task-registry.json) was created & synced with triple contract
        reg_doc = shield.load_task_registry(self.data_root)
        self.assertIn(tid_comp, reg_doc["tasks"])
        self.assertEqual(reg_doc["tasks"][tid_comp]["lifecycle"], "completed")
        self.assertEqual(reg_doc["tasks"][tid_comp]["active_binding"]["provider"], "chatgpt")
        self.assertEqual(reg_doc["tasks"][tid_comp]["active_binding"]["carrier"], "Chrome:Default")
        self.assertEqual(reg_doc["tasks"][tid_comp]["active_binding"]["conv_uuid"], conv_comp)

        # 3. Switch auto_archive_completed_mode to '1d' -> tid_comp (2 days old) auto-archives and enqueues cloud archive!
        self._post_json("/studio/action", {"action": "set_global_settings", "auto_archive_completed_mode": "1d"})
        snap_1d = self._get_json("/studio/snapshot")
        self.assertIn(tid_unfin, [s["SessionKey"] for s in snap_1d["sessions"]])
        self.assertIn(tid_comp, [s["SessionKey"] for s in snap_1d["archived_sessions"]])
        wb_1d = self._get_json("/web-bridge/state")
        self.assertTrue(
            any(r["conv_uuid"] == conv_comp and r["operation"] == "archive" and r["status"] == "pending" for r in wb_1d["retire_actions"])
        )

        # 4. Restore tid_comp ('↺ 还原') -> refreshes restored_at so it stays visible on main board until another 1d passes
        self._post_json("/studio/action", {"action": "restore", "session_key": tid_comp})
        snap_restored = self._get_json("/studio/snapshot")
        self.assertIn(tid_comp, [s["SessionKey"] for s in snap_restored["sessions"]])
        self.assertNotIn(tid_comp, [s["SessionKey"] for s in snap_restored["archived_sessions"]])


if __name__ == "__main__":
    unittest.main()
