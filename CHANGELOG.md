# 更新日志（Changelog）

本项目的重要版本演进记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，最新发行包可前往 [GitHub Releases](https://github.com/yuan88964/RelayStudio/releases/latest) 获取。

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
