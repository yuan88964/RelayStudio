# RelayStudio 深模块架构与全链路会话守护重构规格书（Spec）

> [!IMPORTANT]
> **规格书定位与执行门禁**
> 本规格书（Spec）将此前关于 `RelayStudio` 架构症结、双通道通信物理事实、以及基于 `codebase-design`（深模块与清晰接缝）重构方案的全部讨论结晶为唯一实施基准。**在用户明确批准同意实施之前，严禁修改 `d:/tool/RelayStudio/` 下的任何运行代码。**

---

## 1. Problem Statement（问题陈述：用户视角下的六大核心痛点）

在使用 `RelayStudio` 监督本地开发任务并与 ChatGPT 网页端联动守护的过程中，由于现有系统采用“散装浅模块（Shallow Modules）”设计——即将日志流水、工具调用碎片、后厨工单账本、死名单标签与网页桥接队列散落在多份本地文件中，并把“全量读日志拼凑卡片”与“自动催工保安计时”全部耦合在桌面窗口的前台单线程里——导致用户频繁遭遇以下六类严重异常：

1. **启动黑屏半分钟 & 分屏聊天时监控窗口画面冻结假死**：
   - 双击启动程序时，桌面窗口在显示（`Show()`）之前同步连续 3 次从第 1 行重读 3,000+ 行原始隧道日志，导致长达 **27 秒**桌面上看不见任何窗口。
   - 当用户把监控窗口放在屏幕一侧、鼠标点去旁边的浏览器与 ChatGPT 聊天时，监控窗口因失去鼠标焦点（`Deactivated`）直接关停刷新计时器，画面彻底冻结。
2. **删除/归档机制混乱：误删后原网页继续聊却永久“失明”，且硬盘垃圾文件从未真正清理**：
   - 现有“删除”按钮只是在配置文件里写死一个无时间戳的 `"deleted"` 黑名单标签：一方面导致用户在原网页继续发消息推进任务时，桌面端永久屏蔽该任务、无法继续监督；另一方面硬盘上的历史工单账本与活动记录文件从未被真正物理删除，越积越多。
3. **同项目多会话串台吞流 & 交接时产生孪生重复工单（如 `tsk_1928` 与 `tsk_2046` 左右互搏）**：
   - 在新网页做同一软件（如 `project_alpha`）的开发工作时，建单前的工具调用被模糊匹配强行吞并进已完工的旧卡片；同时，握手探测包中的无引号数字 ID（`"rpc_request_id":0`）因正则漏配凭空产生“1 次调用”幽灵卡片。
   - 当把同一份交接文档发给新窗口续跑时，若 GPT 误调用 `task_manage(action="create")`，底层引擎无脑新建重单 `tsk_2046`，导致 `tsk_1928` 与 `tsk_2046` 两个会话同时独立推进同一项任务、互相踩踏代码与进度。
4. **最小化或缩入托盘时，自动守护彻底失灵（只有打开窗口才扎堆补发）**：
   - 自动催工熔断器（`Step-SessionCircuitBreaker`）寄生在桌面窗口的 UI 刷新计时器内；一旦窗口最小化或隐藏至系统托盘，计时器停止运行，后台无人值守。
5. **新开网页聊别的事时，程序乱开新网页交接、抢占空白聊天页、且弄丢 ChatGPT 项目文件夹**：
   - 网页状态上报依赖标签页内的定时轮询；当原任务标签页切到后台被浏览器休眠限速超过 **6 秒**未领信时，后台擅自将「原页催工（`in_place_wakeup`）」篡改为「新开网页交接（`new_window_handover`）」，并强行抢占用户刚打开的普通空白聊天页（`https://chatgpt.com/`），或在新建窗口时丢弃原会话所属的 ChatGPT 项目文件夹前缀（`/g/g-p-...`）。
6. **同一进度连开两个雷同新窗口 & 新旧网页来回抢夺绑定权（乒乓覆盖）**：
   - 触发换桌时，本机脚本与浏览器插件两边同时点火开窗，且因新窗口未及时回绑原卡片、看不见 GPT 正在深度思考（`is_generating`），满 90 秒后误判超时又发第 2 遍雷同交接词、再开第 2 个新窗口。
   - 换到新网页 B（或手动开新网页 C、或在界面切换目标浏览器）后，只要未关闭的旧网页 A 聊天记录里还留着 `tsk_xxx` 字样，旧网页 A 每隔 2 秒上报就会把绑定权从新网页手里抢回去。

---

## 2. Solution & Global Architecture（零件级全链路调用拓扑蓝图与 16 零件对照表）

### 2.1 零件级全链路调用拓扑蓝图（含 16 个真实零件组块与 22 条带圈调用箭头 `①` ~ `⑪c`）

下图将全系统中的 **16 个真实代码组块与磁盘文件（`E1~E2`、`D1~D4`、`M1~M6`、`B1~B2`、`U1~U2`）** 以及它们之间的 **22 条真实调用关系（带圈编号 `①` ~ `⑪c`）** 完整展开，你可以顺着图上的带圈数字箭头，像看电路图一样看清每一个真实零件和每一份真实文件的来龙去脉：

> 📐 **架构拓扑参阅**：完整闭环架构与模块职责契约请参见 [`docs/architecture.md`](docs/architecture.md)。

---

### 2.2 图中 16 个真实零件组块与文件位置对照表

| 区域 | 图中节点编号 | 对应本机真实文件 / 路径 | 它在图中的核心连接点 |
| :--- | :--- | :--- | :--- |
| **⚙️ 第一区**<br/>隧道与执行引擎 | **`【组块 E1】`** | [`bin/tunnel-client.exe`](bin/tunnel-client.exe) (`:8789`) | 接云端 `①`，写日志 `①a`，转请求 `②` 给 `M1` |
| 同上 | **`【组块 E2】`** | [`bin/relaystudio-core.exe`](bin/relaystudio-core.exe) (`:8765`) | 接 `M1` 放行的 `③`，通过 `③a` 读写账本 `D2` |
| **💾 磁盘文件群**<br/>（第二区中部） | **`【文件 D1】`** | [`data/logs/tunnel.out.log`](data/logs/tunnel.out.log) | 被 `E1` 追加（`①a`），被 `M2` 增量尾读与裁剪（`④a`） |
| 同上 | **`【文件 D2】`** | `engine-data/tasks/tsk_*.json` | 被 `E2` 读写（`③a`）、`M1` 查重（`②a`）、`M2` 读详情（`④b`）、`M4` 物理粉碎（`⑦b`） |
| 同上 | **`【文件 D3】`** | [`data/task-archives.json`](data/task-archives.json) | 被 `M4` 读写 `archived_at` 归档时间戳与自动复活（`⑦a`） |
| 同上 | **`【文件 D4】`** | [`data/logs/web-bridge-state.json`](data/logs/web-bridge-state.json) | 被 `M3` 持久化绑定簿、`retired_uuids` 退役名单与发信队列（`⑥`） |
| **🏛️ 第二区**<br/>常驻中枢<br/>[`McpReadOnlyShield.py`](McpReadOnlyShield.py) | **`【组块 M1】`** | `/mcp` 入口滤网与防重单拦截函数 | 接 `E1`（`②`），查 `D2`（`②a`），放行 `E2`（`③`），推事件给 `M2`（`④`） |
| 同上 | **`【组块 M2】`** | 增量日志尾读与会话归属函数 | 读 `D1`（`④a`）、`D2`（`④b`），分发状态给 `M3/M4/M5`（`⑤a/⑤b/⑤c`）及 `M6`（`⑨a`） |
| 同上 | **`【组块 M3】`** | 房产证绑定簿与退役防回抢状态机 | 接 `M2`（`⑤a`），读写 `D4`（`⑥`），向 `M5` 供址（`⑧a`），汇总至 `M6`（`⑨a`） |
| 同上 | **`【组块 M4】`** | 两段式归档复活与物理粉碎状态机 | 接 `M2`（`⑤b`），读写 `D3`（`⑦a`），粉碎 `D2`（`⑦b`），关停 `M5` 保安（`⑧b`） |
| 同上 | **`【组块 M5】`** | 24h 独立后台保安与单飞换桌线程 | 接 `M2/M3/M4`（`⑤c/⑧a/⑧b`），把催工信与交接单压入 `M6`（`⑨b`） |
| 同上 | **`【组块 M6】`** | 内存邮局与 `<10ms` 快照 HTTP 总机 | 对接左下方插件 `B1`（`⑩a`）与右下方桌面端 `U1/U2`（`⑪a/⑪c`） |
| **🌐 第三区左翼**<br/>浏览器插件 | **`【组块 B1】`** | [`browser-bridge/background.js`](browser-bridge/background.js) | 每 2 秒通过 `⑩a` 与 `M6` 班车通信，通过 `⑩b` 调度标签页 `B2` |
| 同上 | **`【组块 B2】`** | [`browser-bridge/bridge-content.js`](browser-bridge/bridge-content.js) | 通过 `⑩b` 向 `B1` 报页面状态，并按 `B1` 点名指令向当前网页填字发送 |
| **🪟 第三区右翼**<br/>桌面工作台 | **`【组块 U1】`** | [`连接管理.ps1`](%E8%BF%9E%E6%8E%A5%E7%AE%A1%E7%90%86.ps1) | 0.5 秒开窗后，通过 `⑪a` 每 2 秒拉 `M6` 快照；点击事件 `⑪b` 交 `U2` |
| 同上 | **`【组块 U2】`** | [`ConnectionManager.psm1`](ConnectionManager.psm1) | 通过 `⑪c` 向 `M6` 发送「📦归档 / 🗑️彻底粉碎 / 🌐切浏览器」指令 |

