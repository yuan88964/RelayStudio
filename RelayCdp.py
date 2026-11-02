"""RelayStudio CDP host adapter (deep module, stdlib only).

Interface (everything a caller must know):
  * ``find_cdp_endpoint(cached_port, probe_fn, http_fn)``  -> where is ChatGPT.exe's DevTools endpoint?
  * ``ChatGptDesktopSession(evaluate)``                     -> read state / deliver / archive inside the
                                                              embedded ``https://chatgpt.com`` webview.
  * ``ensure_chatgpt_desktop(...)``                         -> cold start / hot restart ChatGPT.exe with CDP.
  * ``launch_process(args, minimize_no_activate)``          -> start a process without stealing focus.

Invariants:
  * Nothing here ever calls SetForegroundWindow / Page.bringToFront / chrome.tabs.update.
  * Every browser-side wait lives in Python (``sleep_fn``): hidden or minimized pages throttle timers, so
    page scripts are synchronous one-shot probes (``/*relay:<op>*/`` marker on the first line).
  * Test seams: ``evaluate`` (production = CDP WebSocket, test = fake page), ``probe_fn``/``http_fn`` for
    endpoint discovery and ``run_ps``/``popen_fn`` for process control.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import socket
import struct
import subprocess
import time
import urllib.parse
import urllib.request

CHATGPT_AUMID = "OpenAI.Codex_2p2nqsd0c76g0!App"
FALLBACK_CDP_PORTS = (9222, 9223, 9224, 9229, 9333)
SW_SHOWNORMAL = 1
SW_SHOWMINNOACTIVE = 7
_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
_CREATE_NO_WINDOW = 0x08000000
_MAX_FRAME_BYTES = 32 * 1024 * 1024


class CdpError(RuntimeError):
    pass


# ---------------------------------------------------------------------------------------------------
# Minimal RFC 6455 client + Runtime.evaluate
# ---------------------------------------------------------------------------------------------------

def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise CdpError("websocket closed while reading")
        buf += chunk
    return buf


def _send_frame(sock: socket.socket, opcode: int, payload: bytes) -> None:
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header += struct.pack("!H", length)
    else:
        header.append(0x80 | 127)
        header += struct.pack("!Q", length)
    mask = os.urandom(4)
    header += mask
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(header) + masked)


def _recv_message(sock: socket.socket) -> str:
    chunks: list[bytes] = []
    while True:
        b1, b2 = _recv_exact(sock, 2)
        fin = bool(b1 & 0x80)
        opcode = b1 & 0x0F
        length = b2 & 0x7F
        if length == 126:
            length = struct.unpack("!H", _recv_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", _recv_exact(sock, 8))[0]
        if length > _MAX_FRAME_BYTES:
            raise CdpError("websocket frame too large")
        mask = _recv_exact(sock, 4) if (b2 & 0x80) else b""
        payload = _recv_exact(sock, length) if length else b""
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 0x8:
            raise CdpError("websocket closed by peer")
        if opcode == 0x9:
            _send_frame(sock, 0xA, payload)
            continue
        if opcode == 0xA:
            continue
        chunks.append(payload)
        if fin:
            return b"".join(chunks).decode("utf-8", errors="replace")


def ws_cdp_call(ws_url: str, method: str, params: dict | None = None, timeout: float = 8.0) -> dict:
    """Send one CDP command over a fresh WebSocket and return its ``result`` object."""
    parsed = urllib.parse.urlsplit(ws_url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 80
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    deadline = time.time() + timeout
    sock = socket.create_connection((host, port), timeout=min(timeout, 3.0))
    try:
        sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        sock.sendall(request.encode("ascii"))
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(4096)
            if not chunk:
                raise CdpError("websocket handshake closed")
            head += chunk
            if len(head) > 16384:
                raise CdpError("websocket handshake too large")
        header_text = head.split(b"\r\n\r\n", 1)[0].decode("latin-1")
        if " 101 " not in header_text.split("\r\n", 1)[0]:
            raise CdpError("websocket upgrade refused: " + header_text.split("\r\n", 1)[0])
        expected = base64.b64encode(hashlib.sha1((key + _WS_GUID).encode("ascii")).digest()).decode("ascii")
        if expected.lower() not in header_text.lower():
            raise CdpError("websocket accept key mismatch")
        req_id = 1
        _send_frame(sock, 0x1, json.dumps({"id": req_id, "method": method, "params": params or {}}).encode("utf-8"))
        while True:
            if time.time() > deadline:
                raise CdpError("cdp call timed out")
            sock.settimeout(max(0.2, deadline - time.time()))
            try:
                message = json.loads(_recv_message(sock))
            except socket.timeout:
                raise CdpError("cdp call timed out")
            if isinstance(message, dict) and message.get("id") == req_id:
                if "error" in message:
                    raise CdpError(str(message["error"]))
                return message.get("result") or {}
    finally:
        try:
            sock.close()
        except Exception:
            pass


def cdp_evaluate(ws_url: str, expression: str, await_promise: bool = True, timeout: float = 8.0):
    """Run ``expression`` in the target page and return its JSON-serialisable value."""
    result = ws_cdp_call(
        ws_url,
        "Runtime.evaluate",
        {"expression": expression, "awaitPromise": bool(await_promise), "returnByValue": True, "userGesture": True},
        timeout=timeout,
    )
    if result.get("exceptionDetails"):
        det = result["exceptionDetails"]
        text = (det.get("exception") or {}).get("description") or det.get("text") or "evaluate exception"
        raise CdpError(str(text))
    return (result.get("result") or {}).get("value")


# ---------------------------------------------------------------------------------------------------
# Endpoint discovery
# ---------------------------------------------------------------------------------------------------

def http_json(url: str, timeout: float = 1.5):
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def list_cdp_targets(port: int, http_fn=None) -> list[dict]:
    fetch = http_fn or http_json
    try:
        items = fetch(f"http://127.0.0.1:{int(port)}/json/list")
    except Exception:
        return []
    return [it for it in items if isinstance(it, dict)] if isinstance(items, list) else []


def pick_targets(targets: list[dict]) -> dict:
    """Return {'main_page': clean app://-/index.html page, 'shell': alias of main_page, 'webview': legacy non-pricing webview}.

    Spec v4.2 Plan C strictly locks onto ``type == "page"`` with clean ``url`` in ``("app://-/index.html", "app://-")``,
    excluding auxiliary popups (``?initialRoute=``, ``detached-window.html``), embedded ``#pricing`` webviews,
    and ``codex-sandbox://`` frames.
    """
    main_page = None
    webview = None
    for t in targets or []:
        url = str(t.get("url") or "").strip()
        low_url = url.lower()
        ttype = str(t.get("type") or "").strip()
        clean_url = url.rstrip("/")
        if ttype == "page" and clean_url in ("app://-/index.html", "app://-") and main_page is None:
            main_page = t
        elif (
            ttype in ("webview", "page")
            and "chatgpt.com" in low_url
            and "#pricing" not in low_url
            and "codex_app_embedded" not in low_url
            and webview is None
        ):
            webview = t
    return {"main_page": main_page, "shell": main_page, "webview": webview}


_PROBE_PS = r"""
$procs = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue | Select-Object ProcessId,CommandLine)
$ids = @($procs | ForEach-Object { $_.ProcessId })
$ports = @()
if ($ids.Count -gt 0) {
  $ports = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { ($ids -contains $_.OwningProcess) -and ($_.LocalAddress -eq '127.0.0.1' -or $_.LocalAddress -eq '::1') } | Select-Object -ExpandProperty LocalPort)
}
[pscustomobject]@{ procs = $procs; ports = $ports } | ConvertTo-Json -Compress -Depth 4
"""


def run_powershell(script: str, timeout: float = 8.0) -> str:
    flags = _CREATE_NO_WINDOW if os.name == "nt" else 0
    res = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "[Console]::OutputEncoding=[Text.Encoding]::UTF8;" + script],
        capture_output=True,
        timeout=timeout,
        creationflags=flags,
    )
    return res.stdout.decode("utf-8", errors="replace")


def probe_chatgpt_host(run_ps=None) -> dict:
    """Inspect running ChatGPT.exe processes: {'running', 'main_pid', 'cmd_ports', 'listen_ports'}."""
    runner = run_ps or run_powershell
    info = {"running": False, "main_pid": 0, "cmd_ports": [], "listen_ports": []}
    try:
        raw = (runner(_PROBE_PS) or "").strip()
        data = json.loads(raw) if raw else {}
    except Exception:
        return info
    procs = data.get("procs") if isinstance(data, dict) else None
    if isinstance(procs, dict):
        procs = [procs]
    for p in procs or []:
        if not isinstance(p, dict):
            continue
        info["running"] = True
        cmd = str(p.get("CommandLine") or "")
        if "--type=" not in cmd and not info["main_pid"]:
            info["main_pid"] = int(p.get("ProcessId") or 0)
        m = re.search(r"--remote-debugging-port=(\d+)", cmd)
        if m and "--type=" not in cmd:
            info["cmd_ports"].append(int(m.group(1)))
    ports = data.get("ports") if isinstance(data, dict) else None
    if isinstance(ports, (int, float)):
        ports = [ports]
    info["listen_ports"] = [int(x) for x in (ports or []) if str(x).isdigit()]
    return info


def find_cdp_endpoint(cached_port: int | None = None, probe_fn=None, http_fn=None) -> dict:
    """Locate a DevTools endpoint exposing ChatGPT.exe's clean ``app://-/index.html`` main window.

    Returns {'port', 'targets', 'running', 'main_pid'}; ``port`` is None when nothing usable was found
    (``running`` tells the caller whether ChatGPT.exe is alive without a debug port).
    """
    seen: list[int] = []

    def try_port(port):
        if port in seen or not port:
            return None
        seen.append(port)
        targets = list_cdp_targets(port, http_fn)
        picked = pick_targets(targets)
        if picked.get("main_page"):
            return targets
        return None

    if cached_port:
        targets = try_port(int(cached_port))
        if targets:
            return {"port": int(cached_port), "targets": targets, "running": True, "has_debug_port": True, "main_pid": 0}

    info = (probe_fn or probe_chatgpt_host)()
    for port in list(info.get("cmd_ports") or []) + list(info.get("listen_ports") or []):
        targets = try_port(int(port))
        if targets:
            return {"port": int(port), "targets": targets, "running": True, "has_debug_port": True, "main_pid": info.get("main_pid", 0)}
    if info.get("running") and (probe_fn is None or http_fn is not None):
        # ChatGPT.exe is alive but no known port answered; a last blind probe of the usual ports. Only the real
        # app://-/index.html main window is accepted so that a user's own debug-enabled Chrome is never adopted.
        for port in FALLBACK_CDP_PORTS:
            targets = try_port(port)
            if targets:
                return {"port": port, "targets": targets, "running": True, "has_debug_port": True, "main_pid": info.get("main_pid", 0)}
    has_debug_port = bool(info.get("cmd_ports") or info.get("listen_ports"))
    return {
        "port": None,
        "targets": [],
        "running": bool(info.get("running")),
        "booting": has_debug_port,
        "has_debug_port": has_debug_port,
        "main_pid": info.get("main_pid", 0),
    }


def _extract_effort_items(raw_efforts) -> list[dict]:
    items: list[dict] = []
    seen: set[str] = set()
    if not isinstance(raw_efforts, list):
        return items
    for ef in raw_efforts:
        if isinstance(ef, dict):
            ef_id = str(
                ef.get("thinking_effort")
                or ef.get("reasoning_effort")
                or ef.get("id")
                or ef.get("slug")
                or ef.get("value")
                or ""
            ).strip().lower()
            ef_lbl = str(
                ef.get("short_label")
                or ef.get("mobile_full_label")
                or ef.get("label")
                or ef.get("title")
                or ef.get("display_name")
                or ef.get("full_label")
                or ""
            ).strip()
            ef_full = str(ef.get("full_label") or ef_lbl or ef_id).strip()
        else:
            ef_id = str(ef or "").strip().lower()
            ef_lbl = ""
            ef_full = ""
        if ef_id and ef_id not in seen:
            seen.add(ef_id)
            items.append({
                "id": ef_id,
                "label": ef_lbl or ef_id,
                "full_label": ef_full or ef_lbl or ef_id,
            })
    return items


def _extract_effort_ids(raw_efforts) -> list[str]:
    return [it["id"] for it in _extract_effort_items(raw_efforts)]


def _is_hidden_or_work_model(item: dict, slug: str) -> bool:
    low = slug.lower()
    if not low or low.endswith("-wm"):
        return True
    if bool(item.get("is_work_mode_model") or item.get("isWorkModeModel") or item.get("is_hidden") or item.get("isHidden") or item.get("hidden")):
        return True
    if str(item.get("model_lane") or "").strip().lower() == "thinking_plus_plus":
        return True
    if low.startswith("chatgpt_alpha_model_external_access_reserved_gate_") or low.startswith("reserved_gate_"):
        return True
    tags = item.get("tags")
    if isinstance(tags, list) and any(str(t).strip().lower() == "hidden" for t in tags):
        return True
    return False


def _humanize_model_slug(slug: str) -> str:
    clean = slug.strip()
    if clean == "gpt-6-thinking":
        return "GPT-6 Thinking"
    if clean == "gpt-6-instant":
        return "GPT-6 Instant"
    if clean == "gpt-6":
        return "GPT-6"
    if clean == "gpt-6-pro":
        return "GPT-6 Pro"
    parts = clean.replace("_", "-").split("-")
    out = []
    for p in parts:
        if p.lower() == "gpt":
            out.append("GPT")
        elif re.match(r"^\d+(\.\d+)?$", p):
            out.append(p)
        else:
            out.append(p.capitalize())
    return "-".join(out[:2]) + (" " + " ".join(out[2:]) if len(out) > 2 else "") if out else clean


def read_codex_cached_models(state_path: str | None = None) -> list[dict]:
    """Read-only pre-warm of pure cloud Chat models from ``~/.codex/.codex-global-state.json``.

    Invariants (Spec v4.2 Q8 & T16):
      * Strictly read-only: opens ``state_path`` with mode ``"r"`` only; zero writes, zero temp files.
      * Filters out all ``-wm`` Work Mode models, ``thinking_plus_plus`` lane models, and hidden/gate models.
      * Never reads or touches any local Codex SQLite database.
    """
    path = state_path or os.path.expanduser(os.path.join("~", ".codex", ".codex-global-state.json"))
    if not path or not os.path.isfile(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return []
    if not isinstance(data, dict):
        return []
    atoms = data.get("electron-persisted-atom-state")
    if not isinstance(atoms, dict):
        atoms = data

    catalog_entries: list[tuple[int, dict]] = []
    for key, val in atoms.items():
        if not isinstance(val, dict):
            continue
        low_k = str(key).lower()
        if "models" in low_k and isinstance(val.get("response"), dict):
            fetched = int(val.get("fetchedAt") or 0) if isinstance(val.get("fetchedAt"), (int, float)) else 0
            catalog_entries.append((fetched, val["response"]))
    catalog_entries.sort(key=lambda pair: pair[0], reverse=True)

    seen: set[str] = set()
    results: list[dict] = []
    base_meta_by_slug: dict[str, dict] = {}

    for _, resp in catalog_entries:
        raw_models = resp.get("models")
        if not isinstance(raw_models, list):
            continue
        for item in raw_models:
            if not isinstance(item, dict):
                continue
            slug = str(item.get("slug") or item.get("id") or "").strip()
            if not slug:
                continue
            effort_items = _extract_effort_items(
                item.get("thinking_efforts")
                or item.get("thinkingEfforts")
                or item.get("effort_items")
                or item.get("efforts")
                or item.get("reasoning_effort_options")
            )
            efforts = [it["id"] for it in effort_items]
            def_effort = str(item.get("default_thinking_effort") or item.get("defaultThinkingEffort") or item.get("default_effort") or "").strip().lower()
            has_cfg_key = ("configurable_thinking_effort" in item) or ("configurableThinkingEffort" in item) or ("configurable_effort" in item)
            cfg_effort = (
                bool(item.get("configurable_thinking_effort", item.get("configurableThinkingEffort", item.get("configurable_effort"))))
                if has_cfg_key
                else bool(effort_items)
            )
            title = str(item.get("title") or item.get("display_name") or item.get("name") or _humanize_model_slug(slug)).strip()
            desc = str(item.get("description") or item.get("tagline") or "").strip()
            if slug.lower().endswith("-wm") and len(slug) > 3:
                base_slug = slug[:-3]
                if base_slug and base_slug not in base_meta_by_slug and not bool(item.get("is_hidden") or item.get("hidden")):
                    base_meta_by_slug[base_slug] = {
                        "title": title,
                        "description": desc,
                        "efforts": list(efforts),
                        "effort_items": list(effort_items),
                        "default_effort": def_effort,
                        "configurable_effort": cfg_effort,
                    }
                continue
            if _is_hidden_or_work_model(item, slug) or slug in seen:
                continue
            seen.add(slug)
            results.append({
                "slug": slug,
                "title": title,
                "description": desc,
                "efforts": efforts,
                "effort_items": effort_items,
                "default_effort": def_effort,
                "configurable_effort": cfg_effort,
            })

    def _add_referenced_slug(raw_slug: str, raw_effort: str = "") -> None:
        slug = str(raw_slug or "").strip()
        if not slug or slug in seen or _is_hidden_or_work_model({}, slug):
            return
        seen.add(slug)
        meta = base_meta_by_slug.get(slug) or {}
        efforts = list(meta.get("efforts") or [])
        effort_items = list(meta.get("effort_items") or [])
        ef = str(raw_effort or "").strip().lower()
        if not efforts:
            if "thinking" in slug.lower():
                efforts = ["min", "standard", "extended", "max"]
            elif ef:
                efforts = [ef]
        elif ef and ef not in efforts:
            efforts.append(ef)
        if not effort_items and efforts:
            effort_items = [{"id": e_id, "label": e_id, "full_label": e_id} for e_id in efforts]
        results.append({
            "slug": slug,
            "title": str(meta.get("title") or _humanize_model_slug(slug)),
            "description": str(meta.get("description") or ""),
            "efforts": efforts,
            "effort_items": effort_items,
            "default_effort": str(meta.get("default_effort") or ""),
            "configurable_effort": bool(meta.get("configurable_effort", bool(efforts))),
        })

    last_sel = atoms.get("chatgpt-last-selected-model-v1")
    if isinstance(last_sel, dict):
        _add_referenced_slug(str(last_sel.get("slug") or ""), str(last_sel.get("thinkingEffort") or ""))

    recent_cfgs = atoms.get("composer-recent-model-configurations-v1")
    if isinstance(recent_cfgs, list):
        for cfg in recent_cfgs:
            if isinstance(cfg, dict):
                _add_referenced_slug(str(cfg.get("model") or cfg.get("slug") or ""), str(cfg.get("reasoningEffort") or ""))

    return results


# ---------------------------------------------------------------------------------------------------
# Process control (zero focus stealing)
# ---------------------------------------------------------------------------------------------------

def launch_process(args: list[str], minimize_no_activate: bool = True, popen_fn=None) -> bool:
    """Start ``args``; when minimize_no_activate the window opens minimized without taking focus."""
    popen = popen_fn or subprocess.Popen
    kwargs = {"close_fds": True}
    if os.name == "nt":
        startup_cls = getattr(subprocess, "STARTUPINFO", None)
        if startup_cls is not None:
            si = startup_cls()
            si.dwFlags |= getattr(subprocess, "STARTF_USESHOWWINDOW", 1)
            si.wShowWindow = SW_SHOWMINNOACTIVE if minimize_no_activate else SW_SHOWNORMAL
            kwargs["startupinfo"] = si
    try:
        popen(args, **kwargs)
        return True
    except Exception:
        return False


def pick_free_port(preferred: int = 9222) -> int:
    for candidate in (preferred, 0):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", candidate))
            return int(s.getsockname()[1])
        except OSError:
            continue
        finally:
            s.close()
    return preferred


_EXE_CACHE: dict = {}


def resolve_chatgpt_exe(run_ps=None) -> str:
    if run_ps is None and _EXE_CACHE.get("exe") and os.path.isfile(_EXE_CACHE["exe"]):
        return _EXE_CACHE["exe"]
    exe = _resolve_chatgpt_exe_uncached(run_ps)
    if exe and run_ps is None:
        _EXE_CACHE["exe"] = exe
    return exe


def process_running(image_name: str) -> bool:
    """Cheap check (tasklist) whether any process with this image name exists."""
    try:
        res = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {image_name}", "/NH"],
            capture_output=True,
            timeout=6,
            creationflags=_CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        return image_name.lower() in res.stdout.decode("utf-8", errors="replace").lower()
    except Exception:
        return False


def _resolve_chatgpt_exe_uncached(run_ps=None) -> str:
    runner = run_ps or run_powershell
    try:
        out = (runner("(Get-AppxPackage -Name 'OpenAI.Codex' | Sort-Object Version -Descending | Select-Object -First 1).InstallLocation") or "").strip()
        if out:
            exe = os.path.join(out.splitlines()[-1].strip(), "app", "ChatGPT.exe")
            if os.path.isfile(exe):
                return exe
    except Exception:
        pass
    try:
        base = r"C:\Program Files\WindowsApps"
        for name in sorted(os.listdir(base), reverse=True):
            if name.startswith("OpenAI.Codex_"):
                exe = os.path.join(base, name, "app", "ChatGPT.exe")
                if os.path.isfile(exe):
                    return exe
    except Exception:
        pass
    return ""


def stop_chatgpt_desktop(run_ps=None, force_fn=None, sleep_fn=None, attempts: int = 6) -> str:
    """Stop ChatGPT.exe gracefully first (CloseMainWindow lets it flush drafts); force-kill only as a last resort.

    Returns 'graceful', 'forced' or 'not_running'.
    """
    runner = run_ps or run_powershell
    sleeper = sleep_fn or time.sleep

    def count() -> int:
        try:
            return int((runner("(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Measure-Object).Count") or "0").strip() or 0)
        except Exception:
            return 0

    if count() == 0:
        return "not_running"
    try:
        runner("Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }")
    except Exception:
        pass
    for _ in range(attempts):
        sleeper(0.5)
        if count() == 0:
            return "graceful"
    force = force_fn or (lambda: subprocess.run(
        ["taskkill", "/IM", "ChatGPT.exe", "/T", "/F"],
        capture_output=True,
        timeout=10,
        creationflags=_CREATE_NO_WINDOW if os.name == "nt" else 0,
    ))
    force()
    for _ in range(attempts):
        sleeper(0.5)
        if count() == 0:
            break
    return "forced"


def ensure_chatgpt_desktop(
    minimize_no_activate: bool = True,
    restart: bool = False,
    popen_fn=None,
    run_ps=None,
    kill_fn=None,
    port: int | None = None,
) -> dict:
    """Start ChatGPT.exe with a DevTools port (restart=True first stops a port-less instance).

    Returns {'ok', 'port', 'exe', 'restarted'}.
    """
    exe = resolve_chatgpt_exe(run_ps)
    if not exe:
        launched = launch_process(["explorer.exe", f"shell:AppsFolder\\{CHATGPT_AUMID}"], False, popen_fn)
        return {"ok": launched, "port": None, "exe": "", "restarted": False}
    if restart:
        try:
            (kill_fn or (lambda: stop_chatgpt_desktop(run_ps)))()
        except Exception:
            pass
        time.sleep(0.8)
    use_port = int(port) if port else pick_free_port(9222)
    runner = run_ps or (run_powershell if popen_fn is None else None)
    if runner is not None:
        bg_env = "$env:CODEX_ELECTRON_START_IN_BACKGROUND='1'; " if minimize_no_activate else ""
        esc_exe = exe.replace("'", "''")
        pkg_ps = (
            f"{bg_env}"
            f"Invoke-CommandInDesktopPackage -PackageFamilyName 'OpenAI.Codex_2p2nqsd0c76g0' -AppId 'App' "
            f"-Command '{esc_exe}' -Args '--remote-debugging-address=127.0.0.1 --remote-debugging-port={use_port}' "
            f"-PreventBreakaway -ErrorAction Stop | Out-Null; 'LAUNCHED_OK'"
        )
        try:
            ps_out = str(runner(pkg_ps) or "")
            if "LAUNCHED_OK" in ps_out:
                return {"ok": True, "port": use_port, "exe": exe, "restarted": bool(restart), "via": "package_identity"}
        except Exception:
            pass
    ok = launch_process(
        [exe, "--remote-debugging-address=127.0.0.1", f"--remote-debugging-port={use_port}"],
        minimize_no_activate,
        popen_fn,
    )
    return {"ok": ok, "port": use_port if ok else None, "exe": exe, "restarted": bool(restart)}


# ---------------------------------------------------------------------------------------------------
# Page scripts (synchronous one-shot probes; first line carries an op marker for fakes/logging)
# ---------------------------------------------------------------------------------------------------

_COMPOSER_JS = (
    "const findComposer=()=>{for(const s of ['#prompt-textarea','div#prompt-textarea[contenteditable=\"true\"]',"
    "'div.ProseMirror[contenteditable=\"true\"]','textarea[data-id=\"root\"]','div[contenteditable=\"true\"][role=\"textbox\"]'])"
    "{for(const n of document.querySelectorAll(s)){if(!n)continue;"
    "if(n.getAttribute&&n.getAttribute('data-codex-composer')==='true')continue;"
    "if(n.closest&&n.closest('[data-codex-composer=\"true\"]'))continue;"
    "if(typeof isHiddenNode==='function'&&isHiddenNode(n))continue;"
    "return n;}} return null;};"
)

_EFFORT_MAP_JS = (
    "const EM={'即时':'none','instant':'none','未开启思考':'none','none':'none',"
    "'轻度':'min','light':'min','极简':'min','minimal':'min','低':'min','low':'min','min':'min',"
    "'标准':'standard','standard':'standard','中':'standard','medium':'standard',"
    "'深度':'extended','extended':'extended','高':'extended','high':'extended','deep':'extended',"
    "'极高':'max','最高':'max','深入':'max','超强':'max','max':'max','heavy':'max','xhigh':'xhigh'};"
)

_NATIVE_FIBER_JS = (
    "const getFiber=(el)=>{if(!el)return null;for(const k of Object.keys(el)){"
    "if(k.startsWith('__reactFiber$')||k.startsWith('__reactInternalInstance$'))return el[k];}return null;};"
    "const isHiddenNode=(el)=>{if(!el)return true;"
    "if(el.hasAttribute&&el.hasAttribute('hidden'))return true;"
    "if(el.closest&&el.closest('[hidden],[aria-hidden=\"true\"]'))return true;"
    "if(typeof el.getBoundingClientRect==='function'){const r=el.getBoundingClientRect();if(r&&r.width===0&&r.height===0)return true;}"
    "let cur=el;while(cur&&cur.nodeType===1){"
    "if(cur.hidden||(cur.getAttribute&&cur.getAttribute('aria-hidden')==='true'))return true;"
    "const st=(cur.style&&cur.style.display)?cur.style:(typeof getComputedStyle==='function'?getComputedStyle(cur):null);"
    "if(st&&(st.display==='none'||st.visibility==='hidden'))return true;"
    "cur=cur.parentElement;}"
    "return false;};"
    "const getActiveSidebarConv=()=>{const rows=Array.from(document.querySelectorAll('[data-sidebar-chatgpt-conversation-key]')||[]);"
    "for(const r of rows){const cur=r.querySelector&&r.querySelector('[aria-current=\"page\"]');"
    "if(cur){const k=String(r.getAttribute('data-sidebar-chatgpt-conversation-key')||'');"
    "const err=r.getAttribute('data-sidebar-indicator')==='error';"
    "const dm=k.match(/chatgpt:conversation:local-chatgpt:([0-9a-fA-F-]{36})$/i);"
    "if(dm)return {uuid:'',draft_id:dm[1],error:err};"
    "const m=k.match(/^chatgpt:conversation:([0-9a-fA-F-]{36})$/i);"
    "if(m)return {uuid:m[1],draft_id:'',error:err};}}"
    "return {uuid:'',draft_id:'',error:false};};"
    "const findCloudCtx=()=>{const forms=Array.from(document.querySelectorAll('form[data-chatgpt-composer]')||[]);"
    "for(const form of forms){"
    "if(form.getAttribute&&form.getAttribute('data-codex-composer')==='true')continue;"
    "if(form.closest&&form.closest('[data-codex-composer=\"true\"]'))continue;"
    "if(isHiddenNode(form))continue;"
    "let f=getFiber(form),steps=0,rejected=false;"
    "const ctx={form,ctrl:null,onModelChange:null,onSelectPower:null,selectedModel:null,selectedPowerSelection:null,"
    "models:null,convId:'',draftId:'',entries:null,isSubmitting:false,isStreaming:false,isStopping:false,isTurnActive:false,"
    "errorMessage:'',hasLoadError:false,rateLimitSendBlocked:false,rateLimitBannerInfo:null,onStop:null,canSteer:false};"
    "while(f&&steps<160){steps++;const p=f.memoizedProps;"
    "if(p&&typeof p==='object'){"
    "if(p.isWorkConversation===true||(p.isHidden===true&&!('dockThreadKey' in p)&&!ctx.ctrl)){rejected=true;break;}"
    "if(p.isSteeringEnabled===true||p.canQueueNativeAnswerSubmission===true)ctx.canSteer=true;"
    "if(!ctx.ctrl&&p.composerController&&typeof p.composerController.setText==='function'&&typeof p.composerController.getText==='function')ctx.ctrl=p.composerController;"
    "if(!ctx.onModelChange&&typeof p.onModelChange==='function')ctx.onModelChange=p.onModelChange;"
    "if(!ctx.onSelectPower&&typeof p.onSelectPower==='function')ctx.onSelectPower=p.onSelectPower;"
    "if(!ctx.selectedModel&&p.selectedModel&&typeof p.selectedModel==='object')ctx.selectedModel=p.selectedModel;"
    "if(!ctx.selectedPowerSelection&&p.selectedPowerSelection&&typeof p.selectedPowerSelection==='object')ctx.selectedPowerSelection=p.selectedPowerSelection;"
    "if(!ctx.models&&p.models&&typeof p.models==='object'&&(p.models.modelConfigBySlug||p.models.powerSelections))ctx.models=p.models;"
    "if(typeof p.scrollStateConversationId==='string'&&/^[0-9a-fA-F-]{36}$/.test(p.scrollStateConversationId)){ctx.convId=p.scrollStateConversationId;}"
    "for(const cid of [p.conversationId,p.clientThreadId]){if(typeof cid!=='string')continue;"
    "const dm=cid.match(/^local-chatgpt:([0-9a-fA-F-]{36})$/i);"
    "if(dm&&!ctx.draftId){ctx.draftId=dm[1];}"
    "else if(!ctx.convId&&/^[0-9a-fA-F-]{36}$/.test(cid)){ctx.convId=cid;}}"
    "if(ctx.entries===null&&Array.isArray(p.entries))ctx.entries=p.entries;"
    "if(p.isSubmitting)ctx.isSubmitting=true;"
    "if(p.isStreaming)ctx.isStreaming=true;"
    "if(p.isStopping)ctx.isStopping=true;"
    "if(p.isTurnActive)ctx.isTurnActive=true;"
    "if(!ctx.errorMessage&&p.errorMessage)ctx.errorMessage=String(p.errorMessage);"
    "if(p.hasLoadError)ctx.hasLoadError=true;"
    "if(p.rateLimitSendBlocked)ctx.rateLimitSendBlocked=true;"
    "if(!ctx.rateLimitBannerInfo&&p.rateLimitBannerInfo)ctx.rateLimitBannerInfo=p.rateLimitBannerInfo;"
    "if(!ctx.onStop){const fn=p.onStop||p.onStopGenerating||p.stopStreaming;if(typeof fn==='function')ctx.onStop=fn;}"
    "}"
    "f=f.return;}"
    "if(!rejected)return ctx;}return null;};"
    "const scanCabinetDrawers=()=>{const out=[];const forms=Array.from(document.querySelectorAll('form[data-chatgpt-composer]')||[]);"
    "for(const form of forms){"
    "if(form.getAttribute&&form.getAttribute('data-codex-composer')==='true')continue;"
    "if(form.closest&&form.closest('[data-codex-composer=\"true\"]'))continue;"
    "const vis=!isHiddenNode(form);"
    "let f=getFiber(form),steps=0,rejected=false,convId='',draftId='',entries=null,isSub=false,isStr=false,isTurn=false,errMsg=false,selM='',selE='';"
    "while(f&&steps<160){steps++;const p=f.memoizedProps;"
    "if(p&&typeof p==='object'){"
    "if(p.isWorkConversation===true){rejected=true;break;}"
    "if(typeof p.scrollStateConversationId==='string'&&/^[0-9a-fA-F-]{36}$/.test(p.scrollStateConversationId))convId=p.scrollStateConversationId;"
    "for(const cid of [p.conversationId,p.clientThreadId]){if(typeof cid!=='string')continue;"
    "const dm=cid.match(/^local-chatgpt:([0-9a-fA-F-]{36})$/i);"
    "if(dm&&!draftId)draftId=dm[1];"
    "else if(!convId&&/^[0-9a-fA-F-]{36}$/.test(cid))convId=cid;}"
    "if(p.selectedModel&&typeof p.selectedModel==='object'){if(!selM&&p.selectedModel.slug)selM=String(p.selectedModel.slug);if(!selE&&p.selectedModel.thinkingEffort)selE=String(p.selectedModel.thinkingEffort);}"
    "if(p.selectedPowerSelection&&typeof p.selectedPowerSelection==='object'){if(!selM&&p.selectedPowerSelection.model)selM=String(p.selectedPowerSelection.model);if(!selE&&p.selectedPowerSelection.reasoningEffort)selE=String(p.selectedPowerSelection.reasoningEffort);}"
    "if(entries===null&&Array.isArray(p.entries))entries=p.entries;"
    "if(p.isSubmitting)isSub=true;if(p.isStreaming)isStr=true;if(p.isTurnActive)isTurn=true;"
    "if(p.errorMessage||p.hasLoadError||p.rateLimitSendBlocked||p.rateLimitBannerInfo)errMsg=true;}"
    "f=f.return;}"
    "if(rejected)continue;"
    "const dHints=new Set();"
    "if(Array.isArray(entries)){for(let i=Math.max(0,entries.length-6);i<entries.length;i++){"
    "let tx='';try{tx=JSON.stringify(entries[i]||'').slice(-6000);}catch(_){}"
    "(tx.match(/\\btsk_[0-9a-zA-Z_-]{4,40}\\b/g)||[]).forEach(x=>dHints.add(x));"
    "(tx.match(/\\bwfr_[0-9a-zA-Z_-]{6,48}\\b/g)||[]).forEach(x=>dHints.add(x));}}"
    "let rootEl=form;"
    "while(rootEl&&rootEl.parentElement&&rootEl.parentElement!==document.body){"
    "rootEl=rootEl.parentElement;"
    "if(rootEl.parentElement&&String(rootEl.parentElement.className||'').includes('_Workspace_'))break;}"
    "if(rootEl&&typeof rootEl.querySelectorAll==='function'){"
    "const tNodes=Array.from(rootEl.querySelectorAll('[data-message-author-role],[data-user-message-bubble=\"true\"],[data-markdown-text-style=\"assistant-message\"]')||[]);"
    "for(let i=Math.max(0,tNodes.length-4);i<tNodes.length;i++){const tx=String(tNodes[i].textContent||'').slice(-4000);"
    "(tx.match(/\\btsk_[0-9a-zA-Z_-]{4,40}\\b/g)||[]).forEach(x=>dHints.add(x));"
    "(tx.match(/\\bwfr_[0-9a-zA-Z_-]{6,48}\\b/g)||[]).forEach(x=>dHints.add(x));}}"
    "const dSse=Boolean(isSub||isStr||isTurn);"
    "if(convId||draftId||dHints.size>0){out.push({conv_uuid:convId,draft_id:draftId,task_hints:Array.from(dHints).slice(0,16),visible:vis,sse_active:dSse,is_generating:dSse,turn_seq:Array.isArray(entries)?entries.length:0,has_error:Boolean(errMsg),current_model:selM,current_effort:selE});}}"
    "return out;};"
    "const extractNativeModels=(modelsObj)=>{if(!modelsObj||typeof modelsObj!=='object')return [];"
    "const out=[],seen=new Set();const bySlug=modelsObj.modelConfigBySlug||{};"
    "for(const [slug,cfg] of Object.entries(bySlug)){"
    "if(!slug||seen.has(slug))continue;const low=slug.toLowerCase();const c=cfg||{};"
    "if(low.endsWith('-wm')||c.isWorkModeModel||c.is_work_mode_model||c.isHidden||c.is_hidden||c.hidden||low.startsWith('reserved_gate_')||low.startsWith('chatgpt_alpha_model_external_access_reserved_gate_'))continue;"
    "seen.add(slug);const rawEf=c.thinkingEfforts||c.thinking_efforts||[];const efforts=[],effort_items=[];"
    "if(Array.isArray(rawEf)){for(const e of rawEf){const isO=Boolean(e&&typeof e==='object');const efId=String((isO?(e.thinking_effort||e.id||e.value):e)||'').trim().toLowerCase();if(efId&&!efforts.includes(efId)){efforts.push(efId);const efLbl=String((isO?(e.short_label||e.mobile_full_label||e.label||e.title||e.full_label):'')||efId).trim();effort_items.push({id:efId,label:efLbl||efId,full_label:String((isO&&e.full_label)||efLbl||efId).trim()});}}}"
    "const defEf=String(c.defaultThinkingEffort||c.default_thinking_effort||'').trim().toLowerCase();"
    "const cfgEf=typeof c.configurableThinkingEffort==='boolean'?c.configurableThinkingEffort:(typeof c.configurable_thinking_effort==='boolean'?c.configurable_thinking_effort:efforts.length>0);"
    "out.push({slug,title:String(c.title||c.displayName||slug),description:String(c.description||''),efforts,effort_items,default_effort:defEf,configurable_effort:cfgEf});}"
    "return out;};"
)


def _js(value) -> str:
    return json.dumps(value, ensure_ascii=False)


def script_state() -> str:
    return (
        "/*relay:state*/(()=>{try{" + _NATIVE_FIBER_JS + _COMPOSER_JS +
        "const ds=(document.documentElement&&document.documentElement.dataset)||{};"
        "const isApp=(location.protocol==='app:');"
        "const ctx=findCloudCtx();const sb=getActiveSidebarConv();"
        "const m=(location.pathname||'').match(/\\/c\\/([0-9a-fA-F-]{36})/);"
        "const conv=isApp?((ctx&&ctx.convId)||sb.uuid||''):((ctx&&ctx.convId)||sb.uuid||(m?m[1]:'')||String(ds.relayActiveConvUuid||''));"
        "const draftId=String((ctx&&ctx.draftId)||sb.draft_id||'');"
        "const hints=new Set();"
        "String(ds.relayTaskHints||'').split(',').forEach(h=>{h=h.trim();if(h)hints.add(h);});"
        "if(hints.size===0&&ctx&&Array.isArray(ctx.entries)){"
        "for(let i=Math.max(0,ctx.entries.length-6);i<ctx.entries.length;i++){"
        "let tx='';try{tx=JSON.stringify(ctx.entries[i]||'').slice(-6000);}catch(_){}"
        "(tx.match(/\\btsk_[0-9a-zA-Z_-]{4,40}\\b/g)||[]).forEach(x=>hints.add(x));"
        "(tx.match(/\\bwfr_[0-9a-zA-Z_-]{6,48}\\b/g)||[]).forEach(x=>hints.add(x));}}"
        # Spec v4.3: never read the whole page text (tens of thousands of words on long chats). The page hook registers task
        # numbers from the live stream; only while none is known we peek at the tail of the last two turns (bounded).
        "if(hints.size===0){const rawTurns=Array.from(document.querySelectorAll('[data-message-author-role],[data-user-message-bubble=\"true\"],[data-markdown-text-style=\"assistant-message\"]')||[]).filter(t=>!isHiddenNode(t));"
        "for(let i=Math.max(0,rawTurns.length-4);i<rawTurns.length;i++){const tx=String(rawTurns[i].textContent||'').slice(-4000);"
        "(tx.match(/\\btsk_[0-9a-zA-Z_-]{4,40}\\b/g)||[]).forEach(x=>hints.add(x));"
        "(tx.match(/\\bwfr_[0-9a-zA-Z_-]{6,48}\\b/g)||[]).forEach(x=>hints.add(x));}}"
        "const stopScope=(ctx&&ctx.form)||document;"
        "const stop=stopScope.querySelector?stopScope.querySelector('button[data-testid=\"stop-button\"],button[data-testid*=\"stop\"],button[aria-label*=\"Stop\"],button[aria-label*=\"停止\"],.result-streaming'):null;"
        "let err=Boolean((ctx&&(ctx.errorMessage||ctx.hasLoadError||ctx.rateLimitSendBlocked||ctx.rateLimitBannerInfo))||sb.error);"
        "if(!err){const eb=document.querySelector('[data-testid*=\"conversation-error\"],div[role=\"alert\"]');"
        "if(eb){const t=(eb.innerText||'').toLowerCase();err=/something went wrong|network error|出了点问题|网络错误/.test(t);}}"
        "const sse=Boolean((ctx&&(ctx.isSubmitting||ctx.isStreaming||ctx.isTurnActive))||ds.relaySseActive==='1');"
        "const gen=Boolean(sse||(stop&&!stop.disabled));"
        "const hasComp=Boolean((ctx&&ctx.form)||findComposer());"
        "const compText=String(ctx&&ctx.ctrl?ctx.ctrl.getText():(()=>{const c=findComposer();return c?(c.innerText||c.value||''):'';})()).replace(/[\\u200B-\\u200D\\uFEFF]/g,'').trim().slice(0,200);"
        "const curModel=String((ctx&&ctx.selectedModel&&ctx.selectedModel.slug)||(ctx&&ctx.selectedPowerSelection&&ctx.selectedPowerSelection.model)||ds.relayActiveModel||'');"
        "const curEffort=String((ctx&&ctx.selectedModel&&ctx.selectedModel.thinkingEffort)||(ctx&&ctx.selectedPowerSelection&&ctx.selectedPowerSelection.reasoningEffort)||ds.relayActiveEffort||'');"
        "const turnSeq=(ctx&&Array.isArray(ctx.entries))?ctx.entries.length:Number(ds.relayTurnSeq||0);"
        "const avail=ctx&&ctx.models?extractNativeModels(ctx.models):[];"
        "const drawers=isApp?scanCabinetDrawers():[];"
        "const vUrl=isApp?(conv?('https://chatgpt.com/c/'+conv):'https://chatgpt.com/'):location.href;"
        "return {url:vUrl,native_url:location.href,conv_uuid:conv,draft_id:draftId,cabinet_drawers:drawers,title:document.title||'',has_composer:hasComp,"
        "sse_active:sse,is_generating:gen,turn_seq:turnSeq,has_error:err,page_hints:Array.from(hints).slice(0,16),"
        "composer_text:compText,has_user_draft:compText.length>0,can_steer:Boolean(ctx&&ctx.canSteer),current_model:curModel,current_effort:curEffort,"
        "available_models:avail,hook:!!window.__RELAYSTUDIO_PAGE_HOOK_INSTALLED__};"
        "}catch(e){return {error:String(e)};}})()"
    )


def script_hook_installed() -> str:
    return "/*relay:hook_installed*/(()=>!!window.__RELAYSTUDIO_PAGE_HOOK_INSTALLED__)()"


def script_nav_new_chat() -> str:
    return (
        "/*relay:nav_new_chat*/(()=>{" + _NATIVE_FIBER_JS +
        "const clr=()=>{try{if(document.documentElement&&document.documentElement.dataset){delete document.documentElement.dataset.relayActiveConvUuid;delete document.documentElement.dataset.relayTaskHints;}}catch(_){}};"
        "const b0=document.querySelector('a[data-testid=\"create-new-chat-button\"],button[data-testid=\"create-new-chat-button\"]');"
        "if(b0){const a0=String((b0.getAttribute&&b0.getAttribute('aria-label'))||'');if(!/中开始新聊天|New chat in /i.test(a0)){clr();b0.click();return {clicked:true,via:'testid'};}}"
        "const bs=Array.from(document.querySelectorAll('button,a,[role=\"button\"]')||[]);"
        "for(const b of bs){"
        "if(b.closest&&b.closest('[data-codex-composer=\"true\"]'))continue;"
        "const aria=String((b.getAttribute&&b.getAttribute('aria-label'))||'').trim();"
        "const txt=String(b.innerText||b.textContent||'').trim();"
        "if(/中开始新聊天|New chat in /i.test(aria)||/中开始新聊天|New chat in /i.test(txt))continue;"
        "if(aria==='新聊天'||aria==='New chat'||txt==='新聊天'||txt==='New chat'){"
        "let f=getFiber(b),steps=0;"
        "while(f&&steps<40){steps++;const p=f.memoizedProps;"
        "if(p&&typeof p.onStartChat==='function'&&p.projectless!==false){clr();p.onStartChat();return {clicked:true,via:'fiber'};}"
        "f=f.return;}"
        "clr();b.click();return {clicked:true,via:'button'};}}"
        "return {clicked:false};})()"
    )


def script_nav_conv(conv_uuid: str) -> str:
    return (
        "/*relay:nav_conv*/(()=>{" + _NATIVE_FIBER_JS +
        "const u=" + _js(conv_uuid) + ";"
        "let row=document.querySelector('[data-sidebar-chatgpt-conversation-key=\"chatgpt:conversation:'+u+'\"]');"
        "let exp=false;"
        "if(!row){const tgs=Array.from(document.querySelectorAll('button[data-app-action-sidebar-section-toggle][aria-expanded=\"false\"]')||[]);"
        "for(const tb of tgs){tb.click();exp=true;}"
        "if(exp)row=document.querySelector('[data-sidebar-chatgpt-conversation-key=\"chatgpt:conversation:'+u+'\"]');}"
        "if(row){const inner=(row.querySelector&&(row.querySelector('[role=\"button\"]')||row.querySelector('[data-sidebar-cycle-item]')))||row;"
        "inner.click();return {found:true,navigated:false,expanded_sidebar:exp};}"
        "const l=document.querySelector('a[href*=\"/c/'+u+'\"]');"
        "if(l){l.click();return {found:true,navigated:false,expanded_sidebar:exp};}"
        "if(location.protocol==='app:'){return {found:false,navigated:false,expanded_sidebar:exp};}"
        "setTimeout(()=>{location.href='/c/'+u;},0);return {found:false,navigated:true};})()"
    )


def script_fill(msg_id: str, text: str = "", model: str = "", effort: str = "") -> str:
    return (
        "/*relay:fill*/(()=>{try{" + _NATIVE_FIBER_JS + _COMPOSER_JS + _EFFORT_MAP_JS +
        "const ds=document.documentElement.dataset;const id=" + _js(msg_id) + ";const text=" + _js(text) + ";"
        "const model=" + _js(model) + ";const effort=" + _js(effort) + ";"
        "const ctx=findCloudCtx();const sb=getActiveSidebarConv();"
        "const rawM=String(model||'').trim();const wantM=(rawM&&rawM.toLowerCase()!=='inherit'&&rawM.toLowerCase()!=='auto')?rawM:'';"
        "const rawE=String(effort||'').trim();const mappedE=(rawE&&rawE.toLowerCase()!=='inherit'&&rawE.toLowerCase()!=='auto')?(EM[rawE]||EM[rawE.toLowerCase()]||rawE.toLowerCase()):'';"
        "if(ctx&&ctx.ctrl){"
        "const entries=Array.isArray(ctx.entries)?ctx.entries:[];"
        "const lastKey=entries.length&&entries[entries.length-1]?String(entries[entries.length-1].turnKey||''):'';"
        "window.__relayDesktopDispatch={id:id,prevEntriesLen:entries.length,prevLastTurnKey:lastKey,prevConvUuid:String(ctx.convId||sb.uuid||''),prevDraftId:String(ctx.draftId||sb.draft_id||''),startedAt:Date.now(),status:'waiting'};"
        "if((wantM||mappedE)&&ctx.onModelChange){"
        "const cur=ctx.selectedModel||{};let nextSlug=wantM||String(cur.slug||'');"
        "let nextEf=mappedE||String(cur.thinkingEffort||'');"
        "if(nextEf==='none'&&nextSlug==='gpt-6-thinking')nextSlug='gpt-6';"
        "else if(nextEf&&nextEf!=='none'&&nextSlug==='gpt-6')nextSlug='gpt-6-thinking';"
        "const bySlug=(ctx.models&&ctx.models.modelConfigBySlug)||{};const mCfg=bySlug[nextSlug];"
        "if(mCfg&&Array.isArray(mCfg.thinkingEfforts)&&mCfg.thinkingEfforts.length>0&&nextEf){"
        "const legal=mCfg.thinkingEfforts.map(x=>String((x&&typeof x==='object'?(x.thinking_effort||x.id):x)||'').toLowerCase()).filter(Boolean);"
        "if(legal.length&&!legal.includes(nextEf)){"
        "if(nextEf==='max'||nextEf==='xhigh')nextEf=legal.includes('max')?'max':(legal.includes('xhigh')?'xhigh':legal[legal.length-1]);"
        "}}"
        "ctx.onModelChange({slug:nextSlug,thinkingEffort:nextEf,versionId:String(cur.versionId||'latest')});}"
        "ctx.ctrl.setText(text);"
        "const ok=String(ctx.ctrl.getText()||'').trim().length>0;"
        "ds.relayDispatchId=id;ds.relayDispatchStatus='waiting';"
        "return {composer:true,filled:ok,native:true};}"
        "const el=findComposer();if(!el)return {composer:false};"
        "if(wantM){ds.relayOverrideModel=wantM;}else{delete ds.relayOverrideModel;}"
        "if(mappedE){ds.relayOverrideEffort=mappedE;}else{delete ds.relayOverrideEffort;}"
        "ds.relayDispatchId=id;ds.relayDispatchStatus='waiting';delete ds.relayComposerFilled;"
        "try{window.dispatchEvent(new CustomEvent('relaystudio:fill-composer',{detail:{text:text}}));}catch(_){}"
        "let filled=ds.relayComposerFilled==='1';"
        "if(!filled){const ce=el.isContentEditable||el.getAttribute('contenteditable')==='true';"
        "if(!ce&&(el.tagName==='TEXTAREA'||el.tagName==='INPUT')){const proto=el.tagName==='TEXTAREA'?window.HTMLTextAreaElement.prototype:window.HTMLInputElement.prototype;"
        "const st=Object.getOwnPropertyDescriptor(proto,'value').set;st.call(el,text);el.dispatchEvent(new InputEvent('input',{bubbles:true,data:text,inputType:'insertText'}));}"
        "else{el.innerHTML='';for(const line of text.split(/\\r?\\n/)){const p=document.createElement('p');p.textContent=line||'\\u200B';el.appendChild(p);}"
        "el.dispatchEvent(new InputEvent('input',{bubbles:true,cancelable:true,inputType:'insertText',data:text}));}"
        "filled=(el.innerText||el.value||'').trim().length>0;}"
        "return {composer:true,filled:filled,native:false};}catch(e){return {composer:false,error:String(e)};}})()"
    )


def script_send() -> str:
    return (
        "/*relay:send*/(()=>{" + _NATIVE_FIBER_JS + _COMPOSER_JS +
        "const ctx=findCloudCtx();"
        "if(ctx&&ctx.form){"
        "for(const s of ['button[type=\"submit\"]','button[data-testid=\"send-button\"]','button[aria-label*=\"发送\"]','button[aria-label*=\"Send\"]']){"
        "const b=ctx.form.querySelector&&ctx.form.querySelector(s);"
        "if(b&&!b.disabled&&b.getAttribute('aria-disabled')!=='true'){"
        "if(typeof ctx.form.requestSubmit==='function')ctx.form.requestSubmit(b);else b.click();"
        "return {clicked:true,via:'requestSubmit'};}}"
        "return {clicked:false,via:''};}"
        "for(const s of ['button[data-testid=\"send-button\"]','button[data-testid*=\"send\"]',"
        "'button[aria-label*=\"Send prompt\"]','button[aria-label*=\"Send message\"]','button[aria-label*=\"发送提示\"]',"
        "'button[aria-label*=\"发送\"]','form button[type=\"submit\"]']){for(const b of document.querySelectorAll(s)){"
        "if(b.closest&&b.closest('[data-codex-composer=\"true\"]'))continue;"
        "if(isHiddenNode(b))continue;"
        "if(b&&!b.disabled&&b.getAttribute('aria-disabled')!=='true'){b.click();return {clicked:true,via:'button'};}}}"
        "const el=findComposer();if(el){el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));"
        "return {clicked:false,via:'enter'};}return {clicked:false,via:''};})()"
    )


def script_dispatch_status(msg_id: str) -> str:
    return (
        "/*relay:dispatch_status*/(()=>{" + _NATIVE_FIBER_JS +
        "const wantId=" + _js(msg_id) + ";"
        "const ds=(document.documentElement&&document.documentElement.dataset)||{};"
        "const d=window.__relayDesktopDispatch;"
        "if(d&&d.id===wantId){"
        "const ctx=findCloudCtx();const sb=getActiveSidebarConv();"
        "const conv=String((ctx&&ctx.convId)||sb.uuid||'');"
        "const draft=String((ctx&&ctx.draftId)||sb.draft_id||'');"
        "const hasErr=Boolean((ctx&&(ctx.errorMessage||ctx.hasLoadError||ctx.rateLimitSendBlocked||ctx.rateLimitBannerInfo))||sb.error);"
        "if(hasErr)return {id:wantId,status:'failed',conv_uuid:conv,draft_id:draft};"
        "const compEmpty=!ctx||!ctx.ctrl||String(ctx.ctrl.getText()||'').trim().length===0;"
        "const entries=ctx&&Array.isArray(ctx.entries)?ctx.entries:[];"
        "const lastKey=entries.length&&entries[entries.length-1]?String(entries[entries.length-1].turnKey||''):'';"
        "const progressed=Boolean(entries.length>d.prevEntriesLen||(lastKey&&lastKey!==d.prevLastTurnKey)||(ctx&&(ctx.isSubmitting||ctx.isStreaming))||(conv&&conv!==d.prevConvUuid)||(draft&&draft!==d.prevDraftId));"
        "if(compEmpty&&progressed){"
        "if(!d.prevConvUuid&&!(/^[0-9a-fA-F-]{36}$/.test(conv))&&!draft&&(Date.now()-d.startedAt)<5000){"
        "return {id:wantId,status:'waiting',conv_uuid:'',draft_id:''};}"
        "return {id:wantId,status:'accepted',conv_uuid:conv,draft_id:draft};}"
        "return {id:wantId,status:'waiting',conv_uuid:conv,draft_id:draft};}"
        "const m=(location.pathname||'').match(/\\/c\\/([0-9a-fA-F-]{36})/);"
        "return {id:String(ds.relayDispatchId||''),status:String(ds.relayDispatchStatus||''),"
        "conv_uuid:(m?m[1]:'')||String(ds.relayActiveConvUuid||''),draft_id:''};})()"
    )


def script_stop() -> str:
    return (
        "/*relay:stop*/(()=>{" + _NATIVE_FIBER_JS +
        "const ctx=findCloudCtx();"
        "if(ctx&&typeof ctx.onStop==='function'){ctx.onStop();return {ok:true,via:'fiber'};}"
        "const scope=(ctx&&ctx.form)||document;"
        "const b=scope.querySelector&&scope.querySelector('button[data-testid=\"stop-button\"],button[data-testid*=\"stop\"],button[aria-label*=\"Stop\"],button[aria-label*=\"停止\"]');"
        "if(b&&!(b.closest&&b.closest('[data-codex-composer=\"true\"]'))&&!b.disabled){b.click();return {ok:true,via:'button'};}"
        "return {ok:false};})()"
    )


def script_archive(conv_uuid: str) -> str:
    return (
        "/*relay:archive*/(async()=>{try{" + _NATIVE_FIBER_JS +
        "const u=" + _js(conv_uuid) + ";"
        "const rows=Array.from(document.querySelectorAll('[data-sidebar-chatgpt-conversation-key=\"chatgpt:conversation:'+u+'\"]')||[]);"
        "for(const row of rows){let f=getFiber(row),steps=0;"
        "while(f&&steps<40){steps++;const p=f.memoizedProps;"
        "if(p&&typeof p.onArchive==='function'){await p.onArchive();return {ok:true,via:'fiber'};}"
        "f=f.return;}}"
        "if(location.protocol==='app:')return {ok:false,error:'sidebar_row_not_found'};"
        "const sr=await fetch('/api/auth/session',{credentials:'include'});"
        "if(!sr.ok)return {ok:false};const s=await sr.json();const t=s&&s.accessToken?String(s.accessToken).trim():'';if(!t)return {ok:false};"
        "const r=await fetch('/backend-api/conversation/'+u,{method:'PATCH',credentials:'include',headers:{'Content-Type':'application/json',Authorization:'Bearer '+t},body:JSON.stringify({is_archived:true})});"
        "return {ok:!!r.ok};}catch(e){return {ok:false,error:String(e)};}})()"
    )


def script_open_main_window() -> str:
    """Ask ChatGPT.exe itself to restore / re-create its main window (the app's own ``open-current-main-window`` command).

    Only ever used for a user-initiated "open web page" click; background delivery never calls it (zero focus stealing).
    """
    return (
        "/*relay:open_main_window*/(()=>{try{const b=window.electronBridge;"
        "if(!b||typeof b.sendMessageFromView!=='function')return {ok:false,error:'no_electron_bridge'};"
        "const r=b.sendMessageFromView({type:'open-current-main-window',stealFocus:true,focusComposer:false});"
        "if(r&&typeof r.catch==='function')r.catch(()=>{});return {ok:true};}"
        "catch(e){return {ok:false,error:String(e)};}})()"
    )


def script_ensure_chat_mode() -> str:
    return (
        "/*relay:ensure_chat_mode*/(()=>{"
        "const back=Array.from(document.querySelectorAll('button[aria-label=\"返回 ChatGPT\"],button[aria-label=\"Back to ChatGPT\"]')||[])[0];"
        "if(back){back.click();return {found:true,switched:true,via:'back_to_chatgpt'};}"
        "const bs=Array.from(document.querySelectorAll('button,[role=\"tab\"],[role=\"radio\"]')||[]);"
        "const t=bs.find(b=>{if(b.closest&&b.closest('[data-tab-id]'))return false;"
        "const x=(b.innerText||b.textContent||'').trim();return x==='聊天'||x==='Chat';});"
        "if(!t)return {found:false,switched:false};"
        "const off=t.getAttribute('aria-pressed')==='false'||t.getAttribute('aria-selected')==='false'||t.getAttribute('data-state')==='inactive'||t.getAttribute('aria-checked')==='false';"
        "if(off){t.click();return {found:true,switched:true,via:'tab'};}"
        "return {found:true,switched:false};})()"
    )


def load_hook_source(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


# ---------------------------------------------------------------------------------------------------
# Session: orchestrates the page scripts (all waiting happens here, in Python)
# ---------------------------------------------------------------------------------------------------

class ChatGptDesktopSession:
    """Drive ChatGPT.exe's native ``app://-/index.html`` main window through ``evaluate(expression) -> value``."""

    def __init__(self, evaluate, hook_source: str = "", sleep_fn=None):
        self._evaluate = evaluate
        self._hook_source = hook_source
        self._sleep = sleep_fn or time.sleep

    def _eval(self, expression: str):
        return self._evaluate(expression)

    def ensure_hook(self) -> None:
        if not self._hook_source:
            return
        try:
            if self._eval(script_hook_installed()):
                return
        except Exception:
            return
        try:
            self._eval(self._hook_source)
        except Exception:
            pass

    def read_state(self) -> dict:
        state = self._eval(script_state())
        return state if isinstance(state, dict) else {}

    def _wait_state(self, predicate, timeout: float, step: float = 0.3) -> dict:
        state: dict = {}
        for attempt in range(max(1, int(timeout / step)) + 1):
            try:
                state = self.read_state()
            except Exception:
                state = {}
            if state and predicate(state):
                return state
            self._sleep(step)
        return state

    def stop_generation(self) -> bool:
        try:
            res = self._eval(script_stop())
            return bool(isinstance(res, dict) and res.get("ok"))
        except Exception:
            return False

    def archive(self, conv_uuids: list[str]) -> list[str]:
        done = []
        for u in conv_uuids:
            try:
                res = self._eval(script_archive(u))
                if isinstance(res, dict) and res.get("ok"):
                    done.append(u)
            except Exception:
                continue
        return done

    def deliver(self, msg: dict) -> dict:
        """Deliver one queued message. Returns {'ok', 'conv_uuid', 'retry_safe', 'uncertain', 'error'}."""
        text = str(msg.get("text") or msg.get("prompt") or "")
        if not text:
            return {"ok": False, "error": "empty_text", "retry_safe": False}
        mode = str(msg.get("mode") or "")
        target_conv = str(msg.get("conv_uuid") or "").strip()
        msg_id = str(msg.get("id") or "relay_" + str(int(time.time() * 1000)))
        self.ensure_hook()

        state = self._wait_state(lambda s: "error" not in s, 4.0)
        if not state:
            return {"ok": False, "error": "no_state", "retry_safe": True}

        if mode == "new_window_handover":
            if state.get("conv_uuid") or not state.get("has_composer"):
                nav = self._eval(script_nav_new_chat())
                if not (isinstance(nav, dict) and nav.get("clicked")) and state.get("conv_uuid"):
                    return {"ok": False, "error": "new_chat_button_missing", "retry_safe": True}
                state = self._wait_state(lambda s: not s.get("conv_uuid") and s.get("has_composer"), 6.0)
                if state.get("conv_uuid") or not state.get("has_composer"):
                    return {"ok": False, "error": "new_chat_not_ready", "retry_safe": True}
        elif not target_conv:
            # An in-place message may only go into a conversation known to belong to this task; typing into
            # whatever chat happens to be open (or a blank one) would hijack it.
            session_key = str(msg.get("session_key") or "")
            owned = bool(session_key and session_key in (state.get("page_hints") or []) and state.get("conv_uuid"))
            if not owned:
                return {"ok": False, "error": "no_bound_conversation", "retry_safe": True, "conv_missing": True}
            if not state.get("has_composer"):
                return {"ok": False, "error": "no_composer", "retry_safe": True}
        elif target_conv and state.get("conv_uuid") != target_conv:
            try:
                nav = self._eval(script_nav_conv(target_conv))
            except Exception:
                nav = {"navigated": True}
            state = self._wait_state(lambda s: s.get("conv_uuid") == target_conv and s.get("has_composer"), 10.0)
            if state.get("conv_uuid") != target_conv:
                return {"ok": False, "error": "conv_not_found", "retry_safe": True, "conv_missing": True}
            self.ensure_hook()
        elif not state.get("has_composer"):
            return {"ok": False, "error": "no_composer", "retry_safe": True}

        # Spec v4.3 Q1/Q3: a manual follow-window instruction typed in the panel may steer a running conversation live and
        # takes priority over a hand-typed draft. Automatic wakeups keep the original polite rules.
        manual_steer = bool(msg.get("manual_send")) and mode == "custom_message"
        draft = str(state.get("composer_text") or "").strip()
        if draft and not manual_steer and not text.strip().startswith(draft[:200]):
            # Never overwrite something the user is typing in the app; try again later.
            return {"ok": False, "error": "user_draft", "retry_safe": True}

        if state.get("is_generating") or state.get("sse_active"):
            if manual_steer and state.get("can_steer"):
                pass  # live steering is available: fill + send straight into the running turn
            else:
                state = self._wait_state(
                    lambda s: not (s.get("is_generating") or s.get("sse_active")) or (manual_steer and s.get("can_steer")),
                    3.0,
                    0.5,
                )
                if state.get("is_generating") or state.get("sse_active"):
                    if manual_steer and not state.get("can_steer"):
                        # Steering never became available: stop-loss -> stop + archive the old conversation, continue in a fresh one.
                        return {"ok": False, "error": "steer_unavailable", "retry_safe": True, "steer_unavailable": True}
                    if not manual_steer:
                        return {"ok": False, "error": "busy_generating", "retry_safe": True}

        fill = self._eval(
            script_fill(
                msg_id,
                text,
                str(msg.get("target_model") or msg.get("model") or ""),
                str(msg.get("reasoning_effort") or ""),
            )
        )
        if not (isinstance(fill, dict) and fill.get("composer")):
            return {"ok": False, "error": "no_composer", "retry_safe": True}
        self._sleep(0.28)

        clicked = False
        try:
            for i in range(16):
                sent = self._eval(script_send())
                if isinstance(sent, dict) and sent.get("clicked"):
                    clicked = True
                    break
                if isinstance(sent, dict) and sent.get("via") == "enter" and i >= 6:
                    clicked = True
                    break
                self._sleep(0.18)
        except Exception as exc:
            return {"ok": False, "error": f"send_error:{exc}", "uncertain": True, "retry_safe": False}
        if not clicked:
            return {"ok": False, "error": "send_button_missing", "retry_safe": True}

        # Past this point the message may already be on its way: any failure is "uncertain", never retry-safe.
        status = ""
        conv = ""
        draft_id = ""
        try:
            for _ in range(170):
                st = self._eval(script_dispatch_status(msg_id))
                if isinstance(st, dict) and st.get("id") == msg_id:
                    status = str(st.get("status") or "")
                    conv = str(st.get("conv_uuid") or "")
                    draft_id = str(st.get("draft_id") or "")
                    if status in ("accepted", "failed"):
                        break
                self._sleep(0.12)
            if status == "accepted" and not conv:
                for _ in range(25):
                    st = self._eval(script_dispatch_status(msg_id))
                    if isinstance(st, dict):
                        conv = str(st.get("conv_uuid") or "")
                        draft_id = str(st.get("draft_id") or draft_id or "")
                    if conv:
                        break
                    self._sleep(0.2)
        except Exception as exc:
            return {"ok": False, "error": f"post_send_error:{exc}", "uncertain": True, "retry_safe": False}
        if status != "accepted":
            return {"ok": False, "error": "unconfirmed", "uncertain": True, "retry_safe": False}
        return {"ok": True, "conv_uuid": conv, "draft_id": draft_id}
