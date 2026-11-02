# 原生单步账本引擎、自进化机制零残留剥离与无人值守催工隔离规格书（Spec v4.6）

Date: 2026-11-02

## Problem Statement

在日常手动对话与夜间无人值守（`implement-spec`）双场景并行的实际使用中，现有系统暴露出 6 项深层架构与状态机冲突：

1. **上游云端自进化（`Evolution` / `evolve`）与两步强制结单（`final_review` + `complete`）造成死循环**：
   - 上游编译产物内建了一套面向机器自动打分与云端经验回传的自进化系统（`Evolution`），并在 `task_manage` 中强行将结单拆为 `final_review` 与 `complete` 两步，要求模型必填 `completion_conditions`、`verified`、`risks`、`missing_checks` 与 `learning_checks` 等冗余复盘考卷字段。
   - 本项目已完全停用云端经验积累与自动进化机制，且 `implement-spec` 规范本身已包含独立双轴 `code-review` 与测试门禁。当模型把所有步骤标为 `completed`（或 `quarantined`）准备收工时，因未调用 `final_review` / `complete`，**任务卡片（Task Card）** 账本顶层状态永久卡在 `in_progress`，导致 **后台大管家（Studio Hub）** 误判模型半途停工，死循环发送 **原页催工单（In-Place Wakeup）**。
2. **日间普通聊天与夜间无人值守任务未做场景隔离**：
   - **后台大管家（Studio Hub）** 在 `tools/list` 描述及每次工具响应末尾无条件追加全局建单指令与 `_NO_CONFIRM_DIRECTIVE`（禁止向用户确认、强制连跑），导致日间普通聊天只要超过两步也被迫建单，或模型在普通探讨时不敢停下来向用户请示。
3. **高频干活工具与低频打卡工具心跳失联，触发假超时催工**：
   - 模型在每个步骤内部会高频调用 `exec_command`、`read_file`、`file_edit`、`session_observe` 等干活工具（这些工具天然不携带 `task_id` 参数），仅在跨步骤节点调用 1 次 `task_manage` 打卡。
   - **后台大管家（Studio Hub）** 与 **桌面联络员（Desktop Bridge Agent）** 的在途保护（`_collect_in_flight_task_ids`）仅统计带显式 `task_id` 的工具调用。当模型正在执行耗时数分钟的编译或长测试（`exec_command` `in_flight_count > 0`）且网页端无流式输出时，催工巡检误判该 **任务卡片（Task Card）** 为 `IDLE` 并强行插嘴催工。
4. **开启自动重发或刷新模型目录时强行拨动思考强度，且新窗交接丢失睡前思考强度**：
   - **前台遥控面板（Studio Panel）** 刷新模型列表或切换自动重发开关时，会将下拉框默认回填值误判为用户手动锁定（`user_locked_effort`）；**桌面联络员（Desktop Bridge Agent）** 在收到非空 `reasoning_effort` 时，即使处于 **跟随原窗口（Follow Window Mode）** 也会每次调用 `onModelChange` 强行拨动 **当前可见抽屉（Active Conversation Drawer）** 的思考档位。
   - 反之，若将思考强度设为 `inherit`（不改动），当夜间触发 **新建网页交接（New Window Handover Mode）** 开辟空白抽屉时，新抽屉会退回客户端出厂默认档位，丢失用户睡前在原窗口调好的思考强度。
5. **熔断计数器被自身催工消息虚假清零（熔断失效）**：
   - **后台大管家（Studio Hub）** 发送 **原页催工单（In-Place Wakeup）** 后，网页端因收到我方催工消息使 `turn_seq` 自增 1；下一轮巡检误将我方催工引起的 `turn_seq + 1` 当作模型已恢复工作，将 `retry_count` 清零，导致在模型彻底卡死时无限原页催工、无法触发熔断或升级换窗。
6. **不支持 `implement-spec` 的 `quarantined`（隔离慢测）终态判定**：
   - 当某一步因慢测试超时按 `implement-spec` 规范标记为 `quarantined` 时，现有账本校验与完工判定不识别该状态，导致包含 `quarantined` 步骤的任务永远无法自动结单。

---

## Solution

通过以下 6 项协同架构演进一次性根治上述冲突：

