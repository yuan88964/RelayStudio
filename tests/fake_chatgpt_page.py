"""Test adapter for the ChatGPT Desktop webview (second adapter at the RelayCdp.evaluate seam).

``FakeChatGptPage.evaluate(expression, kind="webview")`` understands the ``/*relay:<op>*/`` markers that
RelayCdp page scripts carry, and emulates just enough of chatgpt.com to exercise the delivery orchestration.
"""

import json
import re


def _arg_after(expression: str, key: str):
    idx = expression.index(key) + len(key)
    value, _ = json.JSONDecoder().raw_decode(expression, idx)
    return value


class FakeChatGptPage:
    def __init__(
        self,
        conv_uuid: str = "",
        has_composer: bool = True,
        page_hints=None,
        is_generating: bool = False,
        hook_installed: bool = True,
        dispatch_status: str = "accepted",
        new_conv_uuid: str = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        known_convs=None,
        new_chat_button: bool = True,
        chat_mode_selected: bool = True,
        composer_text: str = "",
        archive_ok: bool = True,
        fail_on_op: str = "",
        can_steer: bool = False,
    ):
        self.conv_uuid = conv_uuid
        self.has_composer = has_composer
        self.page_hints = list(page_hints or [])
        self.is_generating = is_generating
        self.hook_installed = hook_installed
        self.dispatch_status = dispatch_status
        self.new_conv_uuid = new_conv_uuid
        self.known_convs = set(known_convs or [])
        self.new_chat_button = new_chat_button
        self.chat_mode_selected = chat_mode_selected
        self.composer_text = composer_text
        self.archive_ok = archive_ok
        self.fail_on_op = fail_on_op
        self.can_steer = can_steer
        self.main_window_opened = 0
        self.calls = []
        self.filled = None
        self.fill_args = None
        self.sent = False
        self.archived = []
        self.stopped = 0
        self.turn_seq = 1
        self.available_models = []
        self.hook_injections = 0
        self.mode_switches = 0
        self._pending_dispatch_id = ""

    def ops(self):
        return [c[0] for c in self.calls]

    def evaluate(self, expression: str, kind: str = "webview"):
        m = re.match(r"/\*relay:([a-z_]+)\*/", expression)
        op = m.group(1) if m else "hook_source"
        self.calls.append((op, kind))
        if self.fail_on_op and op == self.fail_on_op:
            raise RuntimeError(f"simulated cdp error on {op}")
        if op == "ensure_chat_mode":
            if not self.chat_mode_selected:
                self.chat_mode_selected = True
                self.mode_switches += 1
                return {"found": True, "switched": True}
            return {"found": True, "switched": False}
        if op == "hook_installed":
            return self.hook_installed
        if op == "hook_source":
            self.hook_installed = True
            self.hook_injections += 1
            return None
        if op == "state":
            draft = str(self.composer_text or "").strip()
            return {
                "url": f"https://chatgpt.com/c/{self.conv_uuid}" if self.conv_uuid else "https://chatgpt.com/",
                "native_url": "app://-/index.html",
                "conv_uuid": self.conv_uuid,
                "title": "ChatGPT",
                "has_composer": self.has_composer,
                "sse_active": self.is_generating,
                "is_generating": self.is_generating,
                "turn_seq": self.turn_seq,
                "has_error": False,
                "page_hints": list(self.page_hints),
                "composer_text": self.composer_text,
                "has_user_draft": bool(draft),
                "can_steer": bool(self.can_steer),
                "current_model": "gpt-6-thinking",
                "current_effort": "standard",
                "available_models": list(self.available_models),
                "hook": self.hook_installed,
            }
        if op == "nav_new_chat":
            if not self.new_chat_button:
                return {"clicked": False}
            self.conv_uuid = ""
            return {"clicked": True}
        if op == "nav_conv":
            target = _arg_after(expression, "const u=")
            if target in self.known_convs:
                self.conv_uuid = target
                return {"found": True, "navigated": False}
            return {"found": False, "navigated": True}
        if op == "fill":
            if not self.has_composer:
                return {"composer": False}
            self.fill_args = {
                "id": _arg_after(expression, "const id="),
                "text": _arg_after(expression, "const text="),
                "model": _arg_after(expression, "const model="),
                "effort": _arg_after(expression, "const effort="),
            }
            self.filled = self.fill_args["text"]
            self._pending_dispatch_id = self.fill_args["id"]
            return {"composer": True, "filled": True}
        if op == "send":
            if self.filled is None:
                return {"clicked": False, "via": ""}
            self.sent = True
            return {"clicked": True, "via": "button"}
        if op == "dispatch_status":
            if self.sent and self.dispatch_status == "accepted" and not self.conv_uuid:
                self.conv_uuid = self.new_conv_uuid
            return {
                "id": self._pending_dispatch_id,
                "status": self.dispatch_status if self.sent else "waiting",
                "conv_uuid": self.conv_uuid,
            }
        if op == "stop":
            self.stopped += 1
            self.is_generating = False
            return {"ok": True}
        if op == "open_main_window":
            self.main_window_opened += 1
            return {"ok": True}
        if op == "archive":
            self.archived.append(_arg_after(expression, "const u="))
            return {"ok": bool(self.archive_ok)}
        raise AssertionError(f"unexpected script op {op}")
