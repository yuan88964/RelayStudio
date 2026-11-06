---
name: mermaid-diagrams
description: 在回答或 Markdown 文档中用 Mermaid 创建、修改高清系统架构图（C4 C1/C2/C3）、跨角色时序图、业务状态生命周期图、SRE 瑞士奶酪故障屏障图、Novak 命题概念图与数学交换推导图。涉及多模块协作、多分支流转、状态机、故障传导或复杂概念推演时主动使用。
metadata:
  upstream: softaworks/agent-toolkit
  upstream-commit: 3027f20f3181758385a1bb8c022d4041dfb4de84
  local-adaptation: "2026-11-05"
---

# Mermaid 图解表达深模块（判定、规模契约与六大标准模板）

本模块统一维护全库的**画图判定、版面规模、交付形式与六大标准 Mermaid 代码模板**（长期表达目标见 [全局协作规则](../../AGENTS.md)）。

## 0. 模块职责、输入归一化与异常转接契约

1. **典型情景（直接处理）**：涉及跨模块边界、多分支流转、状态生命周期、多道故障屏障或概念/数学等价变换时，直接按下方规模与模板绘制图解。
2. **非典型情景（先归一化再处理）**：
   - 若信息仅是 $\le 5$ 步单线操作或 $\ge 3$ 项并列维度对比，先归一化为**列表**或**对比表格**，不强行画图；
   - 若单图核心节点超过 15 个或跨多层抽象，先拆分为**“1 张宏观总览图 + 1 张局部放大图”**再绘制；
   - 若分支回路复杂、连线交叉或标签拥挤，先调用子零件 [node-link-and-diagram-layout](../node-link-and-diagram-layout/SKILL.md) 整理排列方向与分组，再落图。
3. **异常或越界情景（输出停工说明 `Error` 与转接建议 `Route`）**：
   - 需要先做代码库深模块扫描与候选方案对拷 → 输出 `Route: use improve-codebase-architecture: scan codebase seams before drawing before/after C4 diagrams`；
   - 批量渲染脚本 `scripts/render-batch.mjs` 因本机缺少 Headless Chrome 或依赖失败 → 输出 `Error: <原因>` 与 `Route: need headless-chrome-or-mmdc: fall back to standalone .md Mermaid delivery`。

---

## 一、什么时候不画图，什么时候画图

按信息的自身结构选择合适的呈现方式：

| 信息结构特征 | 适用场景 | 推荐呈现方式 | 判断依据 |
| :--- | :--- | :--- | :--- |
| **1. 单线顺序步骤或单维度要点**<br>（$\le 5$ 步顺序操作、无分支、无回环） | 操作步骤与说明 | **有序或无序列表** | 每个条目只包含 1 个动作且按单线推进时，直接用列表，便于扫读与复制命令。 |
| **2. 多对象并列对比或归因清单**<br>（$\ge 3$ 个同类对象或 $\ge 3$ 个可比维度、故障归因、改造前后对照） | 结构化查阅与对比 | **对比表格** 或 **LaTeX 对齐阵列** | 并列条目共享 3 个及以上可比属性（如：现象 / 触发条件 / 失守点 / 修复动作）时，表格横向扫读效率高于连线图；数学双轨序列对齐使用 LaTeX `\begin{array}`。 |
| **3. 跨模块边界、多分支流转、状态回环或等价变换** | 机制理解与复杂排障 | **独立图解文档或高清图片**<br>（默认独立 `.md`） | 存在跨容器/跨模块接口边界、多分支条件判据、异步回调闭环、多道防线穿透或双路径等价变换，纯文字需要反复写“若 A 则跳回 X”时才画图。 |

---

## 二、交付形式与版面规模原则

### 1. 交付形式（`.md` 简要图与 `.png` 大图二选一）
- **默认交付：独立 `.md` 简要图文档**：日常对话、架构分析或排障解释需要画图时，在当前会话目录创建一份独立的 `.md` 图解文档（集中放入 Mermaid 代码块与必要图例），在对话正文对应句尾内嵌 `[图解名称](file:///...md)` 直链（例如 `整体流转见 [系统架构图解](file:///...md)。`）。此时不额外调用渲染脚本生成 `.png`。
- **按需交付：高清 `.png` 大图（用户要求导出图片或写入笔记长期归档时启用）**：当用户要求导出图片，或需要将定稿图嵌入 Obsidian 笔记长期归档时，将 Mermaid 源码写入临时 `.mmd` 并调用 `node "scripts/render-batch.mjs"` 批量导出 2x `.png`（见 [批量渲染说明](references/rendering.md)），在句尾内嵌 `[图名](file:///...png)` 交付（写入 Obsidian 笔记归档时用 `![图名](路径)`），不再重复创建装相同 Mermaid 代码块的展示用 `.md` 文档。