---

## 3. Core Mechanisms & Design Intent（顺着图上的「带圈箭头（`①` ~ `⑪c`）」分专题详解机制及其背后的意图）

下面严格沿着上方大图中的**零件节点和箭头编号（`①` ~ `⑪c`）**，逐一交代每个机制是为了防止什么用户可见现象而设计的、以及它通过哪几根箭头联动来彻底避免该现象：

---

### 专题一：防重单硬拦截与同目录独立建卡（对应大图 `【组块 M1】` + `【组块 M2】`）

- **👁️ 防止什么用户可见现象？（设计意图）**
  1. **防止 `tsk_1928` 和 `tsk_2046` 变成两个重复推进同一任务的孪生会话**：当你把同样的交接文档发给新网页窗口工作时，GPT 犯傻去调新建工单命令（`task_manage(action="create")`），导致生出 `tsk_2046`，两个窗口对着同一份代码左右互搏。
  2. **防止新开网页做 `leyu` 新功能时，动作被旧卡片吞吃（看不见新卡片）**：在网页新开会话聊 `leyu` 的新内容，前几秒还没创建工单，工具调用全被已完工或已绑定其它网页的旧卡片吞进去了。
  3. **防止每次新开网页挂载连接器时，因无引号数字 `"rpc_request_id":0` 探测包凭空冒出一张“1 次调用”的幽灵卡片**。

- **⚙️ 顺着图上的箭头看它是怎么运作的（跟读箭头 `① → ② → ②a → ③ → ④ → ④a/④b`）**：
  1. **箭头 `① → ② → ②a`（网关门口查重硬拦截 + 环境亮单）**：
     - 当新窗口里的 GPT 下发工具调用（箭头 `①`），经 `【组块 E1】` 转发给 **`【组块 M1】`**（箭头 `②`）。
     - 当新窗口第一次调用 `relay_context` / `workspace_context` 时，**`【组块 M1】`** 先顺着**虚线箭头 `②a`** 查 **`【文件 D2】`（`tsk_*.json`）**，自动在返回结果里注入醒目提醒：“当前本机已有进行中的活跃工单 `tsk_1928`，若是接力续跑请直接读取（`action="get"`）或打卡（`action="checkpoint"`），严禁重复新建！”
     - 万一 GPT 还是对同一项未完工任务调用了 `task_manage(action="create")` 企图新建重单，`M1` 不会急着往右转给 `E2`，而是先顺着**虚线箭头 `②a`** 去查 **`【文件 D2】`（`tsk_*.json`）**。
     - 一旦发现 `D2` 里已经有同任务正在进行中（`status="active"`）的 `tsk_1928`（且未显式传入 `force_new=true`），**`M1` 当场扣下这次 `create` 请求（根本不走箭头 `③`，所以 `tsk_2046` 绝不会出生）**！`M1` 直接顺着**箭头 `②`** 把现有的 `tsk_1928` 账本掉包返回给 GPT，强制新窗口并轨继续使用 `tsk_1928`！
     - 只有当 `tsk_1928` 已完工（`completed`）、已归档（`archived`），或者你明确吩咐做完全不同目标的新功能课题时，`M1` 才会走**箭头 `③`** 放行给 **`【组块 E2】`**，由 `E2` 走**箭头 `③a`** 在 `D2` 里生成真正的新账本 `tsk_2046`。
  2. **箭头 `④ + ④a + ④b`（同目录新会话绝不被旧卡吞吃 + 消灭幽灵卡）**：
     - **`【组块 M2】`** 一边接收 `M1` 推来的实时工具事件（箭头 `④`），一边按字节偏移量 `byte_offset` 增量读取 **`【文件 D1】`（`tunnel.out.log`）** 的新增行（箭头 `④a`）和 **`【文件 D2】`** 的账本详情（箭头 `④b`）。
     - `M2` 兼容识别无引号数字 `rpc_request_id: 0` 与 `openai-mcp-discover` 探测包并直接过滤，彻底消灭“1 次调用幽灵卡”。
     - 当你在新网页聊 `leyu` 的前几秒还没建工单时，`M2` 检查发现旧的 `tsk_1928` 已完结或已绑定其它网页，就会**严禁旧卡片吞吃**，而是为这股无单号工具流单独生成一张临时新卡片；等几秒后新工单 `tsk_2046` 正式创建时，这张临时卡原地平滑转正为 `tsk_2046`！

---

### 专题二：房产证绑定簿与「退役防回抢锁」（对应大图 `【组块 M3】` + `【组块 B1/B2】` + `【组块 U2】`）

- **👁️ 防止什么用户可见现象？（设计意图）**
  1. **防止旧网页 A 没关时，把新网页 B 的绑定权又抢回去**：网页 A 卡死后换到了网页 B，但因为 A 的聊天记录里还写着 `tsk_1928`，导致旧网页 A 每隔 2 秒上报就把绑定权从新网页 B 手里抢回去，使催工消息又发回死掉的网页 A。
  2. **防止你手动新开网页 C 接力、或在界面下拉框切换了目标浏览器（如 Chrome 切到 Edge）后，绑定关系不更新、跨浏览器报错 404 或被旧浏览器标签页抢回**。

