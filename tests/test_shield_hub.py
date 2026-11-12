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

        self.server.calls.append({
            "method": method,
            "tool": tool_name,
            "args": args,
            "accept": self.headers.get("Accept", ""),
            "transfer_encoding": self.headers.get("Transfer-Encoding", ""),
            "content_length": self.headers.get("Content-Length", ""),
        })

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

        self._saved_local_token_env = os.environ.pop("RELAYSTUDIO_LOCAL_TOKEN", None)
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
        if self._saved_local_token_env is None:
            os.environ.pop("RELAYSTUDIO_LOCAL_TOKEN", None)
        else:
            os.environ["RELAYSTUDIO_LOCAL_TOKEN"] = self._saved_local_token_env
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

    def test_platform_catalogs_are_isolated_in_snapshot(self):
        for provider, url, slug in [
            ("chatgpt", "https://chatgpt.com/c/11111111-1111-4111-8111-111111111111", "openai-observed"),
            ("gemini", "https://gemini.google.com/app/abcd1234", "gemini-observed"),
            ("claude", "https://claude.ai/chat/22222222-2222-4222-8222-222222222222", "claude-observed"),
        ]:
            response = self._post_json("/web-bridge/poll", {
                "browser": "Chrome", "browser_profile": "Chrome:Shared",
                "tabs": [{"tab_id": provider, "provider": provider, "url": url,
                          "available_models": [{"slug": slug, "title": slug, "efforts": []}]}],
            })
            self.assertTrue(response["ok"])
        self._post_json("/studio/action", {"action": "set_task_composer_config", "session_key": "__new_task__", "provider": "gemini", "target_model": "gemini-observed"})
        queued = self._post_json("/studio/action", {"action": "enqueue_message", "session_key": "__new_task__", "user_text": "hello"})
        self.assertEqual(queued["message"]["provider"], "gemini")
        self.assertTrue(queued["handover_url"].startswith("https://gemini.google.com/app?relay_handover=1"), queued["handover_url"])
        self.assertNotIn("/app/?", queued["handover_url"])
        task_id = queued["message"]["session_key"]
        self._post_json("/studio/action", {"action": "bind_session", "session_key": task_id, "provider": "gemini", "conv_uuid": "abcd1234", "tab_id": "gemini"})
        switched = self._post_json("/studio/action", {"action": "set_task_composer_config", "session_key": task_id, "provider": "claude"})
        self.assertEqual(switched["binding"]["conv_uuid"], "")
        self.assertEqual(switched["binding"]["tab_id"], "")
        bridge = self._get_json("/studio/snapshot")["web_bridge"]
        catalogs = bridge["available_models_by_provider"]
        self.assertEqual([m["slug"] for m in catalogs["chatgpt"]], ["openai-observed"])
        self.assertEqual([m["slug"] for m in catalogs["gemini"]], ["gemini-observed"])
        self.assertEqual([m["slug"] for m in catalogs["claude"]], ["claude-observed"])
        self.assertEqual(bridge["AvailableModels"], catalogs["chatgpt"])
        # Fixture ages the Gemini probe; snapshot must hide its persisted catalog.
        with open(self.wb_state_path, encoding="utf-8") as f:
            state = json.load(f)
        state["tabs"]["gemini"]["last_seen_at"] = "2000-01-01T00:00:00Z"
        with open(self.wb_state_path, "w", encoding="utf-8") as f:
            json.dump(state, f)
        snapshot = self._get_json("/studio/snapshot")
        task_view = next(session for session in snapshot["sessions"] if session["SessionKey"] == task_id)
        self.assertEqual(task_view["AvailableModelsByProvider"]["gemini"], [])
        self.assertIn("claude", task_view["ConnectedProviders"])
        disconnected = snapshot["web_bridge"]
        self.assertEqual(disconnected["available_models_by_provider"]["gemini"], [])
        self.assertNotIn("gemini", disconnected["connected_providers"])
        self.assertEqual(disconnected["available_models_by_provider"]["claude"][0]["slug"], "claude-observed")

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

    def test_public_mcp_oauth21_handshake_and_head_probe(self):
        import base64
        import hashlib
        import urllib.error
        import urllib.parse

        base = f"http://127.0.0.1:{self.shield_port}"
        tunnel_host = "choir-examined-clause-speech.trycloudflare.com"
        fwd_headers = {
            "X-Forwarded-Proto": "https",
            "X-Forwarded-Host": tunnel_host,
            "User-Agent": "Google",
        }

        # 1. HEAD /mcp without Authorization must return 401 with WWW-Authenticate pointing to resource_metadata
        head_req = urllib.request.Request(f"{base}/mcp", headers=fwd_headers, method="HEAD")
        with self.assertRaises(urllib.error.HTTPError) as head_err:
            urllib.request.urlopen(head_req, timeout=3)
        self.assertEqual(head_err.exception.code, 401)
        www_auth = head_err.exception.headers.get("WWW-Authenticate", "")
        self.assertIn(f'resource_metadata="https://{tunnel_host}/.well-known/oauth-protected-resource"', www_auth)
        head_err.exception.close()

        # 2. Protected resource metadata discovery (both /.well-known/oauth-protected-resource/mcp and root)
        for pr_path in ("/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource"):
            pr_req = urllib.request.Request(f"{base}{pr_path}", headers=fwd_headers, method="GET")
            with urllib.request.urlopen(pr_req, timeout=3) as pr_resp:
                self.assertEqual(pr_resp.status, 200)
                pr_data = json.loads(pr_resp.read().decode("utf-8"))
                self.assertEqual(pr_data["resource"], f"https://{tunnel_host}/mcp")
                self.assertEqual(pr_data["authorization_servers"], [f"https://{tunnel_host}"])

        # 3. Authorization server metadata discovery (RFC 8414)
        for as_path in ("/.well-known/oauth-authorization-server", "/.well-known/oauth-authorization-server/mcp"):
            as_req = urllib.request.Request(f"{base}{as_path}", headers=fwd_headers, method="GET")
            with urllib.request.urlopen(as_req, timeout=3) as as_resp:
                self.assertEqual(as_resp.status, 200)
                as_data = json.loads(as_resp.read().decode("utf-8"))
                self.assertEqual(as_data["issuer"], f"https://{tunnel_host}")
                self.assertEqual(as_data["authorization_endpoint"], f"https://{tunnel_host}/oauth/authorize")
                self.assertEqual(as_data["token_endpoint"], f"https://{tunnel_host}/oauth/token")
                self.assertEqual(as_data["registration_endpoint"], f"https://{tunnel_host}/oauth/register")
                self.assertIn("S256", as_data["code_challenge_methods_supported"])

        # 4. Dynamic Client Registration (RFC 7591 POST /oauth/register)
        redirect_uri = "https://oauth-redirect.googleusercontent.com/r/user_bound_custom-mcp-675498804-choir_examined_clause_speech_trycloudflare_com"
        reg_body = json.dumps({
            "client_name": "Google Gemini Connector",
            "redirect_uris": [redirect_uri],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
        }).encode("utf-8")
        reg_req = urllib.request.Request(
            f"{base}/oauth/register",
            data=reg_body,
            headers={**fwd_headers, "Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(reg_req, timeout=3) as reg_resp:
            self.assertEqual(reg_resp.status, 201)
            reg_data = json.loads(reg_resp.read().decode("utf-8"))
            client_id = reg_data["client_id"]
            client_secret = reg_data["client_secret"]
            self.assertEqual(reg_data["redirect_uris"], [redirect_uri])

        # 5. GET /oauth/authorize with PKCE S256 and a 1200-character state parameter (BerriAI/litellm#46414 regression guard)
        code_verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk_relaystudio_pkce_verifier"
        code_challenge = base64.urlsafe_b64encode(hashlib.sha256(code_verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")
        long_state = "gemini_state_" + ("A1b2C3d4_-." * 110)  # > 1200 chars
        self.assertGreater(len(long_state), 1150)

        class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None

        no_redir_opener = urllib.request.build_opener(_NoRedirectHandler())
        auth_qs = urllib.parse.urlencode({
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "state": long_state,
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
            "scope": "mcp offline_access",
        })
        auth_req = urllib.request.Request(f"{base}/oauth/authorize?{auth_qs}", headers=fwd_headers, method="GET")
        with self.assertRaises(urllib.error.HTTPError) as auth_redir:
            no_redir_opener.open(auth_req, timeout=3)
        self.assertEqual(auth_redir.exception.code, 302)
        loc = auth_redir.exception.headers.get("Location", "")
        auth_redir.exception.close()
        self.assertTrue(loc.startswith(redirect_uri + "?"))
        loc_qs = urllib.parse.parse_qs(urllib.parse.urlsplit(loc).query)
        self.assertEqual(loc_qs["state"][0], long_state)
        auth_code = loc_qs["code"][0]
        self.assertTrue(auth_code)

        # 6. POST /oauth/token: wrong code_verifier must fail with 400 invalid_grant; valid code_verifier must issue tokens
        bad_token_body = urllib.parse.urlencode({
            "grant_type": "authorization_code",
            "code": auth_code,
            "redirect_uri": redirect_uri,
            "client_id": client_id,
            "client_secret": client_secret,
            "code_verifier": "wrong_verifier_value_0000000000000000000000000",
        }).encode("utf-8")
        bad_token_req = urllib.request.Request(
            f"{base}/oauth/token",
            data=bad_token_body,
            headers={**fwd_headers, "Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as bad_tok_err:
            urllib.request.urlopen(bad_token_req, timeout=3)
        self.assertEqual(bad_tok_err.exception.code, 400)
        bad_tok_err.exception.close()

        good_token_body = urllib.parse.urlencode({
            "grant_type": "authorization_code",
            "code": auth_code,
            "redirect_uri": redirect_uri,
            "client_id": client_id,
            "client_secret": client_secret,
            "code_verifier": code_verifier,
        }).encode("utf-8")
        good_token_req = urllib.request.Request(
            f"{base}/oauth/token",
            data=good_token_body,
            headers={**fwd_headers, "Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        with urllib.request.urlopen(good_token_req, timeout=3) as tok_resp:
            self.assertEqual(tok_resp.status, 200)
            tok_data = json.loads(tok_resp.read().decode("utf-8"))
            self.assertEqual(tok_data["token_type"], "Bearer")
            access_token = tok_data["access_token"]
            refresh_token = tok_data["refresh_token"]
            self.assertTrue(access_token)
            self.assertTrue(refresh_token)

        # 7. Persistent linking: refresh_token grant must return the exact same refresh_token
        ref_body = urllib.parse.urlencode({
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": client_id,
        }).encode("utf-8")
        ref_req = urllib.request.Request(
            f"{base}/oauth/token",
            data=ref_body,
            headers={**fwd_headers, "Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        with urllib.request.urlopen(ref_req, timeout=3) as ref_resp:
            self.assertEqual(ref_resp.status, 200)
            ref_data = json.loads(ref_resp.read().decode("utf-8"))
            self.assertEqual(ref_data["refresh_token"], refresh_token)
            self.assertTrue(ref_data["access_token"])

        # 8. HEAD /mcp with Authorization: Bearer <access_token> returns 200 OK, and POST /mcp normalizes Accept header
        authed_head = urllib.request.Request(
            f"{base}/mcp",
            headers={**fwd_headers, "Authorization": f"Bearer {access_token}"},
            method="HEAD",
        )
        with urllib.request.urlopen(authed_head, timeout=3) as ah_resp:
            self.assertEqual(ah_resp.status, 200)

        mcp_post = urllib.request.Request(
            f"{base}/mcp",
            data=json.dumps({"jsonrpc": "2.0", "id": "g1", "method": "tools/list", "params": {}}).encode("utf-8"),
            headers={**fwd_headers, "Authorization": f"Bearer {access_token}", "Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(mcp_post, timeout=3) as mp_resp:
            self.assertEqual(mp_resp.status, 200)
        self.assertIn("text/event-stream", self.upstream.calls[-1]["accept"])

    def test_ticket_05_provider_unification_handover_url_carrier_memory_and_slates(self):
        # 1. Platform ID unification ('chatgpt') with legacy 'openai' normalization
        self.assertEqual(shield._normalize_studio_provider("openai"), "chatgpt")
        self.assertEqual(shield._normalize_studio_provider("OpenAI"), "chatgpt")
        self.assertEqual(shield._normalize_studio_provider("ChatGPT"), "chatgpt")
        self.assertEqual(shield._normalize_studio_provider("gemini"), "gemini")
        self.assertEqual(shield._normalize_studio_provider("claude"), "claude")

        bind_legacy = self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "tsk_legacy_openai",
            "provider": "OpenAI",
            "browser_profile": "Desktop:ChatGPT",
        })
        self.assertTrue(bind_legacy["ok"])
        self.assertEqual(bind_legacy["binding"]["provider"], "chatgpt")
        self.assertEqual(bind_legacy["binding"]["carrier_by_provider"]["chatgpt"], "Desktop:ChatGPT")

        # Legacy 'openai' key in available_models_by_provider normalizes into 'chatgpt'
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "available_models_by_provider": {
                "openai": [{"slug": "gpt-legacy-norm", "title": "GPT Legacy Norm", "efforts": []}],
            },
            "tabs": [{
                "tab_id": "t_openai_alias",
                "provider": "openai",
                "url": "https://chatgpt.com/c/12345678-1234-4234-8234-1234567890ab",
                "conv_uuid": "12345678-1234-4234-8234-1234567890ab",
                "is_generating": False,
            }],
        })
        wb_st = self._get_json("/web-bridge/state")
        self.assertEqual(
            [m["slug"] for m in wb_st["available_models_by_provider"]["chatgpt"]],
            ["gpt-legacy-norm"],
        )

        # 2. Handover URL trailing-slash 404 fix (_build_handover_url)
        gemini_u1 = shield._build_handover_url("https://gemini.google.com/app", msg_id="m_1", task_id="tsk_1", provider="gemini")
        self.assertEqual(gemini_u1, "https://gemini.google.com/app?relay_handover=1&msg_id=m_1&task_id=tsk_1&provider=gemini")
        gemini_u2 = shield._build_handover_url("https://gemini.google.com/app/", msg_id="m_2")
        self.assertEqual(gemini_u2, "https://gemini.google.com/app?relay_handover=1&msg_id=m_2")
        claude_u = shield._build_handover_url("https://claude.ai/new/", msg_id="m_3")
        self.assertEqual(claude_u, "https://claude.ai/new?relay_handover=1&msg_id=m_3")
        chatgpt_u = shield._build_handover_url("https://chatgpt.com", msg_id="m_4")
        self.assertEqual(chatgpt_u, "https://chatgpt.com/?relay_handover=1&msg_id=m_4")

        # 3. Per-platform carrier memory (carrier_by_provider) & Desktop:ChatGPT guard on gemini/claude
        self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "__new_task__",
            "provider": "chatgpt",
            "browser_profile": "Desktop:ChatGPT",
        })
        # Switch __new_task__ to gemini while passing stale Desktop:ChatGPT -> must guard and fall back to browser profile
        nt_gemini = self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "__new_task__",
            "provider": "gemini",
            "browser_profile": "Desktop:ChatGPT",
        })["binding"]
        self.assertEqual(nt_gemini["provider"], "gemini")
        self.assertNotEqual(nt_gemini["browser_profile"], "Desktop:ChatGPT")
        self.assertFalse(nt_gemini["browser_profile"].lower().startswith("desktop:"))
        self.assertEqual(nt_gemini["carrier_by_provider"]["chatgpt"], "Desktop:ChatGPT")

        # Bind Edge:Profile 2 specifically for gemini on __new_task__
        nt_gemini_edge = self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "__new_task__",
            "provider": "gemini",
            "browser_profile": "Edge:Profile 2",
        })["binding"]
        self.assertEqual(nt_gemini_edge["browser_profile"], "Edge:Profile 2")
        self.assertEqual(nt_gemini_edge["carrier_by_provider"]["gemini"], "Edge:Profile 2")
        self.assertEqual(nt_gemini_edge["carrier_by_provider"]["chatgpt"], "Desktop:ChatGPT")

        # Switch __new_task__ back to chatgpt without specifying browser_profile -> restores Desktop:ChatGPT
        nt_back_chatgpt = self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "__new_task__",
            "provider": "chatgpt",
        })["binding"]
        self.assertEqual(nt_back_chatgpt["provider"], "chatgpt")
        self.assertEqual(nt_back_chatgpt["browser_profile"], "Desktop:ChatGPT")

        # Switch __new_task__ to gemini again without specifying browser_profile -> restores Edge:Profile 2
        nt_back_gemini = self._post_json("/studio/action", {
            "action": "set_task_composer_config",
            "session_key": "__new_task__",
            "provider": "gemini",
        })["binding"]
        self.assertEqual(nt_back_gemini["provider"], "gemini")
        self.assertEqual(nt_back_gemini["browser_profile"], "Edge:Profile 2")

        # 4. Cold/Hot tiered slates & high-frequency heartbeat disk-write throttling
        self._write_task("tsk_slate_1", "冷热分层缓存测试任务")
        tasks_1 = shield.load_all_tasks(self.tasks_root)
        self.assertTrue(any(t["id"] == "tsk_slate_1" for t in tasks_1))
        self.assertGreaterEqual(len(shield._STUDIO_TASK_FILE_CACHE), 1)
        # Mutating returned dict must not corrupt _STUDIO_TASK_FILE_CACHE
        tasks_1[0]["title"] = "MUTATED_IN_MEMORY"
        tasks_2 = shield.load_all_tasks(self.tasks_root)
        t_reloaded = next(t for t in tasks_2 if t["id"] == tasks_1[0]["id"])
        self.assertNotEqual(t_reloaded["title"], "MUTATED_IN_MEMORY")

        # Short-TTL snapshot slate reuse when no state mutations occur
        snap_1 = shield.build_studio_snapshot(self.data_root, self.tasks_root, self.wb_state_path)
        snap_2 = shield.build_studio_snapshot(self.data_root, self.tasks_root, self.wb_state_path)
        self.assertEqual(snap_1["rev"], snap_2["rev"])

        # Heartbeat disk-write throttling: first poll writes to disk, second identical poll with only timestamp change skips disk flush
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "tabs": [{
                "tab_id": "t_hb_1",
                "provider": "gemini",
                "url": "https://gemini.google.com/app/room_hb_1",
                "conv_uuid": "room_hb_1",
                "is_generating": False,
            }],
        })
        mtime_1 = os.stat(self.wb_state_path).st_mtime_ns
        time.sleep(0.05)
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "tabs": [{
                "tab_id": "t_hb_1",
                "provider": "gemini",
                "url": "https://gemini.google.com/app/room_hb_1",
                "conv_uuid": "room_hb_1",
                "is_generating": False,
            }],
        })
        mtime_2 = os.stat(self.wb_state_path).st_mtime_ns
        self.assertEqual(mtime_1, mtime_2, "Pure heartbeat poll within 10s must throttle redundant disk write")

        # Substantive change (is_generating=True) must flush to disk immediately
        time.sleep(0.05)
        self._post_json("/web-bridge/poll", {
            "browser": "Chrome",
            "browser_profile": "Chrome:Default",
            "tabs": [{
                "tab_id": "t_hb_1",
                "provider": "gemini",
                "url": "https://gemini.google.com/app/room_hb_1",
                "conv_uuid": "room_hb_1",
                "is_generating": True,
            }],
        })
        mtime_3 = os.stat(self.wb_state_path).st_mtime_ns
        self.assertGreater(mtime_3, mtime_2, "Substantive state change (is_generating=True) must flush to disk immediately")

    def test_15_vpn_resilience_proxy_seam_and_http11_keepalive(self):
        """Verify Seam 1 (outbound proxy resolution) and HTTP/1.1 keep-alive multi-step OAuth + MCP over a single socket."""
        import http.client
        import socket

        # 1. Seam 1: Dead local proxy port must automatically fall back to direct/TUN mode
        dead_env = {"HTTPS_PROXY": "http://127.0.0.1:59997", "HTTP_PROXY": "http://127.0.0.1:59997"}
        res_dead = shield.resolve_effective_outbound_proxy_env(
            data_root=self.data_root,
            base_env=dead_env,
            system_proxy_override="",
        )
        self.assertEqual(res_dead["Mode"], "direct_fallback")
        self.assertEqual(res_dead["ProxyUrl"], "")
        self.assertEqual(res_dead["Env"]["HTTPS_PROXY"], "")
        self.assertIn("*.ts.net", res_dead["NoProxy"])
        self.assertIn("100.64.0.0/10", res_dead["NoProxy"])

        # 2. Seam 1: Live local proxy port (e.g. switched VPN client) is dynamically adopted
        dummy_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        dummy_sock.bind(("127.0.0.1", 0))
        dummy_sock.listen(1)
        live_port = dummy_sock.getsockname()[1]
        try:
            res_live = shield.resolve_effective_outbound_proxy_env(
                data_root=self.data_root,
                base_env=dead_env,
                system_proxy_override=f"127.0.0.1:{live_port}",
            )
            self.assertEqual(res_live["Mode"], "proxy")
            self.assertEqual(res_live["ProxyUrl"], f"http://127.0.0.1:{live_port}")
            self.assertEqual(res_live["Env"]["HTTPS_PROXY"], f"http://127.0.0.1:{live_port}")
        finally:
            dummy_sock.close()

        # 3. Seam 1: Explicit 'direct' setting overrides all proxies
        res_direct = shield.resolve_effective_outbound_proxy_env(
            data_root=self.data_root,
            base_env=dead_env,
            system_proxy_override="",
            outbound_proxy_setting="direct",
        )
        self.assertEqual(res_direct["Mode"], "direct")
        self.assertEqual(res_direct["ProxyUrl"], "")

        # 4. Persistent HTTP/1.1 Keep-Alive over a SINGLE TCP socket (simulating tailscaled Funnel / cloudflared reverse proxy)
        conn = http.client.HTTPConnection("127.0.0.1", self.shield_port, timeout=5)
        try:
            conn.request("GET", "/.well-known/oauth-protected-resource", headers={"Connection": "keep-alive"})
            r1 = conn.getresponse()
            b1 = json.loads(r1.read().decode("utf-8"))
            self.assertEqual(r1.status, 200)
            self.assertEqual(r1.getheader("Connection"), "keep-alive")
            self.assertIn("authorization_servers", b1)
            sock_fileno_1 = conn.sock.fileno()

            # Second request on the exact same TCP connection
            conn.request("GET", "/.well-known/oauth-authorization-server", headers={"Connection": "keep-alive"})
            r2 = conn.getresponse()
            b2 = json.loads(r2.read().decode("utf-8"))
            self.assertEqual(r2.status, 200)
            self.assertEqual(r2.getheader("Connection"), "keep-alive")
            self.assertIn("token_endpoint", b2)
            self.assertEqual(conn.sock.fileno(), sock_fileno_1, "HTTP/1.1 keep-alive must reuse the exact same socket")

            # Third request (forwarded POST /mcp tools/list) on the exact same TCP connection
            mcp_req = json.dumps({"jsonrpc": "2.0", "id": 99, "method": "tools/list", "params": {}}).encode("utf-8")
            conn.request(
                "POST",
                "/mcp",
                body=mcp_req,
                headers={"Content-Type": "application/json", "Connection": "keep-alive"},
            )
            r3 = conn.getresponse()
            b3 = json.loads(r3.read().decode("utf-8"))
            self.assertEqual(r3.status, 200)
            self.assertEqual(r3.getheader("Connection"), "keep-alive")
            self.assertIn("result", b3)
            self.assertEqual(conn.sock.fileno(), sock_fileno_1, "Forwarded /mcp POST must also preserve HTTP/1.1 keep-alive socket")
        finally:
            conn.close()

    def test_16_chunked_request_decoding_and_hop_by_hop_stripping(self):
        """Verify RFC 9112 Transfer-Encoding: chunked decoding and hop-by-hop header stripping across OAuth and /mcp."""
        import http.client

        def _encode_chunked(parts: list[bytes], with_ext: bool = False, trailer: bytes = b"") -> bytes:
            out = bytearray()
            for idx, part in enumerate(parts):
                ext = b";chunk-ext=val" if (with_ext and idx == 0) else b""
                out.extend(f"{len(part):x}".encode("ascii") + ext + b"\r\n" + part + b"\r\n")
            out.extend(b"0\r\n")
            if trailer:
                out.extend(trailer + b"\r\n")
            out.extend(b"\r\n")
            return bytes(out)

        conn = http.client.HTTPConnection("127.0.0.1", self.shield_port, timeout=5)
        try:
            # 1. Chunked POST /oauth/register (with chunk extension) on keep-alive socket
            reg_body = json.dumps({
                "client_name": "Gemini Chunked Connector",
                "redirect_uris": ["https://gemini.google.com/oauth/callback"],
            }).encode("utf-8")
            chunked_reg = _encode_chunked([reg_body[:24], reg_body[24:]], with_ext=True)
            conn.putrequest("POST", "/oauth/register")
            conn.putheader("Content-Type", "application/json")
            conn.putheader("Transfer-Encoding", "chunked")
            conn.putheader("Connection", "keep-alive")
            conn.endheaders()
            conn.send(chunked_reg)

            r_reg = conn.getresponse()
            b_reg = json.loads(r_reg.read().decode("utf-8"))
            self.assertEqual(r_reg.status, 201)
            self.assertEqual(r_reg.getheader("Connection"), "keep-alive")
            self.assertTrue(str(b_reg.get("client_id") or "").startswith("rs_client_"))
            sock_fileno = conn.sock.fileno()

            # 2. Chunked POST /mcp (initialize -> tools/list) on the EXACT SAME socket without Content-Length
            valid_chunked_tok = shield._sign_oauth_envelope(
                "rs_at",
                {
                    "client_id": b_reg["client_id"],
                    "scope": "mcp",
                    "expires_at": int(time.time()) + 3600,
                    "nonce": "chunked_keepalive",
                },
            )
            init_payload = json.dumps({
                "jsonrpc": "2.0",
                "id": 101,
                "method": "initialize",
                "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "Google", "version": "1.0"}},
            }).encode("utf-8")
            chunked_init = _encode_chunked([init_payload[:30], init_payload[30:90], init_payload[90:]], with_ext=True, trailer=b"X-Checksum: ok")
            conn.putrequest("POST", "/mcp")
            conn.putheader("Content-Type", "application/json")
            conn.putheader("Transfer-Encoding", "chunked")
            conn.putheader("Authorization", f"Bearer {valid_chunked_tok}")
            conn.putheader("Connection", "keep-alive")
            conn.endheaders()
            conn.send(chunked_init)

            r_init = conn.getresponse()
            b_init = json.loads(r_init.read().decode("utf-8"))
            self.assertEqual(r_init.status, 200)
            self.assertEqual(r_init.getheader("Connection"), "keep-alive")
            self.assertEqual(b_init.get("id"), 101)
            self.assertEqual(conn.sock.fileno(), sock_fileno, "Socket must remain open and synchronized after chunked POST /mcp")

            # Verify upstream received decoded Content-Length and NO Transfer-Encoding header
            last_call = self.upstream.calls[-1]
            self.assertEqual(last_call["method"], "initialize")
            self.assertEqual(last_call["transfer_encoding"], "", "Transfer-Encoding hop-by-hop header must be stripped before upstream")
            self.assertEqual(int(last_call["content_length"]), len(init_payload), "Upstream must receive exact decoded Content-Length")

            # 3. Follow-up chunked POST /mcp (tools/list) on the same socket
            list_payload = json.dumps({"jsonrpc": "2.0", "id": 102, "method": "tools/list", "params": {}}).encode("utf-8")
            chunked_list = _encode_chunked([list_payload[:18], list_payload[18:]])
            conn.putrequest("POST", "/mcp")
            conn.putheader("Content-Type", "application/json")
            conn.putheader("Transfer-Encoding", "chunked")
            conn.putheader("Connection", "keep-alive")
            conn.endheaders()
            conn.send(chunked_list)

            r_list = conn.getresponse()
            b_list = json.loads(r_list.read().decode("utf-8"))
            self.assertEqual(r_list.status, 200)
            self.assertEqual(b_list.get("id"), 102)
            self.assertIn("tools", b_list.get("result") or {})
            self.assertEqual(conn.sock.fileno(), sock_fileno)

            # 4. Malformed chunked request on /mcp must return 400 with Connection: close
            conn.putrequest("POST", "/mcp")
            conn.putheader("Content-Type", "application/json")
            conn.putheader("Transfer-Encoding", "chunked")
            conn.putheader("Connection", "keep-alive")
            conn.endheaders()
            conn.send(b"ZZZ_NOT_HEX\r\n{}\r\n0\r\n\r\n")

            r_bad = conn.getresponse()
            _ = r_bad.read()
            self.assertEqual(r_bad.status, 400)
            self.assertEqual(r_bad.getheader("Connection"), "close")
        finally:
            conn.close()

    def test_17_shield_handler_timeout_whiteboard_sharing_and_tailscale_fixed_url_preservation(self):
        """Verify 15s keep-alive timeout, whiteboard cache sharing for since_sig callers, runtime read-only log bookmark, and Tailscale FixedUrl preservation."""
        self.assertEqual(shield.ShieldHandler.timeout, 15)

        # 1. Whiteboard cache sharing even when since_sig is provided and outdated
        s_init = shield.build_studio_snapshot(self.data_root, self.tasks_root, self.wb_state_path)
        cur_rev = s_init.get("rev")
        self.assertTrue(cur_rev)
        s_outdated_caller = shield.build_studio_snapshot(self.data_root, self.tasks_root, self.wb_state_path, since_sig="rev_outdated_000")
        self.assertEqual(s_outdated_caller.get("rev"), cur_rev)
        self.assertFalse(s_outdated_caller.get("not_modified", False))

        # 2. Runtime tunnel log reading over 2500 lines trims in memory without creating .tmp files on disk when host side effects are active
        tmp_log = os.path.join(self.logs_dir, "bookmark-test.log")
        with open(tmp_log, "w", encoding="utf-8") as fh:
            for idx in range(2600):
                fh.write(f'{{"time":"2026-11-07T08:00:00Z","level":"INFO","msg":"line {idx}"}}\n')
        orig_size = os.path.getsize(tmp_log)
        prev_host_flag = shield._HOST_SIDE_EFFECTS_ENABLED
        try:
            shield._HOST_SIDE_EFFECTS_ENABLED = True
            kept_lines = shield.read_tunnel_log_incremental(tmp_log)
        finally:
            shield._HOST_SIDE_EFFECTS_ENABLED = prev_host_flag
        self.assertEqual(len(kept_lines), 2000)
        self.assertEqual(os.path.getsize(tmp_log), orig_size, "Runtime log reader must never rewrite or truncate locked log file on disk")
        leftover_tmps = [f for f in os.listdir(self.logs_dir) if f.startswith("bookmark-test.log.") and f.endswith(".tmp")]
        self.assertEqual(leftover_tmps, [])

        # 3. _guardian_check_public_tunnel must never overwrite user's configured fixed Tailscale URL
        from unittest import mock
        ts_state_file = os.path.join(self.data_root, "public-mcp-tunnel.json")
        fixed_ts_url = "https://thinkbook16pl.tail29988f.ts.net/mcp"
        with open(ts_state_file, "w", encoding="utf-8") as fh:
            json.dump({"Mode": "tailscale", "FixedUrl": fixed_ts_url, "Port": self.shield_port}, fh)
        with mock.patch.object(
            shield,
            "_probe_public_mcp_edge_health",
            return_value={"ok": False, "phase": "Offline", "rtt_ms": 0, "ingress_ip": ""},
        ), mock.patch("subprocess.run", return_value=mock.Mock(returncode=1)):
            chk1 = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
            self.assertEqual(chk1.get("action"), "debounce_hold")
            chk2 = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
            self.assertEqual(chk2.get("action"), "offline_persisted")
            with open(ts_state_file, "r", encoding="utf-8") as fh:
                after_saved = json.load(fh)
            self.assertEqual(after_saved.get("Mode"), "tailscale")
            self.assertEqual(after_saved.get("FixedUrl"), fixed_ts_url)

    def test_18_public_edge_health_probe_doh_filtering_and_rtt_classification(self):
        """Verify DoH IPv4 filtering (rejecting Tailscale 100.64/10 & Fake-IP 198.18/15), 8.0s default timeout, SNI probe classification, and proxy/cloudflared seams."""
        import inspect
        from unittest import mock

        # 1. Verify calibrated default timeout_sec = 8.0 and slow_threshold_ms = 2500
        sig = inspect.signature(shield._probe_public_mcp_edge_health)
        self.assertEqual(sig.parameters["timeout_sec"].default, 8.0)
        self.assertEqual(sig.parameters["slow_threshold_ms"].default, 2500)

        # 2. Verify DoH filtering rejects MagicDNS CGNAT (100.64.0.0/10), Clash Fake-IP (198.18.0.0/15), RFC1918, loopback, link-local
        for rejected_ip in (
            "100.85.42.19",
            "100.64.0.1",
            "100.127.255.254",
            "198.18.0.25",
            "198.19.255.250",
            "127.0.0.1",
            "10.0.0.8",
            "172.16.12.1",
            "192.168.1.100",
            "169.254.10.20",
        ):
            self.assertFalse(shield._is_public_edge_ipv4(rejected_ip), f"{rejected_ip} must be rejected as non-public")

        for public_ip in ("103.84.155.153", "104.16.132.229", "172.64.150.10"):
            self.assertTrue(shield._is_public_edge_ipv4(public_ip), f"{public_ip} must be accepted as public IPv4")

        with shield._PUBLIC_DOH_LOCK:
            shield._PUBLIC_DOH_CACHE.clear()

        mixed_doh_doc = {
            "Status": 0,
            "Answer": [
                {"name": "node.tail29988f.ts.net", "type": 1, "data": "100.85.42.19"},
                {"name": "node.tail29988f.ts.net", "type": 1, "data": "198.18.0.25"},
                {"name": "node.tail29988f.ts.net", "type": 28, "data": "2606:4700::1"},
                {"name": "node.tail29988f.ts.net", "type": 1, "data": "103.84.155.153"},
                {"name": "node.tail29988f.ts.net", "type": 1, "data": "104.16.132.229"},
            ],
        }
        with mock.patch.object(shield, "_fetch_doh_json", return_value=mixed_doh_doc) as mock_doh:
            resolved = shield._resolve_public_edge_ipv4s("node.tail29988f.ts.net", data_root=self.data_root)
            self.assertEqual(resolved, ["103.84.155.153", "104.16.132.229"])
            self.assertEqual(mock_doh.call_count, 1)
            # Second lookup hits 300s in-memory _PUBLIC_DOH_CACHE without network call
            resolved_cached = shield._resolve_public_edge_ipv4s("node.tail29988f.ts.net", data_root=self.data_root)
            self.assertEqual(resolved_cached, ["103.84.155.153", "104.16.132.229"])
            self.assertEqual(mock_doh.call_count, 1)

        # 3. If DoH returns ONLY non-public MagicDNS/Fake-IP records, must return Offline (doh_unresolved) and NEVER dial 100.x
        poisoned_doh = {
            "Status": 0,
            "Answer": [
                {"name": "poisoned.tail29988f.ts.net", "type": 1, "data": "100.85.1.2"},
                {"name": "poisoned.tail29988f.ts.net", "type": 1, "data": "198.18.1.9"},
            ],
        }
        with mock.patch.object(shield, "resolve_effective_outbound_proxy_env", return_value={"Mode": "direct", "ProxyUrl": "", "Env": {}}), \
             mock.patch.object(shield, "_fetch_doh_json", return_value=poisoned_doh), \
             mock.patch("socket.create_connection") as mock_conn:
            p_poison = shield._probe_public_mcp_edge_health("https://poisoned.tail29988f.ts.net/mcp", data_root=self.data_root)
            self.assertFalse(p_poison["ok"])
            self.assertEqual(p_poison["phase"], "Offline")
            self.assertEqual(p_poison["reason"], "doh_unresolved")
            self.assertEqual(p_poison["ingress_ip"], "")
            mock_conn.assert_not_called()

        # 4. Classify Online (<= 2500ms) vs Degraded (> 2500ms) vs Offline over raw TCP + TLS SNI
        class _FakeTlsSock:
            def __init__(self, status_line: bytes):
                self._resp = status_line
                self.sent = b""
                self.closed = False

            def settimeout(self, _t):
                pass

            def sendall(self, data: bytes):
                self.sent += data

            def recv(self, _n: int) -> bytes:
                out, self._resp = self._resp, b""
                return out

            def close(self):
                self.closed = True

        sni_seen = []

        class _FakeSslCtx:
            def __init__(self, status_line: bytes):
                self._status_line = status_line

            def wrap_socket(self, _raw_sock, server_hostname=None):
                sni_seen.append(server_hostname)
                return _FakeTlsSock(self._status_line)

        with mock.patch.object(shield, "_resolve_public_edge_ipv4s", return_value=["103.84.155.153"]), \
             mock.patch("socket.create_connection", return_value=mock.MagicMock()) as m_sock, \
             mock.patch("ssl.create_default_context", return_value=_FakeSslCtx(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{}")), \
             mock.patch("time.perf_counter", side_effect=[100.0, 100.01, 100.02, 100.05, 100.08, 100.18]):
            res_online = shield._probe_public_mcp_edge_health("https://node.tail29988f.ts.net/mcp", data_root=self.data_root)
            self.assertTrue(res_online["ok"])
            self.assertEqual(res_online["phase"], "Online")
            self.assertEqual(res_online["rtt_ms"], 180)
            self.assertEqual(res_online["ingress_ip"], "103.84.155.153")
            self.assertEqual(sni_seen[-1], "node.tail29988f.ts.net")
            m_sock.assert_called_once()
            self.assertEqual(m_sock.call_args[0][0], ("103.84.155.153", 443))

        # Cellular hotspot 4.125s RTT (> 2500ms) -> Degraded (not Offline!)
        with mock.patch.object(shield, "_resolve_public_edge_ipv4s", return_value=["103.84.155.153"]), \
             mock.patch("socket.create_connection", return_value=mock.MagicMock()), \
             mock.patch("ssl.create_default_context", return_value=_FakeSslCtx(b"HTTP/1.1 401 Unauthorized\r\n\r\n")), \
             mock.patch("time.perf_counter", side_effect=[200.0, 200.125, 200.5, 201.25, 202.0, 204.125]):
            res_deg = shield._probe_public_mcp_edge_health("https://node.tail29988f.ts.net/mcp", data_root=self.data_root)
            self.assertTrue(res_deg["ok"])
            self.assertEqual(res_deg["phase"], "Degraded")
            self.assertEqual(res_deg["rtt_ms"], 4125)
            self.assertEqual(res_deg["ingress_ip"], "103.84.155.153")

        # Cloudflare 530 / Tunnel offline across both candidate IPs -> Offline
        with mock.patch.object(shield, "_resolve_public_edge_ipv4s", return_value=["104.16.1.1", "104.16.1.2"]), \
             mock.patch("socket.create_connection", return_value=mock.MagicMock()) as m_sock_off, \
             mock.patch("ssl.create_default_context", return_value=_FakeSslCtx(b"HTTP/1.1 530 Origin DNS Error\r\n\r\n")):
            res_off = shield._probe_public_mcp_edge_health("https://dead-tunnel.trycloudflare.com/mcp", data_root=self.data_root)
            self.assertFalse(res_off["ok"])
            self.assertEqual(res_off["phase"], "Offline")
            self.assertEqual(res_off["rtt_ms"], 0)
            self.assertEqual(res_off["ingress_ip"], "")
            self.assertEqual(m_sock_off.call_count, 2)

        # 5. Verify runtime auto-discovery of local proxy port 7897 when base_env is None, and bin/cloudflared.exe lookup
        with mock.patch.dict(os.environ, {"HTTP_PROXY": "", "HTTPS_PROXY": "", "ALL_PROXY": "", "http_proxy": "", "https_proxy": "", "all_proxy": ""}, clear=False), \
             mock.patch.object(shield, "_is_local_proxy_port_open", side_effect=lambda u, timeout_sec=0.15: u == "http://127.0.0.1:7897"):
            auto_proxy = shield.resolve_effective_outbound_proxy_env(
                data_root=self.data_root,
                base_env=None,
                system_proxy_override="",
                outbound_proxy_setting="auto",
            )
            self.assertEqual(auto_proxy["Mode"], "proxy")
            self.assertEqual(auto_proxy["ProxyUrl"], "http://127.0.0.1:7897")

        cf_src = inspect.getsource(shield._spawn_cloudflared_quick_tunnel)
        self.assertIn('os.path.join(repo_root, "bin", "cloudflared.exe")', cf_src)

    def test_19_guardian_public_tunnel_debounce_circuit_breaker_lock_yield_and_no_churn(self):
        """Verify 2-strike debounce, 3-strike reconnect circuit breaker, StartTicks manual-reset, lock yield, zero Online file churn, and strict FixedUrl stability."""
        from unittest import mock

        ts_state_file = os.path.join(self.data_root, "public-mcp-tunnel.json")
        fixed_ts_url = "https://thinkbook16pl.tail29988f.ts.net/mcp"
        initial_doc = {
            "Mode": "tailscale",
            "ProcessId": -1,
            "StartTicks": 639300000000000001,
            "FixedUrl": fixed_ts_url,
            "TailscalePath": "tailscale.exe",
            "Port": self.shield_port,
            "ProfileId": "prof_main",
            "FallbackFrom": "",
        }
        with open(ts_state_file, "w", encoding="utf-8") as fh:
            json.dump(initial_doc, fh, ensure_ascii=False, indent=2)

        # 1. Manual Always Wins: holding public-mcp-tunnel.lock makes _guardian_check_public_tunnel yield immediately in 0ms
        with shield._try_acquire_public_tunnel_file_lock(self.data_root) as held:
            self.assertTrue(held)
            t0 = time.perf_counter()
            with mock.patch.object(shield, "_probe_public_mcp_edge_health") as m_probe_locked:
                yield_res = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
                self.assertEqual(yield_res["action"], "lock_busy_yielded")
                self.assertLess(time.perf_counter() - t0, 0.25)
                m_probe_locked.assert_not_called()

        # 2. First Online verification writes telemetry; steady Online does NOT churn file mtime; lock is NEVER held during probe
        lock_free_during_probe = []

        def _online_probe(url, timeout_sec=8.0, slow_threshold_ms=2500, data_root=""):
            with shield._try_acquire_public_tunnel_file_lock(self.data_root) as can_lock:
                lock_free_during_probe.append(can_lock)
            return {"ok": True, "phase": "Online", "rtt_ms": 142, "ingress_ip": "103.84.155.153"}

        with mock.patch.object(shield, "_probe_public_mcp_edge_health", side_effect=_online_probe):
            res_on_1 = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
            self.assertEqual(res_on_1["action"], "healthy_online")
            self.assertTrue(res_on_1["wrote_state"])
            self.assertEqual(lock_free_during_probe, [True], "public-mcp-tunnel.lock must NEVER be held during network probe")

            saved_on = json.loads(pathlib.Path(ts_state_file).read_text(encoding="utf-8"))
            self.assertEqual(saved_on["Mode"], "tailscale")
            self.assertEqual(saved_on["FixedUrl"], fixed_ts_url)
            self.assertEqual(saved_on["Url"], fixed_ts_url)
            self.assertEqual(saved_on["StartTicks"], 639300000000000001)
            self.assertEqual(saved_on["ProfileId"], "prof_main")
            self.assertEqual(saved_on["HealthPhase"], "Online")
            self.assertTrue(saved_on["Running"])
            self.assertEqual(saved_on["Status"], "在线")
            self.assertEqual(saved_on["PublicRttMs"], 142)
            self.assertEqual(saved_on["VerifiedIngressIp"], "103.84.155.153")
            self.assertTrue(saved_on["LastCheckedUtc"])

            mtime_steady_1 = os.stat(ts_state_file).st_mtime_ns
            time.sleep(0.05)
            # Non-forced call within 60s Online schedule is throttled
            res_throttled = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=False)
            self.assertEqual(res_throttled["action"], "throttled")
            # Forced steady Online check does NOT rewrite file (0 mtime churn for PowerShell UI cache!)
            res_on_2 = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
            self.assertEqual(res_on_2["action"], "healthy_online")
            self.assertFalse(res_on_2["wrote_state"])
            self.assertEqual(os.stat(ts_state_file).st_mtime_ns, mtime_steady_1)

        # 3. Degraded 2-strike debounce (never restarts tunnel)
        with mock.patch.object(
            shield,
            "_probe_public_mcp_edge_health",
            return_value={"ok": True, "phase": "Degraded", "rtt_ms": 3850, "ingress_ip": "103.84.155.153"},
        ), mock.patch("subprocess.run") as m_deg_run:
            deg_1 = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
            self.assertEqual(deg_1["action"], "degraded_debounce_hold")
            self.assertEqual(json.loads(pathlib.Path(ts_state_file).read_text(encoding="utf-8"))["HealthPhase"], "Online")

            deg_2 = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
            self.assertEqual(deg_2["action"], "degraded_persisted")
            saved_deg = json.loads(pathlib.Path(ts_state_file).read_text(encoding="utf-8"))
            self.assertEqual(saved_deg["HealthPhase"], "Degraded")
            self.assertTrue(saved_deg["Running"])
            self.assertEqual(saved_deg["Status"], "偏慢")
            self.assertEqual(saved_deg["PublicRttMs"], 3850)
            self.assertEqual(saved_deg["FixedUrl"], fixed_ts_url)
            m_deg_run.assert_not_called()

        # 4. Offline 2-strike debounce + 3-strike reconnect circuit breaker + strict FixedUrl preservation (never cloudflared_quick!)
        with mock.patch.object(
            shield,
            "_probe_public_mcp_edge_health",
            return_value={"ok": False, "phase": "Offline", "rtt_ms": 0, "ingress_ip": ""},
        ), mock.patch("subprocess.run", return_value=mock.Mock(returncode=1)) as m_ts_run, \
             mock.patch.object(shield, "_spawn_cloudflared_quick_tunnel") as m_cf_quick:
            # Strike 1: debounce hold (file stays Degraded/Running=True, 0 subprocesses)
            off_1 = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
            self.assertEqual(off_1["action"], "debounce_hold")
            self.assertEqual(off_1["fail_streak"], 1)
            self.assertEqual(m_ts_run.call_count, 0)
            self.assertEqual(json.loads(pathlib.Path(ts_state_file).read_text(encoding="utf-8"))["HealthPhase"], "Degraded")

            # Strike 2: confirmed Offline -> persists Offline + Reconnect Attempt #1
            off_2 = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
            self.assertEqual(off_2["action"], "offline_persisted")
            self.assertEqual(off_2["reconnect_attempts"], 1)
            self.assertFalse(off_2["tripped"])
            self.assertEqual(m_ts_run.call_count, 1)
            saved_off = json.loads(pathlib.Path(ts_state_file).read_text(encoding="utf-8"))
            self.assertEqual(saved_off["Mode"], "tailscale")
            self.assertEqual(saved_off["FixedUrl"], fixed_ts_url)
            self.assertEqual(saved_off["Url"], fixed_ts_url)
            self.assertEqual(saved_off["HealthPhase"], "Offline")
            self.assertFalse(saved_off["Running"])
            self.assertEqual(saved_off["Status"], "离线")
            self.assertEqual(saved_off["PublicRttMs"], 0)
            self.assertEqual(saved_off["VerifiedIngressIp"], "")

            # Reconnect Attempt #2
            off_3 = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
            self.assertEqual(off_3["reconnect_attempts"], 2)
            self.assertFalse(off_3["tripped"])
            self.assertEqual(m_ts_run.call_count, 2)

            # Reconnect Attempt #3 -> Circuit Breaker Tripped!
            off_4 = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
            self.assertEqual(off_4["action"], "circuit_breaker_tripped")
            self.assertEqual(off_4["reconnect_attempts"], 3)
            self.assertTrue(off_4["tripped"])
            self.assertEqual(m_ts_run.call_count, 3)

            # Subsequent checks while tripped: ZERO further subprocess spawns and NEVER downgrades to cloudflared_quick!
            off_5 = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=True)
            self.assertEqual(off_5["action"], "circuit_breaker_tripped")
            self.assertEqual(m_ts_run.call_count, 3)
            m_cf_quick.assert_not_called()
            self.assertEqual(json.loads(pathlib.Path(ts_state_file).read_text(encoding="utf-8"))["FixedUrl"], fixed_ts_url)

        # 5. StartTicks Manual-Reconnect Reset: updating StartTicks immediately clears tripped/backoff even with force=False!
        manual_reconnect_doc = dict(initial_doc)
        manual_reconnect_doc["StartTicks"] = 639300000000999999
        with open(ts_state_file, "w", encoding="utf-8") as fh:
            json.dump(manual_reconnect_doc, fh, ensure_ascii=False, indent=2)

        with mock.patch.object(
            shield,
            "_probe_public_mcp_edge_health",
            return_value={"ok": True, "phase": "Online", "rtt_ms": 210, "ingress_ip": "103.84.155.153"},
        ):
            # force=False proves the 180s tripped backoff was immediately cleared by StartTicks change!
            recovered = shield._guardian_check_public_tunnel(self.data_root, listen_port=self.shield_port, force=False)
            self.assertEqual(recovered["action"], "healthy_online")
            with shield._PUBLIC_TUNNEL_GUARD_LOCK:
                self.assertEqual(shield._PUBLIC_TUNNEL_GUARD_STATE["fail_streak"], 0)
                self.assertEqual(shield._PUBLIC_TUNNEL_GUARD_STATE["reconnect_attempts"], 0)
                self.assertFalse(shield._PUBLIC_TUNNEL_GUARD_STATE["tripped"])
            saved_rec = json.loads(pathlib.Path(ts_state_file).read_text(encoding="utf-8"))
            self.assertEqual(saved_rec["HealthPhase"], "Online")
            self.assertTrue(saved_rec["Running"])
            self.assertEqual(saved_rec["Status"], "在线")
            self.assertEqual(saved_rec["FixedUrl"], fixed_ts_url)

    def test_20_host_maintenance_async_tunnel_worker_never_blocks_caller(self):
        """Verify _run_host_maintenance dispatches public tunnel check asynchronously on a non-blocking daemon thread."""
        from unittest import mock

        entered = threading.Event()
        release = threading.Event()
        call_count = []

        def _slow_tunnel_check(data_root="", listen_port=8766, force=False):
            call_count.append(data_root)
            entered.set()
            release.wait(timeout=3.0)
            return {"ok": True, "action": "healthy_online"}

        prev_flag = shield._HOST_SIDE_EFFECTS_ENABLED
        try:
            shield._HOST_SIDE_EFFECTS_ENABLED = True
            with mock.patch.object(shield, "cold_start_pending_hosts", return_value=None), \
                 mock.patch.object(shield.DesktopAppBridge, "tick", return_value={"ok": True}), \
                 mock.patch.object(shield, "_guardian_check_public_tunnel", side_effect=_slow_tunnel_check):
                t0 = time.perf_counter()
                shield._run_host_maintenance(self.wb_state_path, self.tasks_root)
                caller_elapsed = time.perf_counter() - t0
                self.assertLess(caller_elapsed, 0.2, "_run_host_maintenance must return immediately without blocking on tunnel check")
                self.assertTrue(entered.wait(timeout=2.0), "Async daemon worker must enter _guardian_check_public_tunnel")

                # Second call while first worker holds _PUBLIC_TUNNEL_WORKER_LOCK must skip spawning duplicate worker
                spawned_second = shield._trigger_public_tunnel_guardian_async(data_root=self.data_root)
                self.assertFalse(spawned_second)
                self.assertEqual(len(call_count), 1)
                release.set()

                deadline = time.time() + 2.0
                while shield._PUBLIC_TUNNEL_WORKER_LOCK.locked() and time.time() < deadline:
                    time.sleep(0.02)
                self.assertFalse(shield._PUBLIC_TUNNEL_WORKER_LOCK.locked())
        finally:
            release.set()
            shield._HOST_SIDE_EFFECTS_ENABLED = prev_flag

    def test_21_post_mcp_expired_oauth_token_401_challenge_and_client_persistence(self):
        """Verify POST /mcp challenges expired/invalid rs_at tokens with 401 + WWW-Authenticate while allowing valid rs_at & loopback, plus _OAUTH_CLIENTS disk persistence."""
        import base64
        import hashlib
        import http.client
        import urllib.error
        import urllib.parse

        base = f"http://127.0.0.1:{self.shield_port}"
        tunnel_host = "thinkbook16pl.tail29988f.ts.net"
        fwd_headers = {
            "X-Forwarded-Proto": "https",
            "X-Forwarded-Host": tunnel_host,
            "Content-Type": "application/json",
        }
        mcp_body = json.dumps({"jsonrpc": "2.0", "id": "auth-check-1", "method": "tools/list", "params": {}}).encode("utf-8")

        # 1. Local loopback POST /mcp without Authorization -> 200 OK
        local_resp = self._post_json("/mcp", {"jsonrpc": "2.0", "id": "loc-1", "method": "tools/list", "params": {}})
        self.assertIn("tools", local_resp.get("result") or {})

        # 2. Public forwarded POST /mcp without Authorization -> 401 + RFC 9728 WWW-Authenticate challenge
        unauth_pub_req = urllib.request.Request(f"{base}/mcp", data=mcp_body, headers=fwd_headers, method="POST")
        with self.assertRaises(urllib.error.HTTPError) as unauth_err:
            urllib.request.urlopen(unauth_pub_req, timeout=3)
        self.assertEqual(unauth_err.exception.code, 401)
        self.assertIn("resource_metadata=", unauth_err.exception.headers.get("WWW-Authenticate") or "")
        unauth_err.exception.close()

        # 3. Expired Bearer rs_at... on POST /mcp -> 401 + WWW-Authenticate + oauth-shim.log event, without breaking HTTP/1.1 keep-alive!
        expired_tok = shield._sign_oauth_envelope(
            "rs_at",
            {"client_id": "rs_client_exp", "scope": "mcp", "expires_at": int(time.time()) - 120, "nonce": "exp1"},
        )
        valid_tok = shield._sign_oauth_envelope(
            "rs_at",
            {"client_id": "rs_client_exp", "scope": "mcp", "expires_at": int(time.time()) + 3600, "nonce": "val1"},
        )
        upstream_before = len(self.upstream.calls)

        conn = http.client.HTTPConnection("127.0.0.1", self.shield_port, timeout=5)
        try:
            conn.request(
                "POST",
                "/mcp",
                body=mcp_body,
                headers={
                    **fwd_headers,
                    "Authorization": f"Bearer {expired_tok}",
                    "Connection": "keep-alive",
                },
            )
            r_exp = conn.getresponse()
            exp_payload = json.loads(r_exp.read().decode("utf-8"))
            self.assertEqual(r_exp.status, 401)
            self.assertEqual(exp_payload.get("error"), "invalid_token")
            www_auth = r_exp.getheader("WWW-Authenticate") or ""
            self.assertIn('Bearer realm="mcp"', www_auth)
            self.assertIn(f'resource_metadata="https://{tunnel_host}/.well-known/oauth-protected-resource"', www_auth)
            self.assertEqual(len(self.upstream.calls), upstream_before, "Expired rs_at token must NOT forward to upstream")
            sock_fn = conn.sock.fileno()

            # Retry immediately on the EXACT SAME keep-alive socket with refreshed valid rs_at token -> 200 OK!
            conn.request(
                "POST",
                "/mcp",
                body=mcp_body,
                headers={
                    **fwd_headers,
                    "Authorization": f"Bearer {valid_tok}",
                    "Connection": "keep-alive",
                },
            )
            r_ok = conn.getresponse()
            ok_payload = json.loads(r_ok.read().decode("utf-8"))
            self.assertEqual(r_ok.status, 200)
            self.assertIn("tools", ok_payload.get("result") or {})
            self.assertEqual(conn.sock.fileno(), sock_fn, "401 challenge must drain request body so keep-alive socket stays reusable")
        finally:
            conn.close()

        # Verify tampered rs_at token also challenges 401, and post_mcp_token_expired was logged to oauth-shim.log
        tampered_req = urllib.request.Request(
            f"{base}/mcp",
            data=mcp_body,
            headers={**fwd_headers, "Authorization": "Bearer rs_at.tampered.signature"},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as tamp_err:
            urllib.request.urlopen(tampered_req, timeout=3)
        self.assertEqual(tamp_err.exception.code, 401)
        tamp_err.exception.close()

        oauth_log_path = os.path.join(self.logs_dir, "oauth-shim.log")
        self.assertTrue(os.path.isfile(oauth_log_path))
        oauth_log_txt = pathlib.Path(oauth_log_path).read_text(encoding="utf-8")
        self.assertIn("post_mcp_token_expired", oauth_log_txt)

        # 4. Dynamic client registration persists to oauth-clients.json and lazy-reloads across _OAUTH_CLIENTS reset
        reg_redirect = "https://claude.ai/api/mcp/auth_callback"
        reg_req = urllib.request.Request(
            f"{base}/oauth/register",
            data=json.dumps({"client_name": "Claude Persistent Connector", "redirect_uris": [reg_redirect]}).encode("utf-8"),
            headers=fwd_headers,
            method="POST",
        )
        with urllib.request.urlopen(reg_req, timeout=3) as reg_resp:
            self.assertEqual(reg_resp.status, 201)
            reg_doc = json.loads(reg_resp.read().decode("utf-8"))
            persisted_cid = reg_doc["client_id"]

        clients_disk_path = os.path.join(self.data_root, "oauth-clients.json")
        self.assertTrue(os.path.isfile(clients_disk_path))
        disk_clients = json.loads(pathlib.Path(clients_disk_path).read_text(encoding="utf-8"))
        self.assertIn(persisted_cid, disk_clients)
        self.assertEqual(disk_clients[persisted_cid]["redirect_uris"], [reg_redirect])

        # Simulate :8766 process restart by clearing in-memory _OAUTH_CLIENTS
        with shield._OAUTH_LOCK:
            shield._OAUTH_CLIENTS.clear()

        # Authorize WITHOUT passing redirect_uri on query string -> must lazy-load oauth-clients.json and redirect 302 to reg_redirect!
        verifier = "persist_pkce_verifier_0123456789_abcdefghijklmnopqrstuvwxyz"
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")

        class _NoRedir(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None

        opener = urllib.request.build_opener(_NoRedir())
        qs = urllib.parse.urlencode({
            "response_type": "code",
            "client_id": persisted_cid,
            "state": "st_persist",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        })
        with self.assertRaises(urllib.error.HTTPError) as redir_exc:
            opener.open(urllib.request.Request(f"{base}/oauth/authorize?{qs}", headers=fwd_headers, method="GET"), timeout=3)
        self.assertEqual(redir_exc.exception.code, 302)
        self.assertTrue((redir_exc.exception.headers.get("Location") or "").startswith(reg_redirect + "?"))
        redir_exc.exception.close()

    def test_22_local_control_plane_security_guard_blocks_public_tunnel_while_preserving_mcp_oauth(self):
        """Verify /studio/*, /__studio__/*, and /web-bridge/* reject public-tunnel headers, non-loopback Host, and non-loopback peers with 403 while /mcp and OAuth remain public."""
        import http.client
        import urllib.error
        import urllib.parse

        base = f"http://127.0.0.1:{self.shield_port}"
        tunnel_host = "thinkbook16pl.tail29988f.ts.net"

        def _expect_403(method: str, path: str, headers: dict, body: bytes | None = None) -> dict:
            conn = http.client.HTTPConnection("127.0.0.1", self.shield_port, timeout=3)
            try:
                put_host = "Host" in headers
                conn.putrequest(method, path, skip_host=put_host)
                for hk, hv in headers.items():
                    conn.putheader(hk, hv)
                if body is not None and "Content-Length" not in headers:
                    conn.putheader("Content-Length", str(len(body)))
                conn.endheaders(body)
                resp = conn.getresponse()
                raw = resp.read()
                self.assertEqual(resp.status, 403, f"Expected 403 on {method} {path} with {headers}, got {resp.status}: {raw!r}")
                return json.loads(raw.decode("utf-8")) if raw else {}
            finally:
                conn.close()

        # 1. Reverse-proxy / public-tunnel headers MUST trigger 403 forbidden_public_tunnel across all control-plane endpoints
        tunnel_header_cases = [
            {"X-Forwarded-For": "203.0.113.42"},
            {"X-Forwarded-Host": tunnel_host},
            {"X-Forwarded-Proto": "https"},
            {"Tailscale-Funnel-Request": "?1"},
            {"Cf-Connecting-Ip": "198.51.100.7"},
            {"Cf-Ray": "89abcdef01234567-HKG"},
            {"Forwarded": "for=203.0.113.42;proto=https"},
        ]
        protected_routes = [
            ("GET", "/studio/snapshot", None),
            ("GET", "/__studio__/snapshot", None),
            ("POST", "/studio/action", b'{"action":"set_alias","session_key":"tsk_1","title":"x"}'),
            ("GET", "/studio/events?max_events=1", None),
            ("GET", "/web-bridge/state", None),
            ("POST", "/web-bridge/poll", b'{"browser":"Chrome","tabs":[]}'),
        ]
        for hdr_case in tunnel_header_cases:
            for method, path, body in protected_routes:
                err_doc = _expect_403(method, path, hdr_case, body=body)
                self.assertEqual(err_doc.get("error"), "forbidden_public_tunnel")

        # 2. Non-loopback Host header (even without X-Forwarded-* headers!) MUST trigger 403 forbidden_host
        for bad_host in (tunnel_host, f"{tunnel_host}:443", "quick-demo.trycloudflare.com"):
            for method, path, body in protected_routes:
                err_doc = _expect_403(method, path, {"Host": bad_host}, body=body)
                self.assertEqual(err_doc.get("error"), "forbidden_host")

        # HEAD and DELETE on control-plane routes are also guarded
        _expect_403("HEAD", "/studio/snapshot", {"Tailscale-Funnel-Request": "?1"})
        del_err = _expect_403("DELETE", "/studio/action", {"Cf-Connecting-Ip": "198.51.100.7"})
        self.assertEqual(del_err.get("error"), "forbidden_public_tunnel")

        # Loopback Host variants ([::1]:port, localhost:port, 127.0.0.1:port) ARE allowed
        for ok_host in (f"127.0.0.1:{self.shield_port}", f"localhost:{self.shield_port}", f"[::1]:{self.shield_port}"):
            conn_ok = http.client.HTTPConnection("127.0.0.1", self.shield_port, timeout=3)
            try:
                conn_ok.putrequest("GET", "/studio/snapshot", skip_host=True)
                conn_ok.putheader("Host", ok_host)
                conn_ok.endheaders()
                r_ok = conn_ok.getresponse()
                snap_ok = json.loads(r_ok.read().decode("utf-8"))
                self.assertEqual(r_ok.status, 200)
                self.assertTrue(snap_ok.get("ok"))
            finally:
                conn_ok.close()

        # 3. Non-loopback client_address[0] (e.g. Tailscale tailnet peer 100.85.12.34) MUST trigger 403 forbidden_non_loopback
        captured_non_loopback = []
        dummy_handler = shield.ShieldHandler.__new__(shield.ShieldHandler)
        dummy_handler.client_address = ("100.85.12.34", 54321)
        dummy_handler.headers = {}
        dummy_handler.server = self.shield_srv
        dummy_handler._send_json = lambda code, payload, **kw: captured_non_loopback.append((code, payload))
        allowed = dummy_handler._check_local_control_plane_guard(
            urllib.parse.urlsplit("/studio/snapshot"),
            require_studio_token=True,
        )
        self.assertFalse(allowed)
        self.assertEqual(captured_non_loopback, [(403, {"ok": False, "error": "forbidden_non_loopback"})])

        # 4. Meanwhile, public /mcp and /.well-known/oauth-protected-resource MUST continue serving normally through the tunnel!
        pub_headers = {
            "Host": tunnel_host,
            "X-Forwarded-Proto": "https",
            "X-Forwarded-Host": tunnel_host,
            "X-Forwarded-For": "203.0.113.42",
            "Tailscale-Funnel-Request": "?1",
        }
        pr_req = urllib.request.Request(f"{base}/.well-known/oauth-protected-resource", headers=pub_headers, method="GET")
        with urllib.request.urlopen(pr_req, timeout=3) as pr_resp:
            self.assertEqual(pr_resp.status, 200)
            pr_doc = json.loads(pr_resp.read().decode("utf-8"))
            self.assertEqual(pr_doc.get("resource"), f"https://{tunnel_host}/mcp")

        head_mcp_req = urllib.request.Request(f"{base}/mcp", headers=pub_headers, method="HEAD")
        with self.assertRaises(urllib.error.HTTPError) as head_err:
            urllib.request.urlopen(head_mcp_req, timeout=3)
        self.assertEqual(head_err.exception.code, 401)
        self.assertIn("WWW-Authenticate", head_err.exception.headers)
        head_err.exception.close()

        unauth_mcp_req = urllib.request.Request(
            f"{base}/mcp",
            data=json.dumps({"jsonrpc": "2.0", "id": "pub-unauth-1", "method": "tools/list", "params": {}}).encode("utf-8"),
            headers={**pub_headers, "Content-Type": "application/json"},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as unauth_mcp_err:
            urllib.request.urlopen(unauth_mcp_req, timeout=3)
        self.assertEqual(unauth_mcp_err.exception.code, 401)
        self.assertIn(
            f'resource_metadata="https://{tunnel_host}/.well-known/oauth-protected-resource"',
            unauth_mcp_err.exception.headers.get("WWW-Authenticate") or "",
        )
        unauth_mcp_err.exception.close()

        pub_valid_tok = shield._sign_oauth_envelope(
            "rs_at",
            {"client_id": "rs_client_pub", "scope": "mcp", "expires_at": int(time.time()) + 3600, "nonce": "pub1"},
        )
        mcp_req = urllib.request.Request(
            f"{base}/mcp",
            data=json.dumps({"jsonrpc": "2.0", "id": "pub-ok-1", "method": "tools/list", "params": {}}).encode("utf-8"),
            headers={**pub_headers, "Content-Type": "application/json", "Authorization": f"Bearer {pub_valid_tok}"},
            method="POST",
        )
        with urllib.request.urlopen(mcp_req, timeout=3) as mcp_resp:
            self.assertEqual(mcp_resp.status, 200)
            mcp_doc = json.loads(mcp_resp.read().decode("utf-8"))
            self.assertIn("tools", mcp_doc.get("result") or {})

    def test_23_studio_local_token_enforcement_query_and_header_cors_and_web_bridge_exemption(self):
        """Verify studio-local.token & RELAYSTUDIO_LOCAL_TOKEN enforcement on /studio/* (header + query param + WebView2 CORS) while exempting /web-bridge/*."""
        import urllib.error

        base = f"http://127.0.0.1:{self.shield_port}"
        tok_file = os.path.join(self.data_root, "studio-local.token")
        secret_tok = "rs_local_tok_9f8e7d6c5b4a3210"

        # Write studio-local.token with UTF-8 BOM + trailing newline to verify PowerShell-compatible reading
        with open(tok_file, "wb") as fh:
            fh.write(b"\xef\xbb\xbf" + secret_tok.encode("utf-8") + b"\r\n")

        # 1. OPTIONS preflight from WebView2 virtual host MUST return 204 BEFORE auth and expose X-Studio-Token, Last-Event-ID
        for wv_origin in ("https://studio.relaystudio.local", "http://studio.relaystudio.local"):
            opt_req = urllib.request.Request(
                f"{base}/studio/action",
                headers={
                    "Origin": wv_origin,
                    "Access-Control-Request-Method": "POST",
                    "Access-Control-Request-Headers": "Content-Type, X-Studio-Token",
                },
                method="OPTIONS",
            )
            with urllib.request.urlopen(opt_req, timeout=3) as opt_resp:
                self.assertEqual(opt_resp.status, 204)
                self.assertEqual(opt_resp.headers.get("Access-Control-Allow-Origin"), wv_origin)
                allow_hdrs = opt_resp.headers.get("Access-Control-Allow-Headers") or ""
                self.assertIn("X-Studio-Token", allow_hdrs)
                self.assertIn("Last-Event-ID", allow_hdrs)

        evil_opt = urllib.request.Request(
            f"{base}/studio/action",
            headers={"Origin": "https://studio.relaystudio.local.evil.invalid"},
            method="OPTIONS",
        )
        with urllib.request.urlopen(evil_opt, timeout=3) as evil_resp:
            self.assertIsNone(evil_resp.headers.get("Access-Control-Allow-Origin"))

        # 2. /studio/* without token or with wrong token -> 403 invalid_studio_token
        for bad_req in (
            urllib.request.Request(f"{base}/studio/snapshot", method="GET"),
            urllib.request.Request(f"{base}/studio/snapshot", headers={"X-Studio-Token": "wrong_token"}, method="GET"),
            urllib.request.Request(f"{base}/studio/events?max_events=1", method="GET"),
            urllib.request.Request(
                f"{base}/studio/action",
                data=b'{"action":"set_alias","session_key":"tsk_x","title":"y"}',
                headers={"Content-Type": "application/json"},
                method="POST",
            ),
        ):
            with self.assertRaises(urllib.error.HTTPError) as tok_err:
                urllib.request.urlopen(bad_req, timeout=3)
            self.assertEqual(tok_err.exception.code, 403)
            err_body = json.loads(tok_err.exception.read().decode("utf-8"))
            self.assertEqual(err_body.get("error"), "invalid_studio_token")
            tok_err.exception.close()

        # 3. /studio/* with X-Studio-Token header + Origin: https://studio.relaystudio.local -> 200 OK + CORS echo
        hdr_ok_req = urllib.request.Request(
            f"{base}/studio/snapshot",
            headers={"X-Studio-Token": secret_tok, "Origin": "https://studio.relaystudio.local"},
            method="GET",
        )
        with urllib.request.urlopen(hdr_ok_req, timeout=3) as hdr_ok_resp:
            self.assertEqual(hdr_ok_resp.status, 200)
            self.assertEqual(hdr_ok_resp.headers.get("Access-Control-Allow-Origin"), "https://studio.relaystudio.local")
            self.assertTrue(json.loads(hdr_ok_resp.read().decode("utf-8")).get("ok"))

        # 4. /studio/events and /studio/snapshot with ?studio_token= query param (for browser EventSource) -> 200 OK
        ev_ok_req = urllib.request.Request(
            f"{base}/studio/events?max_events=1&studio_token={secret_tok}",
            headers={"Origin": "https://studio.relaystudio.local"},
            method="GET",
        )
        with urllib.request.urlopen(ev_ok_req, timeout=3) as ev_ok_resp:
            self.assertEqual(ev_ok_resp.status, 200)
            self.assertEqual(ev_ok_resp.headers.get("Access-Control-Allow-Origin"), "https://studio.relaystudio.local")
            self.assertIn("text/event-stream", ev_ok_resp.headers.get("Content-Type") or "")
            ev_raw = ev_ok_resp.read().decode("utf-8")
            self.assertIn("event: snapshot\n", ev_raw)

        # 5. /web-bridge/state and /web-bridge/poll remain accessible on loopback WITHOUT X-Studio-Token!
        wb_st = self._get_json("/web-bridge/state")
        self.assertIn("queue", wb_st)
        wb_poll = self._post_json("/web-bridge/poll", {"browser": "Chrome", "browser_profile": "Chrome:Default", "tabs": []})
        self.assertTrue(wb_poll.get("ok", True))

        # 6. Removing studio-local.token and setting RELAYSTUDIO_LOCAL_TOKEN enforces env token
        os.remove(tok_file)
        env_tok = "rs_env_tok_abcdef123456"
        os.environ["RELAYSTUDIO_LOCAL_TOKEN"] = env_tok
        try:
            with self.assertRaises(urllib.error.HTTPError) as env_err:
                urllib.request.urlopen(urllib.request.Request(f"{base}/studio/snapshot", headers={"X-Studio-Token": secret_tok}), timeout=3)
            self.assertEqual(env_err.exception.code, 403)
            env_err.exception.close()

            with urllib.request.urlopen(urllib.request.Request(f"{base}/studio/snapshot?studio_token={env_tok}"), timeout=3) as env_ok:
                self.assertEqual(env_ok.status, 200)
        finally:
            os.environ.pop("RELAYSTUDIO_LOCAL_TOKEN", None)

    def test_24_studio_sse_events_initial_snapshot_and_sub_300ms_live_push_and_clean_shutdown(self):
        """Verify GET /studio/events streams initial snapshot immediately, pushes state mutations in <300ms, and closes cleanly on server_close."""
        import http.client

        self._write_task("tsk_sse_1", "初始任务标题")

        def _read_one_sse_event(resp) -> tuple[str, dict]:
            ev_name = ""
            data_lines = []
            while True:
                line_bytes = resp.fp.readline()
                if not line_bytes:
                    break
                line = line_bytes.decode("utf-8").rstrip("\r\n")
                if line == "":
                    if ev_name or data_lines:
                        break
                    continue
                if line.startswith(":"):
                    continue
                if line.startswith("event:"):
                    ev_name = line[len("event:") :].strip()
                elif line.startswith("data:"):
                    data_lines.append(line[len("data:") :].strip())
            payload = json.loads("\n".join(data_lines)) if data_lines else {}
            return (ev_name, payload)

        # 1. Connect to GET /studio/events?max_events=2 -> immediate initial snapshot + <300ms push on set_alias
        conn = http.client.HTTPConnection("127.0.0.1", self.shield_port, timeout=5)
        try:
            conn.request("GET", "/studio/events?max_events=2", headers={"Origin": "https://studio.relaystudio.local"})
            resp = conn.getresponse()
            self.assertEqual(resp.status, 200)
            self.assertEqual(resp.getheader("Content-Type"), "text/event-stream; charset=utf-8")
            self.assertEqual(resp.getheader("Cache-Control"), "no-cache, no-store")
            self.assertEqual(resp.getheader("X-Accel-Buffering"), "no")
            self.assertIsNone(resp.getheader("Content-Length"))
            self.assertEqual(resp.getheader("Access-Control-Allow-Origin"), "https://studio.relaystudio.local")

            ev1_name, ev1_data = _read_one_sse_event(resp)
            self.assertEqual(ev1_name, "snapshot")
            self.assertTrue(ev1_data.get("ok"))
            rev_1 = ev1_data.get("rev", "")
            self.assertTrue(rev_1.startswith("rev_"))
            s1 = next(s for s in ev1_data["sessions"] if s["SessionKey"] == "tsk_sse_1")
            self.assertFalse(s1.get("HasCustomAlias"))

            # Trigger POST /studio/action (set_alias) from a concurrent thread and measure SSE wakeup latency!
            post_started = threading.Event()
            t_post_holder = [0.0]

            def _mutate_alias():
                time.sleep(0.03)
                t_post_holder[0] = time.perf_counter()
                post_started.set()
                self._post_json(
                    "/studio/action",
                    {"action": "set_alias", "session_key": "tsk_sse_1", "title": "WebView2 毫秒级推送标题"},
                )

            mut_thread = threading.Thread(target=_mutate_alias, daemon=True)
            mut_thread.start()

            ev2_name, ev2_data = _read_one_sse_event(resp)
            t_received = time.perf_counter()
            self.assertTrue(post_started.is_set())
            mut_thread.join(timeout=2.0)

            push_latency = t_received - t_post_holder[0]
            self.assertLess(push_latency, 0.3, f"SSE mutation push took {push_latency:.3f}s (expected <0.300s)")
            self.assertEqual(ev2_name, "snapshot")
            rev_2 = ev2_data.get("rev", "")
            self.assertNotEqual(rev_2, rev_1)
            s2 = next(s for s in ev2_data["sessions"] if s["SessionKey"] == "tsk_sse_1")
            self.assertEqual(s2["Title"], "WebView2 毫秒级推送标题")
            self.assertTrue(s2["HasCustomAlias"])

            # Verify stream closed cleanly after max_events=2
            self.assertEqual(resp.fp.readline(), b"")
        finally:
            conn.close()

        # 2. Reconnect with since_sig=rev_2 on /__studio__/events?max_events=2 -> initial synced frame + <300ms push on enqueue_message
        conn2 = http.client.HTTPConnection("127.0.0.1", self.shield_port, timeout=5)
        try:
            conn2.request("GET", f"/__studio__/events?max_events=2&since_sig={rev_2}")
            resp2 = conn2.getresponse()
            self.assertEqual(resp2.status, 200)
            ev_sync_name, ev_sync_data = _read_one_sse_event(resp2)
            self.assertEqual(ev_sync_name, "snapshot")
            self.assertTrue(ev_sync_data.get("not_modified"))
            self.assertEqual(ev_sync_data.get("rev"), rev_2)

            t_enq_holder = [0.0]

            def _mutate_enqueue():
                time.sleep(0.03)
                t_enq_holder[0] = time.perf_counter()
                self._post_json(
                    "/studio/action",
                    {"action": "enqueue_message", "session_key": "tsk_sse_1", "user_text": "继续推进测试"},
                )

            enq_thread = threading.Thread(target=_mutate_enqueue, daemon=True)
            enq_thread.start()

            ev_enq_name, ev_enq_data = _read_one_sse_event(resp2)
            enq_latency = time.perf_counter() - t_enq_holder[0]
            enq_thread.join(timeout=2.0)

            self.assertLess(enq_latency, 0.3, f"SSE enqueue push took {enq_latency:.3f}s (expected <0.300s)")
            self.assertEqual(ev_enq_name, "snapshot")
            self.assertNotEqual(ev_enq_data.get("rev"), rev_2)
            s_enq = next(s for s in ev_enq_data["sessions"] if s["SessionKey"] == "tsk_sse_1")
            self.assertGreaterEqual(s_enq["PendingQueueCount"], 1)
        finally:
            conn2.close()

        # 3. Verify open unbounded SSE stream (no max_events) exits promptly when server_close() / shutdown() runs
        extra_srv = shield.ShieldServer(
            ("127.0.0.1", 0),
            f"http://127.0.0.1:{self.upstream_port}/mcp",
            self.activity_path,
            tasks_root=self.tasks_root,
            data_root=self.data_root,
        )
        extra_port = extra_srv.server_address[1]
        extra_th = threading.Thread(target=extra_srv.serve_forever, daemon=True)
        extra_th.start()
        conn3 = http.client.HTTPConnection("127.0.0.1", extra_port, timeout=5)
        try:
            conn3.request("GET", "/studio/events")
            resp3 = conn3.getresponse()
            ev_init, _ = _read_one_sse_event(resp3)
            self.assertEqual(ev_init, "snapshot")

            t_close0 = time.perf_counter()
            extra_srv.shutdown()
            extra_srv.server_close()
            eof_line = resp3.fp.readline()
            close_elapsed = time.perf_counter() - t_close0
            self.assertEqual(eof_line, b"")
            self.assertLess(close_elapsed, 0.6, "SSE stream must terminate cleanly upon server shutdown/close without blocking")
        finally:
            conn3.close()
            extra_srv.server_close()

    def test_25_pna_cors_preflight_and_snapshot_milestone_queue_fidelity(self):
        """Verify Chromium PNA CORS headers, strict 403 tunnel guard, Milestone/Queue fidelity, and PS 5.1 ConvertFrom-Json safety."""
        import http.client
        import subprocess
        import urllib.error

        base = f"http://127.0.0.1:{self.shield_port}"
        tok_file = os.path.join(self.data_root, "studio-local.token")
        secret_tok = "rs_pna_tok_0123456789abcdef"
        with open(tok_file, "w", encoding="utf-8") as fh:
            fh.write(secret_tok + "\n")

        try:
            # 1. OPTIONS /studio/snapshot with Origin: https://studio.relaystudio.local + Access-Control-Request-Private-Network: true
            for path in ("/studio/snapshot", "/studio/events", "/studio/queue_digest", "/studio/action"):
                opt_req = urllib.request.Request(
                    f"{base}{path}",
                    headers={
                        "Origin": "https://studio.relaystudio.local",
                        "Access-Control-Request-Method": "POST" if path.endswith("/action") else "GET",
                        "Access-Control-Request-Headers": "Content-Type, X-Studio-Token, Authorization, Cache-Control, Last-Event-ID",
                        "Access-Control-Request-Private-Network": "true",
                    },
                    method="OPTIONS",
                )
                with urllib.request.urlopen(opt_req, timeout=3) as opt_resp:
                    self.assertIn(opt_resp.status, (200, 204))
                    self.assertEqual(opt_resp.headers.get("Access-Control-Allow-Origin"), "https://studio.relaystudio.local")
                    self.assertEqual(opt_resp.headers.get("Access-Control-Allow-Private-Network"), "true")
                    allow_hdrs = {
                        h.strip().lower()
                        for h in (opt_resp.headers.get("Access-Control-Allow-Headers") or "").split(",")
                        if h.strip()
                    }
                    for req_h in ("content-type", "x-studio-token", "authorization", "cache-control", "last-event-id"):
                        self.assertIn(req_h, allow_hdrs)

            # 2. Seed rich task checkpoints + app-initiated pending & delivered web messages
            now_ep = time.time()
            iso_t1 = shield.datetime.fromtimestamp(now_ep - 120, tz=shield.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            iso_t2 = shield.datetime.fromtimestamp(now_ep - 30, tz=shield.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            iso_deliv = shield.datetime.fromtimestamp(now_ep - 15, tz=shield.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            raw_cp_warn = "s1=in_progress: 集成回归出现 1F 阻塞，正在定位原因 || SHAabcdef12 pytest=4P1F"
            raw_cp_ok = "completed=[s1], current=s2: 全部门禁测试已恢复通过，准备热重启验证。 || SHA98765432 all_green"

            task_doc = {
                "id": "tsk_pna_fid_1",
                "title": "PNA 与台账保真回归任务",
                "goal": "验证里程碑原文、步骤跳转与队列全文保真",
                "status": "active",
                "created_at": iso_t1,
                "updated_at": iso_t2,
                "steps": [
                    {"id": "s1", "title": "修复 PNA 预检头", "status": "completed", "updated_at": iso_t1},
                    {"id": "s2", "title": "验证快照字段保真", "status": "in_progress", "updated_at": iso_t2},
                ],
                "checkpoints": [
                    {
                        "type": "checkpoint",
                        "summary": raw_cp_warn,
                        "trace_text": "trace: test_pna_cors failed at line 42",
                        "created_at": iso_t1,
                    },
                    {
                        "type": "checkpoint",
                        "summary": raw_cp_ok,
                        "trace_text": "trace: 25/25 green in 12.4s",
                        "created_at": iso_t2,
                    },
                ],
                "summary": raw_cp_ok,
            }
            with open(os.path.join(self.tasks_root, "tsk_pna_fid_1.json"), "w", encoding="utf-8") as fh:
                json.dump(task_doc, fh, ensure_ascii=False)

            full_sent_prompt = "【RelayStudio 任务契约】\n请严格执行 s1 修复并回写检查点。\n---\n用户原始输入：先修 PNA"
            full_pend_prompt = "【RelayStudio 任务契约】\n完成后请热重启 8766 并汇报。\n---\n用户原始输入：再跑全量单测"
            with open(self.wb_state_path, "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "schema_version": 1,
                        "tabs": {},
                        "bindings": {},
                        "queue": [
                            {
                                "id": "msg_sent_1",
                                "session_key": "tsk_pna_fid_1",
                                "status": "delivered",
                                "mode": "new_window_handover",
                                "app_initiated": True,
                                "display_text": "先修 PNA",
                                "prompt": full_sent_prompt,
                                "created_at": iso_t1,
                                "claimed_at": iso_t2,
                                "delivered_at": iso_deliv,
                                "defer_until_stopped": False,
                                "target_model": "gpt-5-4-thinking",
                                "reasoning_effort": "high",
                                "browser_profile": "Edge:Default",
                                "provider": "chatgpt",
                                "conv_uuid": "conv-fid-1234",
                            },
                            {
                                "id": "msg_pend_2",
                                "session_key": "tsk_pna_fid_1",
                                "status": "pending",
                                "mode": "custom_message",
                                "app_initiated": True,
                                "display_text": "再跑全量单测",
                                "prompt": full_pend_prompt,
                                "created_at": iso_t2,
                                "claimed_at": "",
                                "delivered_at": "",
                                "defer_until_stopped": True,
                                "target_model": "gpt-5-4-thinking",
                                "reasoning_effort": "xhigh",
                                "browser_profile": "Edge:Default",
                                "provider": "chatgpt",
                                "conv_uuid": "conv-fid-1234",
                            },
                        ],
                    },
                    fh,
                    ensure_ascii=False,
                )

            # 3. GET /studio/snapshot, GET /studio/queue_digest, GET /studio/events, POST /studio/action on loopback return PNA header
            snap_req = urllib.request.Request(
                f"{base}/studio/snapshot",
                headers={"Origin": "https://studio.relaystudio.local", "X-Studio-Token": secret_tok},
                method="GET",
            )
            with urllib.request.urlopen(snap_req, timeout=3) as snap_resp:
                self.assertEqual(snap_resp.status, 200)
                self.assertEqual(snap_resp.headers.get("Access-Control-Allow-Private-Network"), "true")
                self.assertEqual(snap_resp.headers.get("Access-Control-Allow-Origin"), "https://studio.relaystudio.local")
                snap_raw_bytes = snap_resp.read()
                snap_data = json.loads(snap_raw_bytes.decode("utf-8"))

            qd_req = urllib.request.Request(
                f"{base}/studio/queue_digest",
                headers={"Origin": "https://studio.relaystudio.local", "X-Studio-Token": secret_tok},
                method="GET",
            )
            with urllib.request.urlopen(qd_req, timeout=3) as qd_resp:
                self.assertEqual(qd_resp.status, 200)
                self.assertEqual(qd_resp.headers.get("Access-Control-Allow-Private-Network"), "true")
                qd_data = json.loads(qd_resp.read().decode("utf-8"))
                self.assertTrue(qd_data.get("ok"))

            sse_req = urllib.request.Request(
                f"{base}/studio/events?max_events=1&studio_token={secret_tok}",
                headers={"Origin": "https://studio.relaystudio.local"},
                method="GET",
            )
            with urllib.request.urlopen(sse_req, timeout=3) as sse_resp:
                self.assertEqual(sse_resp.status, 200)
                self.assertEqual(sse_resp.headers.get("Access-Control-Allow-Private-Network"), "true")
                _ = sse_resp.read()

            act_req = urllib.request.Request(
                f"{base}/studio/action",
                data=json.dumps({"action": "set_alias", "session_key": "tsk_pna_fid_1", "title": "PNA已对齐"}).encode("utf-8"),
                headers={
                    "Origin": "https://studio.relaystudio.local",
                    "Content-Type": "application/json",
                    "X-Studio-Token": secret_tok,
                },
                method="POST",
            )
            with urllib.request.urlopen(act_req, timeout=3) as act_resp:
                self.assertEqual(act_resp.status, 200)
                self.assertEqual(act_resp.headers.get("Access-Control-Allow-Private-Network"), "true")
                self.assertTrue(json.loads(act_resp.read().decode("utf-8")).get("ok"))

            # 4. Forwarded / public-tunnel headers or non-loopback Host MUST STILL return 403 even with valid token & PNA request headers!
            for tunnel_hdrs, expected_err in (
                ({"Cf-Connecting-Ip": "203.0.113.9", "X-Studio-Token": secret_tok}, "forbidden_public_tunnel"),
                ({"X-Forwarded-For": "203.0.113.9", "X-Studio-Token": secret_tok}, "forbidden_public_tunnel"),
                ({"Tailscale-Funnel-Request": "?1", "X-Studio-Token": secret_tok}, "forbidden_public_tunnel"),
                ({"Host": "relay.tail29988f.ts.net", "X-Studio-Token": secret_tok}, "forbidden_host"),
            ):
                for bad_method in ("GET", "OPTIONS"):
                    conn_bad = http.client.HTTPConnection("127.0.0.1", self.shield_port, timeout=3)
                    try:
                        has_host = any(k.lower() == "host" for k in tunnel_hdrs)
                        conn_bad.putrequest(bad_method, "/studio/snapshot", skip_host=has_host)
                        conn_bad.putheader("Origin", "https://studio.relaystudio.local")
                        conn_bad.putheader("Access-Control-Request-Private-Network", "true")
                        for hk, hv in tunnel_hdrs.items():
                            conn_bad.putheader(hk, hv)
                        conn_bad.endheaders()
                        r_bad = conn_bad.getresponse()
                        err_doc = json.loads(r_bad.read().decode("utf-8"))
                        self.assertEqual(r_bad.status, 403)
                        self.assertEqual(err_doc.get("error"), expected_err)
                        self.assertNotIn("sessions", err_doc)
                    finally:
                        conn_bad.close()

            # 5. Verify Milestone, Step, PendingQueue, and SentWebMessages fidelity
            sess = next((s for s in snap_data["sessions"] if s["SessionKey"] == "tsk_pna_fid_1"), None)
            self.assertIsNotNone(sess)
            self.assertEqual([st["id"] for st in sess["Steps"]], ["s1", "s2"])
            self.assertEqual([st["status"] for st in sess["Steps"]], ["completed", "in_progress"])

            ms_list = sess["Milestones"]
            self.assertEqual(len(ms_list), 2)
            # Newest first: ms_list[0] is s2 (ok), ms_list[1] is s1 (warning)
            ms_ok, ms_warn = ms_list[0], ms_list[1]
            self.assertEqual(ms_ok["StepId"], "s2")
            self.assertEqual(ms_ok["step_id"], "s2")
            self.assertIn("验证快照字段保真", ms_ok["Title"])
            self.assertIn("全部门禁测试已恢复通过", ms_ok["Body"])
            self.assertTrue(ms_ok["TimeText"])
            self.assertEqual(ms_ok["TimeText"], ms_ok["time_text"])
            self.assertEqual(ms_ok["TraceText"], "trace: 25/25 green in 12.4s")
            self.assertEqual(ms_ok["trace_text"], "trace: 25/25 green in 12.4s")
            self.assertEqual(ms_ok["RawSummary"], raw_cp_ok)
            self.assertEqual(ms_ok["raw_summary"], raw_cp_ok)
            self.assertFalse(ms_ok["IsWarning"])
            self.assertFalse(ms_ok["is_warning"])

            self.assertEqual(ms_warn["StepId"], "s1")
            self.assertEqual(ms_warn["step_id"], "s1")
            self.assertEqual(ms_warn["RawSummary"], raw_cp_warn)
            self.assertEqual(ms_warn["raw_summary"], raw_cp_warn)
            self.assertEqual(ms_warn["TraceText"], "trace: test_pna_cors failed at line 42")
            self.assertTrue(ms_warn["IsWarning"])
            self.assertTrue(ms_warn["is_warning"])

            # PendingQueue preserves full prompt vs short display_text/text + defer_until_stopped
            self.assertEqual(len(sess["PendingQueue"]), 1)
            pq = sess["PendingQueue"][0]
            self.assertEqual(pq["id"], "msg_pend_2")
            self.assertEqual(pq["prompt"], full_pend_prompt)
            self.assertEqual(pq["display_text"], "再跑全量单测")
            self.assertEqual(pq["text"], "再跑全量单测")
            self.assertEqual(pq["created_at"], iso_t2)
            self.assertEqual(pq["status"], "pending")
            self.assertEqual(pq["mode"], "custom_message")
            self.assertTrue(pq["defer_until_stopped"])

            # SentWebMessages preserves full prompt vs short display_text/text + delivered_at + mode
            sent_delivered = next((m for m in sess["SentWebMessages"] if m["id"] == "msg_sent_1"), None)
            self.assertIsNotNone(sent_delivered)
            self.assertEqual(sent_delivered["prompt"], full_sent_prompt)
            self.assertEqual(sent_delivered["display_text"], "先修 PNA")
            self.assertEqual(sent_delivered["text"], "先修 PNA")
            self.assertEqual(sent_delivered["created_at"], iso_t1)
            self.assertEqual(sent_delivered["delivered_at"], iso_deliv)
            self.assertEqual(sent_delivered["status"], "delivered")
            self.assertEqual(sent_delivered["mode"], "new_window_handover")
            self.assertFalse(sent_delivered["defer_until_stopped"])

            # 6. Verify Windows PowerShell 5.1 ConvertFrom-Json parses the entire snapshot without duplicate-key collisions
            snap_tmp = os.path.join(self.data_root, "snap_ps51_check.json")
            with open(snap_tmp, "wb") as fh:
                fh.write(snap_raw_bytes)
            ps_check = subprocess.run(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-Command",
                    f"$s = Get-Content -Raw -Encoding UTF8 -LiteralPath '{snap_tmp}' | ConvertFrom-Json; "
                    "$c = $s.sessions | Where-Object { $_.SessionKey -eq 'tsk_pna_fid_1' }; "
                    "if (-not $c -or $c.PendingQueue[0].Prompt -ne $c.PendingQueue[0].prompt -or -not $c.Milestones[0].RawSummary) { exit 2 }",
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(ps_check.returncode, 0, f"PS 5.1 ConvertFrom-Json failed: {ps_check.stderr}")
        finally:
            if os.path.exists(tok_file):
                os.remove(tok_file)


if __name__ == "__main__":
    unittest.main()