1. **彻底物理剥离自进化（`Evolution` / `evolve`）与两步复盘结单机制（零残留）**：
   - 在 Go 引擎源码库与 Python **后台大管家（Studio Hub）** 中彻底移除 `Evolution` / `evolve` 子系统、`final_review`、`complete` 动作及所有复盘考卷字段（`completion_conditions`、`verified`、`risks`、`missing_checks`、`learning_checks`、`guidance_context`、`evolution_candidates`、`review_revision`），在代码中不留任何兼容后门或废弃接口。
2. **后台大管家（`:8766`）100% 原生接管 `task_manage` 全生命周期与「一步到位自动结单」**：
   - 由 **后台大管家（Studio Hub）** 原生处理 `task_manage` 的全部 7 个精简动作（`create`、`update`、`checkpoint`、`list`、`get`、`block`、`resume`），直接读写本地 `engine-data/tasks/tsk_*.json` 账本，彻底绕开旧编译二进制中的死锁校验。
   - 原生支持步骤状态 `pending`、`in_progress`、`completed`、`quarantined`。只要 `update` 或 `checkpoint` 执行后，非空步骤列表中的每一步均处于终态（`completed` 或 `quarantined`），账本顶层 `status` 当场一步自动跃迁为 `completed` 并记录 `completed_at`，无需二次结单调用。
3. **日间手动聊天与夜间无人值守工单的场景隔离**：
   - 移除 `tools/list` 中强制“两步以上必须建卡”的全局提示词；仅当当前活跃 **任务卡片（Task Card）** 开启了自动重发开关（`auto_resend_enabled == True`）时，才在工具响应末尾动态注入 `_NO_CONFIRM_DIRECTIVE` 免确认连跑指令。
4. **全工具在途保护（In-Flight Gate）与无 `task_id` 干活工具心跳归集**：
   - 任何在途本机工具调用（`in_flight_count > 0`，无论是否携带 `task_id`）一律将当前活跃 **任务卡片（Task Card）** 标为 `LIVE`，在 **后台大管家（Studio Hub）** 与 **桌面联络员（Desktop Bridge Agent）** 双端刚性拦截一切催工与换窗投递；无 `task_id` 的干活工具完成后自动刷新当前唯一 `in_progress` **任务卡片（Task Card）** 的最后活跃心跳。
5. **思考强度「原窗零触碰 + 换窗快照继承」与开关解耦**：
   - 默认档位定义为 `inherit`：在 **跟随原窗口（Follow Window Mode）** 下绝不调用 `onModelChange` 触碰抽屉现有档位；在升级为 **新建网页交接（New Window Handover Mode）** 前，自动提取原 **会话房间（Conversation Room）** 的实时思考强度与模型（`WebCurrentEffort` / `WebCurrentModel`）写入 **新窗交接单（Handover Dispatch）** 快照，在新抽屉中 1:1 还原用户睡前设置；用户显式指定档位时立即按指定档位生效；切换自动重发开关或刷新模型目录绝不改动或锁定思考强度。
6. **基于下游真实执行证据的严格熔断计数（Downstream Execution Proof）**：
   - 发出 **原页催工单（In-Place Wakeup）** 时记录基准快照（`prev_cmd_cnt` 与 `prev_turn_seq`）。后续巡检仅当检测到**新的本机工具调用**（`current_cmd_cnt > prev_cmd_cnt`）或**模型完成一整轮无报错新增回复**（`current_turn_seq >= prev_turn_seq + 2` 且 `has_error == False`）时，才清零 `retry_count`；否则严格累加 `retry_count` 直至触发熔断或换窗。

---

## User Stories