- **⚙️ 顺着图上的箭头看它是怎么运作的（跟读箭头 `⑩b → ⑩a → ⑤a → ⑥ → ⑧a`）**：
  1. **网页端信息怎么收上来？（箭头 `⑩b → ⑩a`）**：
     - 左下角每个网页里的 **`【组块 B2】`（`bridge-content.js`）** 采集当前页的网址 `conv_uuid`、项目夹前缀 `/g/g-p-...`、是否正在生成 `is_generating`、是否报错 `has_error`、正文里的 `tsk_xxx` 单号以及网址上的 `?msg_id` 交接令牌，通过**箭头 `⑩b`** 报给插件后台 **`【组块 B1】`**，再由 `B1` 通过**箭头 `⑩a`** 汇总进 **`【组块 M6】`**，同步给 **`【组块 M3】`（房产证绑定簿）**。
  2. **三种过户怎么在 `【组块 M3】` 里完成并锁死旧网页？（箭头 `⑤a + ⑥ + ⑧a`）**：
     - 每张卡片在 `【组块 M3】` 中维护唯一现役等价绑定：`tsk_xxx ⇔ (Browser Profile + 项目夹前缀 project_prefix + 现役网址 conv_uuid)`，并配有一份 **`retired_uuids`（已退役旧网址黑名单）**。**铁律：凡是进入 `retired_uuids` 的旧网址，只要页面处于静止态（`is_generating == false` 且无新增后厨调用），其上报的 `page_hints` 一律忽略，绝不允许抢回绑定权！**
     - **通道 ①（桥连接自动换桌过户：凭 `?msg_id` 令牌）**：系统自动新建的换桌网页 B 带着 `?relay_handover=1&msg_id=<id>` 令牌报上来，`M3` 立即把 `tsk_1928` 过户给新网址 `uuid_B`，并把旧网页 `uuid_A` 锁入 **`retired_uuids`（已退役名单）**，顺着**箭头 `⑥`** 持久化存入 **`【文件 D4】`（`web-bridge-state.json`）**。
     - **通道 ②（你手动新开网页 C 接力过户：凭「后厨实干 + 前台思考」双印证）**：当你在新网页 C（无 `msg_id` 令牌）手动粘贴交接词接力 `tsk_1928` 时，**`【组块 M2】`** 顺着**箭头 `⑤a`** 告诉 `M3`：“后厨刚收到 `tsk_1928` 的实干调用！”，同时 `M3` 看到新网页 C 正在活跃生成（`is_generating == true`，而旧网页 A 静止），立即自动将 `tsk_1928` 过户给新网页 C，并将旧网页 A 列入 `retired_uuids` 退役名单！若新网页 C 正文中同时出现旧单号与新单号，永远以 `M2` 顺着箭头 `⑤a` 报来的**最新实际发生写操作的工单号**为准。
     - **通道 ③（界面下拉切换目标浏览器过户：跨浏览器搬家）**：当你在右下角 **`【组块 U2】`** 下拉框切换目标浏览器（如从 `Chrome` 切到 `Edge`，走**箭头 `⑪c` → `M6` → `M3`**），`M3` 立即将旧浏览器网址 `uuid_A` 压入 `retired_uuids` 退役，清空现役 `conv_uuid`，锁死新浏览器 `Edge`，并通过**箭头 `⑧a`** 通知保安 `M5`：下次发信时直接在 `Edge` 中发起一次 `new_window_handover`（新建网页发送完整交接单），在 `Edge` 新网页中落户并绑定全新的 `uuid_Edge`。

---

### 专题三：两段式生命周期与「物理粉碎机」（对应大图 `【组块 M4】` + `【文件 D1~D4】` + `【组块 U2】`）

- **👁️ 防止什么用户可见现象？（设计意图）**
  1. **防止误点删除后，原网页继续发消息却再也无法在界面上监督（永久失明）**。
  2. **防止做完的历史任务越来越多，硬盘里的账本文件和日志越积越多清不掉**。

- **⚙️ 顺着图上的箭头看它是怎么运作的（跟读箭头 `⑤b → ⑦a → ⑦b → ⑧b`）**：
  1. **第一阶：带时间戳归档与自动破壳复活（箭头 `⑤b + ⑦a + ⑧b`）**：
     - 彻底废除无时间戳的 `"deleted"` 死名单状态！主列表卡片只提供清爽的「📦 归档」按钮（任务完工变为 `completed` 时也自动归档）。
     - 当你在主列表点「📦 归档」时，**`【组块 M4】`** 顺着**箭头 `⑦a`** 在 **`【文件 D3】`（`task-archives.json`）** 里记下归档时刻 `archived_at` 时间戳，卡片折叠进底部「归档抽屉」，并通过**箭头 `⑧b`** 通知 **`【组块 M5】`** 关停该卡片的催工保安。
     - **自动破壳复活定律**：如果你后来又在网页端跟这个会话发消息干活了，**`【组块 M2】`** 顺着**箭头 `⑤b`** 把最新动作时间 `last_activity_at` 传给 **`【组块 M4】`**。`M4` 发现 **`最新动作时间 last_activity_at > archived_at 归档时间`**，立即通过**箭头 `⑦a`** 将状态恢复为 `active`，让卡片**自动破壳复活弹回主列表**！
  2. **第二阶：归档抽屉物理粉碎（箭头 `⑪c → ⑦b / ④a`）**：
     - 当你在右下角 **`【组块 U2】`** 的归档抽屉里点「🗑️ 彻底物理清理」（或「一键清空已归档」，走**箭头 `⑪c`** 到中枢），**`【组块 M4】`** 顺着**粗箭头 `⑦b`** 直接把硬盘上的 **`【文件 D2】`（`engine-data/tasks/tsk_*.json`）** 物理删除，同时抹除 `D3`（`task-archives.json`）、`D4`（`web-bridge-state.json`）里的残留记录，并配合 `M2`（箭头 `④a`）把 **`【文件 D1】`（`tunnel.out.log`）** 自动滚动裁剪保持在 2,000 行以内！

---

### 专题四：24h 独立后台保安与「三级换桌单飞锁」（对应大图 `【组块 M5】` + `【组块 B1/B2】`）

- **👁️ 防止什么用户可见现象？（设计意图）**
  1. **防止窗口最小化或缩到托盘时自动守护失灵，只有打开窗口才扎堆补发**。
  2. **防止你在网页端新开会话聊别的事，程序却在 6 秒后乱开新窗口、抢占你的空白聊天页、还把 `/g/g-p-...` 项目文件夹弄丢**。
  3. **防止同一进度下连开两个一模一样的新会话、发两遍雷同提示词**。

- **⚙️ 顺着图上的箭头看它是怎么运作的（跟读箭头 `⑤c + ⑧a → ⑨b → ⑩a → ⑩b`）**：
  1. **保安常驻后台 `M5`（看图中 `【组块 M5】` 位置）**：
     - `M5` 作为独立守护线程运行在第二区常驻后台 `McpReadOnlyShield.py` 里，根本不依赖右下角的桌面窗口 `U1`。哪怕 `U1` 最小化、失焦或缩进托盘，`M5` 照样每 3 秒通过**箭头 `⑤c`** 监控所有活跃卡片的静默时长，超时立即走**箭头 `⑨b`** 发催工信。
  2. **三级渐进 + 严禁碰空白页 + 保留项目夹（箭头 `⑧a → ⑨b → ⑩a → ⑩b`）**：
     - **第一阶（默认原页催工 `in_place_wakeup`）**：彻底废除“6 秒没领信就篡改为新开窗口”的旧逻辑！日常静默超时（如 `> 3` 分钟无工具调用且 `in_flight_count == 0`、原页未报错且 `is_generating == false`），`M5` 从 `M3`（箭头 `⑧a`）拿到绑定的 `conv_uuid`，压入 `in_place_wakeup`（原页催工，箭头 `⑨b`），死死锁定原网页投递；左下角 **`【组块 B2】`** 彻底删除 `is_blank_new_chat` 抢占代码，**绝不触碰你新开的普通空白聊天页（`https://chatgpt.com/`）**。
     - **第二阶（何时才升级为 `new_window_handover` 新窗口交接？）**：只有当满足以下 3 个明确条件之一时，才升级为新窗口交接：
       1. 原网页检测到红字报错或崩溃（`has_error == true`）；
       2. 原页催工已连续送达 `MaxRetries` 次（每次间隔满 90 秒），而后厨工具计数（箭头 `⑤c` 传来的 `CommandCount`）仍无任何增长，证明原网页已彻底卡死或上下文耗尽；
       3. 你在界面上手动点击「新窗口交接」或将该卡片显式设为换窗模式。
     - **第三阶（保留 `/g/g-p-...` 项目文件夹前缀）**：当发出 `new_window_handover` 时，`M5` 自动附上从 `M3`（箭头 `⑧a`）读出的 **`/g/g-p-...` 项目夹前缀**（生成 `<project_prefix>/?relay_handover=1&msg_id=<id>`），交由 **`【组块 B1】`** 静默新建同项目夹专属标签页，确保新窗口绝不脱离你的 ChatGPT 项目文件夹！
  3. **进度指纹「单飞锁」（杜绝双开雷同页）**：
     - 移除 PowerShell 端抢先调用 `Start-Process` 开窗的重复点火逻辑，统一由 **`【组块 B1】`**（`background.js`）静默新建标签页。
     - `M5` 内部根据箭头 `⑤c` 传来的 `${session_key}|${command_count}|${completed_steps}` 生成唯一**进度指纹（Progress Fingerprint）**：**在同一进度指纹下，全局最多只准往箭头 `⑨b` 压入 1 张自动交接单**！
     - 新窗口一旦打开即凭 `?msg_id` 通过箭头 `⑩b → ⑩a` 回绑原卡片；且只要绑定网页报回“正在思考（`is_generating == true`）”，`M5` 立即暂停 90 秒超时重试倒计时，绝不在 GPT 思考期间发出第 2 张雷同交接单！

