# RelayStudio 顶栏双组纯图标分段胶囊、多平台模型分组呼应与跨层契约防崩规格书（Spec）

- **Status**: `ready-for-agent`
- **Date**: 2026-11-04

---

## Problem Statement

在围绕「主动向网页端派发开发任务，并让网页端借助本地 MCP 工具回调操控电脑」的核心闭环打磨 **前台遥控面板（Studio Panel）** 与 **新建任务发射台（New Task Launchpad）** 的过程中，当前系统在顶栏交互布局、上下模型/思考强度联动以及跨模块底层契约上存在四类核心问题：

1. **顶栏控件分散、文字冗余且缺乏多平台分段生长能力**：
   - 顶栏按钮分散在左右两端并夹杂竖线隔板与文字标签，视觉不够紧凑；
   - 隧道状态区仅支持单一固定按钮，无法以一体式分段胶囊的形态按需通过末尾 `＋` 动态添加和切换多个平台分栏（如 `OpenAI`、`Claude`、`Gemini`、`DeepSeek`、`OpenCode`）；
   - 平台配置弹窗中存在多余的界面操作说明小字，且对「需要本地反向隧道进程（`tunnel`）」与「仅需 API Key 与接口配置（`apikey`）」的平台未做表单与底部操作区分，左下角快捷链接顺序也未统一为「左：获取或管理 API Key，右：平台适配入口」。
2. **顶栏胶囊分栏与下方模型下拉框、思考强度栏脱节，且冷启动越权预填假数据**：
   - 下方左一栏「模型下拉框」未与顶栏胶囊已启用的平台分栏建立分组与呼吸灯呼应关系，用户在顶栏添加新平台分栏后，无法在下方模型下拉框中看到对应的平台分组；
   - 在网页尚未连接或尚未抓回真实模型与思考档位信息的冷启动阶段，底层逻辑会偷偷读取本机 `~/.codex/.codex-global-state.json` 的 CLI 缓存冒充网页模型，且 UI 层在无网页信息时硬编码预填了 `min / standard / extended / max` 四个思考档位并将默认项显示为 `🧠 默认 (standard)`，违背了「一开始只显示 `默认 (跟随网页)`、待从网页读取实际信息后再展开」的原则。
3. **跨模块底层接口契约缺乏防御性校验，易引发内核或隧道进程静默崩溃**：
   - 本地 Go 内核（`:8765`）对环境变量 `RELAYCORE_ACP_PROFILES_JSON` 中的 `kind`（仅限 `"codex" | "claude" | "custom"`）、`id` 命名正则与保留字双向约束（`custom` 类型严禁使用 `"codex"` 或 `"claude"` 作为 `id`），以及 `RELAYCORE_ACP_DEFAULT_PROFILE` 必须命中已启用列表具有强校验，一旦传入未归一化的字段即刻以 `exit code 1` 秒退，进而阻断后续 **后台大管家（Studio Hub）**（`:8766`）与隧道客户端（`:8789`）的启动；
   - 配置保存模块在覆写 `settings.json` 时使用固定字段白名单字典，会静默抹除 `workspace_roots`、`extra_bin_dirs` 等扩展配置项；
   - 若将非隧道类的平台密钥配置（`kind: "apikey"`）混入原有的 `Save-ConnectionProfile` / `Select-ConnectionProfile` 流程，会触发 `tunnel_...` 正则校验报错或错误覆写 OpenAI 隧道的 `relay-tunnel.yaml` 与 `openai-api-key.dpapi`。

---

## Solution

围绕「顶栏双组纯图标与分段生长胶囊、上下分组同频呼应与冷启动纯净默认、五层跨模块契约防崩守卫」三大方向，对系统进行收敛重构：