1. 作为一名在日间与模型进行日常探讨的用户，我希望普通多步问答不会被强行要求创建 **任务卡片（Task Card）**，且模型在未开启自动重发时能正常停下来向我请示方案，以便日常聊天自然顺畅、不被自动化指令干扰。
2. 作为一名在睡前发起 `implement-spec` 全自动开发并开启自动重发的用户，我希望模型在开启自动重发的 **任务卡片（Task Card）** 下收到免确认连跑指令（`_NO_CONFIRM_DIRECTIVE`），按工单依赖图连续推进直至全部完成，以便夜间无人值守不中途断流。
3. 作为一名使用 `task_manage` 追踪进度的用户，我希望当模型通过 `update` 或 `checkpoint` 将所有步骤标记为 `completed`（或将慢测试步骤标记为 `quarantined`）时，**任务卡片（Task Card）** 顶层状态一步自动变为 `completed` 并立即关停自动催工，以便彻底消除因漏调 `final_review` / `complete` 引发的死循环催工。
4. 作为一名维护者，我希望系统中彻底移除无用的云端自进化（`Evolution` / `evolve`）与两步复盘考卷字段（`completion_conditions`、`verified`、`risks`、`missing_checks`、`learning_checks` 等），以便模型工具列表干净轻量、不再浪费上下文窗口填写机器打分八股文。
5. 作为一名运行耗时编译或长测试任务的用户，我希望当模型正在后台执行 `exec_command`、`read_file` 或 `file_edit` 等不带 `task_id` 的高频干活工具时，**后台大管家（Studio Hub）** 与 **桌面联络员（Desktop Bridge Agent）** 均识别该任务处于在途忙碌状态（`in_flight_count > 0`），绝不在工具尚未返回时向网页乱发催工消息。
6. 作为一名在聊天窗口中手动调好思考强度（如 `Extended` 或 `Pro`）后开启自动重发去睡觉的用户，我希望在 **跟随原窗口（Follow Window Mode）** 下系统绝不拨动我的思考强度，而在触发 **新建网页交接（New Window Handover Mode）** 开启新抽屉时自动继承原窗口睡前的思考强度与模型，以便全程保持我设定的推理质量。
7. 作为一名在 **前台遥控面板（Studio Panel）** 主动修改了某张 **任务卡片（Task Card）** 思考强度下拉框的用户，我希望系统在下一次发送消息时按我显式指定的思考强度投递，而仅仅开关“自动重发”或刷新面板时绝不误锁或篡改思考强度。
8. 作为一名依赖自动重发熔断保护的用户，我希望当原 **会话房间（Conversation Room）** 彻底卡死、每次催工后模型没有任何新的工具调用或完整回复时，熔断计数器（`retry_count`）不会被我方自己的催工消息虚假清零，而是在达到最大重试次数后准确触发换窗或熔断停机，以便防止无限刷屏催工。

---

## Implementation Decisions

### 1. 彻底移除 `Evolution` 自进化系统与两步结单机制（零残留契约）

- **工具与动作级物理剥离**：
  - 从 MCP `tools/list` 与 `tools/call` 中彻底移除 `evolve` 工具。
  - 从 `task_manage` 的动作枚举中彻底删除 `final_review` 与 `complete`，仅保留 7 个核心生命周期动作：`create`、`update`、`checkpoint`、`list`、`get`、`block`、`resume`。
  - 从 `task_manage` 的输入 Schema、响应负载与磁盘账本结构中彻底删除：`completion_conditions`、`verified`、`risks`、`missing_checks`、`learning_checks`、`guidance_context`、`evolution_candidates`、`review_revision`、`PhaseCloseout`。
- **Go 源码库与 Python 中枢双端同步**：
  - 在 Go 源码库中物理删除 `internal/evolution/` 全包、任务状态与工具层中的 `evolution` 钩子文件、HTTP `/internal/runtime/evolve` 路由及自进化架构文档。
  - 在 Python **后台大管家（Studio Hub）** 中实现 100% 原生的 `task_manage` 引擎，直接接管全部 7 个动作的校验、状态迁移与 `engine-data/tasks/tsk_*.json` 原子持久化，不再向 `:8765` 旧二进制转发任何 `task_manage` 或 `evolve` 请求。

### 2. 原生 `task_manage` 一步自动结单状态机与 `quarantined` 支持

- **合法状态集合**：
  - **任务卡片（Task Card）** 顶层状态（`status`）：`pending`、`in_progress`、`blocked`、`completed`。
  - 步骤状态（`steps[].status`）：`pending`、`in_progress`、`completed`、`quarantined`。
- **一步到位自动结单规则（One-Step Auto-Closeout）**：
  - 每当 `task_manage(action="update")` 或 `task_manage(action="checkpoint")` 更新步骤状态或追加检查点后，原生引擎立即计算步骤终态集合：
    ```python
    TERMINAL_STEP_STATUSES = {"completed", "quarantined"}
    if steps and all(s.get("status") in TERMINAL_STEP_STATUSES for s in steps):
        task["status"] = "completed"
        task["completed_at"] = now_iso
    ```
  - 一旦顶层 `status` 自动跃迁为 `"completed"`，或者所有步骤均处于 `TERMINAL_STEP_STATUSES`，`is_task_completed(task)` 立即返回 `True`，**后台大管家（Studio Hub）** 当场停止对该 **任务卡片（Task Card）** 的超时计时与催工派单。
