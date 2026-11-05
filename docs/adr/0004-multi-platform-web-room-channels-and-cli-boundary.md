# 4. 顶栏平台通道胶囊收敛至原生 MCP 三大平台与本地 CLI 智能体边界切割

Date: 2026-11-05

## Status

Accepted

## Context

在扩展 **前台遥控面板（Studio Panel）** 顶栏 **平台通道胶囊（Platform Channel Capsule）** 时，早期设计将 `OpenAI`、`Claude`、`Gemini`、`DeepSeek`、`OpenCode` 五者并列，且将后四者全部设计为填写 API Key 的表单（`kind: "apikey"`），与真实业务需求存在三处冲突：

1. **本地 CLI 智能体凭证已由外部换号软件接管**：本机安装的 **本地 CLI 智能体（Local CLI Agent）**（`Codex`、`Claude`、`WorkBuddy`、`AGY`）已由独立的换号软件完成账号登录，无需在面板内重复填写 API Key；`OpenCode` 纯属不常用的本地命令行工具，不属于云端网页会话房间。
2. **Gemini 与 Claude 原生 MCP 采用公网 HTTPS 直连而非 API Key**：Gemini（网页端与 Windows 桌面端）及 Claude（网页端与桌面端）的官方「已关联的应用 / Connectors」均由云端服务器主动连接用户提供的公网 `https://.../mcp` 挂载地址，不需要在本地填写平台 API Key。
3. **DeepSeek 网页端缺乏原生 MCP 且自动化风控严苛**：经实证核查，`chat.deepseek.com` 完全没有原生 MCP 连接器入口，每次发言强制校验 WASM 工作量证明（`/api/v0/chat/create_pow_challenge`）与 Cloudflare Turnstile，且高峰期频发“服务器繁忙”断流；若依靠网页 DOM 正则伪造工具调用，多轮长程开发极易中断崩溃。

## Decision

1. **顶栏平台通道胶囊收敛至原生支持 MCP 的三大平台（`OpenAI`、`Gemini`、`Claude`）**：
   - 从顶栏「添加平台隧道」列表中彻底移除无原生 MCP 且网页端风控易断流的 `DeepSeek` 以及不常用的 `OpenCode`；
   - **本地 CLI 智能体** 保持归口于左上角 `⚙ 通用设置 ➔ 默认 CLI 智能体` 自动扫描列表（`Codex`、`Claude`、`WorkBuddy`、`AGY`）。
2. **顶栏三大平台统一按真实 MCP 隧道机制实装（取消无用的 API Key 表单）**：
   - **`OpenAI`（专用反向隧道 `OpenAI Private Tunnel`）**：保持现有 `tunnel-client.exe` 机制（凭 `tunnel_...` 编号与隧道鉴权 API Key 连接 OpenAI 控制面）。
   - **`Gemini` 与 `Claude`（公网 MCP 隧道 `Public HTTPS MCP Tunnel`）**：共用本机已安装的 `cloudflared.exe`（或自定义反向代理域名），将 **后台大管家（`127.0.0.1:8766/mcp`）** 映射为公网 `https://.../mcp` 地址；卡片内直接展示隧道运行状态、提供「一键启动 HTTPS 隧道」与「一键复制 `https://.../mcp` 挂载网址」按钮，左下角直达 Gemini「已关联的应用 ↗」与 Claude「网页端 Connectors ↗」。
3. **双端探针与底部输入舱同频扩展**：
   - 浏览器扩展内的 **网页探针（Web Probe）** 与底部输入舱按已启用的 `OpenAI`、`Gemini`、`Claude` 三个平台同步抓取网页端真实模型列表、执行消息投递与 **新建网页交接（New Window Handover Mode）**。

## Consequences

- 顶栏 **平台通道胶囊** 概念彻底纯粹化：100% 对应「具备官方原生 MCP 能力的三大云端主力会话房间（GPT / Gemini / Claude）」，彻底剔除 fragile 的 DOM 伪造工具链与无用的 API Key 输入框。
- 本地 CLI 智能体统一归口于 `⚙ 通用设置`，与用户的外部换号软件职责正交、零冗余。
