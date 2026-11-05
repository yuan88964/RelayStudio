# 03: 多平台模型目录分槽采集与底部模型下拉框分组展开闭环

**What to build:** 打通 **网页探针（Web Probe）**、**后台大管家（Studio Hub）** 与 **前台遥控面板（Studio Panel）** 底部任务输入舱之间的多平台模型目录分槽同步链路。当浏览器打开 ChatGPT、Gemini 或 Claude 网页端时，**网页探针** 采集当前平台的可用模型列表并上报至 **后台大管家** 对应平台的独立模型槽位（多平台同时在线互不覆盖）；用户在面板底部点开左一栏「模型下拉框」时，顶栏已启用的各平台分组标题下各自展开该平台真实的可用模型选项，尚未连接对应网页的平台分组下则严格保持只显示 `默认 (跟随网页)`。

**Blocked by:** 02: Gemini 与 Claude 网页探针接入、会话投递与新窗交接闭环

**Status:** completed

- [x] **后台大管家** 在会话桥接状态与面板快照中按平台分槽维护可用模型目录（涵盖 `OpenAI`、`Gemini`、`Claude`），不同平台的 **网页探针** 上报各自模型列表时归入对应平台槽位、互不覆盖，同时保持原有默认模型字段与 `OpenAI` 槽位同步以兼容既有调用方。
- [x] **网页探针** 在 Gemini 与 Claude 网页端采集当前页面可用的模型目录，并随轮询报文连同当前平台标识上报至 **后台大管家**。
- [x] 当顶栏 **平台通道胶囊** 启用多个平台时，面板底部左一栏「模型下拉框」按已启用平台展示带同频呼吸灯状态的分组标题，并在每个已连接网页的平台分组下动态展开该平台真实的可用模型选项。
- [x] 当某个已启用平台尚未连接网页或尚未抓回模型列表时，该平台分组下严格只显示唯一一项 `默认 (跟随网页)`，绝不预填虚假模型或借用其他平台的模型列表。
- [x] 底部输入舱模型与思考强度联动测试、后台大管家快照测试与网页探针测试全部通过。

## Accepted Amendments & Internal Adaptations

- Canonical keys chatgpt/gemini/claude; OpenAI maps to chatgpt, legacy available_models remains OpenAI alias. Persistent catalogs and visible catalogs are separate: snapshot/session metadata exposes only fresh-probe catalogs (15s) plus connected_providers.
- Selected provider travels through composer config and launchpad inheritance. Online/offline provider switches clear old room, tab and project identities.
- Review fixes have actual producer-to-consumer coverage: HTTP session metadata, raw launchpad freshness, production-shaped StateInfo arrays.
- Verified: Hub HTTP12; v46/v47 combined36; probe68, bridge39, effort76, receipt17; PS default265, effort31, ModelCatalogOnly5. Standards0 findings; Spec findings fixed and final re-review passed3649752. Integration/root owns final full regression.
- Real logged-in websites, live external MCP APIs and visible desktop UI not exercised.

## Attempt Log & Quarantine Status

- (If a subagent hits Two-Strike-Stop or Quarantined status, record: [1] approach tried, [2] falsifying error/evidence, [3] constraint for the next agent or user decision needed.)

## Integration verification repair

- Final integration default PS run exposed legacy snapshots with AvailableModels but no availability metadata being interpreted as disconnected. The earlier 265-pass result predated the final resolver changes; it did not cover that candidate.
- 1b535ef preserves legacy unknown(null) vs explicit disconnected(empty array), without changing the existing assertion. Same default PS file then passed265; model/effort suite32 passed.
- 5209b98 distinguishes those states in the render cache signature; sequential unknown-to-disconnected regression passes, model/effort suite33 passed. Both Standards and Spec review the committed repair.