- **防重单硬拦截保留**：
  - 当 `task_manage(action="create")` 被调用时，若当前存在未完结的同任务或交接续跑中的活跃 `tsk_*` 账本，原生引擎直接复用并返回该现有账本，防止新窗口续跑时分裂出重复 **任务卡片（Task Card）**。

### 3. 日间手动模式与夜间无人值守模式的场景隔离契约

- **`tools/list` 描述去强制化**：
  - 重写 `task_manage` 的工具描述：仅声明当用户显式下达多步工程工单、调用 `/implement-spec` / `/implement` 或要求建卡追踪时才使用 `task_manage(action="create")`，废除“凡 2 步以上操作必须强制建单”的全局霸王条款。
- **`_NO_CONFIRM_DIRECTIVE` 按卡动态门控**：
  - **后台大管家（Studio Hub）** 在 `rewrite_tools_call_response_payload` 中检查当前关联 **任务卡片（Task Card）**（或全局活跃单卡）的自动重发开关状态：
    - 仅当 `auto_resend_enabled == True` 时，才在工具返回文本末尾追加 `_NO_CONFIRM_DIRECTIVE`（要求模型禁止停下询问、遇到局部阻碍走 `quarantined` 或自行排障继续推进）；
    - 当 `auto_resend_enabled == False`（日间手动模式）时，绝不注入 `_NO_CONFIRM_DIRECTIVE`，允许模型随时停下与用户交互。

### 4. 高频干活工具在途保护（In-Flight Gate）与无单号心跳归集

- **全局与单卡双层在途保护门禁**：
  - `_collect_in_flight_task_ids` 不仅收集携带显式 `task_id` 的在途调用，还将所有未完成（`in_flight == True` 且未满 15 分钟硬超时）的无 `task_id` 工具调用（如 `exec_command`、`read_file`、`file_edit`、`session_observe`）归集到当前唯一处于 `in_progress` 的活跃 **任务卡片（Task Card）**（若无法唯一归属，则置位全局 `has_any_in_flight = True`）。
  - 在 `run_guardian_tick`（**后台大管家**）与 `DesktopAppBridge.tick`（**桌面联络员**）中增加硬门禁：只要目标 **任务卡片（Task Card）** 处于在途状态或 `in_flight_count > 0`，强制判定为 `LIVE`（`ElapsedSeconds = 0`、`IsStalled = False`），严禁压入或投递任何催工单。
- **无单号干活工具完工心跳归集**：
  - 当无 `task_id` 的本机工具调用完成并写入 `shield-activity.json` 或 `tunnel.out.log` 时，若当前存在唯一 `in_progress` 的活跃 **任务卡片（Task Card）**，其 `last_activity_at` 与 `command_count` 同步吸纳该次调用时间戳，确保步骤内部连续干活期间静默倒计时实时清零。

### 5. 思考强度「原窗零触碰 + 换窗快照继承」与 UI 开关解耦

- **三态思考强度契约（`inherit` vs 显式档位）**：
  - **任务卡片（Task Card）** 与全局配置的默认思考强度设为 `"inherit"`（界面显示为“保持原窗口设置”）。
  - **跟随原窗口（Follow Window Mode）**：当待发消息的 `reasoning_effort` 为 `""` 或 `"inherit"` 时，**桌面联络员（Desktop Bridge Agent）** 与网页插件在 `script_fill` 中**完全跳过模型与思考强度切换逻辑**（零 `onModelChange` 调用），100% 保持 **当前可见抽屉（Active Conversation Drawer）** 的现有档位；仅当用户在面板显式选定了非 `"inherit"` 档位（`user_locked_effort == True`）时，才按指定档位调用 `onModelChange`。
  - **新建网页交接（New Window Handover Mode）**：当 `run_guardian_tick` 或手动交接准备生成 **新窗交接单（Handover Dispatch）** 时，若当前卡片配置为 `"inherit"`，**后台大管家（Studio Hub）** 自动从原绑定 **会话房间（Conversation Room）** 的最近一次状态快照中提取实时 `current_effort`（`WebCurrentEffort`）与 `current_model`（`WebCurrentModel`），注入 **新窗交接单（Handover Dispatch）** 的 `reasoning_effort` 与 `model` 字段，使新开辟的空白抽屉自动继承用户睡前调好的思考强度与模型。