1. **顶栏左侧双组纯图标布局 + 一体式分段生长胶囊**：
   - **完全集中在顶栏左侧，移除所有竖线隔板**：
     - **第一组（视图与外观组，3 项紧凑相连）**：最左端为 `[R] RelayStudio` 品牌标识，紧跟 `[◧ 侧边栏切换纯图标]` 与 `[☀/🌙 外观切换纯图标]`；全部采用纯图标设计，不带文字标签，仅在鼠标悬停时显示提示说明。
     - **第二组（设置与平台胶囊组，与第一组保留舒适留白间距）**：左侧为 `[⚙ 通用设置纯图标]`，右侧紧贴 **一体式分段生长胶囊**。
   - **一体式分段生长胶囊与平台卡片弹窗**：
     - 胶囊内部以 `1px` 细线分隔各个已启用的平台分栏，每个分栏保留 **呼吸灯状态点（`🟢` / `⚪`）+ 当前配置名称**（多平台共存时前缀显示平台短名，如 `OpenAI:yuan88964`），胶囊最末尾一格固定为 **`＋`** 按钮。
     - 点击胶囊任意平台分栏，弹出该平台的配置卡片（去除冗余的界面用法说明小字）：
       - **隧道型平台（`kind: "tunnel"`，如 OpenAI）**：展示配置名称、`tunnel_...` 隧道编号、OpenAI API Key，右下角提供 `▶ 启动隧道 / ↻ 重新连接` 与 `断开`；
       - **密钥型平台（`kind: "apikey"`，如 Claude / Gemini / DeepSeek / OpenCode）**：展示配置名称、API Key、接口地址（可选），右下角提供 `✓ 测试连接` 与 `启用密钥 / 停用`；
       - **卡片左下角链接统一规范**：所有平台卡片左下角统一为 **左侧固定是 `获取或管理 API Key ↗`（`ApiKeysButton`），右侧是该平台对应的适配入口（`PlatformButton`）**（如 OpenAI 为 `打开 OpenAI 隧道设置 ↗`、Claude 为 `网页端 Connectors ↗`、Gemini 为 `打开 Google AI Studio ↗`、DeepSeek 为 `开放平台文档 ↗`、OpenCode 为 `OpenCode 官方文档 ↗`）。
     - 点击胶囊末尾的 **`＋`** 按钮，弹出平台添加面板（包含 `OpenAI` 本身及预设平台，仅保留各平台自身作用说明，不写多余的界面操作提示；新添加的分栏默认仅创建干净的初始配置，不预填假账号或假密钥）。
2. **顶栏胶囊分栏 ↔ 下方「模型栏 / 思考强度栏」分组呼应与冷启动纯净默认态**：
   - **顶栏加一个分栏 ➔ 下方模型下拉框自动多一个带呼吸灯的分组**：顶栏胶囊中有几个平台分栏，下方左一栏「模型下拉框」点开后就自动渲染几个对应的平台分组，且分组标题旁同步显示顶栏该分栏的呼吸灯状态（`🟢` / `⚪`）与当前配置名。
   - **冷启动严格只显示 `默认 (跟随网页)`**：在 **网页探针（Web Probe）** 或 **桌面联络员（Desktop Bridge Agent）** 尚未从真实网页读取到模型目录与思考档位信息前（同时切断对本地 `~/.codex` CLI 缓存的跨界借用），下方左一栏（模型下拉框各分组内）与中间栏（思考强度下拉框）**一律只显示唯一一项 `默认 (跟随网页)`（`Tag = 'inherit'`）**，绝不预填写死的假模型列表或兜底的 `min / standard / extended / max` 档位；待网页实际回传信息后，再动态展开真实模型与对应思考档位。
   - **右侧运行载体栏保持纯粹自由选择**：只要隧道已建立，右一栏「运行载体下拉框」可自由选择任意浏览器分身或桌面客户端派发任务，不加呼吸灯绑定或错配告警。
3. **跨模块强约束契约守卫（防崩加固）**：
   - 在连接管理引擎层落地 ACP Profile 双向校验守卫、`settings.json` 非破坏性合并写盘守卫、以及 `tunnel` 与 `apikey` 两类配置的读写与进程隔离守卫，确保新增平台或自定义 CLI 智能体绝不引发内核崩溃或配置丢失。

---

## User Stories