---

### 专题五：内存邮局与「浏览器 2 秒聚合班车」（对应大图 `【组块 M6】` + `【组块 B1/B2】`）

- **👁️ 防止什么用户可见现象？（设计意图）**
  1. **防止多开几个网页标签页后，频繁读写硬盘文件导致电脑和界面卡顿**。
  2. **防止多个浏览器（Chrome + Edge）、多个会话同时触发自动守护时，发消息互相挤占、串台或抢走鼠标焦点**。

- **⚙️ 顺着图上的箭头看它是怎么运作的（跟读箭头 `⑨a/⑨b → M6 ↔ ⑩a ↔ ⑩b`）**：
  1. **内存级 `<1ms` 邮局（看 `【组块 M6】` 与箭头 `⑩a`）**：
     - `M2/M3/M4/M5` 的最新状态随时通过**箭头 `⑨a / ⑨b`** 汇总在 **`【组块 M6】`** 的内存字典里（仅在绑定或队列变更时异步落盘至 `D4`）。
     - 左下角每个浏览器的 **`【组块 B1】`（`background.js`）** 每 2 秒只走一次**箭头 `⑩a`**（**1 个浏览器 1 辆聚合班车心跳**，且扩展后台不受标签页切后台休眠限速影响），一次性上报该浏览器内所有 ChatGPT 标签页状态，并按**「本浏览器 Profile + `conv_uuid` 专属邮筒」**把属于自己的催工信领走，全程内存操作耗时 `<1ms`，零磁盘卡顿。
  2. **跨浏览器并行、同浏览器错峰 1 秒静默填字（箭头 `⑩b`）**：
     - Chrome 的 `B1` 和 Edge 的 `B1` 各自领信，完全并行、互不干扰；
     - 同一个浏览器内若有两个标签页同时有信，**`【组块 B1】`** 通过**箭头 `⑩b`** 排队调度：先让标签页 1 的 `B2` 在后台填字发送，隔 **1 秒**再让标签页 2 的 `B2` 在后台填字发送，全程后台静默操作网页 DOM，绝不激活窗口、绝不抢夺你的鼠标键盘焦点！

---

### 专题六：0.5 秒秒开窗口与分屏常亮刷新（对应大图 `【组块 U1/U2】` + `【组块 M2/M6】`）

- **👁️ 防止什么用户可见现象？（设计意图）**
  1. **防止双击打开程序后，整整 27 秒黑屏不显示窗口**。
  2. **防止一边在 Chrome 跟 GPT 聊天、一边在旁边看监控窗口时，监控窗口因为失去鼠标焦点而画面冻结假死**。

- **⚙️ 顺着图上的箭头看它是怎么运作的（跟读箭头 `④a → ⑨a → ⑪a → ⑪b → ⑪c`）**：
  1. **告别 27 秒黑屏（看右下角 `【组块 U1/U2】` 与箭头 `⑪a`）**：
     - 以前是 **`【组块 U1/U2】`** 自己跨过半张图去全量连读 3 遍 `【文件 D1】`（3,000 行日志）；现在请看大图：**`U1/U2` 与上面的磁盘文件 `D1~D4` 之间已经没有任何直接连线了！**
     - 读日志的活全由后台 **`【组块 M2】`** 走**箭头 `④a`** 增量完成，组装好的现成卡片随时准备在 **`【组块 M6】`** 内存里。
     - 双击启动时，**`【组块 U1】`（`连接管理.ps1`）** 第一步先执行 `Show()` 把窗口骨架画出来（**0.5 秒立即现身**），第二步才走**箭头 `⑪a`**（`GET /studio/snapshot`）用不到 10 毫秒把现成卡片贴上屏幕！
  2. **分屏聊天不断更（箭头 `⑪a` 常亮）**：
     - 移除 `连接管理.ps1` 中失去焦点（`Deactivated`）即关停刷新计时器的逻辑。
     - 只要 **`【组块 U1】`** 窗口在屏幕上可见（未最小化、未藏入托盘），哪怕你的鼠标点在旁边的 Chrome 窗口里聊天（`U1` 失焦），`U1` 依然每 2 秒走一次**箭头 `⑪a`** 拉取 `<10ms` 的现成快照，让你边聊边看实时进度！

---

## 4. User Stories（用户故事与验收全景清单）