### 2. 版面与规模三原则
1. **控制单图节点数量**：
   - 单张图核心节点控制在 **5～15 个**，架构图 `subgraph` 边界框最多嵌套 **1 层**（一张图只打开 1 个容器白盒展示内部组件）。
   - 超出 15 个节点时，拆分为**“1 张宏观总览图 + 1 张局部放大图”**，放入同一个独立 `.md` 图解文档上下对照。
   - 概念图与数学交换图不加 `subgraph` 外框，用语义浅底色与实/虚线粗细区分角色。
2. **阅读方向顺应结构自然延展**：
   - 分层架构、跨角色时序、状态生命周期与多道防御切片默认采用从上到下（`TB`）；短链路或层级树采用从左到右（`LR`）。
3. **选用匹配的原生图型**：
   - 按场景选用 Mermaid 原生图型（`flowchart`、`sequenceDiagram`、`stateDiagram-v2`、`classDiagram`、`erDiagram`）。
   - 每条有向连线写明主动动词或守卫条件，子图 `style` 保持常规字重以免标题截断。

---

## 三、六类常见场景与代码模板速查

| 读者想搞懂的问题 | 对应图解范式与本地代码模板 | 节点要写清什么 | 连线要写清什么 |
| :--- | :--- | :--- | :--- |
| **1. 软件有哪些独立程序与外部系统、整体怎么配合？（宏观边界）** | **C4 Level 1/2（系统上下文 / 容器图）**<br>（模板：[C4 架构图手册](references/c4-diagrams.md)） | 角色 / 独立运行容器 / 数据库 + `[类型]` + 一句话对外职责 | 谁向谁发起什么业务动作 + 传输介质 |
| **2. 某个程序内部有哪些深模块、各自管什么账与接口？（内部放大）** | **C4 Level 3（组件/深模块契约图）**<br>（模板：下方 Template 1 · [领域契约图](references/class-diagrams.md)） | 内部深模块名称 + 负责的数据源 + 对外接口契约（底层函数名留给正文对照表） | 模块间调用规则、输入输出凭据与异常退路 |
| **3. 一次请求或操作怎么跨角色跑通？（动态交互）** | **带编号跨角色时序图**<br>（模板：下方 Template 2 · [时序图手册](references/sequence-diagrams.md)） | 3～5 个真实职责泳道（客户端 / 服务端 / 核心库 / 外部网关） | ①②③ 编号 + 实线同步请求 / 虚线异步回调；用 `alt/else` 框出正常路径与异常降级 |
| **4. 业务对象的状态怎么切换、何时挂起或终结？（生命周期）** | **业务状态生命周期图**<br>（模板：下方 Template 3，原生 `stateDiagram-v2`） | 业务状态名 + 含义短注（用浅底色区分初始态、等待态、成功/异常终态） | 触发状态切换的业务事件或守卫条件 |
| **5. 复杂故障为什么发生、修复方案在哪道门拦截？（排障复盘）** | **瑞士奶酪防御屏障图**<br>（模板：下方 Template 4） | 触发源、各道防线被穿透的 `❌ 漏洞`、新增的 `🛡️ 修复屏障` 与终态结果 | 粗红实线 `==>` 表示故障穿透路径；绿线表示新增屏障拦截与降级路径 |
| **6. 新概念原理或数学方法如何一步步推演？（认知与数学）** | **命题概念图** 或 **数学交换图**<br>（模板：下方 Template 5 & 6） | 免 `subgraph` 外框：宏观概念/空间名 + 微观直觉/算式 | `[节点A] + 连线谓词短语 + [节点B]` 能连读成完整句子；数学交换图注明等价条件与算子 |

---

## 四、六大经典场景标准代码模板 (Canonical Reference Examples)

### Template 1: C4 Level 3 Component & Deep Module Contract (Simon Brown's Classic *Big Bank plc* Pattern)
> **Standard**: Simon Brown C4 Component View & arc42 Section 5 Blackbox/Whitebox Rule (see [C4 Diagrams](references/c4-diagrams.md) for C1/C2 templates).