1. As a RelayStudio 用户, I want 顶栏所有操作入口集中在左侧且分为紧凑的两组纯图标（`RelayStudio + 侧边栏图标 + 外观图标` 为第一组，留白后 `设置图标 + 分段隧道胶囊` 为第二组，无任何竖线隔板或文字标签，悬停才显示说明）, so that 顶栏视觉干净克制且符合高频操作动线。
2. As a RelayStudio 用户, I want 隧道状态区呈现为一个内部用细线分隔、末尾固定带 `＋` 的一体式胶囊，每一节都保留呼吸灯和当前生效配置名, so that 我能一眼看清各平台的在线状态并按需向右生长新的平台分栏。
3. As a RelayStudio 用户, I want 点击胶囊的某一节时直接弹出对应平台的配置卡片，且所有平台卡片左下角统一为「左侧：获取或管理 API Key ↗，右侧：平台适配入口 ↗」, so that 我在不同平台卡片中拥有一致的直觉操作体验。
4. As a RelayStudio 用户, I want 平台配置卡片根据平台真实机制区分表单与操作（OpenAI 展示隧道编号与 API Key 并控制本地隧道进程；Claude / Gemini / DeepSeek / OpenCode 展示 API Key 与可选接口地址并提供连接测试与启用/停用）, so that 界面配置项与各平台的真实工作原理严格一致。
5. As a RelayStudio 用户, I want 点击胶囊末尾的 `＋` 时弹出包含 OpenAI 及预设平台的添加列表（不含多余的界面操作说明小字），且添加新平台分栏时不预填假账号或假密钥, so that 界面清爽且不会混入干扰性的虚假预设数据。
6. As a RelayStudio 用户, I want 顶栏胶囊每增加或启用一个平台分栏，下方「新建任务 / 任务输入舱」左一栏的模型下拉框中就自动对应多出一个带同频呼吸灯的平台分组, so that 上方平台通道配置与下方模型选择能够直观呼应。
7. As a RelayStudio 用户, I want 模型下拉框（各平台分组下）与思考强度下拉框在尚未从网页端读取到实际信息前，一开始都只显示 `默认 (跟随网页)` 而不预填很多选项，等到从网页端读取到实际信息后再显示出相应的模型与思考档位, so that 下拉列表真实反映当前网页状态而不会展示虚假或过期的预填项。
8. As a RelayStudio 用户, I want 建好隧道后在右一栏「运行载体」中可以自由选择任意浏览器分身或桌面客户端来派发任务，不受隧道账号强制绑定或告警条干扰, so that 我能灵活把任务派发给任意目标浏览器窗口。
9. As a RelayStudio 用户, I want 本地内核、护盾与隧道进程在面对各种 CLI 智能体配置、多平台密钥切换与设置保存时具备严格的跨层契约保护, so that 不会再发生因枚举值不匹配或配置覆写导致隧道连不上、内核崩溃退出或设置丢失的故障。

---

## Implementation Decisions

### 1. 五层架构模块划分与跨边界接口契约（Architecture & Module Contracts）

系统由五个正交的 **模块** 组成，各模块通过明确的 **接口契约** 通信：

```
┌────────────────────────────────────────────────────────────────────────────┐
│ 1. 前台遥控面板模块 (WPF UI Module)                                         │
│    - 职责：顶栏双组纯图标 + 分段生长胶囊、双弹窗交互、底部任务输入舱联动    │
└───────────────────┬────────────────────────────────────┬───────────────────┘
                    │ PowerShell 模块接口契约              │ HTTP JSON 接口契约 (:8766)
                    ▼                                    ▼
┌───────────────────────────────────────┐  ┌─────────────────────────────────┐
│ 2. 连接与凭据引擎模块                  │  │ 3. 后台大管家模块 (Studio Hub)   │
│    (Connection & Credential Engine)   │  │    - 职责：会话快照、网页桥接态   │
│    - 职责：多平台凭据读写、DPAPI 加密、 │  │      聚合、任务账本与催工守护   │
│      内核与隧道守护进程生命周期管理    │  └────────────────┬────────────────┘
└─────────┬───────────────────┬─────────┘                   │ HTTP / CDP 桥接契约
          │ 环境变量/CLI 契约  │ YAML/环境变量契约           ▼
          ▼                   ▼            ┌─────────────────────────────────┐
┌──────────────────┐ ┌───────────────────┐ │ 4. 网页探针与桌面联络员模块      │
│ 5a. 本地内核进程  │ │ 5b. 反向隧道客户端 │ │    (Web Probe & Desktop Bridge) │
│ (:8765 Go Core)  │ │ (:8789 Tunnel)    │ │    - 职责：实时抓取网页模型目录  │
└──────────────────┘ └───────────────────┘ │      与思考档位、执行网页派单    │
                                           └─────────────────────────────────┘
```

### 2. 连接与凭据引擎模块（Connection & Credential Engine）接口契约与防崩守卫

