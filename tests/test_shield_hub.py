import json
import os
import pathlib
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import sys
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
import McpReadOnlyShield as shield


class MockUpstreamHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        if self.path == "/healthz":
            body = json.dumps({"ok": True}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b""
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
                            "name": "task_manage",
                            "description": "Manage task lifecycle",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "action": {
                                        "type": "string",
                                        "enum": ["create", "list", "get", "checkpoint", "block", "resume", "final_review", "complete"],
                                    },
                                    "task_id": {"type": "string"},
                                    "summary": {"type": "string"},
                                },
                                "required": ["action"],
                            },
                        },
                        {
                            "name": "exec_command",
                            "description": "Execute command",
                            "inputSchema": {"type": "object", "properties": {"cmd": {"type": "string"}}},
                        },
                    ]
                },
            }
        elif method == "tools/call" and tool_name in ("relay_context", "relaycore_context", "agentdock_context"):
            resp_obj = {
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": {
                    "content": [{"type": "text", "text": "Workspace context loaded: project_alpha"}],
                    "structuredContent": {"workspace": "project_alpha"},
                },
            }
        elif method == "tools/call" and (tool_name == "task_create" or (tool_name == "task_manage" and args.get("action") == "create")):
            self.server.task_create_count += 1
            new_id = f"tsk_upstream_{self.server.task_create_count}"
            resp_obj = {
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": {
                    "content": [{"type": "text", "text": json.dumps({"task_id": new_id, "title": args.get("title", "")})}],
                    "structuredContent": {"task_id": new_id, "title": args.get("title", "")},
                },
            }
        else:
            resp_obj = {
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": {
                    "content": [{"type": "text", "text": "ok"}],
                },
            }

        body = json.dumps(resp_obj, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ShieldHubSeamTests(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.TemporaryDirectory()
        self.root = self.tmp_dir.name
        self.data_root = os.path.join(self.root, "data")
        self.logs_dir = os.path.join(self.data_root, "logs")
        self.tasks_root = os.path.join(self.root, "engine-data", "tasks")
        os.makedirs(self.logs_dir, exist_ok=True)
        os.makedirs(self.tasks_root, exist_ok=True)

        self.activity_path = os.path.join(self.logs_dir, "shield-activity.json")
        self.tunnel_log_path = os.path.join(self.logs_dir, "tunnel.out.log")
        self.wb_state_path = os.path.join(self.logs_dir, "web-bridge-state.json")
        self.archives_path = os.path.join(self.data_root, "task-archives.json")

        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), MockUpstreamHandler)
        self.upstream.calls = []
        self.upstream.task_create_count = 0
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
        if hasattr(self.shield_srv, "shutdown"):
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

    def test_multi_platform_routing_claim_and_receipt(self):
        for origin in ["https://chatgpt.com", "https://gemini.google.com", "https://claude.ai"]:
            req = urllib.request.Request(f"http://127.0.0.1:{self.shield_port}/web-bridge/state", headers={"Origin": origin})
            with urllib.request.urlopen(req) as response:
                self.assertEqual(response.headers.get("Access-Control-Allow-Origin"), origin)
        req = urllib.request.Request(f"http://127.0.0.1:{self.shield_port}/web-bridge/state", headers={"Origin": "https://claude.ai.evil.invalid"})
        with urllib.request.urlopen(req) as response:
            self.assertNotEqual(response.headers.get("Access-Control-Allow-Origin"), "https://claude.ai.evil.invalid")
        for provider, root, room_path, room in [
            ("gemini", "https://gemini.google.com/app", "/", "abc123def456"),
            ("claude", "https://claude.ai/new", "https://claude.ai/chat/", "aaaaaaaa-1111-4111-8111-111111111111"),
        ]:
            task = "tsk_platform_" + provider
            self._post_json("/studio/action", {"action": "bind_session", "session_key": task, "provider": provider})
            enq = self._post_json("/web-bridge/enqueue", {"session_key": task, "mode": "new_window_handover", "text": "continue", "no_launch": True})
            mid = enq["message"]["id"]
            self.assertTrue(enq["handover_url"].startswith(root), enq)
            wrong = self._post_json("/web-bridge/poll", {"tab_id": "wrong", "provider": "chatgpt", "url": "https://chatgpt.com/?msg_id=" + mid, "handover_msg_id": mid})
            self.assertFalse(wrong.get("messages"))
            url = root + "/" + room if provider == "gemini" else room_path + room
            claim = self._post_json("/web-bridge/poll", {"tab_id": provider, "provider": provider, "url": url, "conv_uuid": room, "handover_msg_id": mid})
            self.assertEqual(len(claim["messages"]), 1)
            before_ack = self._get_json("/web-bridge/state")
            self.assertFalse(before_ack["session_bindings"][task].get("conv_uuid"), "Claim is not room ownership")
            denied = self._post_json("/web-bridge/ack-deliver", {"msg_id": mid, "tab_id": provider, "provider": "chatgpt", "conv_uuid": room})
            self.assertFalse(denied["ok"])
            ack = self._post_json("/web-bridge/ack-deliver", {"msg_id": mid, "tab_id": provider, "provider": provider, "conv_uuid": room})
            self.assertTrue(ack["ok"])
            opened = self._post_json("/studio/action", {"action": "open_tab", "session_key": task, "no_launch": True})
            self.assertTrue(opened["url"].startswith(url), opened)

    def _write_task(self, task_id: str, title: str, status: str = "active", updated_at: str = None, steps=None):
        now_iso = updated_at or shield._utc_now_iso()
        doc = {
            "schema_version": 1,
            "id": task_id,
            "title": title,
            "goal": f"推进 {title}",
            "status": status,
            "created_at": now_iso,
            "updated_at": now_iso,
            "steps": steps or [
                {"id": "1", "title": "步骤一", "status": "completed", "updated_at": now_iso},
                {"id": "2", "title": "步骤二", "status": "in_progress", "updated_at": now_iso},
            ],
            "summary": "正在执行步骤二",
        }
        with open(os.path.join(self.tasks_root, f"{task_id}.json"), "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False)

    def test_t1_anti_duplicate_task_and_context_injection(self):
        self._write_task("tsk_19283093310b828b", "ProjectAlpha C4 三层重构：工单 06–21")

        # 1. relay_context injects active unfinished task reminder
        ctx_resp = self._post_json("/mcp", {
            "jsonrpc": "2.0",
            "id": "ctx-1",
            "method": "tools/call",
            "params": {"name": "relay_context", "arguments": {"path": "D:\\project_alpha"}},
        })
        txt = ctx_resp["result"]["content"][0]["text"]
        self.assertIn("tsk_19283093310b828b", txt)
        self.assertIn("防重单", txt)

        # 2. Duplicate task_manage(action="create") is intercepted without hitting upstream
        dup_resp = self._post_json("/mcp", {
            "jsonrpc": "2.0",
            "id": "create-dup",
            "method": "tools/call",
            "params": {
                "name": "task_manage",
                "arguments": {
                    "action": "create",
                    "title": "ProjectAlpha C4 三层重构（新窗口续跑）",
                    "goal": "继续完成 tsk_19283093310b828b 工单 06-21",
                },
            },
        })
        dup_txt = dup_resp["result"]["content"][0]["text"]
        self.assertIn("tsk_19283093310b828b", dup_txt)
        self.assertIn("防重单已自动并轨", dup_txt)
        self.assertEqual(self.upstream.task_create_count, 0)

        # 3. Explicit force_new=True allows creating a brand new native task on :8766 (Spec v4.6 Decision 2)
        force_resp = self._post_json("/mcp", {
            "jsonrpc": "2.0",
            "id": "create-force",
            "method": "tools/call",
            "params": {
                "name": "task_manage",
                "arguments": {
                    "action": "create",
                    "title": "全新独立项目",
                    "force_new": True,
                },
            },
        })
        self.assertEqual(self.upstream.task_create_count, 0)
        new_tid = force_resp["result"]["structuredContent"]["task_id"]
        self.assertTrue(new_tid.startswith("tsk_") and new_tid != "tsk_19283093310b828b")
        self.assertTrue(os.path.isfile(os.path.join(self.tasks_root, f"{new_tid}.json")))

    def test_t2_incremental_log_tail_rolling_and_same_workspace_isolation(self):
        # Write 2,600 lines to trigger rolling truncation (<= 2,000 lines) + probe filtering
        now_iso = shield._utc_now_iso()
        lines = []
        for i in range(2550):
            lines.append(json.dumps({
                "time": now_iso,
                "level": "INFO",
                "msg": "dispatcher forwarded command to MCP server",
                "cmd_request_id": "wfr_01a1735d3994733c87ad836e7898a160",
                "rpc_request_id": f"rpc-{i}",
            }))
        # Add 1-shot discovery ping with unquoted rpc_request_id:0 and openai-mcp-discover
        lines.append('{"time":"' + now_iso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"deadbeef-0000-4000-8000-000000000001/ping","rpc_request_id":0}')
        lines.append('{"time":"' + now_iso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"wfr_discover","rpc_request_id":"openai-mcp-discover"}')
        with open(self.tunnel_log_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")

        self._write_task("tsk_19283093310b828b", "ProjectAlpha C4 三层重构")
        # Bind tsk_19283093310b828b to conv_old
        self._post_json("/studio/action", {
            "action": "bind_session",
            "session_key": "tsk_19283093310b828b",
            "conv_uuid": "11111111-1111-4111-8111-111111111111",
            "browser_profile": "Chrome:Profile 1",
        })

        snap1 = self._get_json("/studio/snapshot")
        # Verify rolling kept <= 2000 lines on disk
        with open(self.tunnel_log_path, "r", encoding="utf-8") as fh:
            disk_lines = fh.read().splitlines()
        self.assertLessEqual(len(disk_lines), 2005)
        # Verify discovery pings did not create ghost cards
        session_keys = [s["SessionKey"] for s in snap1["sessions"]]
        self.assertNotIn("deadbeef-0000-4000-8000-000000000001", session_keys)
        self.assertNotIn("wfr_discover", session_keys)

        # Now append a new un-tasked conversation in the SAME workspace (project_alpha) from a different web chat
        self._post_json("/mcp", {
            "jsonrpc": "2.0",
            "id": "rpc-new-chat-1",
            "method": "tools/call",
            "params": {"name": "fs_read", "arguments": {"path": "D:\\project_alpha\\README.md"}},
        })
        with open(self.tunnel_log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "time": shield._utc_now_iso(),
                "level": "INFO",
                "msg": "dispatcher forwarded command to MCP server",
                "cmd_request_id": "22222222-2222-4222-8222-222222222222/abcd",
                "rpc_request_id": "rpc-new-chat-1",
            }) + "\n")
            fh.write(json.dumps({
                "time": shield._utc_now_iso(),
                "level": "INFO",
                "msg": "dispatcher forwarded command to MCP server",
                "cmd_request_id": "22222222-2222-4222-8222-222222222222/efgh",
                "rpc_request_id": "rpc-new-chat-1",
            }) + "\n")

        snap2 = self._get_json("/studio/snapshot")
        keys2 = [s["SessionKey"] for s in snap2["sessions"]]
        self.assertIn("tsk_19283093310b828b", keys2)
        self.assertNotIn("22222222-2222-4222-8222-222222222222", keys2, "Spec v3 M1: Un-tasked tool streams in the same workspace must aggregate into active tsk_xxx and never spawn wild cards")
        c4_after = next(s for s in snap2["sessions"] if s["SessionKey"] == "tsk_19283093310b828b")
        self.assertGreaterEqual(c4_after["CommandCount"], 2, "Same-workspace slash_stream calls must aggregate into tsk_19283093310b828b")

    def test_t3_t4_ownership_transfer_and_retired_anti_ping_pong_lock(self):
        self._write_task("tsk_19283093310b828b", "ProjectAlpha C4 三层重构")
        conv_a = "aaaaaaaa-1111-4111-8111-111111111111"
        conv_b = "bbbbbbbb-2222-4222-8222-222222222222"
        conv_c = "cccccccc-3333-4333-8333-333333333333"
        project_prefix = "https://chatgpt.com/g/g-p-69be4f3b62d881919c8fb3cd3eb0fb36"

        # Initial binding to conv_a inside project folder
        self._post_json("/web-bridge/poll", {
            "tab_id": "tab_a",
            "conv_uuid": conv_a,
            "project_prefix": project_prefix,
            "url": f"{project_prefix}/c/{conv_a}",
            "title": "ProjectAlpha C4 旧窗口",
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "page_hints": ["tsk_19283093310b828b"],
            "is_generating": False,
        })

        # Queue a handover message for tsk_19283093310b828b
        enq = self._post_json("/web-bridge/enqueue", {
            "session_key": "tsk_19283093310b828b",
            "title": "ProjectAlpha C4 三层重构",
            "mode": "new_window_handover",
            "text": "请继续推进 tsk_19283093310b828b",
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
        })
        msg_id = enq["message"]["id"]

        # Channel 1: New tab conv_b polls with handover_msg_id -> ownership transfers to conv_b, conv_a is retired
        poll_b = self._post_json("/web-bridge/poll", {
            "tab_id": "tab_b",
            "conv_uuid": conv_b,
            "project_prefix": project_prefix,
            "url": f"{project_prefix}/c/{conv_b}?relay_handover=1&msg_id={msg_id}",
            "title": "ProjectAlpha C4 新窗口",
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "handover_msg_id": msg_id,
            "page_hints": ["tsk_19283093310b828b"],
            "is_generating": True,
        })
        self.assertEqual(len(poll_b["messages"]), 1)

        # Anti-Ping-Pong check: unclosed old tab conv_a polls with page_hints=["tsk_19283093310b828b"] and is_generating=False
        self._post_json("/web-bridge/poll", {
            "tab_id": "tab_a",
            "conv_uuid": conv_a,
            "project_prefix": project_prefix,
            "url": f"{project_prefix}/c/{conv_a}",
            "title": "ProjectAlpha C4 旧窗口",
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "page_hints": ["tsk_19283093310b828b"],
            "is_generating": False,
        })
        wb_state = self._get_json("/web-bridge/state")
        binding = wb_state["session_bindings"]["tsk_19283093310b828b"]
        self.assertEqual(binding["conv_uuid"], conv_b)
        self.assertIn(conv_a, binding["retired_uuids"])
        self.assertEqual(binding["project_prefix"], project_prefix)

        # Channel 2: Manual new tab conv_c actively generating while conv_b is idle -> transfers to conv_c and retires conv_b
        self._post_json("/web-bridge/poll", {
            "tab_id": "tab_b",
            "conv_uuid": conv_b,
            "project_prefix": project_prefix,
            "url": f"{project_prefix}/c/{conv_b}",
            "title": "ProjectAlpha C4 窗口B",
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "page_hints": ["tsk_19283093310b828b"],
            "is_generating": False,
        })
        self._post_json("/web-bridge/poll", {
            "tab_id": "tab_c",
            "conv_uuid": conv_c,
            "project_prefix": project_prefix,
            "url": f"{project_prefix}/c/{conv_c}",
            "title": "ProjectAlpha C4 手动新开窗口C",
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "page_hints": ["tsk_19283093310b828b"],
            "is_generating": True,
        })
        wb_state2 = self._get_json("/web-bridge/state")
        binding2 = wb_state2["session_bindings"]["tsk_19283093310b828b"]
        self.assertEqual(binding2["conv_uuid"], conv_c)
        self.assertIn(conv_b, binding2["retired_uuids"])

        # Channel 3: UI switches target browser to Edge:Profile 1 -> retires conv_c, clears conv_uuid, locks Edge:Profile 1
        self._post_json("/studio/action", {
            "action": "bind_browser",
            "session_key": "tsk_19283093310b828b",
            "browser_profile": "Edge:Profile 1",
        })
        wb_state3 = self._get_json("/web-bridge/state")
        binding3 = wb_state3["session_bindings"]["tsk_19283093310b828b"]
        self.assertEqual(binding3["conv_uuid"], "")
        self.assertEqual(binding3["browser_profile"], "Edge:Profile 1")
        self.assertIn(conv_c, binding3["retired_uuids"])

    def test_t5_two_stage_archive_auto_revive_and_physical_purge(self):
        from datetime import datetime, timezone
        t0 = datetime.fromtimestamp(time.time() - 600, tz=timezone.utc).isoformat().replace("+00:00", "Z")
        self._write_task("tsk_arch_revive", "测试归档复活与物理粉碎", updated_at=t0)
        with open(self.tunnel_log_path, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "time": t0,
                "level": "INFO",
                "msg": "dispatcher forwarded command to MCP server",
                "cmd_request_id": "wfr_arch_revive",
                "rpc_request_id": "rpc-arch-1",
            }) + "\n")

        # Stage 1: Archive session
        self._post_json("/studio/action", {
            "action": "archive",
            "session_key": "tsk_arch_revive",
        })
        snap_arch = self._get_json("/studio/snapshot")
        self.assertEqual([s["SessionKey"] for s in snap_arch["sessions"]], [])
        self.assertIn("tsk_arch_revive", [s["SessionKey"] for s in snap_arch["archived_sessions"]])

        # Simulate new activity arriving AFTER archived_at -> Spec Decision 3.1: archived tasks stay archived until explicit restore!
        time.sleep(0.05)
        now_iso = shield._utc_now_iso()
        self._write_task("tsk_arch_revive", "测试归档复活与物理粉碎", updated_at=now_iso)
        with open(self.tunnel_log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "time": now_iso,
                "level": "INFO",
                "msg": "dispatcher forwarded command to MCP server",
                "cmd_request_id": "wfr_arch_revive",
                "rpc_request_id": "rpc-arch-2",
            }) + "\n")

        snap_still_archived = self._get_json("/studio/snapshot")
        self.assertIn("tsk_arch_revive", [s["SessionKey"] for s in snap_still_archived["archived_sessions"]])

        # Explicit restore ('↺ 还原') revives to active rail
        self._post_json("/studio/action", {
            "action": "restore",
            "session_key": "tsk_arch_revive",
        })
        snap_revived = self._get_json("/studio/snapshot")
        self.assertIn("tsk_arch_revive", [s["SessionKey"] for s in snap_revived["sessions"]])

        # Archive again and Stage 2: Physical Purge
        self._post_json("/studio/action", {
            "action": "archive",
            "session_key": "tsk_arch_revive",
        })
        self._post_json("/studio/action", {
            "action": "purge",
            "session_key": "tsk_arch_revive",
        })
        self.assertFalse(os.path.exists(os.path.join(self.tasks_root, "tsk_arch_revive.json")))
        snap_purged = self._get_json("/studio/snapshot")
        self.assertNotIn("tsk_arch_revive", [s["SessionKey"] for s in snap_purged["sessions"]])
        self.assertNotIn("tsk_arch_revive", [s["SessionKey"] for s in snap_purged["archived_sessions"]])

    def test_t6_t7_guardian_escalation_single_flight_and_batch_shuttle(self):
        from datetime import datetime, timezone
        stall_iso = datetime.fromtimestamp(time.time() - 600, tz=timezone.utc).isoformat().replace("+00:00", "Z")
        self._write_task("tsk_guard_1", "守护升级与单飞锁测试", updated_at=stall_iso)
        with open(self.tunnel_log_path, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "time": stall_iso,
                "level": "INFO",
                "msg": "dispatcher forwarded command to MCP server",
                "cmd_request_id": "wfr_guard_1",
                "rpc_request_id": "rpc-guard-1",
            }) + "\n")

        conv_g = "gggggggg-1111-4111-8111-111111111111"
        proj_prefix = "https://chatgpt.com/g/g-p-69be4f3b62d881919c8fb3cd3eb0fb36"
        # Batch shuttle poll from Chrome with bound tab + blank new chat tab
        batch_res1 = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [
                {
                    "tab_id": "101",
                    "conv_uuid": conv_g,
                    "project_prefix": proj_prefix,
                    "url": f"{proj_prefix}/c/{conv_g}",
                    "title": "守护升级测试窗口",
                    "page_hints": ["tsk_guard_1"],
                    "is_generating": False,
                    "has_error": False,
                },
                {
                    "tab_id": "102",
                    "conv_uuid": "",
                    "project_prefix": "",
                    "url": "https://chatgpt.com/",
                    "title": "ChatGPT",
                    "page_hints": [],
                    "is_generating": False,
                    "has_error": False,
                },
            ],
        })
        self.assertIn("dispatches", batch_res1)

        # Trigger guardian tick while stalled -> queues in_place_wakeup (NOT new_window_handover)
        shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        wb = self._get_json("/web-bridge/state")
        q_list = wb.get("queue") if "queue" in wb else wb.get("outbox", [])
        pending = [m for m in q_list if m["status"] in ("pending", "claimed")]
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["mode"], "in_place_wakeup")
        self.assertEqual(pending[0]["conv_uuid"], conv_g)

        # Verify blank tab 102 NEVER hijacks in_place_wakeup even after 10 seconds
        pending[0]["created_at"] = "2026-10-28T01:00:00Z"
        with open(self.wb_state_path, "w", encoding="utf-8") as fh:
            json.dump(wb, fh, ensure_ascii=False)

        blank_poll = self._post_json("/web-bridge/poll", {
            "tab_id": "102",
            "conv_uuid": "",
            "url": "https://chatgpt.com/",
            "title": "ChatGPT",
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "page_hints": [],
            "is_generating": False,
        })
        self.assertEqual(len(blank_poll["messages"]), 0)

        # Spec v4.7 Option A: when has_error=True with usable composer, pending in_place_wakeup is preserved;
        # when the page becomes unusable (has_load_error=True / has_composer=False), guardian upgrades to new_window_handover ONCE (Single-Flight lock)
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [
                {
                    "tab_id": "101",
                    "conv_uuid": conv_g,
                    "project_prefix": proj_prefix,
                    "url": f"{proj_prefix}/c/{conv_g}",
                    "title": "守护升级测试窗口",
                    "page_hints": ["tsk_guard_1"],
                    "is_generating": False,
                    "has_error": True,
                    "has_load_error": True,
                }
            ],
        })
        shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)

        batch_res2 = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [
                {
                    "tab_id": "101",
                    "conv_uuid": conv_g,
                    "project_prefix": proj_prefix,
                    "url": f"{proj_prefix}/c/{conv_g}",
                    "title": "守护升级测试窗口",
                    "page_hints": ["tsk_guard_1"],
                    "is_generating": False,
                    "has_error": True,
                    "has_load_error": True,
                }
            ],
        })
        handover_dispatches = [d for d in batch_res2.get("dispatches", []) if d.get("open_new_tab")]
        self.assertEqual(len(handover_dispatches), 1)
        self.assertTrue(handover_dispatches[0]["handover_url"].startswith(f"{proj_prefix}/?relay_handover=1&msg_id="))

    def test_t8_to_t12_remediation_and_anti_fake_seam_gates(self):
        # T8: Pure 36-char UUID cmd_request_id + C4 task updated 81s ago + Milestone cleaning (T9) + 43-field UI Contract (T12)
        now_epoch = time.time()
        iso_81s_ago = shield._epoch_to_iso(now_epoch - 81) if hasattr(shield, "_epoch_to_iso") else "2026-10-28T19:21:13Z"
        from datetime import datetime, timezone
        iso_81s_ago = datetime.fromtimestamp(now_epoch - 81, tz=timezone.utc).isoformat().replace("+00:00", "Z")
        iso_10s_ago = datetime.fromtimestamp(now_epoch - 10, tz=timezone.utc).isoformat().replace("+00:00", "Z")
        iso_200s_ago = datetime.fromtimestamp(now_epoch - 200, tz=timezone.utc).isoformat().replace("+00:00", "Z")

        c4_task = {
            "id": "tsk_19283093310b828b",
            "title": "C4：实现第一版界面与端到端闭环（D:\\project_alpha）",
            "goal": "在 D:\\project_alpha 落地 C4 端到端闭环",
            "status": "active",
            "created_at": iso_200s_ago,
            "updated_at": iso_81s_ago,
            "steps": [
                {"id": "20", "title": "修复预览刷新", "status": "completed"},
                {"id": "21", "title": "完整后端与前端验收", "status": "in_progress"},
            ],
            "checkpoints": [
                {
                    "type": "checkpoint",
                    "summary": "matt_read=in_progress: 已定位35项Matt来源技能，正在核对区别 || files=35",
                    "created_at": iso_200s_ago,
                },
                {
                    "type": "checkpoint",
                    "summary": "completed=[matt_read,research], current=revise: 完整阅读与上游核对已完成 || detail=1",
                    "created_at": iso_200s_ago,
                },
                {
                    "type": "checkpoint",
                    "summary": "pass: 完整阅读、来源核验和修订交付三项条件均满足 || gate=pass",
                    "created_at": iso_200s_ago,
                },
                {
                    "type": "checkpoint",
                    "summary": "21=in_progress: 同一版本的完整后端验收已全部通过，现按顺序检查全部前端测试。 || SHA5e6e40b8522e78d",
                    "created_at": iso_81s_ago,
                },
            ],
            "summary": "21=in_progress: 同一版本的完整后端验收已全部通过，现按顺序检查全部前端测试。 || SHA5e6e40b8522e78d",
        }
        with open(os.path.join(self.tasks_root, "tsk_19283093310b828b.json"), "w", encoding="utf-8") as fh:
            json.dump(c4_task, fh, ensure_ascii=False)

        # Write pure 36-char UUID cmd_request_id lines in tunnel.out.log
        conv_stream_uuid = "59eff340-e988-441a-a46d-7256b602cb08"
        rpc_1 = "8b16cf69-dec0-4543-8cd2-57b3060b07f8"
        rpc_2 = "2585a1eb-1111-4222-8333-57b3060b07f9"
        rpc_3 = "eda0428f-2222-4333-8444-57b3060b07fa"
        log_lines = [
            json.dumps({"time": iso_81s_ago, "level": "INFO", "msg": "dispatcher forwarded command to MCP server", "cmd_request_id": conv_stream_uuid, "rpc_request_id": rpc_1}),
            json.dumps({"time": iso_10s_ago, "level": "INFO", "msg": "dispatcher forwarded command to MCP server", "cmd_request_id": conv_stream_uuid, "rpc_request_id": rpc_2}),
            json.dumps({"time": iso_10s_ago, "level": "INFO", "msg": "dispatcher forwarded command to MCP server", "cmd_request_id": conv_stream_uuid, "rpc_request_id": rpc_3}),
        ]
        with open(self.tunnel_log_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(log_lines) + "\n")

        act_payload = {
            "schema_version": 1,
            "calls": {
                rpc_1: {
                    "method": "tools/call",
                    "rpc_id": rpc_1,
                    "tool": "task_manage",
                    "action": "记录任务检查点 (tsk_19283093310b828b)",
                    "task_id": "tsk_19283093310b828b",
                    "workspace_hint": "project_alpha",
                    "time": iso_81s_ago,
                    "started_at": iso_81s_ago,
                    "completed_at": iso_81s_ago,
                    "in_flight": False,
                },
                rpc_2: {
                    "method": "tools/call",
                    "rpc_id": rpc_2,
                    "tool": "read_file",
                    "action": "读取文件 (student_intake.js)",
                    "task_id": "",
                    "workspace_hint": "project_alpha",
                    "time": iso_10s_ago,
                    "started_at": iso_10s_ago,
                    "completed_at": iso_10s_ago,
                    "in_flight": False,
                },
                rpc_3: {
                    "method": "tools/call",
                    "rpc_id": rpc_3,
                    "tool": "exec_command",
                    "action": "运行命令 (npm test)",
                    "task_id": "",
                    "workspace_hint": "project_alpha",
                    "time": iso_10s_ago,
                    "started_at": iso_10s_ago,
                    "completed_at": "",
                    "in_flight": True,
                },
            },
            "zero_rpc_events": [],
            "in_flight_count": 1,
        }
        with open(self.activity_path, "w", encoding="utf-8") as fh:
            json.dump(act_payload, fh, ensure_ascii=False)

        snap = self._get_json("/studio/snapshot")
        c4_sess = next((s for s in snap["sessions"] if s["SessionKey"] == "tsk_19283093310b828b"), None)
        self.assertIsNotNone(c4_sess, "tsk_19283093310b828b must be present in active sessions")
        self.assertGreaterEqual(c4_sess["CommandCount"], 3, "Pure UUID cmd_request_id calls must be attributed to the task")
        self.assertFalse(c4_sess["IsStalled"], "Task updated 81s ago with active tool calls must NEVER be marked IsStalled")
        self.assertNotIn("已停顿", c4_sess["StatusBadge"])

        # T9: Verify milestone cleaning and newest-first ordering
        milestones = c4_sess.get("Milestones") or []
        self.assertGreaterEqual(len(milestones), 4)
        # Newest checkpoint must be index 0
        self.assertIn("同一版本的完整后端验收已全部通过", milestones[0]["Title"] + milestones[0]["Prose"])
        for ms in milestones:
            for forbidden in ("=in_progress", "=completed", "completed=[", "pass:", "||"):
                self.assertNotIn(forbidden, ms["Title"], f"Leaked prefix {forbidden} in Title: {ms['Title']}")
                self.assertNotIn(forbidden, ms["Prose"], f"Leaked prefix {forbidden} in Prose: {ms['Prose']}")
        self.assertNotIn("21=in_progress", c4_sess["LatestSummary"])
        self.assertNotIn("||", c4_sess["LatestSummary"])

        # T12: Verify full 43-property StrictMode UI contract on session object
        required_ui_props = [
            "SessionKey", "WfrId", "ShortId", "Title", "ShortTitle", "RawTitle",
            "HasCustomAlias", "WorkspaceName", "IsUnregisteredSession", "Goal",
            "CleanGoalSubtitle", "CurrentStep", "ActionText", "RailSubtitle",
            "LatestSummary", "Steps", "CompletedStepCount", "TotalStepCount",
            "ProgressPercent", "StepCountText", "Milestones", "ReadableCheckpoints",
            "Checkpoints", "RecentCommits", "SentWebMessages", "BreakerStage",
            "BreakerRetryCount", "BreakerMaxRetries", "BreakerMessage",
            "AutoWakeupEnabled", "TimeText", "AgoText", "ElapsedSeconds",
            "StatusBadge", "StatusFg", "StatusBg", "StatusBorder", "CardBg",
            "CardBorder", "DotColor", "IsStalled", "IsActive", "IsArchived",
            "ArchiveReason", "ArchivedAtText", "CommandCount", "SubagentCount",
        ]
        for prop in required_ui_props:
            self.assertIn(prop, c4_sess, f"Missing StrictMode UI property: {prop}")
            self.assertIsNotNone(c4_sess[prop], f"StrictMode property {prop} must not be None")

        # T10: Verify auto_resend_config OFF stops guardian, and enqueue_message via /studio/action works end-to-end
        # Make c4_task appear stalled (updated 400s ago, no in-flight)
        c4_task["updated_at"] = iso_200s_ago
        c4_task["checkpoints"][-1]["created_at"] = iso_200s_ago
        with open(os.path.join(self.tasks_root, "tsk_19283093310b828b.json"), "w", encoding="utf-8") as fh:
            json.dump(c4_task, fh, ensure_ascii=False)
        os.remove(self.tunnel_log_path)
        os.remove(self.activity_path)

        # Turn OFF global auto_resend_config via /studio/action
        self._post_json("/studio/action", {
            "action": "update_resend_config",
            "enabled": False,
            "stall_minutes": 1,
            "max_retries": 2,
        })
        shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        wb_after_off = self._get_json("/web-bridge/state")
        self.assertIn("queue", wb_after_off)
        self.assertIn("breakers", wb_after_off)
        self.assertEqual(len([m for m in wb_after_off["queue"] if m["session_key"] == "tsk_19283093310b828b"]), 0,
                         "Guardian must NOT fire when auto_resend_config.enabled is False")

        # Turn ON global auto_resend_config, but turn OFF per-session auto_wakeup for tsk_19283093310b828b
        self._post_json("/studio/action", {
            "action": "update_resend_config",
            "enabled": True,
            "stall_minutes": 1,
            "max_retries": 2,
        })
        self._post_json("/studio/action", {
            "action": "set_auto_wakeup",
            "session_key": "tsk_19283093310b828b",
            "enabled": False,
        })
        shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        wb_after_sess_off = self._get_json("/web-bridge/state")
        self.assertEqual(len([m for m in wb_after_sess_off["queue"] if m["session_key"] == "tsk_19283093310b828b"]), 0,
                         "Guardian must NOT fire when per-session auto_enabled is False")

        # T11: Multi-tab is_generating OR-aggregation (zombie tab_xxx with False must NOT mask numeric tab with True)
        self._post_json("/studio/action", {
            "action": "set_auto_wakeup",
            "session_key": "tsk_19283093310b828b",
            "enabled": True,
        })
        conv_c4 = "6ae2351c-266c-83ee-acc4-609efe96235b"
        self._post_json("/studio/action", {
            "action": "bind_session",
            "session_key": "tsk_19283093310b828b",
            "conv_uuid": conv_c4,
            "browser_profile": "Chrome:Default",
        })
        # Report a zombie tab with is_generating=False first, and a real tab with is_generating=True second
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "tabs": [
                {
                    "tab_id": "tab_zombie_old",
                    "conv_uuid": conv_c4,
                    "url": f"https://chatgpt.com/c/{conv_c4}",
                    "title": "C4 窗口",
                    "page_hints": ["tsk_19283093310b828b"],
                    "is_generating": False,
                    "has_error": False,
                },
                {
                    "tab_id": "2012474090",
                    "conv_uuid": conv_c4,
                    "url": f"https://chatgpt.com/c/{conv_c4}",
                    "title": "C4 窗口",
                    "page_hints": ["tsk_19283093310b828b"],
                    "is_generating": True,
                    "has_error": False,
                },
            ],
        })
        shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        wb_gen = self._get_json("/web-bridge/state")
        self.assertEqual(len([m for m in wb_gen["queue"] if m["session_key"] == "tsk_19283093310b828b"]), 0,
                         "Guardian must see is_generating=True across tabs and NOT fire while generating")

        # Also test two-phase delivery (claimed -> ack-deliver) via enqueue_message
        enq_res = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_19283093310b828b",
            "mode": "new_window_handover",
            "prompt": "请继续推进 C4 验收",
        })
        self.assertTrue(enq_res.get("ok"))
        msg_id = enq_res["message"]["id"]

        # Poll 1: dispatch reserves the message; delivery is NOT confirmed until the browser ACK.
        poll_claim = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "tabs": [
                {
                    "tab_id": "999",
                    "conv_uuid": "",
                    "url": f"https://chatgpt.com/?relay_handover=1&msg_id={msg_id}",
                    "title": "ChatGPT",
                    "handover_msg_id": msg_id,
                    "page_hints": [],
                    "is_generating": False,
                }
            ],
        })
        dispatches_1 = [d for d in poll_claim.get("dispatches", []) if not d.get("open_new_tab")]
        self.assertEqual(len(dispatches_1), 1)
        self.assertEqual(dispatches_1[0]["message"]["id"], msg_id)

        wb_claimed = self._get_json("/web-bridge/state")
        m_obj = next(m for m in wb_claimed["queue"] if m["id"] == msg_id)
        self.assertEqual(m_obj["status"], "claimed", "A browser poll alone must never mark an unsent message delivered")

        # No duplicate dispatch before ACK; a timeout is uncertain, not an automatic retry.
        poll_again = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "tabs": [{"tab_id": "999", "conv_uuid": "", "url": f"https://chatgpt.com/?relay_handover=1&msg_id={msg_id}",
                      "handover_msg_id": msg_id, "page_hints": [], "is_generating": False}],
        })
        self.assertFalse(any(d.get("msg_id") == msg_id and not d.get("open_new_tab") for d in poll_again.get("dispatches", [])))

        # A forged or mismatched tab ACK must not turn a claimed send into delivered.
        wrong_tab_ack = self._post_json("/web-bridge/ack-deliver", {
            "msg_id": msg_id,
            "tab_id": "different-tab",
            "conv_uuid": "77777777-8888-4999-aaaa-bbbbbbbbbbbb",
        })
        self.assertFalse(wrong_tab_ack.get("ok"))
        self.assertEqual(next(m for m in self._get_json("/web-bridge/state")["queue"] if m["id"] == msg_id)["status"], "claimed")

        # An expired claim becomes unconfirmed, never silently delivered or retried.
        with shield._WEB_BRIDGE_LOCK:
            st = shield._load_web_bridge_state(self.wb_state_path)
            next(m for m in st["queue"] if m["id"] == msg_id)["claimed_at"] = "2020-01-01T00:00:00Z"
            shield._save_web_bridge_state(self.wb_state_path, st)
        timeout_poll = self._post_json("/web-bridge/poll", {
            "browser": "Chrome", "browser_profile": "Chrome:Default",
            "tabs": [{"tab_id": "999", "conv_uuid": "", "url": f"https://chatgpt.com/?relay_handover=1&msg_id={msg_id}",
                      "handover_msg_id": msg_id, "page_hints": [], "is_generating": False}],
        })
        self.assertFalse(any(d.get("msg_id") == msg_id and not d.get("open_new_tab") for d in timeout_poll.get("dispatches", [])))
        self.assertEqual(next(m for m in self._get_json("/web-bridge/state")["queue"] if m["id"] == msg_id)["status"], "unconfirmed")

        # A late explicit browser ACK may still confirm acceptance and update the binding.
        ack_res = self._post_json("/web-bridge/ack-deliver", {
            "msg_id": msg_id,
            "tab_id": "999",
            "conv_uuid": "77777777-8888-4999-aaaa-bbbbbbbbbbbb",
        })
        self.assertTrue(ack_res.get("ok"))
        wb_delivered = self._get_json("/web-bridge/state")
        m_obj2 = next(m for m in wb_delivered["queue"] if m["id"] == msg_id)
        self.assertEqual(m_obj2["status"], "delivered")

        # Anti-Fake-Seam Static Wiring & Exclusion Gate (Section 5.1)
        repo_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        shield_src = pathlib.Path(repo_dir, "McpReadOnlyShield.py").read_text(encoding="utf-8-sig")
        psm1_src = pathlib.Path(repo_dir, "ConnectionManager.psm1").read_text(encoding="utf-8-sig")
        bg_src = pathlib.Path(repo_dir, "browser-bridge", "background.js").read_text(encoding="utf-8-sig")
        cs_src = pathlib.Path(repo_dir, "browser-bridge", "bridge-content.js").read_text(encoding="utf-8-sig")

        self.assertNotIn("auto-resend.json", shield_src, "McpReadOnlyShield.py must not read phantom auto-resend.json")
        self.assertIn("/web-bridge/ack-deliver", shield_src)
        self.assertIn("/web-bridge/ack-deliver", bg_src)
        self.assertNotIn("Profile " + "19", bg_src, "background.js must not hardcode legacy profile")
        self.assertNotIn("Profile " + "19", cs_src, "bridge-content.js must not hardcode legacy profile")

        # Verify Get-TunnelActivityPulse does NOT call Step-SessionCircuitBreaker
        pulse_start = psm1_src.find("function Get-TunnelActivityPulse")
        pulse_end = psm1_src.find("function Get-ConnectionDisplayState", pulse_start)
        self.assertGreater(pulse_start, 0)
        self.assertGreater(pulse_end, pulse_start)
        pulse_body = psm1_src[pulse_start:pulse_end]
        self.assertNotIn("Step-SessionCircuitBreaker", pulse_body, "Get-TunnelActivityPulse must NEVER call Step-SessionCircuitBreaker")
        self.assertIn("Invoke-StudioHubSnapshot", psm1_src)
        self.assertIn("Invoke-StudioHubAction", psm1_src)
        self.assertNotIn("payload_mode", shield_src, "payload_mode must be completely removed from McpReadOnlyShield.py")
        self.assertNotIn("payload_mode", psm1_src, "payload_mode must be completely removed from ConnectionManager.psm1")

        # Automated Caller -> Callee Action Contract Gate: every action = '...' in ConnectionManager.psm1 must succeed against /studio/action
        import re as _re
        psm1_actions = sorted(set(_re.findall(r"action\s*=\s*'([a-z_]+)'", psm1_src)))
        self.assertGreaterEqual(len(psm1_actions), 8)
        for act_name in psm1_actions:
            act_payload_test = {
                "action": act_name,
                "session_key": "tsk_19283093310b828b",
                "task_id": "tsk_19283093310b828b",
                "state": "active",
                "title": "C4 别名测试",
                "enabled": True,
                "stall_minutes": 3,
                "max_retries": 2,
                "prompt": "测试消息",
                "mode": "custom_message",
                "no_launch": True,
                "physical_purge": False,
                "conv_uuid": conv_c4,
                "browser_profile": "Chrome:Default",
            }
            if act_name == "delete_session":
                self._write_task("tsk_temp_del", "临时删除测试")
                act_payload_test["session_key"] = "tsk_temp_del"
            resp_act = self._post_json("/studio/action", act_payload_test)
            self.assertTrue(resp_act.get("ok"), f"PowerShell action '{act_name}' failed in /studio/action: {resp_act}")

        # Verify R4 15s stale tab pruning in /web-bridge/poll and run_guardian_tick
        with shield._WEB_BRIDGE_LOCK:
            st_prune = shield._load_web_bridge_state(self.wb_state_path)
            st_prune["tabs"]["tab_stale_20s"] = {
                "tab_id": "tab_stale_20s",
                "conv_uuid": conv_c4,
                "is_generating": True,
                "last_seen_at": iso_200s_ago,
                "last_seen": iso_200s_ago,
            }
            shield._save_web_bridge_state(self.wb_state_path, st_prune)
        shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_state_path)
        wb_pruned = self._get_json("/web-bridge/state")
        self.assertNotIn("tab_stale_20s", wb_pruned.get("tabs", {}), "Stale tab >15s must be pruned by guardian tick")

        # Verify R6 cross-workspace task_create is NOT intercepted when workspace differs
        cross_ws_req = json.dumps({
            "jsonrpc": "2.0",
            "id": "rpc-cross-ws",
            "method": "tools/call",
            "params": {
                "name": "task_manage",
                "arguments": {
                    "action": "create",
                    "title": "D:\\OtherProject 独立新工单",
                    "goal": "在 D:\\OtherProject 执行独立开发",
                },
            },
        }).encode("utf-8")
        intercept_cross = shield.check_and_intercept_duplicate_task_create(cross_ws_req, self.tasks_root, self.data_root, self.activity_path)
        self.assertIsNone(intercept_cross, "Task create for a different workspace (OtherProject vs project_alpha) must NOT be intercepted")

    def test_t13_to_t17_spec_v3_task_only_per_task_config_and_cross_browser_handover(self):
        # 1. Spec v4.6 Decision 3: When 0 active tsk_xxx exist, relaycore_context stays clean (no coercive task_manage(action='create') prompt)
        ctx_zero = self._post_json("/mcp", {
            "jsonrpc": "2.0",
            "id": "ctx-zero",
            "method": "tools/call",
            "params": {"name": "relaycore_context", "arguments": {"path": "D:\\project_alpha"}},
        })
        zero_txt = ctx_zero["result"]["content"][0]["text"]
        self.assertNotIn("尚无进行中的 tsk_xxx", zero_txt)
        self.assertNotIn("task_manage(action='create')", zero_txt)

        exec1 = self._post_json("/mcp", {
            "jsonrpc": "2.0",
            "id": "exec-zero-1",
            "method": "tools/call",
            "params": {"name": "file_ops", "arguments": {"action": "read", "path": "D:\\project_alpha\\README.md"}},
        })
        self.assertNotIn("尚无进行中的 tsk_xxx", exec1["result"]["content"][0]["text"])
        exec2 = self._post_json("/mcp", {
            "jsonrpc": "2.0",
            "id": "exec-zero-2",
            "method": "tools/call",
            "params": {"name": "file_ops", "arguments": {"action": "read", "path": "D:\\project_alpha\\setup.py"}},
        })
        self.assertNotIn("尚无进行中的 tsk_xxx", exec2["result"]["content"][0]["text"],
                         "Spec v3.2 Cleanup 1: execution tool calls must NEVER append task reminder; only relaycore_context does")

        # Casual tool call with 0 tasks -> updates non_task_heartbeat, creates 0 session cards
        now_iso = shield._utc_now_iso()
        with open(self.tunnel_log_path, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "time": now_iso,
                "level": "INFO",
                "msg": "dispatcher forwarded command to MCP server",
                "cmd_request_id": "99999999-1111-4222-8333-444444444444/abcd",
                "rpc_request_id": "rpc-casual-1",
            }) + "\n")
            fh.write(json.dumps({
                "time": now_iso,
                "level": "INFO",
                "msg": "dispatcher forwarded command to MCP server",
                "cmd_request_id": "99999999-1111-4222-8333-444444444444/efgh",
                "rpc_request_id": "rpc-casual-2",
            }) + "\n")
        snap_zero = self._get_json("/studio/snapshot")
        self.assertEqual(snap_zero["sessions"], [], "0 formal tsk_xxx tasks on disk -> sessions list must be strictly empty")
        self.assertIn("non_task_heartbeat", snap_zero)
        self.assertGreaterEqual(snap_zero["non_task_heartbeat"]["count"], 2)

        # 2. M2: Per-task independent config & anti-poll-overwrite lock (fix Chrome:Default snap-back bug)
        self._write_task("tsk_task_a", "任务A：ProjectAlpha重装 (D:\\project_alpha)")
        self._write_task("tsk_task_b", "任务B：Obsidian数学讲义 (D:\\Obsidian)")

        res_cfg_a = self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_task_a",
            "target_mode": "follow_window",
            "browser_profile": "Chrome:Profile 1",
            "target_model": "ChatGPT Pro",
            "reasoning_effort": "extended",
            "auto_resend_enabled": True,
            "stall_minutes": 3,
            "max_retries": 1,
        })
        self.assertTrue(res_cfg_a.get("ok"))

        res_cfg_b = self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_task_b",
            "target_mode": "new_window",
            "browser_profile": "Edge:Default",
            "target_model": "o3-pro",
            "reasoning_effort": "heavy",
            "auto_resend_enabled": False,
            "stall_minutes": 5,
            "max_retries": 2,
        })
        self.assertTrue(res_cfg_b.get("ok"))

        # Now background.js polls every 2s with hardcoded browser_profile="Chrome:Default" (Chrome • DevUser)
        conv_a_chrome = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "tabs": [
                {
                    "tab_id": "501",
                    "conv_uuid": conv_a_chrome,
                    "url": f"https://chatgpt.com/c/{conv_a_chrome}",
                    "title": "任务A Chrome窗口",
                    "page_hints": ["tsk_task_a"],
                    "is_generating": False,
                    "current_model": "ChatGPT Thinking",
                    "current_effort": "Standard",
                }
            ],
        })

        snap_ab = self._get_json("/studio/snapshot")
        sess_a = next(s for s in snap_ab["sessions"] if s["SessionKey"] == "tsk_task_a")
        sess_b = next(s for s in snap_ab["sessions"] if s["SessionKey"] == "tsk_task_b")

        # Verify Task A kept Chrome:Profile 1 (NEVER snapped back to Chrome:Default!) and picked up WebCurrentModel
        self.assertEqual(sess_a["BrowserProfile"], "Chrome:Profile 1")
        self.assertEqual(sess_a["TargetMode"], "follow_window")
        self.assertEqual(sess_a["TargetModel"], "ChatGPT Pro")
        self.assertEqual(sess_a["ReasoningEffort"], "extended")
        self.assertEqual(sess_a["WebCurrentModel"], "ChatGPT Thinking")
        self.assertEqual(sess_a["WebCurrentEffort"], "standard")
        self.assertEqual(sess_a["StallMinutes"], 3)
        self.assertEqual(sess_a["MaxRetries"], 1)
        self.assertTrue(sess_a["AutoWakeupEnabled"])

        # Verify Task B kept its completely independent settings
        self.assertEqual(sess_b["BrowserProfile"], "Edge:Default")
        self.assertEqual(sess_b["TargetMode"], "new_window")
        self.assertEqual(sess_b["TargetModel"], "o3-pro")
        self.assertEqual(sess_b["ReasoningEffort"], "heavy")
        self.assertEqual(sess_b["StallMinutes"], 5)
        self.assertEqual(sess_b["MaxRetries"], 2)
        self.assertFalse(sess_b["AutoWakeupEnabled"])

        # 3. M3/M4: Follow-window empty send -> sends simple "请继续", custom text -> sends raw text
        enq_follow_empty = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_task_a",
            "user_text": "",
        })
        self.assertTrue(enq_follow_empty.get("ok"))
        self.assertEqual(enq_follow_empty["message"]["mode"], "in_place_wakeup")
        self.assertEqual(enq_follow_empty["message"]["prompt"], "请继续")
        self.assertEqual(enq_follow_empty["message"]["target_model"], "ChatGPT Pro")
        self.assertEqual(enq_follow_empty["message"]["reasoning_effort"], "extended")

        enq_follow_custom = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_task_a",
            "user_text": "请检查注册表残留项",
        })
        self.assertTrue(enq_follow_custom.get("ok"))
        self.assertEqual(enq_follow_custom["message"]["prompt"], "请检查注册表残留项")
        self.assertNotIn("【RelayStudio", enq_follow_custom["message"]["prompt"])

        # 4. M2 Cross-Browser Lifecycle (Task A switches from Chrome -> Edge):
        # Step 1: User selects Edge in dropdown -> saves Edge:Default, retires conv_a_chrome, clears conv_uuid, queues 0 messages
        wb_before_switch = self._get_json("/web-bridge/state")
        q_count_before = len([m for m in wb_before_switch["queue"] if m["status"] == "pending"])

        self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_task_a",
            "browser_profile": "Edge:Default",
        })
        wb_after_switch = self._get_json("/web-bridge/state")
        q_count_after_switch = len([m for m in wb_after_switch["queue"] if m["status"] == "pending"])
        self.assertEqual(q_count_after_switch, q_count_before, "Selecting Edge in dropdown must NOT immediately enqueue a handover message")
        bind_a = wb_after_switch["session_bindings"]["tsk_task_a"]
        self.assertEqual(bind_a["browser_profile"], "Edge:Default")
        self.assertEqual(bind_a["conv_uuid"], "")
        self.assertIn(conv_a_chrome, bind_a["retired_uuids"])

        # Step 2: Next send on Task A (even though target_mode is still "follow_window"!) automatically upgrades to new_window_handover for Edge!
        enq_cross = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_task_a",
            "user_text": "在 Edge 继续执行第 2 步",
            "no_launch": True,
        })
        self.assertTrue(enq_cross.get("ok"))
        self.assertEqual(enq_cross["message"]["mode"], "new_window_handover",
                         "First send after switching browser Chrome -> Edge must auto-upgrade to new_window_handover")
        self.assertEqual(enq_cross["message"]["browser_profile"], "Edge:Default")
        self.assertIn("tsk_task_a", enq_cross["message"]["prompt"])
        self.assertIn("【用户追加指令】：在 Edge 继续执行第 2 步", enq_cross["message"]["prompt"])
        self.assertIn("model=chatgpt-pro", enq_cross["handover_url"])

        # Step 3: Edge polls and opens the handover tab, reports conv_a_edge -> Task A binds to conv_a_edge, subsequent sends are in-place in Edge!
        cross_msg_id = enq_cross["message"]["id"]
        conv_a_edge = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        self._post_json("/web-bridge/poll", {
            "browser": "Edge",
            "browser_profile": "Edge:Default",
            "tabs": [
                {
                    "tab_id": "601",
                    "conv_uuid": conv_a_edge,
                    "url": f"https://chatgpt.com/c/{conv_a_edge}?relay_handover=1&msg_id={cross_msg_id}",
                    "title": "任务A Edge新窗口",
                    "handover_msg_id": cross_msg_id,
                    "page_hints": ["tsk_task_a"],
                    "is_generating": False,
                }
            ],
        })
        enq_after_edge_bound = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_task_a",
            "user_text": "",
        })
        self.assertEqual(enq_after_edge_bound["message"]["mode"], "in_place_wakeup")
        self.assertEqual(enq_after_edge_bound["message"]["conv_uuid"], conv_a_edge)
        self.assertEqual(enq_after_edge_bound["message"]["prompt"], "请继续")

    def test_t18_to_t21_spec_v3_2_dynamic_model_catalog_and_deredundancy(self):
        # 1. Dynamic available_models catalog via /web-bridge/poll -> /studio/snapshot
        self._write_task("tsk_gpt6_demo", "任务：GPT-6 动态模型目录验证 (D:\\project_alpha)")
        conv_gpt6 = "66666666-6666-4666-8666-666666666666"
        dyn_catalog = [
            {"slug": "gpt-6-thinking", "title": "GPT-6 Thinking", "efforts": ["light", "standard", "extended", "max"]},
            {"slug": "gpt-6-pro", "title": "GPT-6 Pro", "efforts": ["standard", "max"]},
            {"slug": "gpt-6-fast", "title": "GPT-6 Fast", "efforts": []},
        ]
        poll_resp = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "available_models": dyn_catalog,
            "tabs": [
                {
                    "tab_id": "701",
                    "conv_uuid": conv_gpt6,
                    "url": f"https://chatgpt.com/c/{conv_gpt6}",
                    "title": "GPT-6 动态模型测试窗口",
                    "page_hints": ["tsk_gpt6_demo"],
                    "is_generating": False,
                    "current_model": "GPT-6 Thinking",
                    "current_effort": "深度",
                    "available_models": dyn_catalog,
                }
            ],
        })
        self.assertTrue(poll_resp.get("ok"))

        snap = self._get_json("/studio/snapshot")
        wb_models = snap.get("web_bridge", {}).get("AvailableModels", [])
        self.assertEqual(len(wb_models), 3)
        self.assertEqual(wb_models[0]["slug"], "gpt-6-thinking")
        self.assertEqual(wb_models[0]["title"], "GPT-6 Thinking")
        self.assertEqual(wb_models[0]["efforts"], ["light", "standard", "extended", "max"])

        sess_gpt6 = next(s for s in snap["sessions"] if s["SessionKey"] == "tsk_gpt6_demo")
        self.assertEqual(sess_gpt6["WebCurrentModel"], "GPT-6 Thinking")
        self.assertEqual(sess_gpt6["WebCurrentEffort"], "extended")
        self.assertEqual(len(sess_gpt6["AvailableModels"]), 3)
        self.assertEqual(sess_gpt6["AvailableModels"][1]["slug"], "gpt-6-pro")

        # 2. Dynamic URL slug conversion (zero hardcoded model table)
        self.assertEqual(shield._model_to_url_slug("GPT-6 Thinking"), "gpt-6-thinking")
        self.assertEqual(shield._model_to_url_slug("GPT-6.5 Pro"), "gpt-6-5-pro")
        self.assertEqual(shield._model_to_url_slug("inherit"), "")

        # 3. Static audit of Spec v3.2 mechanisms and 5-item de-redundancy across all production files
        from pathlib import Path
        repo_dir = Path(shield.__file__).resolve().parent
        shield_src = (repo_dir / "McpReadOnlyShield.py").read_text(encoding="utf-8-sig")
        psm1_src = (repo_dir / "ConnectionManager.psm1").read_text(encoding="utf-8-sig")
        ps1_src = (repo_dir / "连接管理.ps1").read_text(encoding="utf-8-sig")
        manifest_obj = json.loads((repo_dir / "browser-bridge" / "manifest.json").read_text(encoding="utf-8-sig"))
        bg_src = (repo_dir / "browser-bridge" / "background.js").read_text(encoding="utf-8-sig")
        cs_src = (repo_dir / "browser-bridge" / "bridge-content.js").read_text(encoding="utf-8-sig")
        hook_src = (repo_dir / "browser-bridge" / "bridge-page-hook.js").read_text(encoding="utf-8-sig")
        gitignore_src = (repo_dir / ".gitignore").read_text(encoding="utf-8-sig")

        for name, src in [("McpReadOnlyShield.py", shield_src), ("ConnectionManager.psm1", psm1_src), ("连接管理.ps1", ps1_src)]:
            self.assertNotIn("GPT-5.4", src, f"{name} must not contain hardcoded GPT-5.4")
            self.assertNotIn("o3-pro", src, f"{name} must not contain hardcoded o3-pro")
            self.assertNotIn("GPT-4o", src, f"{name} must not contain hardcoded GPT-4o")

        self.assertNotIn("_NON_TASK_EXEC_COUNT_BY_WS", shield_src)
        self.assertNotIn("Step-SessionCircuitBreaker", psm1_src)
        self.assertNotIn("applyModelAndEffortIfNeeded", cs_src)
        self.assertNotIn("document.body.click()", cs_src)
        self.assertIn("relayOverrideModel", cs_src)
        self.assertIn("relayOverrideModel", hook_src)
        self.assertIn("/backend-api/models", hook_src)
        self.assertIn("thinking_effort", hook_src)
        self.assertIn("scripting", manifest_obj.get("permissions", []))
        cs_entries = manifest_obj.get("content_scripts", [])
        self.assertTrue(any(c.get("world") == "MAIN" and "bridge-page-hook.js" in c.get("js", []) for c in cs_entries))
        self.assertIn("ensureTabScriptsInjected", bg_src)
        self.assertIn(".scratch/", gitignore_src)

        # 4. Behavioral execution of bridge-page-hook.js in Node.js (Mechanism 1 & 2 runtime verification)
        import subprocess
        node_test_script = r"""
const fs = require('fs');
const hookCode = fs.readFileSync(process.argv[1], 'utf8');
const dataset = {};
const storage = {};
let capturedPostBody = null;
global.window = {
  __relayStudioPageHookInstalled: false,
  location: { href: 'https://chatgpt.com/c/66666666-6666-4666-8666-666666666666', pathname: '/c/66666666-6666-4666-8666-666666666666' },
  localStorage: {
    getItem: (k) => storage[k] || null,
    setItem: (k, v) => { storage[k] = String(v); }
  },
  addEventListener: () => {},
  fetch: async function(input, init) {
    const url = typeof input === 'string' ? input : input.url;
    const method = (init && init.method) || 'GET';
    if (url.includes('/backend-api/models')) {
      return {
        ok: true,
        clone: () => ({
          json: async () => ({
            models: [
              { slug: 'gpt-6-thinking', title: 'GPT-6 Thinking', supported_efforts: ['light', 'standard', 'extended', 'max'] },
              { slug: 'gpt-6-pro', title: 'GPT-6 Pro', supported_efforts: ['standard', 'max'] }
            ]
          })
        })
      };
    }
    if (method === 'POST' && url.includes('/backend-api/f/conversation')) {
      capturedPostBody = JSON.parse(init.body);
      return { ok: true, clone: () => ({ json: async () => ({}) }) };
    }
    return { ok: true, clone: () => ({ json: async () => ({}) }) };
  }
};
global.localStorage = global.window.localStorage;
global.document = { documentElement: { dataset } };
eval(hookCode);
(async () => {
  await window.fetch('https://chatgpt.com/backend-api/models', { method: 'GET' });
  await new Promise(r => setTimeout(r, 20));
  dataset.relayOverrideModel = 'gpt-6-pro';
  dataset.relayOverrideEffort = 'max';
  await window.fetch('https://chatgpt.com/backend-api/f/conversation', {
    method: 'POST',
    body: JSON.stringify({ action: 'next', model: 'auto', messages: [] })
  });
  console.log(JSON.stringify({
    catalog: JSON.parse(dataset.relayModelsCatalog || '[]'),
    cached: JSON.parse(storage['__relaystudio_models_cache__'] || '{}'),
    postBody: capturedPostBody,
    activeModel: dataset.relayActiveModel,
    activeEffort: dataset.relayActiveEffort,
    activeConvUuid: dataset.relayActiveConvUuid,
    overrideCleared: !dataset.relayOverrideModel && !dataset.relayOverrideEffort
  }));
})();
"""
        proc = subprocess.run(
            ["node", "-e", node_test_script, str(repo_dir / "browser-bridge" / "bridge-page-hook.js")],
            capture_output=True, text=True, encoding="utf-8", timeout=10
        )
        self.assertEqual(proc.returncode, 0, f"bridge-page-hook.js runtime test failed: {proc.stderr}")
        hook_res = json.loads(proc.stdout.strip())
        self.assertEqual(len(hook_res["catalog"]), 2)
        self.assertEqual(hook_res["catalog"][0]["slug"], "gpt-6-thinking")
        self.assertEqual(hook_res["postBody"]["model"], "gpt-6-pro")
        self.assertEqual(hook_res["postBody"]["thinking_effort"], "max")
        self.assertEqual(hook_res["activeModel"], "gpt-6-pro")
        self.assertEqual(hook_res["activeEffort"], "max")
        self.assertEqual(hook_res["activeConvUuid"], "66666666-6666-4666-8666-666666666666")
        self.assertTrue(hook_res["overrideCleared"])

    def test_t22_diag_bugs_autoresend_and_follow_window_regressions(self):
        # 1. Bug 1: build_studio_snapshot includes AutoResendEnabled AND per-task auto_resend_enabled=True is not masked by legacy auto_resend_config.enabled=False
        self._write_task("tsk_diag_auto", "Relay Studio 前端任务展示测试")
        with shield._WEB_BRIDGE_LOCK:
            st = shield._load_web_bridge_state(self.wb_state_path)
            st["auto_resend_config"]["enabled"] = False
            st["session_bindings"]["__new_task__"] = {
                "conv_uuid": "69f1cfcc-8bf4-8321-83fa-81e5ff9c0c48",
                "browser_profile": "Chrome:Profile 1",
                "retired_uuids": [],
            }
            st["session_bindings"]["tsk_diag_auto"] = {
                "conv_uuid": "",
                "browser_profile": "Chrome:Profile 1",
                "auto_resend_enabled": True,
                "retired_uuids": [],
            }
            shield._save_web_bridge_state(self.wb_state_path, st)

        snap = self._get_json("/studio/snapshot")
        sess = next(s for s in snap["sessions"] if s["SessionKey"] == "tsk_diag_auto")
        self.assertIn("AutoResendEnabled", sess)
        self.assertTrue(sess["AutoResendEnabled"], "Per-task auto_resend_enabled=True must not be masked by stale auto_resend_config.enabled=False")
        self.assertTrue(sess["AutoWakeupEnabled"])
        # Bug 3a: Newly created task inherits conv_uuid from __new_task__
        self.assertEqual(sess["BoundConvUuid"], "69f1cfcc-8bf4-8321-83fa-81e5ff9c0c48")

        # 2. Bug 3b: state_known=False tab is skipped until bridge-content.js reports state_known=True
        enq = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_diag_auto",
            "user_text": "",
        })
        self.assertTrue(enq.get("ok"))
        msg_id = enq["message"]["id"]
        self.assertEqual(enq["message"]["conv_uuid"], "69f1cfcc-8bf4-8321-83fa-81e5ff9c0c48")

        poll_loading = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [
                {
                    "tab_id": "888",
                    "conv_uuid": "69f1cfcc-8bf4-8321-83fa-81e5ff9c0c48",
                    "url": "https://chatgpt.com/c/69f1cfcc-8bf4-8321-83fa-81e5ff9c0c48",
                    "title": "Relay Studio 前端任务展示测试",
                    "state_known": False,
                    "is_generating": False,
                }
            ],
        })
        self.assertEqual(len(poll_loading.get("dispatches", [])), 0, "Must NOT dispatch into tab with state_known=False")

        poll_ready = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "tabs": [
                {
                    "tab_id": "888",
                    "conv_uuid": "69f1cfcc-8bf4-8321-83fa-81e5ff9c0c48",
                    "url": "https://chatgpt.com/c/69f1cfcc-8bf4-8321-83fa-81e5ff9c0c48",
                    "title": "Relay Studio 前端任务展示测试",
                    "state_known": True,
                    "is_generating": False,
                }
            ],
        })
        self.assertEqual(len(poll_ready.get("dispatches", [])), 1, "Must dispatch once state_known=True")
        self.assertEqual(poll_ready["dispatches"][0]["msg_id"], msg_id)

    def test_t23_spec_v4_deep_modules_and_chat_bridge(self):
        # 1. Module 4: Filter out -wm (Work mode) and hidden alpha-gate models in _normalize_available_models
        raw_catalog = [
            {"slug": "gpt-6", "title": "GPT-6", "efforts": []},
            {"slug": "gpt-6-instant", "title": "GPT-6 Instant", "efforts": []},
            {"slug": "gpt-6-thinking", "title": "GPT-6 Thinking", "efforts": ["min", "standard", "extended", "max"]},
            {"slug": "gpt-6-pro", "title": "GPT-6 Pro", "efforts": ["standard", "max"]},
            {"slug": "gpt-6.1-sol-wm", "title": "GPT-6.1 Sol", "is_work_mode_model": True, "efforts": ["low", "high", "xhigh"]},
            {"slug": "gpt-6.1-terra-wm", "title": "GPT-6.1 Terra", "efforts": ["low", "high"]},
            {"slug": "chatgpt_alpha_model_external_access_reserved_gate_13", "title": "Newly create multisys_rollout", "tags": ["hidden"]},
        ]
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "browser_instance_id": "inst_profile19",
            "available_models": raw_catalog,
            "tabs": [],
        })
        snap = self._get_json("/studio/snapshot")
        avail_slugs = [m["slug"] for m in snap["web_bridge"]["AvailableModels"]]
        self.assertEqual(avail_slugs, ["gpt-6", "gpt-6-instant", "gpt-6-thinking", "gpt-6-pro"],
                         "Must filter out -wm work models and hidden alpha gate models")

        # 2. Module 4: Effort-to-thinking slug auto-upgrade in set_task_composer_config
        self._write_task("tsk_v4_a", "任务A：旧模块重构 (D:\\project_alpha)")
        cfg_think = self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_v4_a",
            "target_model": "gpt-6",
            "reasoning_effort": "max",
        })
        self.assertEqual(cfg_think["binding"]["target_model"], "gpt-6-thinking",
                         "Selecting thinking effort on gpt-6 must auto-switch slug to gpt-6-thinking")
        cfg_inst = self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_v4_a",
            "target_model": "gpt-6-thinking",
            "reasoning_effort": "instant",
        })
        self.assertEqual(cfg_inst["binding"]["target_model"], "gpt-6-instant",
                         "Selecting instant effort must auto-switch slug to gpt-6-instant")

        # 3. Module 2: Defect A fix + Auto-Supersede (same-workspace different task creates new ID and auto-archives old task)
        conv_old_a = "11111111-2222-4333-8444-555555555555"
        self._post_json("/studio/action", {
            "action": "bind_session",
            "session_key": "tsk_v4_a",
            "conv_uuid": conv_old_a,
            "tab_id": "777",
            "browser_profile": "Chrome:Profile 1",
        })
        # Same title -> still deduplicated
        same_req = json.dumps({
            "jsonrpc": "2.0", "id": "rpc-same", "method": "tools/call",
            "params": {"name": "task_manage", "arguments": {"action": "create", "title": "任务A：旧模块重构 (D:\\project_alpha)", "goal": "继续重构"}},
        }).encode("utf-8")
        self.assertIsNotNone(shield.check_and_intercept_duplicate_task_create(same_req, self.tasks_root, self.data_root, self.activity_path),
                             "Identical task title in same workspace must still be deduplicated")

        # Different title & goal in same workspace -> NOT intercepted (returns None so :8765 creates new task_id), AND keeps old task A active side-by-side (Spec v4.2 Q3/Q4)!
        diff_req = json.dumps({
            "jsonrpc": "2.0", "id": "rpc-diff", "method": "tools/call",
            "params": {"name": "task_manage", "arguments": {"action": "create", "title": "任务B：全新支付网关开发 (D:\\project_alpha)", "goal": "开发独立支付网关"}},
        }).encode("utf-8")
        intercept_diff = shield.check_and_intercept_duplicate_task_create(diff_req, self.tasks_root, self.data_root, self.activity_path, self.wb_state_path)
        self.assertIsNone(intercept_diff, "Genuinely different task in same workspace must NOT be merged into old task A")
        snap_after_create = self._get_json("/studio/snapshot")
        active_ids = [s["SessionKey"] for s in snap_after_create["sessions"]]
        self.assertIn("tsk_v4_a", active_ids, "Spec v4.2 Q3/Q4: creating independent task B must keep active task A side-by-side")

        # 4. Module 3: Defect B fix (legacy ack_msg_ids in poll must NOT mark claimed message delivered)
        self._write_task("tsk_v4_b", "任务B：全新支付网关开发 (D:\\project_alpha)")
        self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_v4_b",
            "browser_profile": "Chrome:Profile 1",
            "target_mode": "new_window",
        })
        enq_b = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_v4_b",
            "mode": "new_window_handover",
            "prompt": "启动任务 B",
            "no_launch": True,
        })
        msg_b_id = enq_b["message"]["id"]

        # Module 1: Defect C fix (a different instance reporting Chrome:Default must NOT wildcard-claim Chrome:Profile 1's open_new_tab)
        poll_wrong_inst = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "browser_instance_id": "inst_other_default",
            "tabs": [{"tab_id": "101", "conv_uuid": "", "url": "https://chatgpt.com/", "is_generating": False}],
        })
        self.assertEqual([d for d in poll_wrong_inst.get("dispatches", []) if d.get("open_new_tab")], [],
                         "Chrome:Default instance must NOT wildcard-claim Chrome:Profile 1's new tab handover")

        # Correct paired instance claims the handover tab
        poll_right_inst = self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "browser_instance_id": "inst_profile19",
            "tabs": [{
                "tab_id": "802",
                "conv_uuid": "",
                "url": f"https://chatgpt.com/?relay_handover=1&msg_id={msg_b_id}",
                "handover_msg_id": msg_b_id,
                "state_known": True,
                "is_generating": False,
            }],
        })
        self.assertEqual(len(poll_right_inst.get("dispatches", [])), 1)
        # Attempt legacy ack_msg_ids bypass via poll -> must remain 'claimed', NOT 'delivered'!
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "browser_instance_id": "inst_profile19",
            "ack_msg_ids": [msg_b_id],
            "tabs": [],
        })
        q_item = next(m for m in self._get_json("/web-bridge/state")["queue"] if m["id"] == msg_b_id)
        self.assertEqual(q_item["status"], "claimed", "Legacy ack_msg_ids in poll must NOT upgrade claimed to delivered")

        # 5. End-to-end /web-bridge/ack-deliver -> handover retirement + /web-bridge/ack-retire completion
        conv_b_first = "22222222-3333-4444-8555-666666666666"
        ack_del_1 = self._post_json("/web-bridge/ack-deliver", {
            "msg_id": msg_b_id,
            "tab_id": "802",
            "conv_uuid": conv_b_first,
        })
        self.assertTrue(ack_del_1.get("ok"))
        # Now trigger a second handover on tsk_v4_b and verify ack-deliver enqueues retire_action for conv_b_first even when new conv_uuid is empty at header time
        enq_b2 = self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_v4_b",
            "mode": "new_window_handover",
            "prompt": "接力任务 B 第二棒",
            "no_launch": True,
        })
        msg_b2_id = enq_b2["message"]["id"]
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Profile 1",
            "browser_instance_id": "inst_profile19",
            "tabs": [{
                "tab_id": "803",
                "conv_uuid": "",
                "url": f"https://chatgpt.com/?relay_handover=1&msg_id={msg_b2_id}",
                "handover_msg_id": msg_b2_id,
                "state_known": True,
                "is_generating": False,
            }],
        })
        ack_del_2 = self._post_json("/web-bridge/ack-deliver", {
            "msg_id": msg_b2_id,
            "tab_id": "803",
            "conv_uuid": "",  # simulates new chat URL not yet rewritten to /c/<uuid> when HTTP 200 arrives
        })
        self.assertTrue(ack_del_2.get("ok"))
        wb_state_after_b2 = self._get_json("/web-bridge/state")
        pending_retires = [r for r in wb_state_after_b2.get("retire_actions", []) if r.get("status") == "pending"]
        self.assertTrue(any(r.get("conv_uuid") == conv_b_first for r in pending_retires),
                        "ack-deliver on new_window_handover must enqueue retire_action for old conv_uuid even when new conv_uuid is not yet in URL")
        retire_b1_id = next(r["id"] for r in pending_retires if r.get("conv_uuid") == conv_b_first)
        ack_ret = self._post_json("/web-bridge/ack-retire", {
            "retire_id": retire_b1_id,
            "conv_uuid": conv_b_first,
        })
        self.assertTrue(ack_ret.get("ok"))
        wb_state_after_ret = self._get_json("/web-bridge/state")
        ret_obj = next(r for r in wb_state_after_ret.get("retire_actions", []) if r["id"] == retire_b1_id)
        self.assertEqual(ret_obj["status"], "completed")

        # 6. Verify explicit TargetModel switch to gpt-6-instant is NOT overwritten by previous thinking effort (Blocking 3 fix)
        self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_v4_b",
            "target_model": "gpt-6-thinking",
            "reasoning_effort": "深度",
        })
        res_switch_inst = self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_v4_b",
            "target_model": "gpt-6-instant",
        })
        self.assertEqual(res_switch_inst["binding"]["target_model"], "gpt-6-instant")
        self.assertEqual(res_switch_inst["binding"]["reasoning_effort"], "none")

        # 7. Built-in DesktopAppBridge tick (Web Chat mode guard + delivery + retire_actions)
        self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_v4_b",
            "browser_profile": "Desktop:ChatGPT",
        })
        self._post_json("/studio/action", {
            "action": "enqueue_message",
            "session_key": "tsk_v4_b",
            "mode": "new_window_handover",
            "prompt": "桌面端 Web 聊天接力",
            "no_launch": True,
        })
        try:
            from fake_chatgpt_page import FakeChatGptPage
        except ImportError:
            from tests.fake_chatgpt_page import FakeChatGptPage
        fake_page = FakeChatGptPage(conv_uuid="", chat_mode_selected=False, new_conv_uuid="77777777-8888-4999-8aaa-bbbbbbbbbbbb")
        d_res = shield.DesktopAppBridge.tick(
            self.wb_state_path, self.tasks_root, eval_fn=fake_page.evaluate, sleep_fn=lambda s: None
        )
        self.assertTrue(d_res.get("ok") and d_res.get("processed", 0) >= 1)
        self.assertEqual(fake_page.mode_switches, 1, "Desktop must be switched from 工作 to 聊天 (Web) before delivery")
        self.assertTrue(fake_page.sent and "桌面端 Web 聊天接力" in (fake_page.filled or ""))
        with shield._WEB_BRIDGE_LOCK:
            wb_after_desktop = shield._load_web_bridge_state(self.wb_state_path)
        self.assertEqual(
            wb_after_desktop["session_bindings"]["tsk_v4_b"]["conv_uuid"], "77777777-8888-4999-8aaa-bbbbbbbbbbbb"
        )

        # 8. Defect D: CORS Origin Allowlist (allow trusted origins, block evil origins and localhost.evil.com)
        for allowed_origin in ("https://chatgpt.com", "app://-", "http://127.0.0.1:8766", "chrome-extension://abcdefghijklmnop"):
            req = urllib.request.Request(f"http://127.0.0.1:{self.shield_port}/shieldz", headers={"Origin": allowed_origin}, method="GET")
            with urllib.request.urlopen(req, timeout=3) as resp:
                self.assertEqual(resp.headers.get("Access-Control-Allow-Origin"), allowed_origin)
        for blocked_origin in ("https://evil.example.com", "http://localhost.evil.com", "http://127.0.0.1.evil.com"):
            req = urllib.request.Request(f"http://127.0.0.1:{self.shield_port}/shieldz", headers={"Origin": blocked_origin}, method="GET")
            with urllib.request.urlopen(req, timeout=3) as resp:
                self.assertIsNone(resp.headers.get("Access-Control-Allow-Origin"),
                                  f"Untrusted origin {blocked_origin} must NOT receive Access-Control-Allow-Origin")


if __name__ == "__main__":
    unittest.main()

