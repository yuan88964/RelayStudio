# -*- coding: utf-8 -*-
"""Spec v4.7 Module 2 seam tests (Studio Hub / McpReadOnlyShield.py):
- 2.1 tunnel log cross-truncation counting, tunnel_network_hold, last_tunnel_drop_epoch
- 2.2 ghost in_flight cleanup (LONG_RUNNING_TOOLS), 15s DUAL_STREAM, WorkspaceRoot + pipeline.state.json probe
- 2.3 MAX_DISPATCHING_HOLD_SEC=35, new probe fields (web tab + DesktopAppBridge), VitalSubstate six states
- 2.4 guardian: claimed protection, 90s observation lock, 60s tool silence gate, NETWORK_HOLD, option-A ladder
- 2.5 checkpoint summary protection, short git SHA preservation, no "刚刚刚" stutter
"""

import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

import McpReadOnlyShield as shield


def iso(ep: float) -> str:
    return datetime.fromtimestamp(ep, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def fwd_line(ep: float, cid: str, rpc: str) -> str:
    return json.dumps({
        "time": iso(ep),
        "level": "INFO",
        "msg": "dispatcher forwarded command to MCP server",
        "cmd_request_id": cid,
        "rpc_request_id": rpc,
    })


def err_line(ep: float, msg: str = "poll failed", err: str = "EOF") -> str:
    return json.dumps({"time": iso(ep), "level": "ERROR", "msg": msg, "error": err})


class V47Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rs_v47_")
        self.data_root = os.path.join(self.tmp, "data")
        self.logs = os.path.join(self.data_root, "logs")
        self.tasks_root = os.path.join(self.tmp, "tasks")
        os.makedirs(self.logs, exist_ok=True)
        os.makedirs(self.tasks_root, exist_ok=True)
        self.tunnel = os.path.join(self.logs, "tunnel.out.log")
        self.activity = os.path.join(self.logs, "shield-activity.json")
        self.wb_path = os.path.join(self.logs, "web-bridge-state.json")
        shield._LOG_READERS.clear()

    def tearDown(self):
        shield._LOG_READERS.clear()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_task(self, tid, title="v47 任务", updated_ep=None, summary="执行中", events=None, steps=None):
        u = iso(updated_ep if updated_ep is not None else time.time() - 600)
        doc = {
            "schema_version": 1,
            "id": tid,
            "title": title,
            "goal": f"推进 {title}",
            "status": "active",
            "created_at": u,
            "updated_at": u,
            "steps": steps or [
                {"id": "1", "title": "准备", "status": "completed", "updated_at": u},
                {"id": "2", "title": "联调接口", "status": "in_progress", "updated_at": u},
            ],
            "summary": summary,
            "events": events or [],
        }
        with open(os.path.join(self.tasks_root, f"{tid}.json"), "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False)
        return doc

    def write_lines(self, lines, mode="w"):
        with open(self.tunnel, mode, encoding="utf-8") as fh:
            for ln in lines:
                fh.write(ln + "\n")

    def snap(self):
        return shield.build_studio_snapshot(self.data_root, self.tasks_root, self.wb_path)

    def card(self, snap, tid):
        return next(s for s in snap["sessions"] if s["SessionKey"] == tid)


# ---------------------------------------------------------------- 2.5
class Slice25TextFixes(V47Base):
    def test_short_git_sha_is_preserved_but_sha_prefixed_and_full_hash_stripped(self):
        out = shield.format_readable_milestone("修复登录缺陷并提交 a1b2c3d 已通过门禁")
        self.assertIn("a1b2c3d", out["CleanSummary"])
        out12 = shield.format_readable_milestone("合入 1234567890ab 到主干")
        self.assertIn("1234567890ab", out12["CleanSummary"])
        stripped = shield.format_readable_milestone("完成核心模块重构并通过验证 SHA5e6e40b8522e78d")
        self.assertNotIn("SHA5e6e40b8522e78d", stripped["CleanSummary"])
        full = shield.format_readable_milestone("提交 " + "a" * 40 + " 完成")
        self.assertNotIn("a" * 40, full["CleanSummary"])

    def test_checkpoint_without_summary_keeps_previous_real_summary(self):
        tid = "tsk_v47ckpt0001"
        self.write_task(tid, summary="阶段二完成：接口联调通过")
        raw = json.dumps({
            "jsonrpc": "2.0", "id": "ck1", "method": "tools/call",
            "params": {"name": "task_manage", "arguments": {"action": "checkpoint", "task_id": tid}},
        }).encode("utf-8")
        shield.handle_native_task_manage(raw, self.tasks_root, self.data_root, self.activity, self.wb_path)
        with open(os.path.join(self.tasks_root, f"{tid}.json"), "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        self.assertEqual(doc["summary"], "阶段二完成：接口联调通过")

    def test_snapshot_latest_summary_falls_back_to_last_real_checkpoint(self):
        tid = "tsk_v47ckpt0002"
        now = time.time()
        self.write_task(tid, summary="记录检查点", events=[
            {"type": "checkpoint", "summary": "完成接口联调并通过回归", "created_at": iso(now - 900)},
            {"type": "checkpoint", "summary": "记录检查点", "created_at": iso(now - 800)},
        ])
        c = self.card(self.snap(), tid)
        self.assertIn("完成接口联调并通过回归", c["LatestSummary"])

        tid2 = "tsk_v47ckpt0003"
        self.write_task(tid2, summary="记录检查点", events=[
            {"type": "checkpoint", "summary": "记录检查点", "created_at": iso(now - 800)},
        ])
        c2 = self.card(self.snap(), tid2)
        self.assertIn("联调接口", c2["LatestSummary"])

    def test_human_diagnosis_has_no_triple_gang(self):
        tid = "tsk_v47diag0001"
        now = time.time()
        self.write_task(tid, updated_ep=now)
        self.write_lines([fwd_line(now - 2, "wfr_diag01", "rpc-d1")])
        c = self.card(self.snap(), tid)
        self.assertIn("刚刚调用过本机工具", c["HumanDiagnosis"])
        self.assertNotIn("刚刚刚", c["HumanDiagnosis"])


# ---------------------------------------------------------------- 2.1
class Slice21TunnelLog(V47Base):
    def test_command_count_accumulates_across_truncation(self):
        tid = "tsk_v47count001"
        now = time.time()
        self.write_task(tid)
        self.write_lines([fwd_line(now - 3000 + i * 0.5, "wfr_cnt01", f"rpc-a{i}") for i in range(2600)])
        s1 = self.snap()
        self.assertEqual(s1["command_count"], 2600)
        self.assertEqual(self.card(s1, tid)["CommandCount"], 2600)
        self.write_lines([fwd_line(now - 500 + i * 0.5, "wfr_cnt01", f"rpc-b{i}") for i in range(600)], mode="a")
        s2 = self.snap()
        self.assertEqual(s2["command_count"], 3200)
        self.assertEqual(self.card(s2, tid)["CommandCount"], 3200)

    def test_network_hold_requires_two_recent_errors_without_later_success(self):
        tid = "tsk_v47net00001"
        now = time.time()
        self.write_task(tid)
        self.write_lines([fwd_line(now - 30, "wfr_net01", "rpc-n1"), err_line(now - 10), err_line(now - 5, "tunnel metadata fetch failed", "context deadline exceeded")])
        s = self.snap()
        self.assertTrue(s["tunnel_network_hold"])
        self.assertTrue(self.card(s, tid)["NetworkHold"])

    def test_network_hold_clears_after_success_or_when_errors_are_old(self):
        now = time.time()
        self.write_task("tsk_v47net00002")
        self.write_lines([err_line(now - 12), err_line(now - 8), fwd_line(now - 2, "wfr_net02", "rpc-n2")])
        self.assertFalse(self.snap()["tunnel_network_hold"])
        shield._LOG_READERS.clear()
        self.write_lines([err_line(now - 60), err_line(now - 50)])
        self.assertFalse(self.snap()["tunnel_network_hold"])
        shield._LOG_READERS.clear()
        self.write_lines([err_line(now - 5)])
        self.assertFalse(self.snap()["tunnel_network_hold"], "a single error is not a storm")

    def test_last_tunnel_drop_epoch_is_recorded_and_survives_truncation(self):
        now = time.time()
        self.write_task("tsk_v47drop0001")
        self.write_lines([
            json.dumps({"time": iso(now - 4000), "level": "ERROR", "msg": "failed to post response to control plane", "error": "EOF"}),
            json.dumps({"time": iso(now - 3990), "level": "WARN", "msg": "command response deadline reached"}),
        ] + [fwd_line(now - 3900 + i, "wfr_drop01", f"rpc-x{i}") for i in range(2600)])
        s = self.snap()
        self.assertAlmostEqual(s["last_tunnel_drop_epoch"], now - 3990, delta=1.5)
        st = shield.get_tunnel_log_reader_state(self.tunnel)
        self.assertAlmostEqual(st["last_tunnel_drop_epoch"], now - 3990, delta=1.5)
        self.assertGreaterEqual(st["evicted_valid_tool_count"], 600)


# ---------------------------------------------------------------- 2.2
def mcp_call(tool: str, args: dict, rpc: str) -> bytes:
    return json.dumps({"jsonrpc": "2.0", "id": rpc, "method": "tools/call", "params": {"name": tool, "arguments": args}}).encode("utf-8")


class Slice22InFlightDualStreamWorkspace(V47Base):
    def write_activity(self, calls: dict):
        with open(self.activity, "w", encoding="utf-8") as fh:
            json.dump({"schema_version": 1, "calls": calls, "in_flight_count": len(calls)}, fh)

    def test_long_running_tools_constant(self):
        self.assertEqual(
            shield.LONG_RUNNING_TOOLS,
            {"exec_command", "shell_exec", "run_command", "run_process", "desktop-commander:start_process",
             "desktop-commander:interact_with_process", "acp_dispatch"},
        )

    def test_new_request_closes_ghost_fast_tool_in_flight_of_same_task(self):
        tid = "tsk_v47ghost001"
        e1 = shield.record_shield_activity(self.activity, mcp_call("read_file", {"task_id": tid, "path": "a.txt"}, "g1"))
        e2 = shield.record_shield_activity(self.activity, mcp_call("read_file", {"task_id": tid, "path": "b.txt"}, "g2"))
        with open(self.activity, "r", encoding="utf-8") as fh:
            calls = json.load(fh)["calls"]
        self.assertFalse(calls[e1["call_seq_id"]]["in_flight"], "ghost fast-tool in_flight must be closed by the next request")
        self.assertTrue(calls[e2["call_seq_id"]]["in_flight"])
        # Long-running tools keep their own concurrent in_flight state
        x1 = shield.record_shield_activity(self.activity, mcp_call("exec_command", {"task_id": tid, "cmd": "pytest"}, "g3"))
        shield.record_shield_activity(self.activity, mcp_call("read_file", {"task_id": tid, "path": "c.txt"}, "g4"))
        with open(self.activity, "r", encoding="utf-8") as fh:
            calls = json.load(fh)["calls"]
        self.assertTrue(calls[x1["call_seq_id"]]["in_flight"])

    def test_fast_tool_in_flight_window_is_45s_long_tool_keeps_900s(self):
        now = time.time()
        self.write_task("tsk_v47window01")
        old = iso(now - 120)
        self.write_activity({
            "c1": {"rpc_id": "c1", "tool": "read_file", "task_id": "", "in_flight": True, "time": old, "started_at": old},
        })
        self.assertEqual(self.snap()["in_flight_count"], 0)
        self.assertEqual(shield._collect_in_flight_task_ids(self.wb_path, now), set())
        self.write_activity({
            "c2": {"rpc_id": "c2", "tool": "exec_command", "task_id": "", "in_flight": True, "time": old, "started_at": old},
        })
        self.assertEqual(self.snap()["in_flight_count"], 1)
        self.assertIn(shield._UNATTRIBUTED_IN_FLIGHT_SENTINEL, shield._collect_in_flight_task_ids(self.wb_path, now))

    def test_extract_workspace_root_walks_up_to_project_marker(self):
        root = os.path.join(self.tmp, "AlmaLeyu")
        os.makedirs(os.path.join(root, ".git"))
        os.makedirs(os.path.join(root, "src", "app"))
        raw = json.dumps({"workdir": os.path.join(root, "src", "app"), "cmd": "pytest -q"})
        self.assertEqual(os.path.normcase(shield._extract_workspace_root(raw)), os.path.normcase(root))
        self.assertEqual(shield._extract_workspace_root(json.dumps({"cmd": "echo hi"})), "")
        tel = shield.extract_mcp_call_telemetry(mcp_call("exec_command", {"cwd": os.path.join(root, "src")}, "w1"))
        self.assertEqual(os.path.normcase(tel["workspace_root"]), os.path.normcase(root))

    def test_snapshot_exposes_workspace_root_and_pipeline_heartbeat_keeps_live(self):
        tid = "tsk_v47pipe0001"
        now = time.time()
        self.write_task(tid)
        root = os.path.join(self.tmp, "Biz")
        os.makedirs(os.path.join(root, ".scratch"))
        with open(os.path.join(root, "pyproject.toml"), "w") as fh:
            fh.write("")
        old = iso(now - 600)
        self.write_activity({
            "p1": {"rpc_id": "p1", "tool": "exec_command", "task_id": tid, "in_flight": False, "time": old,
                   "started_at": old, "completed_at": old, "workspace_root": root, "action": "执行命令"},
        })
        c = self.card(self.snap(), tid)
        self.assertEqual(os.path.normcase(c["WorkspaceRoot"]), os.path.normcase(root))
        self.assertEqual(c["VitalState"], "STOPPED")
        with open(os.path.join(root, ".scratch", "pipeline.state.json"), "w") as fh:
            fh.write("{}")
        shield._PIPELINE_PROBE_CACHE.clear()
        c2 = self.card(self.snap(), tid)
        self.assertEqual(c2["VitalState"], "LIVE")
        self.assertLessEqual(c2["LastToolAgeSec"], 5)

    def test_dual_stream_detected_when_two_streams_active_within_15s(self):
        tid = "tsk_v47dual0001"
        now = time.time()
        self.write_task(tid)
        self.write_lines([fwd_line(now - 6, "wfr_dualA", "rpc-da"), fwd_line(now - 3, "wfr_dualB", "rpc-db")])
        c = self.card(self.snap(), tid)
        self.assertTrue(c["DualStream"])
        self.assertEqual(c["VitalState"], "LIVE")
        self.assertEqual(c["VitalSubstate"], "DUAL_STREAM")

        shield._LOG_READERS.clear()
        self.write_lines([fwd_line(now - 60, "wfr_dualA", "rpc-da2"), fwd_line(now - 3, "wfr_dualB", "rpc-db2")])
        c2 = self.card(self.snap(), tid)
        self.assertFalse(c2["DualStream"])
        self.assertNotEqual(c2["VitalSubstate"], "DUAL_STREAM")


# ---------------------------------------------------------------- 2.3
CONTRACT_FIELDS = (
    "VitalState", "VitalSubstate", "LastToolAgeSec", "SilenceCountdownSec", "DetectedUiError",
    "NetworkHold", "HasComposer", "HasLoadError", "WorkspaceRoot", "DualStream",
)


class Slice23DispatchHoldAndVitalSubstate(V47Base):
    def fresh_state(self):
        return shield._ensure_web_bridge_schema(shield._default_web_bridge_state())

    def test_is_dispatching_is_capped_at_35s_without_stream(self):
        now = time.time()
        st = self.fresh_state()
        base = {"tab_id": "t1", "conv_uuid": "c0000000-0000-4000-8000-000000000001", "url": "https://chatgpt.com/c/x",
                "is_dispatching": True, "sse_active": False, "is_generating": False}
        rec1 = shield._update_tab_and_bindings(st, dict(base), "Chrome", "Chrome:Default", {}, iso(now - 40))
        self.assertTrue(rec1["is_dispatching"])
        rec2 = shield._update_tab_and_bindings(st, dict(base), "Chrome", "Chrome:Default", {}, iso(now))
        self.assertFalse(rec2["is_dispatching"], "dispatching > 35s without SSE must be released")
        self.assertLess(shield._parse_iso_epoch(rec2["last_live_at"]), now - 30, "capped dispatching must not refresh last_live_at")
        # Real streaming resets the hold
        rec3 = shield._update_tab_and_bindings(st, dict(base, sse_active=True), "Chrome", "Chrome:Default", {}, iso(now + 1))
        self.assertTrue(rec3["is_dispatching"])

    def test_web_tab_payload_new_probe_fields_are_persisted(self):
        st = self.fresh_state()
        rec = shield._update_tab_and_bindings(st, {
            "tab_id": "t2", "conv_uuid": "c0000000-0000-4000-8000-000000000002", "url": "https://chatgpt.com/c/y",
            "has_composer": False, "turn_incomplete": True, "stream_incomplete": True, "has_load_error": True,
            "ui_error_text": "未收到 ChatGPT 的回复，请检查网络连接。",
        }, "Chrome", "Chrome:Default", {}, iso(time.time()))
        self.assertFalse(rec["has_composer"])
        self.assertTrue(rec["turn_incomplete"])
        self.assertTrue(rec["stream_incomplete"])
        self.assertTrue(rec["has_load_error"])
        self.assertEqual(rec["ui_error_text"], "未收到 ChatGPT 的回复，请检查网络连接。")
        self.assertTrue(rec["has_error"])
        rec_default = shield._update_tab_and_bindings(st, {"tab_id": "t3", "url": "https://chatgpt.com/"}, "Chrome", "Chrome:Default", {}, iso(time.time()))
        self.assertTrue(rec_default["has_composer"])
        self.assertFalse(rec_default["has_load_error"])
        self.assertEqual(rec_default["ui_error_text"], "")

    def test_desktop_bridge_forwards_new_probe_fields(self):
        conv = "d0000000-0000-4000-8000-000000000003"
        shield._save_web_bridge_state(self.wb_path, self.fresh_state())

        def fake_eval(expr, kind="main_page"):
            return {
                "url": f"https://chatgpt.com/c/{conv}", "native_url": "app://-/index.html", "conv_uuid": conv,
                "has_composer": False, "sse_active": False, "is_generating": False, "turn_seq": 2, "has_error": True,
                "has_load_error": True, "turn_incomplete": True, "ui_error_text": "无法加载此 ChatGPT 对话",
                "page_hints": [], "composer_text": "", "has_user_draft": False,
            }

        shield.DesktopAppBridge.tick(self.wb_path, tasks_root=self.tasks_root, eval_fn=fake_eval, sleep_fn=lambda _: None)
        st = shield._load_web_bridge_state(self.wb_path)
        rec = st["tabs"][shield.DesktopAppBridge.TAB_ID]
        self.assertFalse(rec["has_composer"])
        self.assertTrue(rec["has_load_error"])
        self.assertTrue(rec["turn_incomplete"])
        self.assertEqual(rec["ui_error_text"], "无法加载此 ChatGPT 对话")

    def _tab(self, now, **kw):
        t = {"tab_id": "t9", "conv_uuid": "e0000000-0000-4000-8000-000000000009", "last_seen_at": iso(now - 1),
             "state_known": True, "sse_active": False, "is_generating": False, "is_dispatching": False, "has_error": False}
        t.update(kw)
        return {"t9": t}

    def _eval(self, now, tabs, **kw):
        binding = {"conv_uuid": "e0000000-0000-4000-8000-000000000009"}
        args = dict(now_epoch=now, now_iso=iso(now))
        args.update(kw)
        return shield.evaluate_session_vital_state("tsk_v47vital01", now - 600, False, binding, {}, tabs, [], **args)

    def test_vital_substates(self):
        now = time.time()
        # tools 20s ago, page errored -> LIVE / PSEUDO_STOPPED
        v = self._eval(now, self._tab(now, has_error=True, ui_error_text="传输超时，请重试"), last_tool_epoch=now - 20)
        self.assertEqual((v["vital_state"], v["vital_substate"]), ("LIVE", "PSEUDO_STOPPED"))
        self.assertEqual(v["detected_ui_error"], "传输超时，请重试")
        # tools 50s ago -> STOPPED / WAITING_CONFIRM with ~10s silence countdown
        v = self._eval(now, self._tab(now, has_error=True), last_tool_epoch=now - 50, stall_threshold_sec=180)
        self.assertEqual((v["vital_state"], v["vital_substate"]), ("STOPPED", "WAITING_CONFIRM"))
        self.assertTrue(8 <= v["silence_countdown_sec"] <= 11)
        self.assertEqual(v["last_tool_age_sec"], 50)
        # network storm -> NETWORK_HOLD
        v = self._eval(now, self._tab(now, has_error=True), last_tool_epoch=now - 120, tunnel_network_hold=True)
        self.assertEqual((v["vital_state"], v["vital_substate"]), ("STOPPED", "NETWORK_HOLD"))
        self.assertTrue(v["network_hold"])
        # silent >= 60s, healthy network, error -> CONFIRMED_STOPPED
        v = self._eval(now, self._tab(now, has_error=True), last_tool_epoch=now - 120, stall_threshold_sec=180)
        self.assertEqual((v["vital_state"], v["vital_substate"]), ("STOPPED", "CONFIRMED_STOPPED"))
        self.assertEqual(v["silence_countdown_sec"], 0)
        # no error -> waits for stall threshold
        v = self._eval(now, self._tab(now), last_tool_epoch=now - 120, stall_threshold_sec=180)
        self.assertEqual(v["vital_substate"], "WAITING_CONFIRM")
        # web streaming -> LIVE / LIVE ; dual stream -> DUAL_STREAM
        v = self._eval(now, self._tab(now, sse_active=True, is_generating=True))
        self.assertEqual((v["vital_state"], v["vital_substate"]), ("LIVE", "LIVE"))
        v = self._eval(now, self._tab(now, sse_active=True), dual_stream=True)
        self.assertEqual(v["vital_substate"], "DUAL_STREAM")
        # composer / load error surfaced
        v = self._eval(now, self._tab(now, has_composer=False, has_load_error=True, has_error=True), last_tool_epoch=now - 300)
        self.assertFalse(v["has_composer"])
        self.assertTrue(v["has_load_error"])

    def test_stale_dispatching_tab_is_not_live(self):
        now = time.time()
        v = self._eval(now, self._tab(now, is_dispatching=True, dispatching_since=iso(now - 40)))
        self.assertEqual(v["vital_state"], "STOPPED")
        v = self._eval(now, self._tab(now, is_dispatching=True, dispatching_since=iso(now - 10)))
        self.assertEqual(v["vital_state"], "LIVE")

    def test_snapshot_card_exposes_contract_fields(self):
        tid = "tsk_v47contract"
        self.write_task(tid)
        c = self.card(self.snap(), tid)
        for f in CONTRACT_FIELDS:
            self.assertIn(f, c)
        self.assertIn(c["VitalState"], ("LIVE", "STOPPED", "UNKNOWN"))
        self.assertIn(c["VitalSubstate"], ("LIVE", "PSEUDO_STOPPED", "DUAL_STREAM", "WAITING_CONFIRM", "NETWORK_HOLD", "CONFIRMED_STOPPED"))
        self.assertIsInstance(c["DualStream"], bool)
        self.assertTrue(c["HasComposer"])
        self.assertFalse(c["HasLoadError"])


# ---------------------------------------------------------------- 2.4
class Slice24GuardianOptionA(V47Base):
    TID = "tsk_v47guard001"
    CONV = "f0000000-0000-4000-8000-0000000000aa"

    def arrange(self, tab_kw=None, brk=None, queue=None, tool_age=600, extra_lines=None, max_retries=2):
        now = time.time()
        self.write_task(self.TID, updated_ep=now - 600)
        self.write_lines([fwd_line(now - tool_age, "wfr_guard01", "rpc-gd1")] + list(extra_lines or []))
        st = shield._ensure_web_bridge_schema(shield._default_web_bridge_state())
        st["auto_resend_config"] = dict(st.get("auto_resend_config") or {}, enabled=True, max_retries=max_retries)
        st["session_bindings"][self.TID] = {
            "conv_uuid": self.CONV, "browser": "Chrome", "browser_profile": "Chrome:Default",
            "target_model": "inherit", "reasoning_effort": "inherit", "max_retries": max_retries,
        }
        tab = {
            "tab_id": "101", "conv_uuid": self.CONV, "url": f"https://chatgpt.com/c/{self.CONV}", "browser": "Chrome",
            "browser_profile": "Chrome:Default", "page_hints": [self.TID], "last_seen_at": iso(now), "state_known": True,
            "sse_active": False, "is_generating": False, "is_dispatching": False, "has_error": True, "has_composer": True,
            "has_load_error": False, "turn_seq": 4, "current_model": "gpt-5-pro", "current_effort": "xhigh",
        }
        tab.update(tab_kw or {})
        st["tabs"] = {"101": tab}
        if brk is not None:
            base_brk = {"baseline_command_count": 10 ** 6, "last_command_count": 10 ** 6, "wakeup_baseline_cmd_cnt": 10 ** 6}
            base_brk.update(brk)
            st["breakers"][self.TID] = base_brk
        st["queue"] = list(queue or [])
        shield._save_web_bridge_state(self.wb_path, st)
        return now

    def tick(self):
        return shield.run_guardian_tick(self.data_root, self.tasks_root, self.wb_path)

    def state(self):
        return shield._load_web_bridge_state(self.wb_path)

    def test_red_error_with_usable_composer_first_wakes_in_place(self):
        self.arrange()
        g = self.tick()
        self.assertEqual([a["action"] for a in g["actions"]], ["in_place_wakeup"])
        st = self.state()
        self.assertEqual(st["breakers"][self.TID]["retry_count"], 1)
        msg = next(m for m in st["queue"] if m["id"] == g["actions"][0]["msg_id"])
        self.assertEqual(msg["conv_uuid"], self.CONV)

    def test_retries_exhausted_escalates_to_handover_inheriting_model_and_effort(self):
        self.arrange(brk={"retry_count": 2, "stage": "Idle"})
        g = self.tick()
        self.assertEqual([a["action"] for a in g["actions"]], ["new_window_handover"])
        msg = next(m for m in self.state()["queue"] if m["id"] == g["actions"][0]["msg_id"])
        self.assertEqual(msg["target_model"], "gpt-5-pro")
        self.assertEqual(msg["reasoning_effort"], "xhigh")

    def test_load_error_or_missing_composer_hands_over_immediately(self):
        self.arrange(tab_kw={"has_load_error": True})
        self.assertEqual([a["action"] for a in self.tick()["actions"]], ["new_window_handover"])
        shield._LOG_READERS.clear()
        self.arrange(tab_kw={"has_composer": False})
        self.assertEqual([a["action"] for a in self.tick()["actions"]], ["new_window_handover"])

    def test_tool_silence_gate_waits_60s(self):
        self.arrange(tool_age=50)
        g = self.tick()
        self.assertEqual(g["actions"], [])
        self.assertEqual([m for m in self.state()["queue"] if m.get("session_key") == self.TID], [])

    def test_network_hold_freezes_dispatch_and_keeps_quota(self):
        now = time.time()
        self.arrange(extra_lines=[err_line(now - 8), err_line(now - 4)], brk={"retry_count": 1, "stage": "Idle", "consecutive_dead_handovers": 1})
        g = self.tick()
        self.assertEqual(g["actions"], [])
        b = self.state()["breakers"][self.TID]
        self.assertEqual(b["last_message"], "检测到本机代理/隧道断网，暂缓派单并保留重试配额")
        self.assertEqual(b["retry_count"], 1)
        self.assertEqual(b["consecutive_dead_handovers"], 1)

    def test_claimed_wakeup_is_never_rewritten(self):
        now = time.time()
        claimed = {"id": "msg_claimed01", "session_key": self.TID, "mode": "in_place_wakeup", "status": "claimed",
                   "conv_uuid": self.CONV, "created_at": iso(now - 5), "claimed_at": iso(now - 4), "claimed_tab_id": "101"}
        self.arrange(tab_kw={"has_load_error": True}, queue=[claimed])
        g = self.tick()
        self.assertEqual(g["actions"], [])
        m = next(x for x in self.state()["queue"] if x["id"] == "msg_claimed01")
        self.assertEqual((m["mode"], m["status"]), ("in_place_wakeup", "claimed"))

    def test_pending_wakeup_upgraded_only_when_handover_condition_met(self):
        now = time.time()
        pending = {"id": "msg_pending01", "session_key": self.TID, "mode": "in_place_wakeup", "status": "pending",
                   "conv_uuid": self.CONV, "created_at": iso(now - 5)}
        self.arrange(queue=[dict(pending)])
        self.assertEqual(self.tick()["actions"], [])
        self.assertEqual(next(x for x in self.state()["queue"] if x["id"] == "msg_pending01")["mode"], "in_place_wakeup")
        shield._LOG_READERS.clear()
        self.arrange(tab_kw={"has_load_error": True}, queue=[dict(pending)])
        g = self.tick()
        self.assertEqual([a["action"] for a in g["actions"]], ["upgraded_to_handover"])
        m = next(x for x in self.state()["queue"] if x["id"] == "msg_pending01")
        self.assertEqual(m["mode"], "new_window_handover")
        self.assertEqual(m["reasoning_effort"], "xhigh")

    def test_observation_lock_90s_only_pierced_by_unusable_page(self):
        now = time.time()
        delivered = {"id": "msg_w1", "session_key": self.TID, "mode": "in_place_wakeup", "status": "delivered",
                     "conv_uuid": self.CONV, "created_at": iso(now - 40), "delivered_at": iso(now - 30)}
        lock_brk = {"retry_count": 1, "stage": "WakeupSent", "last_wakeup_msg_id": "msg_w1", "wakeup_sent_at": iso(now - 40)}
        self.arrange(brk=dict(lock_brk), queue=[dict(delivered)])
        self.assertEqual(self.tick()["actions"], [])
        shield._LOG_READERS.clear()
        self.arrange(brk=dict(lock_brk), queue=[dict(delivered)], tab_kw={"has_load_error": True})
        self.assertEqual([a["action"] for a in self.tick()["actions"]], ["new_window_handover"])


if __name__ == "__main__":
    unittest.main()
