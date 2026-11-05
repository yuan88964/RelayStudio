# 01: 顶栏三大平台通道收敛与公网 MCP 隧道一键挂载

**What to build:** 将 **前台遥控面板（Studio Panel）** 顶栏 **平台通道胶囊（Platform Channel Capsule）** 的可选平台收敛为原生支持 MCP 的 `OpenAI`、`Gemini`、`Claude` 三项（彻底移除 `DeepSeek` 与 `OpenCode` 并自动净化历史残留配置）；将 `Gemini` 与 `Claude` 分栏的配置卡片从无用的 API Key 表单升级为共享本机 **公网 MCP 隧道（Public HTTPS MCP Tunnel）** 的挂载卡片，支持免配置快速生成或按自定义固定域名生成公网 HTTPS MCP 挂载网址、一键复制该网址并跳转官方连接器设置页，使 Gemini 与 Claude 的网页端和桌面端均可直接回调本机 **后台大管家（Studio Hub）** 的全部工具。

**Blocked by:** None (can start immediately)

**Status:** completed (implementation and synthetic verification; live external/UI verification not run)

- [x] 点击顶栏 **平台通道胶囊** 末尾的 `＋` 时，添加面板仅展示 `OpenAI`、`Gemini`、`Claude` 三个平台及其连接云端 **会话房间（Conversation Room）** 的用途说明；请求添加 `DeepSeek` 或 `OpenCode` 时直接拒绝并报错，且读取已有配置时自动过滤清理历史残留的已废弃平台分栏。
- [x] 点开 `Gemini` 或 `Claude` 分栏时，卡片不再展示无用的平台 API Key 表单，而是直接展示本机共享 **公网 MCP 隧道** 的运行状态与当前生效的公网 HTTPS MCP 挂载网址，并提供一键复制该网址的交互入口。
- [x] 在 `Gemini` 或 `Claude` 卡片中触发启动隧道时，支持「免配置快速模式（自动拉起本机公网隧道进程并提取生成的临时 HTTPS MCP 挂载网址）」与「固定域名模式（使用用户配置的自定义 HTTPS 域名与可选隧道凭证生成固定挂载网址）」，且 `Gemini` 与 `Claude` 共享单实例隧道进程，不重复启动。
- [x] 点击 `Gemini` 卡片左下角平台入口按钮可直接打开 Gemini 官方「已关联的应用」设置页，点击 `Claude` 卡片左下角平台入口按钮可直接打开 Claude 官方「Connectors」设置页。
- [x] 当 Gemini 或 Claude 云端后台通过 **公网 MCP 隧道** 访问本机 **后台大管家** 时，能够正常拉取经免弹窗只读护盾处理后的工具列表并调用任务进度账本、本地文件与终端工具。
- [x] 对 `Gemini` 或 `Claude` 通道的任何保存、切换、启用或启停隧道操作，绝不修改、覆盖或重启 `OpenAI` 的 **专用反向隧道（OpenAI Private Tunnel）** 配置与密钥。
- [x] 连接与凭据引擎及前台遥控面板自动化测试套件全部通过。

## Accepted Amendments & Internal Adaptations

- Historical platform API profiles migrate persistently to quick public-tunnel mode, retaining OpenAI settings/keys unchanged; obsolete records are filtered and persisted on read.
- Existing legacy HTTP probe helper remains callable for compatibility; the public card no longer invokes platform API probes.
- Public tunnel process receipt is separate from Hub session state and guarded with a shared exclusive lock plus PID/start-time identity checks. Fixed mode supports Cloudflare token or local certificate/hostname setup; external domain/DNS configuration remains user-provided.
- Automated: `Test-ConnectionManager.ps1` passed 262 checks; `-PublicTunnelOnly` passed 13 checks via executable/log boundary fixture. Live cloud callback and visible desktop UI have NOT been run; checked acceptance items above mean implementation coverage, not a claim of real-cloud verification.
- Code review: Standards 0 hard findings; Spec initial 3 findings fixed in 17e8c7e, re-review clear.
- Sources verified 2026-11-05: https://developers.cloudflare.com/tunnel/get-started/ ; https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/ ; https://support.google.com/gemini/answer/17209137

- 2026-11-05 live-run follow-up: cloudflared retains an open writer handle on its logfile, so ReadAllText silently left the shared tunnel in Connecting state. State polling now opens a read-only FileStream with FileShare.ReadWrite | FileShare.Delete, permitting concurrent logging and rotation; process lifecycle and settings are unchanged. Regression added at the existing PublicTunnelOnly public-interface seam with a genuinely held-open write handle: red before fix (specific online-status assertion failed), green after fix (17 checks, including 3 routing checks). No live tunnel restart or production settings change performed by this fix.

## Attempt Log & Quarantine Status

- (If a subagent hits Two-Strike-Stop or Quarantined status, record: [1] approach tried, [2] falsifying error/evidence, [3] constraint for the next agent or user decision needed.)