1. **【极速启动】** 作为用户，我希望双击打开 `RelayStudio.exe` 时窗口在 **1 秒以内**立即显示在屏幕上，以便我不再误以为程序没点开或死机。
2. **【分屏常亮】** 作为用户，我希望当我将监控窗口放在屏幕左侧、鼠标点击右侧浏览器与 ChatGPT 聊天时，左侧监控窗口依然每 2 秒实时刷新工具调用计数与步骤进度，以便我能边聊边监督进度。
3. **【托盘全天候守护】** 作为用户，我希望当我将 `RelayStudio` 最小化或关闭到右下角系统托盘时，后台自动催工与换桌守护依然按设定的静默分钟数准时向网页发送消息，以便我不需要把窗口一直打开在桌面上才能自动续跑。
4. **【空白页免打扰】** 作为用户，我希望当我在浏览器中新开一个普通空白 ChatGPT 页面（`https://chatgpt.com/`）准备聊其它话题时，程序绝不劫持我的空白页面去填充旧任务的交接提示词，以便我可以正常开启新对话。
5. **【后台休眠不乱开窗】** 作为用户，我希望当原任务网页退到浏览器后台超过 6 秒时，只要该卡片处于“原页催工”阶段，程序依然将催工消息精准投递给原任务网页，而不会因为 6 秒超时就擅自弹出一个新网页窗口。
6. **【保留项目文件夹前缀】** 作为用户，我希望当我在 ChatGPT 项目文件夹（网址形如 `https://chatgpt.com/g/g-p-xxx/c/uuid`）内运行任务并触发“新窗口交接”时，新开出的交接网页自动继承 `/g/g-p-xxx` 项目文件夹前缀，以便新窗口不会脱离我的项目文件夹、不会丢失项目预设指令。
7. **【三级渐进换桌】** 作为用户，我希望程序默认优先在原网页发送“继续”催工，只有当原网页出现红字报错（`has_error`）、或原页连续催工达到重试上限后厨仍无任何新工具响应、或我手动点击换窗时，才自动新建网页窗口发送完整交接单，以便兼顾日常轻量催工与长会话卡死后的自动换桌。
8. **【严防双开雷同窗口】** 作为用户，我希望在同一个任务进度下，系统全局最多只打开 **1 个**新交接窗口，并且在新窗口中 ChatGPT 正在思考（`is_generating`）期间自动暂停超时计时，以便彻底杜绝“同一进度连开两个新会话、发送两遍雷同提示词”的异常。
9. **【防重单硬拦截（`1928` vs `2046`）】** 作为用户，我希望当我把同一份交接文档发给新网页窗口续跑未完结任务 `tsk_1928` 时，哪怕 GPT 误调用了 `task_manage(action="create")` 企图新建重单，本机网关也会当场拦截并直接将现有 `tsk_1928` 账本返回给 GPT，以便不会产生 `tsk_1928` 与 `tsk_2046` 两个独立推进同一项任务的重复卡片。
10. **【同项目新课题独立成卡】** 作为用户，我希望当我在新网页中围绕同一个代码仓（如 `project_alpha`）开启另一项全新的开发工作时，哪怕前几秒尚未创建新 `tsk_` 工单，其工具调用也会先生成一张独立的实时卡片（并在随后建单时转正为 `tsk_2046`），而不会被已完工或已绑定其它网页的旧卡片 `tsk_1928` 吞吃。
11. **【消灭幽灵卡】** 作为用户，我希望当我在网页端新开聊天并触发云端 `tools/list` 探测（含无引号 `"rpc_request_id":0`）时，监控列表不会凭空冒出一张“累计 1 次调用”的幽灵卡片。
12. **【自动换桌后防旧页回抢】** 作为用户，我希望当任务 `tsk_1928` 从旧网页 A 交接到新网页 B 后，哪怕我没有关闭旧网页 A 的浏览器标签页，旧网页 A 的后台心跳也绝不会把 `tsk_1928` 的绑定权从新网页 B 手里抢回去。
13. **【手动开新页接力自动认亲】** 作为用户，我希望当我自己手动在浏览器新开一个网页 C 并让 GPT 继续执行 `tsk_1928` 时，一旦后厨收到 `tsk_1928` 的新调用且网页 C 正在活跃生成回复，系统会自动把 `tsk_1928` 的绑定网页过户给网页 C，并将静止的旧网页 A 列入退役名单。
14. **【跨浏览器切换自动搬家】** 作为用户，我希望当我在卡片详情中将目标浏览器从 `Chrome` 切换到 `Edge` 时，系统立即解除与原 `Chrome` 网页的绑定，并在下次发信时自动在 `Edge` 浏览器中新建网页发送完整交接指令，以便无缝将任务搬家到另一个浏览器的账号中继续运行。
15. **【两段式归档与自动破壳复活】** 作为用户，我希望点击卡片上的「📦 归档」按钮将卡片移入归档抽屉后，如果我随后又在对应的网页会话中继续发消息触发了新的本机工具调用，该卡片能**自动破壳复活弹回主监控列表**，以便我不会因为误归档/误删而失去对活跃会话的监督。
16. **【归档抽屉真物理粉碎】** 作为用户，我希望在归档抽屉中点击「🗑️ 彻底清理」（或「一键清空已归档」）时，系统真正物理删除硬盘上的 `engine-data/tasks/tsk_*.json` 账本文件、清除状态文件中的历史记录、并自动滚动裁剪隧道日志，以便真正释放本地磁盘空间、不留历史垃圾。
17. **【多浏览器多会话并发不抢焦点】** 作为用户，我希望当我在 Chrome 和 Edge 中同时开启多个会话并启用自动守护时，各浏览器的催工消息通过各自的后台聚合班车独立并行领取、同浏览器内多标签页按 1 秒间隔错峰在后台静默填字发送，以便不会造成信息挤占、串台或抢走我当前正在使用的鼠标键盘焦点。

---

## 5. Implementation Decisions & Seams（架构接缝与关键实施契约）

### 5.1 全系统仅保留两道高层接缝（Seams）

根据 `codebase-design` 与 `/to-spec` 规范，我们将散乱的跨文件耦合收拢为 **2 道清晰的 HTTP JSON 契约接缝**（也是自动化测试的直接切面）：

#### 🔗 接缝一（Seam 1）：本机中枢 `M6` ↔ 桌面工作台 `U1/U2` 快照与动作契约（箭头 `⑪a` / `⑪c`）
- **`GET /studio/snapshot`（箭头 `⑪a`）**：
  - 由 `【组块 M6】` 从内存直接返回组装完毕的监控快照，响应时间 `< 10ms`。
  - 返回结构包含：
    - `active_sessions`: 主监控列表现成卡片数组（已按活跃度排序，含 `session_key`、`title`、`goal`、`status`、`progress_percent`、`step_count_text`、`steps`、`readable_checkpoints`、`recent_commits`、`command_count`、`recent_minute_count`、`in_flight_count`、`is_stalled`、`bound_browser`、`bound_conv_uuid`、`bound_project_prefix`、`breaker_state`）；
    - `archived_sessions`: 归档抽屉卡片数组（含 `archived_at` 时间戳与归档原因）；
    - `tunnel_pulse`: 隧道整体健康度、近 1 分钟总火力值、最后 `tools/list` 同步时间。
- **`POST /studio/action`（箭头 `⑪c`）**：
  - 接收桌面端 `【组块 U2】` 发起的状态变更指令（原子修改内存并落盘后返回最新状态）：
    - `action = "archive"`：由 `M4` 记录 `archived_at = now_utc`，移入归档抽屉并关停该卡在 `M5` 中的保安；
    - `action = "restore"`：从归档抽屉手动恢复至主列表；
    - `action = "purge"` / `"purge_all_archived"`：由 `M4` **物理粉碎**指定或全部已归档会话（走箭头 `⑦b` 删除 `tsk_*.json`、抹除 `D3/D4` 对应记录、触发 `D1` 滚动裁剪）；
    - `action = "bind_browser"`：由 `M3` 切换目标浏览器 Profile（如 `Chrome:Profile 1` → `Edge:Profile 1`），将原 `conv_uuid` 压入 `retired_uuids`，锁定新浏览器；
    - `action = "set_auto_wakeup"` / `"update_resend_config"`：开启/关闭单卡或全局自动守护，配置静默分钟数与最大重试次数；
    - `action = "enqueue_message"`：手动触发原页唤醒、新窗口交接或自定义消息投递。

#### 🔗 接缝二（Seam 2）：本机中枢 `M6` ↔ 浏览器插件后台 `B1` 聚合班车契约（箭头 `⑩a`）
- **`POST /web-bridge/poll`（支持单浏览器批量标签页聚合上报与分桶领信）**：
  - **请求负载（由 `background.js` 每 2 秒发送 1 次）**：
    ```json
    {
      "browser_profile": "Chrome:Profile 1",
      "browser": "Chrome",
      "tabs": [
        {
          "tab_id": "124",
          "url": "https://chatgpt.com/g/g-p-6789abcd/c/69dc9a33-63a8-8324-9328-d6f9687c76d5",
          "project_prefix": "https://chatgpt.com/g/g-p-6789abcd",
          "conv_uuid": "69dc9a33-63a8-8324-9328-d6f9687c76d5",
          "handover_msg_id": "msg_1730150000123",
          "title": "ProjectAlpha C4 三层重构",
          "is_generating": false,
          "has_error": false,
          "error_text": "",
          "page_hints": ["tsk_19283093310b828b"]
        }
      ],
      "ack_msg_ids": ["msg_1730150000100"]
    }
    ```
    *（向下兼容旧版单 `tab_id` 顶层字段格式，确保平滑过渡）*
  - **响应负载（按请求方 `browser_profile` 专属分桶返回）**：
    ```json
    {
      "ok": true,
      "dispatches": [
        {
          "id": "msg_1730150000123",
          "session_key": "tsk_19283093310b828b",
          "mode": "in_place_wakeup",
          "target_tab_id": "124",
          "target_conv_uuid": "69dc9a33-63a8-8324-9328-d6f9687c76d5",
          "open_url": "",
          "prompt": "继续"
        }
      ],
      "focus_tab_id": ""
    }
    ```