```mermaid
flowchart TB
    classDef person fill:#08427B,stroke:#052E56,stroke-width:2px,color:#FFFFFF
    classDef comp fill:#EBF8FF,stroke:#2B6CB0,stroke-width:2px,color:#1A202C
    classDef db fill:#FEFCE8,stroke:#B7791F,stroke-width:2px,color:#1A202C
    classDef ext fill:#F8FAFC,stroke:#64748B,stroke-width:1.5px,stroke-dasharray: 5 5,color:#334155

    SPA(["🖥️ 单页网页应用 (Single-Page App)<br/>[Container: JavaScript & Angular]"]):::person
    EmailSys["🌐 外部邮件服务 (E-mail System)<br/>[External Software System]"]:::ext
    Mainframe["🏦 银行核心账务大型机 (Mainframe Banking System)<br/>[External Software System]"]:::ext

    subgraph ApiBoundary ["【C3 容器内部边界】网上银行后端服务 (API Application)"]
        direction TB
        SignInCtrl["<b>登录认证控制器 (Sign In Controller)</b><br/>[Component: Spring MVC RestController]<br/>职责：接收客户登录凭证并签发访问令牌"]:::comp
        AcctCtrl["<b>账户总览控制器 (Accounts Summary Controller)</b><br/>[Component: Spring MVC RestController]<br/>职责：向已认证客户返回账户余额与近期流水概览"]:::comp
        SecComp["<b>安全与权限核验模块 (Security Component)</b><br/>[Component: Spring Bean]<br/>职责：统一校验密码哈希、会话令牌与权限边界"]:::comp
        CoreAdapter["<b>核心账务系统防腐适配器 (Mainframe Banking System Facade)</b><br/>[Component: Spring Bean]<br/>职责：封装大型机遗留 XML 协议，对外提供稳定领域接口"]:::comp
    end

    UserDB[("🗄️ 用户与凭证数据库 (Database)<br/>[Container: Relational DB Schema]")]:::db

    SPA -->|"① 提交客户登录请求 [JSON/HTTPS]"| SignInCtrl
    SPA -->|"② 请求账户汇总列表 [JSON/HTTPS]"| AcctCtrl
    SignInCtrl -->|"③ 委托核验客户凭证"| SecComp
    AcctCtrl -->|"④ 委托校验访问令牌有效性"| SecComp
    SecComp -->|"⑤ 读写用户认证状态与审计日志 [JDBC]"| UserDB
    AcctCtrl -->|"⑥ 查询客户名下账户与流水"| CoreAdapter
    CoreAdapter -->|"⑦ 调用核心账务接口并转换格式 [XML/HTTPS]"| Mainframe
    SecComp -.->|"⑧ 密码变更或异常登录时触发通知"| EmailSys

    style ApiBoundary fill:#FFFFFF,stroke:#2B6CB0,stroke-width:2px,stroke-dasharray: 6 4,color:#1E3A8A
```

![Simon Brown C4 Official Level 3 Component Diagram](../../参考资料/调研笔记/Diagram_Skills_Research/assets/03_C4_Official_L3_Components.png)

---

### Template 2: Stripe-Style Numbered Cross-Actor Sequence (*PaymentIntent* & Webhook Pattern)
> **Standard**: Stripe PaymentIntents & Webhooks Runtime View & arc42 Section 6.

```mermaid
sequenceDiagram
    autonumber
    actor Customer as 👤 终端客户 (Browser / App)
    participant Merchant as ⚙️ 商户后端 (Order Service)
    participant DB as 🗄️ 订单数据库 (PostgreSQL)
    participant Stripe as 🌐 支付网关 (Stripe API)

    Note over Customer,Stripe: 阶段一：同步创建支付意图（幂等防重）
    Customer->>+Merchant: 提交结账请求 (携带购物车ID与幂等键)
    Merchant->>+DB: 创建待支付订单记录 (status = PENDING)
    DB-->>-Merchant: 返回唯一订单号 order_id
    Merchant->>+Stripe: 创建 PaymentIntent (金额, 币种, 关联 order_id)
    Stripe-->>-Merchant: 返回 intent_id 与客户端密钥 client_secret
    Merchant-->>-Customer: 返回 client_secret 唤起前端支付组件

    Note over Customer,Stripe: 阶段二：客户端确认扣款与 3DS 风控分支
    Customer->>+Stripe: 提交支付方式并确认扣款 (confirmPayment)
    alt 免密风控直通 (Frictionless Flow)
        Stripe-->>Customer: 授权扣款成功 (status = succeeded)
    else 触发发卡行 3DS 强验证 (requires_action)
        Stripe-->>Customer: 返回 requires_action 与银行验证挑战页
        Customer->>Stripe: 完成短信验证码 / 生物识别挑战
        Stripe-->>-Customer: 验证通过并完成扣款 (status = succeeded)
    end

    Note over Customer,Stripe: 阶段三：异步 Webhook 最终一致性闭环（防客户端掉线）
    Stripe--)Merchant: 异步推送 payment_intent.succeeded 事件 [Webhook]
    activate Merchant
    Merchant->>Merchant: 核验签名并检查事件 ID 幂等去重
    Merchant->>DB: 更新订单状态为已支付 (status = PAID)
    Merchant-->>Stripe: 返回 200 OK 确认签收（停止重试）
    deactivate Merchant
```