- **前台遥控面板（Studio Panel）事件解耦**：
  - 刷新模型目录（`Sync-StudioModelCatalog`）、切换任务卡片选中项或拨动“自动重发”开关时，使用程序内部抑制标志（`$script:SuppressModelComboEvents = $true`），严禁将组合框的数据源回填误判为用户手动修改，绝不触发 `user_locked_effort = True`。

### 6. 基于下游真实执行证据的熔断状态机（Downstream Execution Proof）

- **催工基准快照记录**：
  - 每当 `run_guardian_tick` 向某张 **任务卡片（Task Card）** 压入 **原页催工单（In-Place Wakeup）**（或收到其 `ack-deliver` **发送回执（Delivery Receipt）**）时，在 `breakers[session_key]` 中记录当时的基准快照：
    - `wakeup_baseline_cmd_cnt = session["command_count"]`
    - `wakeup_baseline_turn_seq = bound_tab["turn_seq"]`
- **严格恢复判定（清零条件）**：
  - 在 `retry_count > 0` 期间，只有满足以下任一**下游真实执行证据**时，才认定模型已恢复工作并将 `retry_count` 清零：
    1. **后厨工具证据**：`current_cmd_cnt > wakeup_baseline_cmd_cnt`（模型响应催工并发起了新的本机 MCP 工具调用）；
    2. **完整回复证据**：`current_turn_seq >= wakeup_baseline_turn_seq + 2` 且 `has_error == False` 且 `is_generating == False`（扣除我方催工消息占用的 `+1` 后，模型真实产出了一整轮无报错的新回复）。
  - 仅因我方催工消息入框导致的 `current_turn_seq == wakeup_baseline_turn_seq + 1` 绝不清零 `retry_count`；若静默再次超时，继续累加 `retry_count`，直至达到 `max_retries` 触发 **新建网页交接（New Window Handover Mode）** 或熔断停机（`tripped`）。

---

## Testing Decisions

### 1. 好测试的标准与高层可替换接缝（Replaceable Seams）

遵循 `codebase-design` 与 `/to-spec` 规范，自动化测试只验证高层公开契约边界上的输入与输出，不耦合内部私有辅助函数。本次变更直接复用项目中已验证的 **2 道高层可替换接缝（Seams）**：

- **接缝一（主接缝）：【后台大管家（Studio Hub）】HTTP & MCP 协议契约边界（`:8766`）**
  - **入口**：`POST /mcp`（`tools/list`、`tools/call`）、`GET /__studio__/snapshot`（及 `/studio/snapshot`）、`POST /__studio__/action`（及 `/studio/action`）、`POST /web-bridge/poll`、`POST /web-bridge/ack-deliver` 以及守护巡检入口 `run_guardian_tick`。
  - **验证范围**：
    1. **原生 `task_manage` 与零残留验证**：通过 `POST /mcp` 调用 `tools/list`，断言不存在 `evolve` 工具，`task_manage` 的 `action` 枚举不含 `final_review` 与 `complete`，且属性中不含 `completion_conditions`、`verified`、`risks`、`missing_checks`、`learning_checks`；调用 `task_manage(action="update" / "checkpoint")` 将步骤标为 `completed` 与 `quarantined` 混合终态，断言一步自动返回 `status == "completed"` 且 `GET /__studio__/snapshot` 中该卡片 `IsCompleted == True`、不再触发任何催工。
    2. **场景隔离验证**：当卡片 `auto_resend_enabled == False` 时调用 `POST /mcp` 工具，断言返回内容不含 `_NO_CONFIRM_DIRECTIVE`；通过 `POST /__studio__/action` 开启 `set_auto_wakeup(enabled=True)` 后再次调用工具，断言返回内容包含 `_NO_CONFIRM_DIRECTIVE`。
    3. **高频无单号工具在途保护与心跳归集验证**：模拟在途 `exec_command`（无 `task_id`，`in_flight=True`）且静默时长超过阈值，运行 `run_guardian_tick`，断言 **待发队列（Dispatch Queue）** 为空、卡片状态为 `LIVE`；模拟 `exec_command` 完成，断言当前活跃 `in_progress` **任务卡片（Task Card）** 的 `command_count` 与 `last_activity_at` 同步更新。
    4. **熔断防假清零验证**：预置 `retry_count = 1` 与基准 `wakeup_baseline_turn_seq = 10`、`wakeup_baseline_cmd_cnt = 5`；模拟网页上报 `turn_seq = 11`（仅增加了我方催工消息本身）且 `command_count = 5`，运行 `run_guardian_tick` 满静默阈值后，断言 `retry_count` 递增为 `2`（未被虚假清零），并在达到 `max_retries` 时准确升级为 `new_window_handover` 或进入 `tripped` 熔断态。

