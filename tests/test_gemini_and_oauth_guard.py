import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from http.server import HTTPServer

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

import McpReadOnlyShield as shield


def _pick_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


class _ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class _MiniUpstreamHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _reply(self):
        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            doc = json.loads(raw.decode("utf-8"))
        except Exception:
            doc = {}
        self.server.calls.append({"method": self.command, "path": self.path, "id": doc.get("id")})
        out = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": doc.get("id", 1),
                "result": {"tools": [{"name": "ping_tool"}]},
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(out)

    def do_POST(self):
        self._reply()

    def do_GET(self):
        out = b": sse-ok\n\n"
        self.server.calls.append({"method": "GET", "path": self.path, "id": None})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_DELETE(self):
        self.server.calls.append({"method": "DELETE", "path": self.path, "id": None})
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")


class GeminiAndOAuthGuardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp_dir = tempfile.mkdtemp(prefix="rs_gemini_oauth_test_")
        cls.tasks_root = os.path.join(cls.tmp_dir, "tasks")
        cls.data_root = os.path.join(cls.tmp_dir, "data")
        os.makedirs(cls.tasks_root, exist_ok=True)
        os.makedirs(os.path.join(cls.data_root, "logs"), exist_ok=True)
        cls.prev_data_dir = os.environ.get("RELAYSTUDIO_DATA_DIR")
        os.environ["RELAYSTUDIO_DATA_DIR"] = cls.data_root
        shield._OAUTH_SECRET_CACHE = None

        cls.upstream_port = _pick_free_port()
        cls.upstream_srv = _ThreadingHTTPServer(("127.0.0.1", cls.upstream_port), _MiniUpstreamHandler)
        cls.upstream_srv.calls = []
        cls.upstream_thread = threading.Thread(target=cls.upstream_srv.serve_forever, daemon=True)
        cls.upstream_thread.start()

        cls.shield_srv = shield.ShieldServer(
            ("127.0.0.1", 0),
            f"http://127.0.0.1:{cls.upstream_port}/mcp",
            os.path.join(cls.data_root, "logs", "shield-activity.json"),
            tasks_root=cls.tasks_root,
            data_root=cls.data_root,
        )
        cls.shield_port = cls.shield_srv.server_address[1]
        cls.wb_path = cls.shield_srv.web_bridge_path
        cls.shield_thread = threading.Thread(target=cls.shield_srv.serve_forever, daemon=True)
        cls.shield_thread.start()

    @classmethod
    def tearDownClass(cls):
        try:
            cls.shield_srv.shutdown()
            cls.shield_srv.server_close()
        except Exception:
            pass
        try:
            cls.upstream_srv.shutdown()
            cls.upstream_srv.server_close()
        except Exception:
            pass
        if cls.prev_data_dir is None:
            os.environ.pop("RELAYSTUDIO_DATA_DIR", None)
        else:
            os.environ["RELAYSTUDIO_DATA_DIR"] = cls.prev_data_dir
        shield._OAUTH_SECRET_CACHE = None
        shutil.rmtree(cls.tmp_dir, ignore_errors=True)

    def _raw_http(self, method: str, path: str, headers: dict, body: bytes = b"") -> tuple[int, dict, bytes]:
        conn = http.client.HTTPConnection("127.0.0.1", self.shield_port, timeout=5)
        try:
            conn.request(method, path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            hdrs = {k.lower(): v for k, v in resp.getheaders()}
            return resp.status, hdrs, data
        finally:
            conn.close()

    def test_01_public_tunnel_mcp_oauth_guard_matrix_and_keepalive_safety(self):
        mcp_payload = json.dumps({"jsonrpc": "2.0", "id": "t1", "method": "tools/list", "params": {}}).encode("utf-8")
        valid_tok = shield._sign_oauth_envelope(
            "rs_at",
            {"client_id": "rs_client_ok", "scope": "mcp", "expires_at": int(time.time()) + 3600, "nonce": "n1"},
        )
        expired_tok = shield._sign_oauth_envelope(
            "rs_at",
            {"client_id": "rs_client_ok", "scope": "mcp", "expires_at": int(time.time()) - 60, "nonce": "n2"},
        )
        refresh_tok = shield._sign_oauth_envelope(
            "rs_rt",
            {"client_id": "rs_client_ok", "scope": "mcp", "expires_at": int(time.time()) + 3600, "nonce": "n3"},
        )
        tampered_tok = valid_tok[:-4] + ("AAAA" if valid_tok[-4:] != "AAAA" else "BBBB")

        # 1. Loopback & OpenAI private tunnel-client requests without Authorization MUST pass (200 OK)
        for local_hdrs in (
            {"Host": f"127.0.0.1:{self.shield_port}", "Content-Type": "application/json"},
            {"Host": f"localhost:{self.shield_port}", "Content-Type": "application/json"},
            {"Host": f"[::1]:{self.shield_port}", "Content-Type": "application/json"},
            {
                "Host": f"127.0.0.1:{self.shield_port}",
                "User-Agent": "oai-tunnel-client/0.0.14+db2a944eb17464ef923dfee2be695ef8dbba76cf",
                "Content-Type": "application/json",
            },
        ):
            st, _, raw = self._raw_http("POST", "/mcp", local_hdrs, mcp_payload)
            self.assertEqual(st, 200, f"Loopback/OpenAI tunnel failed for {local_hdrs}")
            self.assertIn("tools", json.loads(raw.decode("utf-8")).get("result") or {})

        st_get_local, _, _ = self._raw_http("GET", "/mcp", {"Host": f"127.0.0.1:{self.shield_port}"})
        self.assertEqual(st_get_local, 200)

        # 2. Public tunnel scenarios MUST require valid rs_at Bearer on POST /mcp, GET /mcp, and DELETE /mcp
        public_vectors = [
            (
                "tailscale_funnel",
                {
                    "Host": "studio.tail9988.ts.net",
                    "Tailscale-Funnel-Request": "?1",
                },
                "https://studio.tail9988.ts.net/.well-known/oauth-protected-resource",
            ),
            (
                "cloudflare_quick_tunnel",
                {
                    "Host": "random-words.trycloudflare.com",
                    "Cf-Connecting-Ip": "203.0.113.42",
                    "Cf-Ray": "89abcdef01234567-LAX",
                    "X-Forwarded-Proto": "https",
                },
                "https://random-words.trycloudflare.com/.well-known/oauth-protected-resource",
            ),
            (
                "custom_public_domain_host_only",
                {
                    "Host": "mcp.example.com:8443",
                    "X-Forwarded-Proto": "https",
                },
                "https://mcp.example.com:8443/.well-known/oauth-protected-resource",
            ),
            (
                "x_forwarded_for_reverse_proxy",
                {
                    "Host": f"127.0.0.1:{self.shield_port}",
                    "X-Forwarded-Host": "relay.example.org",
                    "X-Forwarded-Proto": "https",
                    "X-Forwarded-For": "198.51.100.7",
                },
                "https://relay.example.org/.well-known/oauth-protected-resource",
            ),
        ]

        before_upstream = len(self.upstream_srv.calls)
        for label, pub_hdrs, expected_meta in public_vectors:
            # Missing Authorization on POST /mcp -> 401
            st_post, hdrs_post, _ = self._raw_http(
                "POST",
                "/mcp",
                {**pub_hdrs, "Content-Type": "application/json"},
                mcp_payload,
            )
            self.assertEqual(st_post, 401, f"{label}: unauthenticated POST /mcp must return 401")
            self.assertIn(f'resource_metadata="{expected_meta}"', hdrs_post.get("www-authenticate", ""))

            # Missing Authorization on GET /mcp -> 401
            st_get, hdrs_get, _ = self._raw_http("GET", "/mcp", dict(pub_hdrs))
            self.assertEqual(st_get, 401, f"{label}: unauthenticated GET /mcp must return 401")
            self.assertIn(f'resource_metadata="{expected_meta}"', hdrs_get.get("www-authenticate", ""))

            # Missing Authorization on DELETE /mcp -> 401
            st_del, _, _ = self._raw_http("DELETE", "/mcp", dict(pub_hdrs))
            self.assertEqual(st_del, 401, f"{label}: unauthenticated DELETE /mcp must return 401")

            # Non-rs_at Bearer, refresh token, expired rs_at, tampered rs_at -> 401
            for bad_auth in (
                "Bearer opaque_non_rs_at_token",
                f"Bearer {refresh_tok}",
                f"Bearer {expired_tok}",
                f"Bearer {tampered_tok}",
                "Basic dXNlcjpwYXNz",
            ):
                st_bad, hdrs_bad, _ = self._raw_http(
                    "POST",
                    "/mcp",
                    {**pub_hdrs, "Content-Type": "application/json", "Authorization": bad_auth},
                    mcp_payload,
                )
                self.assertEqual(st_bad, 401, f"{label} with {bad_auth[:18]} must return 401")
                self.assertIn("Bearer realm=", hdrs_bad.get("www-authenticate", ""))

        # None of those rejected requests may reach upstream
        self.assertEqual(len(self.upstream_srv.calls), before_upstream)

        # 3. Valid rs_at token + HTTP/1.1 keep-alive body drain verification
        conn = http.client.HTTPConnection("127.0.0.1", self.shield_port, timeout=5)
        try:
            large_body = json.dumps(
                {"jsonrpc": "2.0", "id": "unauth-big", "method": "tools/list", "params": {"pad": "X" * 8192}}
            ).encode("utf-8")
            conn.request(
                "POST",
                "/mcp",
                body=large_body,
                headers={
                    "Host": "studio.tail9988.ts.net",
                    "Tailscale-Funnel-Request": "?1",
                    "Content-Type": "application/json",
                    "Connection": "keep-alive",
                },
            )
            r1 = conn.getresponse()
            r1.read()
            self.assertEqual(r1.status, 401)

            # Reuse exact same TCP socket with valid Bearer token
            conn.request(
                "POST",
                "/mcp",
                body=mcp_payload,
                headers={
                    "Host": "studio.tail9988.ts.net",
                    "Tailscale-Funnel-Request": "?1",
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {valid_tok}",
                    "Connection": "keep-alive",
                },
            )
            r2 = conn.getresponse()
            doc2 = json.loads(r2.read().decode("utf-8"))
            self.assertEqual(r2.status, 200)
            self.assertIn("tools", doc2.get("result") or {})

            # Valid Bearer on GET /mcp over public tunnel -> 200 OK
            conn.request(
                "GET",
                "/mcp",
                headers={
                    "Host": "studio.tail9988.ts.net",
                    "Tailscale-Funnel-Request": "?1",
                    "Authorization": f"Bearer {valid_tok}",
                },
            )
            r3 = conn.getresponse()
            r3.read()
            self.assertEqual(r3.status, 200)
        finally:
            conn.close()

    def test_02_gemini_multi_account_and_gem_url_routing_and_ack_persistence(self):
        # Unit-level URL extraction and reconstruction
        self.assertEqual(
            shield._extract_conv_uuid_from_url("https://gemini.google.com/u/1/app/room_abc_123", "gemini"),
            "room_abc_123",
        )
        self.assertEqual(
            shield._extract_conv_uuid_from_url("https://gemini.google.com/gem/coding-partner/gem_conv_99", "gemini"),
            "gem_conv_99",
        )
        self.assertEqual(
            shield._extract_conv_uuid_from_url("https://gemini.google.com/u/2/gem/math-tutor/gem_conv_42?hl=zh", "gemini"),
            "gem_conv_42",
        )
        self.assertEqual(shield._extract_conv_uuid_from_url("https://gemini.google.com/u/1/app", "gemini"), "")
        self.assertEqual(shield._extract_conv_uuid_from_url("https://gemini.google.com/gem/coding-partner", "gemini"), "")

        self.assertEqual(
            shield._extract_project_prefix("https://gemini.google.com/u/1/app/room_abc_123", provider_hint="gemini"),
            "https://gemini.google.com/u/1/app",
        )
        self.assertEqual(
            shield._extract_project_prefix("https://gemini.google.com/u/1/gem/coding-partner/gem_conv_99", provider_hint="gemini"),
            "https://gemini.google.com/u/1/gem/coding-partner",
        )
        self.assertEqual(
            shield._extract_project_prefix("https://gemini.google.com/gem/coding-partner", provider_hint="gemini"),
            "https://gemini.google.com/gem/coding-partner",
        )
        self.assertEqual(
            shield._extract_project_prefix("", explicit_prefix="/u/3/gem/writer-pro", provider_hint="gemini"),
            "https://gemini.google.com/u/3/gem/writer-pro",
        )
        # Cross-provider isolation: ChatGPT project prefix must not leak onto Gemini
        self.assertEqual(
            shield._extract_project_prefix("", explicit_prefix="https://chatgpt.com/g/g-p-123456", provider_hint="gemini"),
            "",
        )

        # Room URL & handover URL construction preserves /u/<n> and /gem/<slug>
        rec_u1 = {"provider": "gemini", "project_prefix": "https://gemini.google.com/u/1/app"}
        self.assertEqual(
            shield._platform_room_url(rec_u1, "conv_u1_77"),
            "https://gemini.google.com/u/1/app/conv_u1_77",
        )
        self.assertEqual(
            shield._build_handover_url(
                shield._platform_base(rec_u1),
                msg_id="msg_h1",
                browser_profile="Chrome:Profile 1",
                provider="gemini",
            ),
            "https://gemini.google.com/u/1/app?relay_handover=1&msg_id=msg_h1&provider=gemini&relay_profile=Chrome%3AProfile%201",
        )

        rec_gem = {"provider": "gemini", "project_prefix": "https://gemini.google.com/u/2/gem/coding-partner"}
        self.assertEqual(
            shield._platform_room_url(rec_gem, "conv_gem_88"),
            "https://gemini.google.com/u/2/gem/coding-partner/conv_gem_88",
        )
        self.assertEqual(
            shield._build_handover_url(
                shield._platform_base(rec_gem),
                msg_id="msg_h2",
                browser_profile="Chrome:Profile 2",
                provider="gemini",
            ),
            "https://gemini.google.com/u/2/gem/coding-partner?relay_handover=1&msg_id=msg_h2&provider=gemini&relay_profile=Chrome%3AProfile%202",
        )

        # End-to-end web-bridge poll + handover + ack-deliver persistence for /u/1/gem/coding-partner
        task_id = "tsk_gemu1_aabbcc"
        wb_state = shield._load_web_bridge_state(self.wb_path)
        wb_state["session_bindings"][task_id] = shield._ensure_binding_entry(
            {
                "conv_uuid": "old_gem_conv",
                "provider": "gemini",
                "project_prefix": "https://gemini.google.com/u/1/gem/coding-partner",
                "browser": "Chrome",
                "browser_profile": "Chrome:Default",
            }
        )
        msg_id = "msg_gem_handover_01"
        wb_state["queue"].append(
            {
                "id": msg_id,
                "session_key": task_id,
                "task_id": task_id,
                "provider": "gemini",
                "mode": "new_window_handover",
                "open_new_tab": True,
                "project_prefix": "https://gemini.google.com/u/1/gem/coding-partner",
                "target_profile": "Chrome:Default",
                "text": f"Continue task {task_id}",
                "status": "pending",
                "created_at": shield._utc_now_iso(),
            }
        )
        shield._save_web_bridge_state(self.wb_path, wb_state)

        poll_res = shield.handle_web_bridge_poll(
            self.wb_path,
            self.tasks_root,
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Default",
                "browser_instance_id": "inst_chrome_gemtest",
                "tabs": [
                    {
                        "tab_id": "901",
                        "provider": "gemini",
                        "conv_uuid": "old_gem_conv",
                        "project_prefix": "https://gemini.google.com/u/1/gem/coding-partner",
                        "url": "https://gemini.google.com/u/1/gem/coding-partner/old_gem_conv",
                        "title": "Gemini U1 Gem",
                        "state_known": True,
                    }
                ],
            },
        )
        dispatches = poll_res.get("dispatches") or []
        self.assertEqual(len(dispatches), 1)
        self.assertTrue(dispatches[0].get("open_new_tab"))
        self.assertTrue(
            dispatches[0]["handover_url"].startswith("https://gemini.google.com/u/1/gem/coding-partner?"),
            dispatches[0]["handover_url"],
        )

        # Simulate background tab 902 opening at handover_url and claiming the handover message via poll
        poll_res_2 = shield.handle_web_bridge_poll(
            self.wb_path,
            self.tasks_root,
            {
                "browser": "Chrome",
                "browser_profile": "Chrome:Default",
                "browser_instance_id": "inst_chrome_gemtest",
                "tabs": [
                    {
                        "tab_id": "902",
                        "provider": "gemini",
                        "conv_uuid": "",
                        "project_prefix": "https://gemini.google.com/u/1/gem/coding-partner",
                        "url": dispatches[0]["handover_url"],
                        "handover_msg_id": msg_id,
                        "title": "Gemini U1 Gem Handover",
                        "state_known": True,
                    }
                ],
            },
        )
        dispatches_2 = poll_res_2.get("dispatches") or []
        self.assertEqual(len(dispatches_2), 1)
        self.assertEqual(dispatches_2[0].get("tab_id"), "902")

        # Simulate handover tab 902 ACKing delivery after Gemini pushed /u/1/gem/coding-partner/new_gem_conv_555
        ack_st, _, ack_raw = self._raw_http(
            "POST",
            "/web-bridge/ack-deliver",
            {"Host": f"127.0.0.1:{self.shield_port}", "Content-Type": "application/json"},
            json.dumps(
                {
                    "msg_id": msg_id,
                    "tab_id": "902",
                    "provider": "gemini",
                    "conv_uuid": "new_gem_conv_555",
                    "project_prefix": "https://gemini.google.com/u/1/gem/coding-partner",
                }
            ).encode("utf-8"),
        )
        self.assertEqual(ack_st, 200)
        self.assertTrue(json.loads(ack_raw.decode("utf-8")).get("ok"))

        updated_wb = shield._load_web_bridge_state(self.wb_path)
        bound = updated_wb["session_bindings"][task_id]
        self.assertEqual(bound["conv_uuid"], "new_gem_conv_555")
        self.assertEqual(bound["project_prefix"], "https://gemini.google.com/u/1/gem/coding-partner")
        self.assertEqual(
            shield._platform_room_url(bound, bound["conv_uuid"]),
            "https://gemini.google.com/u/1/gem/coding-partner/new_gem_conv_555",
        )

    def test_03_browser_extension_gemini_and_claude_dom_and_retire_suite(self):
        node_script = r"""
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const repo = process.cwd();
const contentSrc = fs.readFileSync(path.join(repo, 'browser-bridge', 'bridge-content.js'), 'utf8');
const bgSrc = fs.readFileSync(path.join(repo, 'browser-bridge', 'background.js'), 'utf8');

function mountContent({
  href = 'https://gemini.google.com/u/1/app/conv_init_1',
  userNodes = [],
  turnNodes = [],
  errorNodes = [],
  stopNodes = [],
  composerStopNodes = [],
  badgeNodes = [],
  onSendClick = null,
  autoAdvanceMsPerSleep = 0,
} = {}) {
  let u = new URL(href);
  let listener = null;
  const loc = {
    get href() { return u.toString(); },
    set href(v) { u = new URL(v); },
    get pathname() { return u.pathname; },
    get search() { return u.search; },
  };
  let nowMs = 1700000000000;
  const dataset = {};
  const composerScope = {
    querySelectorAll(sel) {
      if (sel.includes('Stop') || sel.includes('stop-button')) return composerStopNodes;
      return [];
    },
  };
  const composer = {
    tagName: 'DIV',
    value: '',
    innerText: '',
    textContent: '',
    isContentEditable: true,
    offsetParent: {},
    parentElement: composerScope,
    focus() {},
    getAttribute(k) { return k === 'contenteditable' ? 'true' : null; },
    hasAttribute() { return false; },
    closest(sel) {
      if (sel.includes('input-area-v2')) return composerScope;
      return null;
    },
    getBoundingClientRect() { return { width: 400, height: 48 }; },
    dispatchEvent() { return true; },
    appendChild() {},
  };
  const sendBtn = {
    disabled: false,
    className: 'send-button',
    getAttribute() { return 'Send message'; },
    hasAttribute() { return false; },
    closest() { return null; },
    getBoundingClientRect() { return { width: 32, height: 32 }; },
    click() {
      if (onSendClick) onSendClick({ composer, userNodes, setUrl: (nextUrl) => { u = new URL(nextUrl); }, sendBtn });
    },
  };
  const doc = {
    readyState: 'complete',
    title: 'Gemini Test',
    documentElement: { dataset },
    body: { appendChild() {} },
    getElementById() { return { style: {}, textContent: '' }; },
    execCommand(op, _ui, txt) {
      if (op === 'insertText') { composer.innerText = txt; composer.textContent = txt; }
      if (op === 'delete') { composer.innerText = ''; composer.textContent = ''; }
      return true;
    },
    querySelector(sel) {
      if (sel === 'rich-textarea [contenteditable="true"]' || sel === 'div.ProseMirror[contenteditable="true"]') return composer;
      return null;
    },
    querySelectorAll(sel) {
      if (sel === 'rich-textarea [contenteditable="true"]' || sel === 'div.ProseMirror[contenteditable="true"]') return [composer];
      if (sel === 'user-query, [data-testid="user-query"]' || sel === '[data-testid="user-message"]') return userNodes;
      if (sel === 'user-query, model-response' || sel === '[data-testid="user-message"], .font-claude-message, [data-is-streaming]') return turnNodes;
      if (sel.includes('conversation-error')) return errorNodes;
      if (sel.includes('Stop response') || sel.includes('停止响应')) return stopNodes;
      if (sel.includes('bard-mode')) return badgeNodes;
      if (sel === 'button.send-button' || sel === 'button[aria-label="Send message"]') return [sendBtn];
      return [];
    },
    addEventListener() {},
  };
  class FakeEvent { constructor(type, init) { this.type = type; this.detail = init && init.detail; } }
  const win = {
    location: loc,
    history: { replaceState(_s, _t, urlStr) { if (urlStr) u = new URL(urlStr, u.toString()); } },
    addEventListener() {},
    removeEventListener() {},
    dispatchEvent() { return true; },
    getSelection() { return { removeAllRanges() {}, addRange() {} }; },
    CustomEvent: FakeEvent,
  };
  doc.createRange = () => ({ selectNodeContents() {} });
  doc.createElement = () => ({ style: {}, textContent: '' });

  const DateFake = Object.assign(function (...a) { return a.length ? new Date(...a) : new Date(nowMs); }, { now: () => nowMs });
  const ctx = {
    window: win,
    document: doc,
    URL,
    URLSearchParams,
    navigator: { userAgent: 'Mozilla/5.0 Chrome/131.0' },
    localStorage: { getItem() { return null; }, setItem() {} },
    chrome: {
      runtime: {
        onMessage: { addListener(fn) { listener = fn; } },
        sendMessage(_m, cb) { if (cb) cb({ shuttle_active: true }); },
        lastError: null,
      },
    },
    InputEvent: FakeEvent,
    Event: FakeEvent,
    KeyboardEvent: FakeEvent,
    CustomEvent: FakeEvent,
    setTimeout(cb, ms) {
      if ([700, 3200, 35000].includes(ms)) return 0;
      if (autoAdvanceMsPerSleep > 0) nowMs += autoAdvanceMsPerSleep;
      queueMicrotask(cb);
      return 0;
    },
    clearTimeout() {},
    setInterval() { return 0; },
    Date: DateFake,
    Math,
    console,
  };
  vm.createContext(ctx);
  vm.runInContext(contentSrc, ctx, { filename: 'bridge-content.js' });
  return {
    composer,
    sendBtn,
    setUrl(v) { u = new URL(v); },
    advanceTime(ms) { nowMs += ms; },
    collect() { return new Promise((res) => listener({ type: 'RELAY_COLLECT_TAB_STATE' }, {}, (r) => res(r.state))); },
    dispatch(message) { return new Promise((res) => listener({ type: 'RELAY_EXECUTE_DISPATCH', message }, {}, res)); },
  };
}

function visibleEl(props = {}) {
  return {
    hidden: false,
    disabled: false,
    className: '',
    tagName: 'DIV',
    innerText: '',
    textContent: '',
    hasAttribute() { return false; },
    getAttribute(k) { return props.attrs && k in props.attrs ? props.attrs[k] : null; },
    closest(sel) { return props.closestMatch && props.closestMatch(sel) ? {} : null; },
    getBoundingClientRect() { return { width: 100, height: 24 }; },
    contains(other) { return Array.isArray(props.children) && props.children.includes(other); },
    ...props,
  };
}

(async () => {
  // 1. Multi-account (/u/<n>) & Gem (/gem/<slug>/<id>) URL parsing + model badge + hints + turn_seq + checkTurnIncomplete + UI_ERROR_EXCLUDE
  const uTurn1 = visibleEl({ tagName: 'USER-QUERY', textContent: 'You said\nHello tsk_112233aabbcc\nedit' });
  const mTurn1 = visibleEl({ tagName: 'MODEL-RESPONSE', textContent: 'Working on wfr_99887766aabbccdd' });
  const politeStatus = visibleEl({
    tagName: 'DIV',
    className: 'cdk-live-announcer-element',
    innerText: 'Message sent',
    textContent: 'Message sent',
    attrs: { 'aria-live': 'polite', role: 'status' },
  });
  const modelReplyErrQuote = visibleEl({
    tagName: 'DIV',
    innerText: 'Error: example inside model-response',
    textContent: 'Error: example inside model-response',
    closestMatch: (sel) => sel.includes('model-response'),
  });
  const badgeBtn = visibleEl({
    tagName: 'BUTTON',
    innerText: '2.5 Pro\nkeyboard_arrow_down',
    textContent: '2.5 Prokeyboard_arrow_down',
  });

  const gemEnv = mountContent({
    href: 'https://gemini.google.com/u/2/gem/coding-partner/gem_room_42',
    turnNodes: [uTurn1, mTurn1],
    errorNodes: [politeStatus, modelReplyErrQuote],
    badgeNodes: [badgeBtn],
  });
  const st1 = await gemEnv.collect();
  assert.equal(st1.provider, 'gemini');
  assert.equal(st1.conv_uuid, 'gem_room_42');
  assert.equal(st1.project_prefix, 'https://gemini.google.com/u/2/gem/coding-partner');
  assert.equal(st1.current_model, '2.5 Pro');
  assert.equal(st1.turn_seq, 2);
  assert.equal(st1.turn_incomplete, false);
  assert.equal(st1.has_error, false, 'Polite status announcer and model-response quote must NOT trigger has_error');
  assert.ok(st1.page_hints.includes('tsk_112233aabbcc'));
  assert.ok(st1.page_hints.includes('wfr_99887766aabbccdd'));

  // Lone user-query on Gemini -> turn_incomplete = true
  const loneEnv = mountContent({
    href: 'https://gemini.google.com/u/1/app/room_lone',
    turnNodes: [uTurn1],
  });
  const stLone = await loneEnv.collect();
  assert.equal(stLone.conv_uuid, 'room_lone');
  assert.equal(stLone.project_prefix, 'https://gemini.google.com/u/1/app');
  assert.equal(stLone.turn_incomplete, true);
  assert.equal(stLone.has_error, true);

  // Broadened Gemini Stop button inside composer area ('Stop' / 'Stop generating')
  const compStop = visibleEl({ tagName: 'BUTTON', className: 'stop-button', attrs: { 'aria-label': 'Stop' } });
  const stopEnv = mountContent({
    href: 'https://gemini.google.com/app/room_gen',
    composerStopNodes: [compStop],
  });
  const stStop = await stopEnv.collect();
  assert.equal(stStop.is_generating, true);
  assert.equal(stStop.project_prefix, '');

  // Claude turn_seq, hints, and nested streaming deduplication
  const claudeUser = visibleEl({ tagName: 'DIV', textContent: 'User prompt tsk_abcdef123456', attrs: { 'data-testid': 'user-message' } });
  const claudeInner = visibleEl({ tagName: 'DIV', className: 'font-claude-message', textContent: 'Claude reply' });
  const claudeOuter = visibleEl({ tagName: 'DIV', textContent: 'Claude reply', attrs: { 'data-is-streaming': 'false' }, children: [claudeInner] });
  const claudeEnv = mountContent({
    href: 'https://claude.ai/chat/claude_room_9',
    turnNodes: [claudeUser, claudeOuter, claudeInner],
  });
  const stClaude = await claudeEnv.collect();
  assert.equal(stClaude.provider, 'claude');
  assert.equal(stClaude.conv_uuid, 'claude_room_9');
  assert.equal(stClaude.turn_seq, 2, 'Nested .font-claude-message inside [data-is-streaming] must be deduplicated');
  assert.equal(stClaude.turn_incomplete, false);
  assert.ok(stClaude.page_hints.includes('tsk_abcdef123456'));

  // 2. Gemini fillAndSendMessage receipt normalization ("You said" + collapsed \n\n + "edit\nexpand_more") + delayed pushState conv_uuid
  let pollCounter = 0;
  const handoverEnv = mountContent({
    href: 'https://gemini.google.com/u/1/app?relay_handover=1&msg_id=m_delay_1',
    onSendClick({ composer, userNodes, setUrl }) {
      composer.innerText = '';
      composer.textContent = '';
      const rendered = visibleEl({
        tagName: 'USER-QUERY',
        innerText: 'You said\nLine one of handover instruction\nLine two with details for task tsk_998877\nedit\nexpand_more\ncontent_copy',
        textContent: 'You said Line one of handover instruction Line two with details for task tsk_998877 edit expand_more content_copy',
      });
      userNodes.push(rendered);
      // Simulate Gemini pushing /u/1/app/<id> after 5 polls
      const origQuery = userNodes.slice;
      setTimeout(() => {}, 0);
      handoverEnv._pushed = false;
      Object.defineProperty(rendered, 'innerText', {
        get() {
          pollCounter += 1;
          if (pollCounter >= 6 && !handoverEnv._pushed) {
            handoverEnv._pushed = true;
            setUrl('https://gemini.google.com/u/1/app/delayed_room_888');
          }
          return 'You said\nLine one of handover instruction\nLine two with details for task tsk_998877\nedit\nexpand_more\ncontent_copy';
        },
      });
    },
  });
  const multiLinePrompt = 'Line one of handover instruction\n\nLine two with details for task tsk_998877';
  const disp1 = await handoverEnv.dispatch({ id: 'm_delay_1', provider: 'gemini', text: multiLinePrompt });
  assert.equal(disp1.ok, true);
  assert.equal(disp1.conv_uuid, 'delayed_room_888');
  assert.equal(disp1.project_prefix, 'https://gemini.google.com/u/1/app');

  // 3. Gem handover where URL stays /u/1/gem/coding-partner without room ID: still accepts after grace wait once bubble + cleared composer confirmed
  const gemNoIdEnv = mountContent({
    href: 'https://gemini.google.com/u/1/gem/coding-partner',
    autoAdvanceMsPerSleep: 250,
    onSendClick({ composer, userNodes }) {
      composer.innerText = '';
      composer.textContent = '';
      userNodes.push(
        visibleEl({
          tagName: 'USER-QUERY',
          innerText: '你说过：\n短指令测试\n编辑\n展开',
          textContent: '你说过： 短指令测试 编辑 展开',
        })
      );
    },
  });
  const disp2 = await gemNoIdEnv.dispatch({ id: 'm_gem_noid', provider: 'gemini', text: '短指令测试' });
  assert.equal(disp2.ok, true);
  assert.equal(disp2.conv_uuid, '');
  assert.equal(disp2.project_prefix, 'https://gemini.google.com/u/1/gem/coding-partner');

  // 4. background.js URL helpers & handleShuttleRetireActions on Gemini/Claude (open tab AND 0 open tabs)
  const ackRetires = [];
  const removedTabs = [];
  const updatedTabs = [];
  let openTabs = [
    { id: 41, windowId: 1, url: 'https://gemini.google.com/u/1/app/gem_retire_1', title: 'G1' },
    { id: 42, windowId: 1, url: 'https://gemini.google.com/u/1/app/gem_keep_2', title: 'G2' },
    { id: 51, windowId: 2, url: 'https://claude.ai/chat/claude_retire_solo', title: 'C1' },
  ];
  const bgCtx = {
    URL,
    URLSearchParams,
    navigator: { userAgent: 'Mozilla/5.0 Chrome/131.0' },
    fetch: async (url, init) => {
      if (String(url).endsWith('/web-bridge/ack-retire')) {
        ackRetires.push(JSON.parse(init.body));
      }
      return { ok: true, async json() { return {}; } };
    },
    chrome: {
      storage: { local: { get(_k, cb) { if (cb) cb({}); }, set() {} } },
      runtime: { onMessage: { addListener() {} }, lastError: null },
      scripting: { async executeScript() {} },
      alarms: { create() {}, onAlarm: { addListener() {} } },
      tabs: {
        onRemoved: { addListener() {} },
        async query(q) {
          if (q && typeof q.windowId === 'number') return openTabs.filter((t) => t.windowId === q.windowId);
          return openTabs.slice();
        },
        async remove(tabId) {
          removedTabs.push(tabId);
          openTabs = openTabs.filter((t) => t.id !== tabId);
        },
        async update(tabId, props) {
          updatedTabs.push({ tabId, props });
        },
        sendMessage(_tabId, _msg, cb) { if (cb) cb({ ok: true }); },
      },
    },
    setInterval() { return 0; },
    setTimeout() { return 0; },
    clearTimeout() {},
    Date,
    Math,
    console,
  };
  vm.createContext(bgCtx);
  vm.runInContext(
    bgSrc + '\n;globalThis.__bgExports = { extractConvUuidFromUrl, extractConvIdFromUrl, extractProjectPrefixFromUrl, handleShuttleRetireActions };',
    bgCtx,
    { filename: 'background.js' }
  );
  const bg = bgCtx.__bgExports;
  assert.equal(bg.extractConvIdFromUrl('https://gemini.google.com/u/1/app/abc_99'), 'abc_99');
  assert.equal(bg.extractConvUuidFromUrl('https://gemini.google.com/u/2/gem/my-gem/xyz_11'), 'xyz_11');
  assert.equal(bg.extractProjectPrefixFromUrl('https://gemini.google.com/u/1/app/abc_99'), 'https://gemini.google.com/u/1/app');
  assert.equal(bg.extractProjectPrefixFromUrl('https://gemini.google.com/u/2/gem/my-gem/xyz_11'), 'https://gemini.google.com/u/2/gem/my-gem');
  assert.equal(bg.extractProjectPrefixFromUrl('https://gemini.google.com/app/abc_99'), '');

  await bg.handleShuttleRetireActions([
    { id: 'ret_g_arch', provider: 'gemini', conv_uuid: 'gem_retire_1', operation: 'archive', close_tab: true },
    { id: 'ret_g_zero_tabs', provider: 'gemini', conv_uuid: 'already_closed_conv', operation: 'delete', close_tab: true },
    { id: 'ret_g_unarch', provider: 'gemini', conv_uuid: 'gem_keep_2', operation: 'unarchive' },
    { id: 'ret_c_solo', provider: 'claude', conv_uuid: 'claude_retire_solo', operation: 'delete', close_tab: true },
  ]);

  assert.deepEqual(removedTabs, [41], 'Multi-tab window removes retired Gemini tab');
  assert.equal(updatedTabs.length, 1, 'Single-tab Claude window navigates to /new instead of closing window');
  assert.equal(updatedTabs[0].tabId, 51);
  assert.equal(updatedTabs[0].props.url, 'https://claude.ai/new');
  assert.deepEqual(
    ackRetires.map((a) => [a.retire_id, a.ok]),
    [
      ['ret_g_arch', true],
      ['ret_g_zero_tabs', true],
      ['ret_g_unarch', true],
      ['ret_c_solo', true],
    ]
  );

  console.log('ALL_GEMINI_EXTENSION_ASSERTIONS_PASSED');
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
"""
        proc = subprocess.run(
            ["node", "-e", node_script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(proc.returncode, 0, f"Node VM suite failed:\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")
        self.assertIn("ALL_GEMINI_EXTENSION_ASSERTIONS_PASSED", proc.stdout)


if __name__ == "__main__":
    unittest.main()