1. **多平台凭据与胶囊分栏持久化 Schema（`data/credential-profiles.json` 向后兼容契约）**：
   - 在保持顶层 `schema_version = 1` 与 `active_profile_id`（专指当前激活的 OpenAI 隧道配置 ID，确保既有调用方与测试零破坏）的基础上，扩展支持多平台胶囊分栏：
     ```json
     {
       "schema_version": 1,
       "active_profile_id": "prof_primary",
       "enabled_platforms": ["openai"],
       "active_profile_by_platform": {
         "openai": "prof_primary"
       },
       "profiles": [
         {
           "id": "prof_primary",
           "platform": "openai",
           "kind": "tunnel",
           "name": "yuan88964",
           "tunnel_id": "tunnel_...",
           "base_url": "https://api.openai.com",
           "key_file": "openai-api-key.dpapi",
           "enabled": true,
           "updated_at": "2026-11-04T22:00:00"
         }
       ]
     }
     ```
   - **读取缺省归一化规则（`Get-ConnectionProfiles`）**：
     - 旧版无 `platform` 字段的条目自动归一化为 `Platform = 'openai'`；
     - 无 `kind` 字段的条目：当 `Platform -eq 'openai'` 时默认 `Kind = 'tunnel'`，其余平台（`claude`、`gemini`、`deepseek`、`opencode`）默认 `Kind = 'apikey'`；
     - 无 `enabled_platforms` 时默认初始化为 `@('openai')`；
     - 返回对象除保留原有的 `ActiveProfileId` 与 `Profiles` 外，新增 `EnabledPlatforms`（字串数组）与 `ActiveProfileByPlatform`（哈希表/对象）。
   - **隧道型（`tunnel`）与密钥型（`apikey`）读写及进程隔离守卫**：
     - `Save-ConnectionProfile` 新增可选参数 `-Platform 'openai'`、`-Kind ''`、`-BaseUrl ''`（不传时默认 `Platform = 'openai'`、`Kind = 'tunnel'`，完全兼容既有测试与调用点）：
       - 仅当 `$Kind -eq 'tunnel'` 且 `$TunnelId` 非空时，才执行 `ConvertTo-TunnelId` 校验；当 `$Kind -eq 'apikey'` 时允许 `$TunnelId` 为空，并保存可选的 `BaseUrl`；
       - 仅当保存或激活的目标条目满足 `Platform -eq 'openai' -and Kind -eq 'tunnel'` 时，才同步更新 `$Settings.tunnel_id`、覆盖 `$Context.KeyPath`（`openai-api-key.dpapi`）并在需要时重启 `tunnel-client.exe`；
       - 对 `Kind -eq 'apikey'` 的条目执行保存、切换（`Select-ConnectionProfile`）或启用/停用时，仅更新 `credential-profiles.json` 中的 `active_profile_by_platform[$platform]` 与对应 `.dpapi` 密钥文件，**严禁修改 `$Settings.tunnel_id`、严禁覆盖 `openai-api-key.dpapi`、严禁启停 `tunnel-client.exe`**。
   - **胶囊平台分栏增删接口（`Add-CapsulePlatform` / `Remove-CapsulePlatform`）**：
     - 当用户在 UI 点击胶囊末尾 `＋` 选择某预设平台（`openai`、`claude`、`gemini`、`deepseek`、`opencode`）时，将该平台 ID 加入 `enabled_platforms`；若该平台尚无任何配置条目，仅初始化一条干净的默认空白条目（`Name = '默认'`、`TunnelId = ''`、无预填假密钥，`Enabled = $false`），绝不预填虚假账号或掩码。

2. **本地内核启动强约束守卫（`Start-OfficialCoreIfNeeded` & `Add-CustomCliAgent`）**：
   - **`kind` 与 `id` 双向保留字守卫**：
     - 在 `Get-DetectedCliAgents`、`Add-CustomCliAgent` 与 `Start-OfficialCoreIfNeeded` 中，除内置的 `id == 'codex'`（`kind = 'codex'`）和 `id == 'claude'`（`kind = 'claude'`）外，所有其他 CLI 智能体的 `kind` 强制归一化为 `'custom'`；
     - 在 `Add-CustomCliAgent` 中，清洗生成的 `$idSlug` 必须匹配 `^[a-z0-9._-]{1,64}$`；若用户选中的自定义可执行文件名为 `codex` 或 `claude`，自动添加前缀转为 `'custom-codex'` 或 `'custom-claude'`，防止触发内核 `ACP profile id is reserved for the built-in profile` 致命退出。
   - **`RELAYCORE_ACP_DEFAULT_PROFILE` 存在性守卫与并发数钳制**：
     - 在 `Start-OfficialCoreIfNeeded` 组装 `$acpList` 后：
       - 若 `$acpList.Count -eq 0` 或 `$acpLim -le 0`，强制设置 `RELAYCORE_ACP_ENABLED = 'false'`；
       - 若 `$acpList.Count -gt 0` 且 `$acpDef -notin @($acpList | ForEach-Object { [string]$_.id })`，自动将 `$acpDef` 回退为 `[string]$acpList[0].id`；
       - 将 `RELAYCORE_ACP_MAX_CONCURRENT_PROMPTS` 严格钳制在 `[Math]::Min(8, [Math]::Max(1, [int]$acpLim))` 范围内。
   - **内核启动失败诊断透出**：
     - 当 `Start-OfficialCoreIfNeeded` 轮询 `:8765/healthz` 未就绪时，自动读取 `data\logs\core.err.log` 末尾非空报错行写入诊断信息，杜绝静默吞没底层退出原因。