### 5.2 核心状态机与持久化数据结构（对应 `【文件 D3】` 与 `【文件 D4】`）

1. **`【文件 D3】` `task-archives.json` 结构升级（向后兼容旧版字符串值）**：
   ```json
   {
     "schema_version": 2,
     "overrides": {
       "tsk_19283093310b828b": {
         "state": "active",
         "updated_at": "2026-10-29T01:30:00Z"
       },
       "tsk_ae47c52fc0733cbe": {
         "state": "archived",
         "archived_at": "2026-10-28T15:30:00Z",
         "reason": "completed"
       }
     }
   }
   ```
   - **自动破壳复活判定**：当某个会话处于 `state == "archived"`，若 `M2` 检测到该会话产生了新的工具调用或账本事件，且 `last_activity_at > archived_at`，则 `M4` 自动将其 `state` 切换为 `"active"`。
2. **`【文件 D4】` `session_bindings` 房产证绑定结构（含 `project_prefix` 与 `retired_uuids`）**：
   ```json
   {
     "conv_uuid": "69dc9a33-63a8-8324-9328-d6f9687c76d5",
     "project_prefix": "https://chatgpt.com/g/g-p-6789abcd",
     "tab_id": "124",
     "title": "ProjectAlpha C4 三层重构",
     "browser_profile": "Chrome:Profile 1",
     "target_mode": "auto",
     "retired_uuids": ["69dc5f82-d7f4-8321-8353-1635f7842fa1"],
     "updated_at": "2026-10-29T01:30:00Z"
   }
   ```
3. **Windows PowerShell 5.1 编码铁律**：
   - 所有 `.ps1` 与 `.psm1` 脚本文件在保存时必须使用 **UTF-8 with BOM（`[Text.UTF8Encoding]::new($true)`）**，防止宿主 `RelayStudio.exe`（基于 Windows PowerShell 5.1 Runspace）因无 BOM 按 GBK 解码中文标点导致语法解析崩溃。

---

## 6. Testing Decisions（测试决策与高层接缝验证）

1. **好测试的标准（只测接缝契约与用户可感知结果，不绑死内部私有实现）**：
   - 所有自动化测试统一通过 **接缝一（`/studio/snapshot`、`/studio/action`）**、**接缝二（`/web-bridge/poll`）** 和 **`/mcp` 代理入口** 注入输入并断言输出状态，不直接耦合内部私有辅助函数名。
2. **被测核心模块与必测场景（100% 覆盖本次全部痛点）**：
   - **场景 T1（防重单硬拦截测试，验证箭头 `② → ②a`）**：在测试目录下预置活跃工单 `tsk_1928`，向 `/mcp` 发送针对同一任务的 `task_manage(action="create")` 请求 → 断言 `M1` 直接拦截并返回 `tsk_1928` 账本，磁盘 `D2` 上未生成第二个 `tsk_*.json` 文件。
   - **场景 T2（无引号整数 `0` 过滤与同目录独立建卡测试，验证箭头 `④a / ④b`）**：向 `tunnel.out.log` 写入 `"rpc_request_id":0` 探测行与无单号 `project_alpha` 工具调用（此时旧 `tsk_1928` 已完工或已绑旧网页）→ 断言 `/studio/snapshot` 不产生“1 次调用幽灵卡”，且为新流独立生成实时卡片而不被旧卡片吞并。
   - **场景 T3（房产证过户与 `retired_uuids` 防回抢测试，验证箭头 `⑩a → ⑤a → ⑥`）**：初始绑定网页 `uuid_A` → 模拟通过 `?msg_id` 交接或手动活跃新网页 `uuid_B` 过户 → 随后让静止的旧网页 `uuid_A` 再次上报 `page_hints: ["tsk_1928"]` → 断言绑定依然保持为 `uuid_B`，绝不被 `uuid_A` 抢回。
   - **场景 T4（跨浏览器切换搬家测试，验证箭头 `⑪c → ⑧a → ⑨b`）**：调用 `/studio/action (bind_browser="Edge:Profile 1")` → 断言原 `Chrome` 的 `uuid_A` 进入 `retired_uuids`，且随后触发催工时生成面向 `Edge:Profile 1` 的 `new_window_handover` 交接单。
   - **场景 T5（两段式归档、自动破壳复活与物理粉碎 Purge 测试，验证箭头 `⑤b → ⑦a → ⑦b`）**：
     - 调用 `archive` 归档 `tsk_1928` → 断言移入 `archived_sessions` 且记录 `archived_at`；
     - 模拟晚于 `archived_at` 的新工具调用 → 断言 `tsk_1928` 自动复活回到 `active_sessions`；
     - 再次归档后调用 `purge` → 断言 `tsk_1928.json` 被物理删除，`task-archives.json` 与 `web-bridge-state.json` 中无残留。
   - **场景 T6（三级渐进守护、保留项目夹前缀、不抢空白页、单飞防双开测试，验证箭头 `⑤c + ⑧a → ⑨b → ⑩a`）**：
     - 模拟 `in_place_wakeup` 超时 `> 10` 秒未领信 → 断言模式保持 `in_place_wakeup`（绝不自动篡改为 `new_window_handover`），且普通空白页 `https://chatgpt.com/` 上报时 `dispatches` 为空（绝不劫持空白页）；
     - 模拟原网页报错 `has_error=true`（原网址含 `/g/g-p-xxx/c/uuid_A`）→ 断言升级为 `new_window_handover`，且 `open_url` 完整保留 `https://chatgpt.com/g/g-p-xxx/?relay_handover=1...`；
     - 在同一进度指纹下连续运行守护巡检，或模拟新窗口 `is_generating=true` 思考满 120 秒 → 断言全局仅生成 **1 条**交接单，绝不发出第 2 条雷同交接单。
   - **场景 T7（增量尾读性能与启动耗时测试，验证箭头 `④a → ⑨a → ⑪a`）**：预置 3,500 行 `tunnel.out.log` → 断言增量尾读与 `/studio/snapshot` 响应时间 `< 50ms`。
3. **测试先例（Prior Art）**：
   - 沿用并扩展现有的 [`tests/Test-ConnectionManager.ps1`](tests/Test-ConnectionManager.ps1) 隔离测试套件（使用独立临时目录 `$testRoot` 进行端到端契约断言，绝不污染本机正在运行的真实数据）。

---

## 7. Out of Scope（范围外事项）

1. **不重新编译底层闭源/上游二进制文件**：[`bin/tunnel-client.exe`](bin/tunnel-client.exe)（OpenAI 官方隧道客户端）与 [`bin/relaystudio-core.exe`](bin/relaystudio-core.exe)（上游 Go 编译产物）保持原样，所有增强与拦截均在 [`McpReadOnlyShield.py`](McpReadOnlyShield.py)、浏览器扩展与 PowerShell 工作台层完成。
2. **不改动 ChatGPT 云端容器内部机制**：OpenAI 云端隧道协议本身不传递浏览器 Tab ID 的物理事实属于外部既定约束，通过本规格书中的本地中枢双向对齐状态机解决。

---

## 8. Accepted Amendments & Internal Adaptations（修订与内部适配账本）

