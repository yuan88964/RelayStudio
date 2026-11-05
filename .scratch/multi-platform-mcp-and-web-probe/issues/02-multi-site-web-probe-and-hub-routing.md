# 02: Gemini 与 Claude 网页探针接入、会话投递与新窗交接闭环

**What to build:** 通过在 **后台大管家（Studio Hub）** 建立多平台路由与跨域规格接缝，并在浏览器 **网页探针（Web Probe）** 建立跨站点探针适配接缝，使系统同时支持 ChatGPT、Gemini 与 Claude 官方对话网页。用户在面板底部向绑定了 Gemini 或 Claude 的任务发送指令、触发 **原页催工单（In-Place Wakeup）**、点击「打开网页 ↗」或执行 **新建网页交接（New Window Handover Mode）** 时，系统能够准确在对应的 Gemini 或 Claude 网页端识别 **会话房间（Conversation Room）**、检测生成状态、填入消息并提交发送，拿到 **发送回执（Delivery Receipt）** 后完成 **房产证绑定簿（Session Binding）** 过户。

**Blocked by:** 01: 顶栏三大平台通道收敛与公网 MCP 隧道一键挂载

**Status:** completed

- [x] **后台大管家** 根据任务或会话绑定的平台标识（`ChatGPT`、`Gemini`、`Claude`），动态解析对应平台的新建对话网址与 **会话房间** 直达网址；当 Gemini 或 Claude 任务触发 **新建网页交接** 或用户点击「打开网页 ↗」时，准确打开或唤醒 Gemini 或 Claude 对应页面，不再误跳往 ChatGPT。
- [x] **后台大管家** 的跨域访问控制自动放行 ChatGPT、Gemini 与 Claude 官方网页来源，确保浏览器在三家网页端下均可正常向 **后台大管家** 发起探针轮询与回执上报。
- [x] 浏览器扩展中的 **网页探针** 同时覆盖 ChatGPT、Gemini 与 Claude 网页端，并根据当前页面域名自动匹配对应的站点适配器，在轮询、认领与回执报文中携带当前平台标识。
- [x] **网页探针** 在 Gemini 与 Claude 网页端能够准确提取当前平台格式的 **会话房间** 标识，并实时检测页面是否处于流式输出或显示停止生成按钮，驱动 **后台大管家** 的停工计时器与 **等原网页停稳后交接（Deferred Stop-Wait Handover）**。
- [x] **网页探针** 兼容普通文本框与富文本编辑器，在认领到任务消息、**原页催工单** 或 **新窗交接单** 后，自动填入 Gemini 或 Claude 页面输入框并触发发送，确认发出后向 **后台大管家** 交回 **发送回执** 并完成 **房产证绑定簿** 过户。
- [x] 后台大管家多平台路由测试与网页探针跨站点适配测试全部通过，且既有 ChatGPT 网页端与桌面端投递回执测试保持 100% 兼容通过。

## Accepted Amendments & Internal Adaptations

- Existing v42 regression uses /web-bridge/heartbeat which was missing in the integration baseline; retain it as an alias to the existing poll contract (no alternate state writer).
- Native room identity is provider-qualified: Gemini IDs are not coerced into ChatGPT UUIDs; desktop ChatGPT UUID rules remain unchanged. Public routes and provider checks extend existing poll/receipt seams.
- Non-ChatGPT retirement closes the local retired tab without invoking ChatGPT-specific cloud archive APIs; no cloud archive success is fabricated. Model catalogs remain ticket03 responsibility.
- The ChatGPT page-hook fixture now supplies an explicit official page URL to exercise the real site guard; assertions unchanged.

## Attempt Log & Quarantine Status

- (If a subagent hits Two-Strike-Stop or Quarantined status, record: [1] approach tried, [2] falsifying error/evidence, [3] constraint for the next agent or user decision needed.)

## Verification

- Hub HTTP seam11 passed, probe59 assertions; bridge39, effort76, dispatch17 plus provider checks.
- Existing v47:28, v45:4, v46:8 passed. v42:33 initially passed and heartbeat compatibility failure fixed; targeted failing test passes after alias.
- PowerShell WPF/engine262 passed; narrow tunnel plus new route assertions16 passed.
- Standards0 findings. Spec2 findings fixed; rereview passed (924aa94).
- Real logged-in browser UI and external cloud APIs not run.