3. **`Save-ConnectionSettings` 非破坏性合并写盘守卫**：
   - 在 `Save-ConnectionSettings` 构造写盘 JSON 前，先读取磁盘上现有的 `data\settings.json` 全部键值作为基底字典，再覆写更新已知核心字段，完整保留 `workspace_roots`、`extra_bin_dirs`、`custom_cli_agents`、`default_browser_profile`、`auto_archive_completed_mode` 等全部扩展属性。

### 3. 前台遥控面板模块（WPF UI Module）接口契约与交互流转

1. **顶栏（`AppTitleBarBorder`）双组纯图标 + 分段生长胶囊布局契约**：
   - **第一组（左侧起点，紧凑相连，无竖线隔板）**：
     - `[R] RelayStudio` 品牌标识 ➔ `ToggleRailButton`（`28x28` 纯图标，ToolTip 显示 `"展开 / 收起左侧任务分栏"`） ➔ `ThemeToggleButton`（`28x28` 纯图标，内含 `ThemeToggleIconPath`，ToolTip 显示当前外观模式说明，左键切换深浅色、右键恢复跟随系统）。
   - **第二组（与第一组相隔 `20px` 留白间距，无竖线隔板）**：
     - `GlobalSettingsButton`（`28x28` 纯齿轮图标，ToolTip 显示 `"通用与本地引擎设置"`） ➔ **分段生长胶囊容器 `TunnelCapsuleBorder`**：
       - 胶囊内部由 `CapsuleSegmentsPanel`（水平 `StackPanel`）承载各已启用平台分栏按钮与 `1px` 竖向内部细分隔线，最右侧固定为 `AddPlatformCellButton`（`＋` 纯图标按钮，ToolTip 显示 `"添加平台隧道或密钥"`）；
       - 第一个 OpenAI 分栏直接复用并保留 `ConnIconBadgeButton`、`TopStatusDot`、`ConnProfileMiniTagBorder`、`ConnProfileMiniTagText` 的控件名与事件绑定，确保既有测试无缝通过；当 `enabled_platforms` 包含多个平台时，动态在 `CapsuleSegmentsPanel` 中追加其余平台分栏按钮（每个分栏显示呼吸灯圆点 + `平台短名:当前配置名`）。
   - **顶栏右侧**：仅保留故障时才显现的 `TopHeartbeatPillBorder`（平时 `Collapsed`）与窗口系统控制按钮（`AppMinButton`、`AppMaxButton`、`AppCloseButton`）。

