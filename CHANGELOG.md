# 更新日志（Changelog）

本项目的重要版本演进记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，最新绿色便携发行包可前往 [Hugging Face 发行文件列表](https://huggingface.co/datasets/yuan88964/RelayStudio-Releases/tree/main) 免登录直接下载。

---

## [v1.2.0] - 2026-11-05

### 新增与增强（Added & Changed）
- **五维生命体征引擎与通用断流自愈闭环（Spec v4.7）**：
  - **一问一答正向闭环与正文隔离提错**：`bridge-page-hook.js` 全程覆盖 `/sentinel/`、`/prepare` 与 `/conversation` 请求，校验真实 SSE 事件流是否收到 `[DONE]` / `message_stream_complete`；`bridge-content.js` 与 `RelayCdp.py` 在剔除 `.markdown, pre, code` 及用户消息气泡后提取外围报错文案 `ui_error_text`，并在输入框卸载（如“无法加载此对话”）时回退扫描主时间线 Fiber。
  - **扩展后台双白名单全量透传**：补齐 `background.js` 在 `upsertTabStateCache` 与 `collectOpenChatGptTabs` 中对 `is_archived`、`can_steer_live`、`has_composer`、`turn_incomplete`、`stream_incomplete`、`has_load_error`、`ui_error_text` 共 7 个关键状态字段的同步透传。
  - **防 Chrome 后台节流死锁与防双份草稿**：发信确认轮询引入 25s / 6.5s 物理时钟上限与 30s `isBusySending` 看门狗复位，大管家对无流生成的 `is_dispatching` 施加 35s 硬上限，彻底消除后台标签页因每分钟 1 次唤醒节流导致的数小时假在线死锁；禁止在输入框非空时二次补填，发送未确认时仅清理机器注入的草稿。
  - **六态生命体征、断网保号（`NETWORK_HOLD`）与“选项 A”原页重试阶梯**：新增 `VitalSubstate`（`LIVE / PSEUDO_STOPPED / DUAL_STREAM / WAITING_CONFIRM / NETWORK_HOLD / CONFIRMED_STOPPED`）与业务目录 `pipeline.state.json` 探针；当 `tunnel.out.log` 检测到代理连续 `EOF` 断网风暴时自动冻结派单并保留重试配额；严禁篡改已被标签页认领（`claimed`）的消息；后台工具静默满 60s 后，只要底部输入框完好且未达重试上限，优先发送原页催工单（`in_place_wakeup`），耗尽配额或页面崩溃时才升级新窗交接（`new_window_handover`）。
  - **跨截断累加计数与详情弹窗全链路校准**：在隧道日志 `2500 -> 2000` 行裁剪前归档累加淘汰行调用数，破除长任务 ~1007 次计数封顶；按会话提取真实业务工程根目录（`WorkspaceRoot`）并优先读取对应仓库 `.git\logs\HEAD`；扩展详情弹窗 `$panelSig` 动态指纹消除 12 条检查点冻结，固定 `× 关闭详情` 等 4 个头部按钮高度为 `28` 且垂直居中，保护非空战报摘要不被 `"记录检查点"` 覆盖，保留 7~12 位 Git 短哈希并消除 `"刚刚刚"` 叠字。
- **顶栏双组纯图标分段胶囊与多平台契约防崩**：
  - 顶栏收敛为左侧紧凑双组纯图标与一体式分段生长胶囊，支持动态添加平台分栏并与下方模型下拉框分组呼吸灯同频呼应；冷启动未连接网页前严格只展示 `默认 (跟随网页)`。
  - 隔离 OpenAI 隧道（`tunnel`）与多平台密钥（`apikey`）配置读写，加固 ACP Profile 双向校验与 `settings.json` 非破坏性合并写盘。

---

## [v1.1.0] - 2026-11-02

### 新增与增强（Added & Changed）
- **原生单步 `task_manage` 账本引擎（Spec v4.6）**：
  - 由 `:8766` 中枢直接接管 `task_manage` 的 `create`、`update`、`checkpoint`、`list`、`get`、`block`、`resume` 七类动作，支持 `pending`、`in_progress`、`completed`、`quarantined` 四种步骤状态。
  - 实现一步自动结单：当非空步骤全部进入终态（`completed` 或 `quarantined`）时，任务顶层状态自动跃迁为 `completed` 并同步关停停顿守护，无需额外的 `final_review` / `complete` 往返调用。
  - 彻底剥离冗余的 `Evolution` / `evolve` 工具与复盘考卷字段，保持 MCP 工具声明精简；免确认连跑尾注改为仅在当前任务开启自动重发时动态注入，隔离日间手动对话与夜间无人值守场景。
- **解耦式自动重发守护与严格进度熔断**：
  - 任务操作舱拆分为独立的停顿时长选择器（`停顿 30 秒 (测试)` / `停顿 3 分钟` / `停顿 5 分钟`，默认 `3 分钟`）与重试上限选择器（`重试 1 次` / `2 次` / `3 次`，默认 `1 次`）。
  - 扩展全工具在途保护门禁：不携带 `task_id` 的高频本机调用（如 `exec_command`、`read_file`、`file_edit`、`session_observe`）在执行期间同样锁定活跃卡片计时器并在完工时刷新心跳。
  - 重试计数器改为严格依据下游真实进展（步骤完成、新 Git 提交、新增本机工具调用或完整无错回复轮次）清零，防止催工消息自身引起轮次自增而误重置熔断计数。
- **三态外观主题记忆与 GPU 多分栏工作区**：
  - 新增 `跟随系统 / 浅色 / 深色` 三态主题记忆（基于 Zinc 暗色色板调校），支持顶栏 `☀/🌙` 按钮一键切换、`Ctrl+Shift+D` 全局快捷键以及右键点击主题图标恢复跟随系统。
  - 优化最多 4 分栏并列工作区的宽度自适应与 GPU 硬件加速滑动淡入过渡动画。
- **思考强度原窗免打扰与换窗快照继承**：
  - 默认采用 `inherit` 档位：在「跟随原窗口」模式下零触碰宿主当前模型与思考强度；触发「新建网页交接」时自动快照原会话的模型与思考强度并还原至新窗口。
- **本地回环网关与内置技能同步加固**：
  - `:8766` 桥接网关严格绑定本机回环地址，开局自动注入 `engine-data/AGENTS.md` 并同步 13 个工程与慢测提速技能包（[`builtin-skills/`](builtin-skills)）。

---

## [v1.0.0] - 2026-11-01

### 新增（Added）
- **双宿主并列桥接架构**：
  - 支持 **Windows ChatGPT 桌面客户端模式（`Desktop:ChatGPT`）**：通过本地回环 CDP（`127.0.0.1:9222`）直连官方客户端，穿透多抽屉容器完成草稿号转正与消息投递。
  - 支持 **Chrome / Edge 浏览器扩展模式（`browser-bridge` MV3）**：按浏览器 Profile 隔离轮询队列，支持后台标签页静默续跑与模型目录动态探测。
- **跨窗口账本交接与两段式归档**：
  - 支持携带本地 `tsk_<16hex>.json` 步骤账本与规格指针开辟新会话，并对旧会话依次执行停止生成、归档与标签页清理。
  - 提供带时间戳的任务归档、活跃自动恢复以及归档抽屉物理清理机制。
- **WPF 可视化连接与任务工作台**：
  - 集成多套 OpenAI 隧道配置与 Windows DPAPI 凭据加密存储、ACP 本地子代理并发上限调节、打包发布脚本（`scripts/build-release.ps1`）及 Python / PowerShell 离线契约回归测试集。