- **2026-10-29 架构图与机制详解版本锁定**：按用户要求，Spec 中的全局架构图固定采用含 16 个真实零件与 22 条带圈调用箭头的完整拓扑图（参见 [`docs/architecture.md`](docs/architecture.md)），配套的 16 零件对照表与六大专题机制说明均完整采用顺着带圈箭头（`①` ~ `⑪c`）展开的详尽版本，不使用缩略改写版。
- **2026-10-29 全系统穿透式排查与防假接缝整改规格书（Spec v2.0 批准生效）**：
  1. **【整改 R1】统一 `web-bridge-state.json` 唯一 Schema**：全系统（Python `:8766` 与 PowerShell 离线沙箱）统一使用 `queue`（同步含 `prompt` 与 `text` 字段，兼容迁移旧 `outbox`）、`breakers`（复数，兼容清理旧 `breaker`）、`auto_resend_config`（彻底废除对不存在的 `data/auto-resend.json` 的读取，Python `run_guardian_tick` 严格遵守 `auto_resend_config.enabled` 与 `breakers[key].auto_enabled` 开关）、`session_bindings`（完整保留 `browser`, `browser_profile`, `project_prefix`, `retired_uuids` 等 9 个字段）与 `tabs`。
  2. **【整改 R2】切除桌面端刷新循环中的第二大脑，打通 `:8766` 真接缝（`⑪a` & `⑪c`）**：
     - 彻底移除 `ConnectionManager.psm1` 的 `Get-TunnelActivityPulse` 中对 `Step-SessionCircuitBreaker` 的调用（调用次数必须为 `0`），并禁止非隔离模式下 UI 刷新循环截断重写 `tunnel.out.log` 或写盘修改 `web-bridge-state.json`。
     - 新增 `Invoke-StudioHubSnapshot`（调用 `GET :8766/studio/snapshot`）与 `Invoke-StudioHubAction`（调用 `POST :8766/studio/action`），在 `:8766` 在线时由 `Get-TunnelActivityPulse`、归档/还原/粉碎、发送消息、切换自动重发开关、修改重发配置、绑定浏览器配置、打开会话网页等入口真实调用（仅在 `-Isolated` 沙箱或 `:8766` 离线时回退本地逻辑）。
     - `POST /studio/action` 完整支持 10 类动作：`archive`, `restore`, `purge`, `purge_all_archived`, `bind_session`, `bind_browser`, `set_auto_wakeup`, `update_resend_config`, `enqueue_message`, `open_tab`。
  3. **【整改 R3】识别 36 位纯 UUID `cmd_request_id` 主工作流 + 四源活跃时间与 `in_flight` 免停顿保护 + 废除孤儿工单硬编码假停顿**：
     - 将不带斜杠的 36 位纯 UUID `cmd_request_id`（`^[0-9a-fA-F-]{36}$`，且 `rpc_request_id != "0"`）与 `wfr_*` 同等识别为一级主工作流，并通过 `shield-activity.json` 的 `rpc_id` 自动继承关联 `task_id`。
     - 会话与工单的最后活跃时间取 `tunnel.out.log`、`shield-activity.json`（含 `started_at`/`completed_at`）、`tsk_*.json` `updated_at` 与最新 `checkpoint.at` 四者的最大值；当存在 `<15min` 的 `in_flight: true` 调用时，`ElapsedSeconds = 0` 且 `IsStalled = false`。
     - 废除孤儿工单分支无条件硬编码 `IsStalled = $true` / `'● 已停顿3分钟，请检查网页端'` / `CommandCount = 0` 的缺陷；未满停顿阈值（默认 3 分钟）时严禁报停顿。
  4. **【整改 R4】浏览器插件单通道轮询、15s 僵尸标签清理、多标签 `is_generating` 取 OR 与 `claimed -> ack-deliver` 两阶段防丢信确认锁**：
     - `bridge-content.js` 仅向 `background.js` 汇报状态并响应 `RELAY_EXECUTE_DISPATCH`（填词成功后返回 `{ ok: true, delivered: true }` 并清除 `stickyHandoverMsgId`），仅在 `chrome.runtime.lastError` 无 Service Worker 时降级直连。
     - `background.js` 在 `tabStateCache` 未命中时标记 `state_known: false`，防止服务端 `is_generating`/`page_hints` 被空缓存的 `false` 覆盖；服务端自动清理 `>15s` 未上报的过期标签，且对同一 `conv_uuid` 的所有鲜活标签页的 `is_generating` 取逻辑 `OR`。
     - 待发消息被 `/web-bridge/poll` 领走时先标为 `claimed`（12 秒超时未确认自动回退 `pending`），待 `bridge-content.js` 实际填词发送成功后由 `background.js` 调用 `POST /web-bridge/ack-deliver` 正式标为 `delivered`。
     - 移除 `background.js` 与 `bridge-content.js` 中硬编码的 `"Profile 1"`。
  5. **【整改 R5 & R6】`ConvertTo-ReadableMilestone` 顺序与全格式前缀修复 + `/studio/snapshot` 43 字段 `StrictMode` 契约补齐**：
     - 先拆分 `||`（不提前 `return`），再剥离 `[a-zA-Z0-9_-]+=(?:in_progress|completed|pending|done|blocked|failed):`、`completed=[...], current=...:`、`pass:` 等全格式步骤前缀；`Checkpoints` 与 `Milestones`/`ReadableCheckpoints` 统一按最新在前（Newest-First）排列。
     - `build_studio_snapshot` 补齐 `连接管理.ps1` 在 `Set-StrictMode -Version Latest` 下读取的全部 43 个 Session 属性。
  6. **【强制门禁】三大防假接缝门禁（`T8 ~ T12` + 静态排他检查）**：
     - 静态断言：`Get-TunnelActivityPulse` 内 `Step-SessionCircuitBreaker` 调用数为 `0`；`Invoke-StudioHubSnapshot` 与 `Invoke-StudioHubAction` 被真实调用；`background.js`/`bridge-content.js` 无硬编码 `"Profile 1"`；存在 `/web-bridge/ack-deliver` 闭环；PowerShell 文件保持 UTF-8 BOM 且无 `\r\r\n`。
     - 真实数据回放与跨进程联调测试：`T8`（纯 UUID 隧道日志与 `C4` 工单回放）、`T9`（6 类真实检查点前缀与 `||` 清洗）、`T10`（跨进程关闭自动重发开关与 UI 发信入队送达闭环）、`T11`（僵尸标签遮蔽防御与 `claimed -> ack-deliver` 两阶段防丢信）、`T12`（`Set-StrictMode` 43 属性全量无异常验证）。