2. **平台配置卡片弹窗（`KeyPopoverBorder`）与 `＋` 添加平台面板交互契约**：
   - **去除冗余小字说明**：移除弹窗标题下方的自我解释类操作说明小字，保持头部干净（标题 `PopoverHeaderTitle` + `+ 新增配置` `AddProfileButton` + 多平台分栏下的 `移除` 按钮）。
   - **按平台类型（`tunnel` vs `apikey`）动态适配表单与底部按钮**：
     - 当激活分栏为 `OpenAI`（`kind: 'tunnel'`）时，`PopoverHeaderTitle.Text` 保持 `"OpenAI 隧道配置 (N)"`；内联编辑表单显示「配置名称」「隧道编号 (tunnel_...)」「OpenAI API Key」；右下角主按钮 `QuickConnectButton` 显示 `▶ 启动隧道` / `↻ 重新连接`，旁配 `DisconnectButton`（`断开`）。
     - 当激活分栏为 `Claude / Gemini / DeepSeek / OpenCode`（`kind: 'apikey'`）时，`PopoverHeaderTitle.Text` 显示 `"<平台标题> (N)"`；内联编辑表单显示「配置名称」「API Key」「接口地址 (可选)」；右下角主按钮 `QuickConnectButton` 显示 `✓ 测试连接`（点击后探测接口连通性并反馈 `✓ 接口连通正常`），旁配 `启用密钥 / 停用`。
   - **左下角快捷链接统一为「左：获取 API Key，右：平台适配选项」**：
     - 调整 `KeyPopoverBorder` 底部左侧链接顺序：**左侧固定放置 `ApiKeysButton`（文案根据平台显示 `获取或管理 API Key ↗` / `获取 XX API Key ↗`），右侧放置 `PlatformButton`（文案根据平台显示 `打开 OpenAI 隧道设置 ↗` / `网页端 Connectors ↗` / `打开 Google AI Studio ↗` / `开放平台文档 ↗` / `OpenCode 官方文档 ↗`）**。
   - **`＋` 添加平台视图**：
     - 点击胶囊末尾的 `AddPlatformCellButton`（`＋`）时，在弹窗内展示预设平台列表（包含 `OpenAI`、`Claude`、`Gemini`、`DeepSeek`、`OpenCode`，展示平台名称与该平台密钥/隧道的实际用途说明，不写多余的界面操作说明小字）；点击某平台后，胶囊向右长出一节对应平台分栏，末尾 `＋` 保持在最右端。

3. **下方任务输入舱（`Build-PlanBComposerPod` & `Sync-ComposerModelAndEffortCombos`）上下呼应与冷启动纯净契约**：
   - **冷启动数据源净化**：
     - 在 `ConnectionManager.psm1` 的 `Get-WebBridgeState` 与 `McpReadOnlyShield.py` 的 `_get_effective_available_models` 中，当 `web-bridge-state.json` 尚未收到网页端上报的 `available_models` 时，直接返回空数组 `@()` / `[]`，**不再读取 `~/.codex/.codex-global-state.json` 冒充网页端模型列表**（保留 `Get-CodexCachedAvailableModels` 独立函数供其单元测试调用）。
   - **冷启动 UI 纯净默认态（模型栏与思考强度栏初始只显示 `默认 (跟随网页)`）**：
     - 在 `Sync-ComposerModelAndEffortCombos` 中判定冷启动状态：
       ```powershell
       $isColdStartNoWebModel = ($modelsArr.Count -eq 0) -and [string]::IsNullOrWhiteSpace($WebModel) -and ([string]::IsNullOrWhiteSpace($CurModel) -or $CurModel -eq 'inherit') -and [string]::IsNullOrWhiteSpace($WebEffort)
       ```
     - 当 `$isColdStartNoWebModel -eq $true` 时：
       - `ModelCombo` 中每个已启用平台分组下**仅生成唯一一项 `🤖 默认 (跟随网页)`**（窄屏为 `🤖 默认`）；
       - `EffortCombo` 的 `$webEffortDisplay` 设为 `'跟随网页'`，且**不预填** `min / standard / extended / max`，使 `EffortCombo` **仅生成唯一一项 `🧠 默认 (跟随网页)`**（窄屏为 `🧠 默认`，`Tag = 'inherit'`）。
     - 当网页端已抓回实际信息（`$modelsArr.Count -gt 0` 或 `$WebModel` / `$WebEffort` 非空，即 `$isColdStartNoWebModel -eq $false`）时：
       - 自动展开从网页端读取到的真实模型列表与对应的思考强度档位（`min / standard / extended / max` 等），并显示网页当前生效的模型与思考强度（如 `🧠 默认 (standard)`）。
   - **顶栏胶囊分栏 ↔ 下方 `ModelCombo` 平台分组与呼吸灯同频呼应**：
     - 在 `ComboBoxItem` 模板与 `Sync-ComposerModelAndEffortCombos` 中，按照顶栏胶囊当前已启用的平台分栏（`enabled_platforms`）组织 `ModelCombo` 内的平台分组：
       - 每个平台分组的首个条目上方通过模板绑定展示带同频呼吸灯（`🟢` 在线 / `⚪` 离线）的分组头（如 `🟢 OpenAI · yuan88964`、`⚪ Claude · 默认`），同时保持 `ModelCombo.Items[0]` 仍为当前主平台的 `inherit` 选项实例（确保 `$pod.Tag.ModelCombo.Items[0]` 引用稳定性与 `.Content` 字符串契约不变）；
       - 当顶栏胶囊仅启用 1 个平台且处于离线单元测试环境（无 `$script:capsuleState`）时，保持原有单列表行为，确保 `Test-ReasoningEffort.ps1` 与 `Test-ConnectionManager.ps1` 100% 兼容。