![Stripe PaymentIntent Cross-Actor Sequence Diagram](assets/04_stripe_payment_sequence.png)

---

### Template 3: Stripe-Style Business State Lifecycle (`stateDiagram-v2` Native State Machine)
> **Standard**: Stripe PaymentIntents Lifecycle Specification. Uses native `stateDiagram-v2` to orthogonally separate state transitions from cross-actor network calls.

```mermaid
stateDiagram-v2
    direction TB
    classDef init fill:#EFF6FF,stroke:#2563EB,stroke-width:1.5px,color:#1E3A8A
    classDef wait fill:#FFFBEB,stroke:#D97706,stroke-width:2px,color:#92400E
    classDef ok fill:#DCFCE7,stroke:#16A34A,stroke-width:2px,color:#14532D
    classDef err fill:#FEE2E2,stroke:#DC2626,stroke-width:2px,color:#7F1D1D

    state "<b>requires_payment_method</b><br/>初始态：等待客户提供银行卡或钱包" as req_pm
    state "<b>requires_confirmation</b><br/>已采集支付方式，等待确认扣款" as req_conf
    state "<b>requires_action [挂起态]</b><br/>等待客户完成发卡行 3DS 验证挑战" as req_act
    state "<b>processing [处理态]</b><br/>已提交清算网络，等待银行最终回执" as proc
    state "<b>succeeded [成功终态]</b><br/>资金已确认入账，可安全发货履约" as succ
    state "<b>canceled [关闭终态]</b><br/>超时未付或主动取消，释放库存锁" as canc

    [*] --> req_pm: 创建支付单 (Create)
    req_pm --> req_conf: 附加支付方式信息
    req_conf --> proc: 免挑战直通 (Confirm)
    req_conf --> req_act: 触发发卡行 3DS 强验证
    req_act --> proc: ✅ 客户完成 3DS 验证
    req_act --> req_pm: ❌ 验证失败或回退重选
    proc --> succ: ✅ 银行扣款清算成功
    proc --> req_pm: ❌ 余额不足或发卡行拒付
    req_pm --> canc: 商户或客户主动取消
    req_act --> canc: 验证超时自动关闭

    succ --> [*]
    canc --> [*]

    class req_pm,req_conf init
    class req_act,proc wait
    class succ ok
    class canc err
```

![Stripe PaymentIntent State Lifecycle](assets/05_stripe_payment_lifecycle.png)

---

### Template 4: James Reason / Cloudflare SRE Swiss Cheese Fault & Defense Barrier
> **Standard**: James Reason Swiss Cheese Model & Google SRE / Cloudflare Cascading Failure Postmortem Pattern (each defensive layer slice contains both the breached hole and the remediation barrier).