- **2026-10-31 领域模型与双端抽屉/排队交接加固规格书（Spec v4.4 批准生效）**：
  - 完整领域术语表见 [`GLOSSARY.md`](GLOSSARY.md)，核心架构决策见 [`ADR-0001`](docs/adr/0001-two-phase-binding-transfer-and-batch-follow-queueing.md) 与 [`ADR-0002`](docs/adr/0002-desktop-active-drawer-resolution-and-interactive-windowstation.md)，详细规格见 [`.scratch/specs/2026-10-31-desktop-drawer-and-handover-queue-spec.md`](.scratch/specs/2026-10-31-desktop-drawer-and-handover-queue-spec.md)。
  1. **【发射台防闪退与可见交互桌面启动】**：新建任务发射台打开网页按钮改用安全分栏变量名并加异常保护，消除覆盖只读 `$PID` 引起的连带托盘闪退；进程启动器废弃 WMI `Win32_Process.Create`，改在用户可见交互桌面（`WinSta0\Default`）中无黑框启动后台大管家与桌面端，并严格区分手动前台唤醒与无人值守静默投递。
  2. **【桌面联络员当前可见抽屉精准认领与正式房间号回执】**：`RelayCdp.py` 的 `isHiddenNode` 要求几何尺寸大于 `0×0` 且向上排查全部祖先节点的 `display: none` / `visibility: hidden`；`findCloudCtx` 仅排除 `isWorkConversation === true` 的编程抽屉（忽略第 89 层迷你悬浮条收起标记 `isHidden: true`），并优先提取第 119 层的 36 位正式云端房间号 `scrollStateConversationId`。
  3. **【两阶段回执确认过户、双常驻档位独立与同批次排队跟随】**：「跟随原窗口」与「新建网页交接」均作为按任务独立保存的常驻档位（修改单任务档位绝不污染全局默认配置）；收到包含 36 位正式房间号的发送回执后立即完成房产证过户与旧房间退役；在「新建网页交接」档位下连续发送多条消息时实行**同批次排队跟随**（第 1 顺位作为排头兵开辟新会话房间并过户，同一批次后续用户消息排入队尾并自动跟随该新会话房间依次投递，绝不覆盖作废前序用户消息）。
  4. **【网页探针精准停稳判定与停稳即放行】**：`bridge-content.js` 的 `isGeneratingState()` 仅检查当前可见聊天表单内部真实可见的 `stop-button`；当原会话房间停稳（`sse_active == false` 且 `is_generating == false`）或原标签页已关闭时，中枢立即解除 `defer_until_stopped` 等待锁放行交接。
- **2026-10-31 桌面端多抽屉文件柜全量转正、空白抽屉去污与商店容器通行证保活规格书（Spec v4.5 草案待确认）**：
  - 核心架构决策见 [`ADR-0003`](docs/adr/0003-desktop-cabinet-draft-promotion-and-package-identity-launch.md)，详细规格见 [`.scratch/specs/2026-10-31-desktop-cabinet-binding-and-lifecycle-spec.md`](.scratch/specs/2026-10-31-desktop-cabinet-binding-and-lifecycle-spec.md)。
  1. **【拒收 `local-chatgpt:` 临时排队号 + 多抽屉文件柜全量扫描转正】**：`RelayCdp.py` 严格过滤 `local-chatgpt:` 临时排队号（仅记为 `draft_id`，绝不混入正式 `conv_uuid`），并在每次巡检时扫描多抽屉文件柜内的全部抽屉（含 `0×0` 后台隐身抽屉），提取 `{draft_id, conv_uuid, task_hints}` 映射表；后台大管家据此跨 60 秒、跨后台抽屉精准完成房产证过户（并自动修复已误绑临时号的存量任务），确保点击「打开网页 ↗」100% 跳入真正的目标对话（如《比较战斗力大小规律》）。
  2. **【桌面端空白抽屉判定去污（根治 `new_chat_not_ready`）】**：在 `app:` 桌面端下，`script_state()` 禁止回退读取根节点残留的 `dataset.relayActiveConvUuid`，并在点击“新聊天”时主动清除该残留属性，使新建网页交接在 0.1 秒内确认空白抽屉就绪。
  3. **【商店容器通行证启动与带端口进程免杀保活】**：借鉴 `Cockpit Tools` 采用 `Invoke-CommandInDesktopPackage`（配 `-PreventBreakaway` 与 `CODEX_ELECTRON_START_IN_BACKGROUND=1`）启动桌面端；只要运行中的 `ChatGPT.exe` 命令行已含 `--remote-debugging-port=`，永远判定 `has_debug_port = True`，严禁因一时繁忙超时而关停重启桌面端。
  4. **【网页探针 `document_start` 安检退避（防 Cloudflare 拦截）】**：移除 `bridge-page-hook.js` 在 `document_start` 阶段的主动 `/api/auth/session` 与 `/backend-api/models` 请求，改为被动拦截或待聊天输入框挂载后再同步。
- **2026-11-02 原生单步账本引擎、自进化机制零残留剥离与无人值守催工隔离规格书（Spec v4.6 批准生效）**：
  - 详细规格见 [`docs/specs/2026-11-02-native-task-manage-and-guardian-isolation-spec.md`](docs/specs/2026-11-02-native-task-manage-and-guardian-isolation-spec.md)。
  1. **【彻底移除 `Evolution` 自进化与两步复盘结单】**：从 MCP 工具列表与 `task_manage` 中 100% 物理剥离 `evolve`、`final_review`、`complete` 及全部复盘考卷字段（`completion_conditions`、`verified`、`risks`、`missing_checks`、`learning_checks` 等），在代码中不留任何兼容后门或废弃字段。
  2. **【`:8766` 原生接管 `task_manage` 与一步自动结单】**：后台大管家原生处理 `task_manage` 全部 7 个动作（`create`、`update`、`checkpoint`、`list`、`get`、`block`、`resume`），原生支持 `quarantined` 步骤状态；当非空步骤全部处于 `completed` 或 `quarantined` 时，一步自动将任务顶层 `status` 标为 `completed` 并关停催工。
  3. **【日间普通聊天与夜间无人值守场景隔离】**：移除全局强制两步建单提示词；仅当活跃任务卡片开启了自动重发开关（`auto_resend_enabled == True`）时，才在工具响应末尾动态追加 `_NO_CONFIRM_DIRECTIVE` 免确认连跑指令。
  4. **【高频无单号干活工具在途保护与心跳归集】**：任何在途本机工具调用（含不带 `task_id` 的 `exec_command`、`read_file`、`file_edit`、`session_observe`）均将活跃任务卡片标为 `LIVE` 并刚性拦截催工投递；无单号工具完成后自动刷新当前唯一 `in_progress` 任务卡片的活跃心跳。
  5. **【思考强度原窗零触碰、换窗快照继承与开关解耦】**：默认档位设为 `inherit`，在跟随原窗口档位下零 `onModelChange` 触碰；在升级为新建网页交接时自动提取原房间睡前实时思考强度与模型（`WebCurrentEffort` / `WebCurrentModel`）写入新窗交接单；刷新模型目录或开关自动重发绝不误锁或篡改思考强度。
  6. **【基于下游真实执行证据的严格熔断计数】**：仅当检测到新的本机工具调用（`command_count` 增长）或模型完成一整轮无报错新回复（`turn_seq >= +2`）时才清零 `retry_count`，杜绝我方催工消息自身导致 `turn_seq + 1` 引发的熔断虚假清零。

---

## 9. Further Notes（补充说明与实施顺序）

确认无误后，将严格按以下 5 步顺序落地：
1. **第 1 步（先写测试）**：在 [`tests/Test-ConnectionManager.ps1`](tests/Test-ConnectionManager.ps1) 中新增覆盖 `T1 ~ T7` 的接缝契约测试；
2. **第 2 步（改造第二区常驻中枢）**：在 [`McpReadOnlyShield.py`](McpReadOnlyShield.py) 中落地 **`【组块 M1 ~ M6】`**；
3. **第 3 步（改造第三区左翼浏览器插件）**：在 [`browser-bridge/background.js`](browser-bridge/background.js) 与 [`browser-bridge/bridge-content.js`](browser-bridge/bridge-content.js) 中落地 **`【组块 B1 ~ B2】`**；
4. **第 4 步（改造第三区右翼桌面工作台）**：在 [`连接管理.ps1`](%E8%BF%9E%E6%8E%A5%E7%AE%A1%E7%90%86.ps1) 与 [`ConnectionManager.psm1`](ConnectionManager.psm1) 中落地 **`【组块 U1 ~ U2】`**（严格保持 UTF-8 with BOM 编码）；
5. **第 5 步（全量验证与热重启）**：运行自动化测试全绿通过后，平滑热重启 `McpReadOnlyShield.py` 与 `RelayStudio.exe` 验收。