---

## Testing Decisions

### 1. 好测试的判定标准
- 测试必须仅对准各模块的对外 **接口契约**（**接口测试面**）验证用户可观测行为与跨层数据契约，不绑定私有辅助函数或内部局部变量名称。
- 优先复用现有的高阶 **可替换接缝**，不新增多余的测试脚手架文件。

### 2. 拟复用的可替换接缝（共 2 个现有最高层可替换接缝）
1. **接缝 ①：连接管理与 WPF 面板集成接缝（`tests/Test-ConnectionManager.ps1` + `tests/Test-ThemeMode.ps1`）**：
   - 覆盖 `ConnectionManager.psm1` 的对外函数契约（`Get-DetectedCliAgents`、`Add-CustomCliAgent`、`Start-OfficialCoreIfNeeded`、`Save-ConnectionSettings`、`Get-ConnectionProfiles`、`Save-ConnectionProfile`、`Select-ConnectionProfile`、`Add-CapsulePlatform`、`Remove-CapsulePlatform`）与 `连接管理.ps1` 的顶栏双组纯图标布局、分段生长胶囊、卡片左下角链接顺序（左 API Key、右平台适配项）及深浅色主题渲染契约。
2. **接缝 ②：底部输入舱模型与思考强度同步接缝（`tests/Test-ReasoningEffort.ps1`）**：
   - 覆盖 `Sync-ComposerModelAndEffortCombos` 在「冷启动未读取网页信息（模型栏与思考强度栏均只显示 `默认 (跟随网页)`）」与「网页端已抓回真实模型与思考档位（动态展开完整列表）」两种状态下的外部可观测行为，以及多平台胶囊分栏下的分组同步契约。

### 3. 既有测试样板（Prior Art）与兼容性铁律
- 参照 `tests/Test-ConnectionManager.ps1`（242 项断言）、`tests/Test-ReasoningEffort.ps1`（18 项断言）、`tests/Test-ThemeMode.ps1`（54 项断言）以及 `tests/test_spec_v46.py`。
- **兼容性铁律**：
  - 严禁破坏 `Test-ReasoningEffort.ps1` 中通过 `IndexOf('function Set-SessionPropSafe(')` 至 `IndexOf('function Build-PlanBComposerPod(')` 截取源码切片的 **可替换接缝**；
  - 严禁删除或重命名 `$script:controls` 中被测试断言的 68 个命名控件（含 `AppTitleBarBorder`、`ToggleRailButton`、`ThemeToggleButton`、`ThemeToggleIconPath`、`GlobalSettingsButton`、`GlobalSettingsPopoverBorder`、`ConnIconBadgeButton`、`TopStatusDot`、`ConnProfileMiniTagText`、`KeyPopoverBorder`、`PopoverHeaderTitle`、`ApiKeysButton`、`PlatformButton` 等）。

---

## Out of Scope

1. **非网页端纯 API 聊天客户端能力**：RelayStudio 的核心职责是向网页端派发任务并让网页端通过 MCP 工具回调操控本地电脑，不在本地面板内直接实现用 API Key 向 Claude / Gemini / DeepSeek 发起纯 HTTP 聊天对话的客户端。
2. **第三方网页端（Claude / Gemini / DeepSeek 网页版）的 DOM 自动注入扩展开发**：本次规格聚焦于顶栏分段胶囊架构、凭据/连接管理以及下方模型与思考强度栏的分组呼应机制；针对非 ChatGPT 网页端的浏览器 DOM 注入探针将在后续专项迭代中按需扩展。

---

## Accepted Amendments & Internal Adaptations

- *(初始为空，仅在实施期间按只追加方式登记经批准的修订或内部适配)*

---

## Further Notes

- 所有 PowerShell 源码文件（`ConnectionManager.psm1`、`连接管理.ps1`、`tests/*.ps1`）在编辑后必须严格保持 **`UTF-8 with BOM`** 编码与 **`CRLF`** 换行符，防止 Windows PowerShell 5.1 解析中文字符串或符号乱码。