- **接缝二（次接缝）：【桌面联络员（Desktop Bridge Agent）】抽屉投递与思考强度继承契约边界（`RelayCdp.script_fill` & `DesktopAppBridge.tick`）**
  - **入口**：`RelayCdp.script_fill(prompt, mode, model, reasoning_effort)` 与 `run_guardian_tick` 生成交接单时的快照注入。
  - **验证范围**：
    1. **`follow_window` + `inherit` 零触碰**：断言当 `mode == "in_place_wakeup"` 且 `reasoning_effort in ("", "inherit")` 时，生成的注入脚本不执行任何 `onModelChange` 调用。
    2. **`new_window_handover` + `inherit` 睡前档位快照继承**：模拟原 **会话房间（Conversation Room）** 上报 `current_effort = "xhigh"`、`current_model = "gpt-5-pro"`，卡片配置为 `inherit`；触发 `new_window_handover` 时，断言生成的 **新窗交接单（Handover Dispatch）** 自动携带 `reasoning_effort == "xhigh"` 与 `model == "gpt-5-pro"`。
    3. **用户显式指定档位优先**：当通过 `POST /__studio__/action` 显式设置卡片 `reasoning_effort = "high"` 后，无论是原窗催工还是新窗交接，均按 `"high"` 投递。

### 2. 测试先例（Prior Art）

- Python 端接缝测试沿用并扩展 `tests/test_shield_hub.py`、`tests/test_spec_v42.py`、`tests/test_spec_v44.py` 与 `tests/test_spec_v45.py`（基于 `unittest` 与独立临时目录 `tempfile.TemporaryDirectory`）。
- Go 源码库测试使用标准 `go test ./...`（在清理完 `internal/evolution` 与 `PhaseCloseout` 相关测试后保持包结构与单测自洽）。

---

## Out of Scope

1. **不重新构建云端经验库或机器自动打分进化系统**：如讨论共识所确定，软件规则与技能的迭代由人工结合实际工程复盘定期维护，不在本系统中保留任何自动总结经验或云端同步机制。
2. **不改动 OpenAI 官方 `tunnel-client.exe` 闭源二进制文件**：所有 MCP 协议改写与原生 `task_manage` 引擎均在 **后台大管家（Studio Hub）**（`:8766`）完成，同时同步清理 Go 源码库以保持源码单一事实源一致。

---

## Accepted Amendments & Internal Adaptations

- **2026-11-02 零残留剥离与 `:8766` 原生引擎接管确认**：
  - 废除此前草案中“保留 `final_review` / `complete` 作为静默兼容入口”的过渡方案，改为从 Schema、代码与文档中 100% 物理删除 `final_review`、`complete` 与 `Evolution` 自进化全套字段；由于运行环境不依赖本地 Go 编译器且 `:8765` 为旧预编译二进制，由 `:8766` `McpReadOnlyShield.py` 100% 原生接管 `task_manage` 全部 7 个动作，并同步清理上游 Go 核心源码仓库。
- **2026-11-02 实施期内部适配记录**：
  1. **网页探针 `turn_seq` 会计代数对齐桌面端 `entries.length`**：为保持既有派发回执契约（`dataset.relayTurnSeq` 继续严格计作已完成且未报错的 SSE 完整回合数），`bridge-page-hook.js` 新增 `dataset.relayAcceptedPostSeq` 记录已被接收的 `/conversation` 发信计数，并由 `bridge-content.js` 的 `getTurnSeq()` 按 `completed * 2 + max(0, accepted - completed)` 导出条目级 `turn_seq`（发信未完结 `+1`、完整用户+助手往返无报错 `+2`），与桌面端 `entries.length` 完全同构。
  2. **既有旧版测试套件辐射范围同步更新**：`tests/test_shield_hub.py`、`tests/test_spec_v41.py` 与 `tests/test_spec_v42.py` 中原先断言“`task_manage(action='create')` 透传至上游 `:8765`”、“零工单时 `relaycore_context` 强弹建单提示”、“`turn_seq` 单步 `+1` 即清零 `retry_count`”的旧规格断言，已按本规格书决策 2、决策 3 与决策 6 同步更新。

---

## Further Notes

- 本规格书确认后，可衔接 `/to-tickets` 拆解执行工单或直接调用 `/implement-spec` 落地实施。