```mermaid
flowchart TB
    classDef trigger fill:#FEF3C7,stroke:#D97706,stroke-width:2px,color:#78350F
    classDef hole fill:#FEE2E2,stroke:#DC2626,stroke-width:2px,color:#7F1D1D
    classDef barrier fill:#DCFCE7,stroke:#16A34A,stroke-width:2px,color:#14532D
    classDef outage fill:#991B1B,stroke:#7F1D1D,stroke-width:2.5px,color:#FFFFFF
    classDef safe fill:#15803D,stroke:#14532D,stroke-width:2px,color:#FFFFFF

    Trigger["⚡ 异常触发源 (Hazard / Trigger)<br/>数据库权限变更导致元数据查询返回重复行"]:::trigger

    subgraph Slice1 ["【防线 1】配置构建与准入校验层 (Config Generator)"]
        direction LR
        H1["❌ 原防线漏洞 (Hole 1)<br/>构建器未校验特征文件体积上限<br/>生成膨胀 2 倍的超规配置文件"]:::hole
        B1["🛡️ 修复屏障 1 (Action Item)<br/>构建端增加 Schema 与条目数硬上限<br/>超阈值立即阻断打包并告警"]:::barrier
    end

    subgraph Slice2 ["【防线 2】发布灰度的爆炸半径控制层 (Canary Rollout)"]
        direction LR
        H2["❌ 原防线漏洞 (Hole 2)<br/>热配置绕过分批金丝雀灰度<br/>5 秒内全量推送至全球边缘节点"]:::hole
        B2["🛡️ 修复屏障 2 (Action Item)<br/>将动态配置纳入分阶段渐进发布<br/>单批次异常率超标自动熔断回滚"]:::barrier
    end

    subgraph Slice3 ["【防线 3】运行时容错与降级层 (Runtime Resilience)"]
        direction LR
        H3["❌ 原防线漏洞 (Hole 3)<br/>代理引擎预分配内存数组越界<br/>触发未捕获异常导致进程崩溃重启"]:::hole
        B3["🛡️ 修复屏障 3 (Action Item)<br/>超限时拒绝加载新配置<br/>静默降级保持上一版可用缓存"]:::barrier
    end

    BadEnd["🔥 事故顶事件 (Losses / Outage)<br/>全球边缘代理节点级联崩溃 · 核心流量返回 5xx"]:::outage
    GoodEnd["✅ 纵深防御韧性态 (Resilient State)<br/>异常配置被逐层拦截或局部降级 · 线上流量零受损"]:::safe

    Trigger ==>|"① 产出超规配置"| H1 ==>|"② 全网瞬间分发"| H2 ==>|"③ 击穿内存上限"| H3 ==>|"级联雪崩"| BadEnd
    Trigger -.->|"复盘加固后路径"| B1 -.->|"漏网异常"| B2 -.->|"漏网异常"| B3 -->|"拦截或保活降级"| GoodEnd

    style Slice1 fill:#F8FAFC,stroke:#94A3B8,stroke-width:1.5px,color:#0F172A
    style Slice2 fill:#F8FAFC,stroke:#94A3B8,stroke-width:1.5px,color:#0F172A
    style Slice3 fill:#F8FAFC,stroke:#94A3B8,stroke-width:1.5px,color:#0F172A
```

![James Reason Swiss Cheese Barrier Model](../../参考资料/调研笔记/Diagram_Skills_Research/assets/05_Swiss_Cheese_Fault_Barrier.png)

---

### Template 5: Novak × Tufte Box-Free Concept Network (IHMC Classic Concept Map Pattern)
> **Standard**: Joseph Novak & Cañas (IHMC) — Theory Underlying Concept Maps. Zero `subgraph` boxes; every `[Node A] + Linking Phrase + [Node B]` reads as a complete proposition.

```mermaid
flowchart TD
    classDef anchor fill:#DBEAFE,stroke:#2563EB,stroke-width:1.5px,color:#1E3A8A
    classDef core fill:#EDE9FE,stroke:#7C3AED,stroke-width:1.5px,color:#4C1D95
    classDef prop fill:#DCFCE7,stroke:#16A34A,stroke-width:2px,color:#14532D
    classDef leaf fill:#FEFCE8,stroke:#CA8A04,stroke-width:1.5px,color:#713F12

    CM["<b>概念图 (Concept Maps)</b><br/>聚焦回答一个特定焦点问题 (Focus Question)"]:::anchor
    OK["<b>结构化知识 (Organized Knowledge)</b><br/>将零散名词整合为可迁移的认知网络"]:::core
    Concepts["<b>概念节点 (Concepts)</b><br/>事件或事物中的感知规律 (用圆角框标示)"]:::core
    Links["<b>连接谓词短语 (Linking Words)</b><br/>标明两个概念之间的精确动词或条件关系"]:::core
    Props["<b>真命题三元组 (Propositions)</b><br/>独立可读的意义单元：概念 A + 连接词 + 概念 B"]:::prop

    Learn["<b>有意义学习 (Meaningful Learning)</b><br/>将新概念锚定在学习者已有的前置直觉上"]:::leaf
    Cross["<b>跨分支横向连接 (Cross-Links)</b><br/>打通不同知识分区，触发创造性顿悟"]:::leaf

    CM == "用于表征与外化" ==> OK
    OK == "直接服务于" ==> Learn
    CM == "由两类基本元素构成" ==> Concepts & Links
    Concepts == "通过有向边结合" ==> Links
    Links == "与目标概念共同组成" ==> Props
    Props == "作为最小基石构建出" ==> OK
    Links -. "当跨层级连接不同领域分支时形成" .-> Cross
    Cross -. "揭示深层机制统一性，加速" .-> Learn
```

![Joseph Novak Official IHMC Concept Map](../../参考资料/调研笔记/Diagram_Skills_Research/assets/06_Novak_Official_Concept_Map.png)

---

### Template 6: Classic Mathematical Commutative Diagram (Isomorphism / Change-of-Domain Pattern)
> **Standard**: First Isomorphism Theorem & Commutative Diagrams. Illustrates why transforming into an auxiliary space ($\varphi$) and inverting ($\varphi^{-1}$) equals the direct mapping ($f = \varphi^{-1} \circ D \circ \varphi$).

```mermaid
flowchart TB
    classDef orig fill:#DBEAFE,stroke:#2563EB,stroke-width:1.5px,color:#1E3A8A
    classDef trans fill:#EDE9FE,stroke:#7C3AED,stroke-width:1.5px,color:#4C1D95
    classDef pain fill:#FEE2E2,stroke:#DC2626,stroke-width:1.5px,color:#7F1D1D
    classDef dest fill:#DCFCE7,stroke:#16A34A,stroke-width:2px,color:#14532D

    P["<b>原问题空间 P (复杂乘除与根式耦合函数)</b><br/>给定 y = f(x) = √((x−1)(x−2) / (x−3))<br/>目标：求导函数 f'(x)"]:::orig
    Hard["<b>直接硬算受阻路径 (链式法则 + 商法则多重嵌套)</b><br/>根号内分式通分与高次展开极易引发代数算错"]:::pain
    T1["<b>对数变换域 P' (线性加减空间)</b><br/>ln |f(x)| = ½ [ ln|x−1| + ln|x−2| − ln|x−3| ]"]:::trans
    T2["<b>变换域隐式导数 Q' (解耦逐项求导结果)</b><br/>f'(x) / f(x) = ½ [ 1/(x−1) + 1/(x−2) − 1/(x−3) ]"]:::trans
    Q["<b>目标结论空间 Q (原空间显式导函数)</b><br/>f'(x) = ½ √((x−1)(x−2)/(x−3)) · [ 1/(x−1) + 1/(x−2) − 1/(x−3) ]"]:::dest

    P -. "若直接在原空间硬套复合商求导法则，陷入" .-> Hard
    Hard -. "计算冗长且难以化简，阻碍抵达" .-> Q

    P == "① 正变换 φ：两边取自然对数 ln |·|<br/>【适用边界：x ≠ 1, 2, 3 且根号内非负】" ==> T1
    T1 == "② 变换域降维运算 D：对数性质将乘除幂降阶为线性加减" ==> T2
    T2 == "③ 逆变换 φ⁻¹：两边同乘原函数 f(x) 还原回原空间 (φ⁻¹ ∘ D ∘ φ = d/dx)" ==> Q
```

![First Isomorphism Theorem Commutative Diagram](../../参考资料/调研笔记/Diagram_Skills_Research/assets/07_Commutative_Diagram_First_Isomorphism.png)

![Mathematical Commutative Diagram](assets/08_math_commutative_diagram.png)

---

## 五、分图型语法手册、布局子零件与业界标杆出处

- **Syntax & Type References**: [Flowcharts](references/flowcharts.md) · [Sequence Diagrams](references/sequence-diagrams.md) · [C4 Diagrams](references/c4-diagrams.md) · [Domain & Class Contracts](references/class-diagrams.md) · [ER & Data Ledgers](references/erd-diagrams.md) · [Cloud Topology](references/architecture-diagrams.md) · [Styling & De-Boxing](references/advanced-features.md) · [Batch Rendering (`render-batch.mjs`)](references/rendering.md)
- **Layout Child Part**: [node-link-and-diagram-layout](../node-link-and-diagram-layout/SKILL.md)（复杂拓扑与连线路由优化）
- **7 Authentic Industry Standard Diagrams & Provenance Links**: [业界权威图解标准与原版经典标杆库](../../参考资料/调研笔记/Diagram_Skills_Research/Diagram_Skill_Validation.md)
