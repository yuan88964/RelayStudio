---
name: mermaid-diagrams
description: Create and refine high-resolution Mermaid diagrams in responses or Markdown documents, including C4 architecture views (C1/C2/C3), numbered cross-actor sequence diagrams, state lifecycle diagrams, SRE Swiss Cheese fault-barrier diagrams, Novak proposition concept maps, and mathematical commutative diagrams. Use whenever explaining cross-module seams, multi-branch flows, state machines, cascading fault barriers, or mathematical/conceptual transformations.
metadata:
  upstream: softaworks/agent-toolkit
  upstream-commit: 3027f20f3181758385a1bb8c022d4041dfb4de84
  local-adaptation: "2026-11-07"
---

# Mermaid Diagramming Deep Module (`mermaid-diagrams`)

Shared visual subroutine (`Role C`) and directly callable diagramming skill for form selection, scale & layout discipline, single-track delivery (`.md` or `.png`), and six canonical Mermaid templates (invoked directly or as an embedded subroutine by [Global_Agent_Rules.md](../../Global_Agent_Rules.md), [`develop`](../develop/SKILL.md), [`improve-codebase-architecture`](../improve-codebase-architecture/SKILL.md), [`math-teaching`](../math-teaching/SKILL.md), and [`pr`](../pr/SKILL.md)).

## 0. Three-State Interface Contract (`Standard / Normalize / Bailout`)

1. **`Standard` (handle directly)**: When the target structure involves cross-module **seams** (`Seam`), multi-branch control flow, state lifecycles, multi-layer fault barriers, or conceptual/mathematical equivalence transformations within **5–15 core nodes**, select the matching template in §3–§4 and deliver via §2.
2. **`Normalize` (normalize $M \to 1$ at entry, then handle)**:
   - For linear sequences ($\le 5$ steps) or parallel comparisons ($\ge 3$ dimensions), normalize into a **list** or **comparison table** per §1;
   - For topologies exceeding **15 core nodes** or mixing abstraction layers, split into **"1 macro overview + 1 whitebox zoom-in"** ($\le 15$ nodes each) per §2.2;
   - When branching, return loops, long labels, or edge crossings hurt readability, consult the bundled layout references ([algorithm selection](references/algorithm-selection.md), [layout families](references/layered-tree-force-and-radial-layouts.md), [routing and quality](references/routing-overlap-and-quality.md)) to establish a 4-check layout plan (`TB`/`LR` direction, grouping, port routing) before rendering.
3. **`Bailout` (abort main path and emit `Error` + `Route`)**:
   - When asked to draw before/after C4 architecture views for an unexamined codebase that requires deep-module seam discovery first → emit `Error: codebase seams not yet audited` and `Route: use module-design: audit module seams and deepen candidates before drawing C4 views`;
   - When the batch renderer `scripts/render-batch.mjs` fails due to a missing Headless Chrome binary or runtime dependency → emit `Error: <reason>` and `Route: need headless-chrome: fall back to standalone .md Mermaid delivery`.

---

## 1. Form Selection: Match Structure to List, Table, or Diagram

Match the visual form to the intrinsic structure of the information:

| Information Structure | Target Scenario | Canonical Form | Selection Criterion |
| :--- | :--- | :--- | :--- |
| **1. Linear sequential steps or single-dimension points**<br>($\le 5$ sequential steps, single linear chain) | Operational steps & instructions | **Ordered or unordered list** | When each item performs one action in a single linear chain, use a list for fast scanning and command copying. |
| **2. Multi-item parallel comparison or attribution**<br>($\ge 3$ peer items or $\ge 3$ comparable dimensions, root-cause matrices, before/after diffs) | Structured comparison & lookup | **Comparison table** or **LaTeX aligned array** | When peer items share $\ge 3$ attributes (e.g., symptom / trigger / breached seam / fix), horizontal table scanning beats node-link boxes; use LaTeX `\begin{array}` for dual-track math alignments. |
| **3. Cross-module seams (`Seam`), multi-branch flows, state loops, or equivalence transforms** | Mechanism comprehension & complex debugging | **Standalone `.md` diagram** or **high-res `.png`** | Draw when cross-container/cross-module seams, conditional branches, async callbacks, multi-layer fault barriers, or dual-path equivalence transforms benefit from spatial topology. |

---

## 2. Delivery Mode & Scale Discipline

### 1. Single-Track File Delivery (Standalone `.md` Link by Default, or `2x .png` on Demand)
- **Default delivery — Standalone `.md` diagram file**: During everyday chat, architecture analysis, or debugging explanations, write the Mermaid code block and brief legend into a standalone `.md` file in the active session folder, and place only the clickable link (`[Diagram Title](file:///...md)`) at the end of the relevant sentence in the chat response.
- **On-demand delivery — High-res `2x .png` image (when the user requests images or when archiving into persistent Obsidian notes)**: Write the Mermaid source to a temporary `.mmd` file, run `node "scripts/render-batch.mjs"` ([Batch Rendering](references/rendering.md)), and link or embed only the resulting `.png` (`[Diagram Title](file:///...png)` in chat, or `![Diagram Title](path)` inside Obsidian notes).
- **Language separation (`Context-as-Sample`)**: Keep this skill's rules in compact English; render user-facing node and edge labels inside diagrams in plain, accurate Chinese per [Global_Agent_Rules.md](../../Global_Agent_Rules.md) unless requested otherwise.

### 2. Three Scale & Layout Invariants
1. **Node & `subgraph` budget**:
   - Keep each diagram within **5–15 core nodes** and at most **1 level of `subgraph` nesting** (open at most 1 container whitebox per diagram).
   - Above 15 nodes, split into **"1 macro overview + 1 whitebox zoom-in"**.
   - Use **0 `subgraph` boxes** in Novak concept maps and mathematical commutative diagrams; distinguish roles via semantic pastel fills and stroke weights.
2. **Reading direction**:
   - Default to top-to-bottom (`TB`) for layered architectures, cross-actor sequences, state lifecycles, and Swiss Cheese defense slices; use left-to-right (`LR`) for short pipelines or shallow trees (see [layout families](references/layered-tree-force-and-radial-layouts.md)).
3. **Native Mermaid diagram types & active-verb edges**:
   - Select the native Mermaid diagram type that matches the domain (`flowchart`, `sequenceDiagram`, `stateDiagram-v2`, `classDiagram`, `erDiagram`).
   - Put an active verb or guard condition on every directed edge, flatten cross-rank edges that cause Dagre rank gaps ([routing and quality](references/routing-overlap-and-quality.md)), and omit `font-weight:bold` from `style SubgraphID` so SVG header labels render cleanly without right-edge clipping.

---

## 3. Six Canonical Scenarios & Template Routing Table

| Reader's Core Question | Canonical Diagram Paradigm & Template | What Each Node Must State | What Each Edge Must State |
| :--- | :--- | :--- | :--- |
| **1. What independent runtime containers and external systems exist, and how do they interact? (Macro Seams)** | **C4 Level 1/2 (System Context / Container View)**<br>(See [C4 Diagrams](references/c4-diagrams.md) · [Cloud Topology](references/architecture-diagrams.md)) | Actor / runtime container / database + `[Type]` + one-line external responsibility | Caller action + transport protocol |
| **2. Which deep modules live inside a container, and what seams/contracts do they expose? (Whitebox Zoom-in)** | **C4 Level 3 (Component / Deep Module Contract View)**<br>(Template 1 below · [Domain Contracts](references/class-diagrams.md) · [ER & Data Ledgers](references/erd-diagrams.md)) | Internal deep module name + owned state + public interface contract | Inter-module call rule, payload contract, and bailout path |
| **3. How does a request or workflow execute chronologically across actors? (Runtime View)** | **Stripe-Style Numbered Cross-Actor Sequence**<br>(Template 2 below · [Sequence Diagrams](references/sequence-diagrams.md)) | 3–5 participant swimlanes (Client / Backend / Core Module / External Gateway) | Numbered steps (`①②③`) + solid sync calls / dashed async callbacks; `alt/else` for happy path vs. bailout |
| **4. How does a domain object transition across states, suspensions, and terminal outcomes? (Lifecycle)** | **Business State Lifecycle (`stateDiagram-v2`)**<br>(Template 3 below) | State name + one-line invariant (color-coded for initial, waiting, success, and terminal states) | Triggering domain event or guard condition |
| **5. Why did a cascading failure occur, and which barrier intercepts it at each defense layer? (Postmortem)** | **SRE Swiss Cheese Fault & Defense Barrier**<br>(Template 4 below) | Hazard trigger, breached `❌ Hole` per slice, added `🛡️ Remediation Barrier` per slice, and terminal outcome | Thick red `==>` for fault penetration path; dashed/green edges for barrier interception and graceful degradation |
| **6. How does a theoretical concept or mathematical transformation work step by step? (Cognition & Math)** | **Novak Concept Map** or **Mathematical Commutative Diagram**<br>(Templates 5 & 6 below) | Box-free (`0 subgraph`): macro concept or space name + micro intuition or formula | `[Node A] + linking verb phrase + [Node B]` forms a complete proposition; math arrows state operators and domain guards |

---

## 4. Six Canonical Reference Templates (Context-as-Sample Exemplars)

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

    subgraph ApiBoundary ["【C3 容器内部白盒】网上银行后端服务 (API Application)"]
        direction TB
        SignInCtrl["<b>登录认证控制器 (Sign In Controller)</b><br/>[Component: Spring MVC RestController]<br/>职责：接收客户登录凭证并签发访问令牌"]:::comp
        AcctCtrl["<b>账户总览控制器 (Accounts Summary Controller)</b><br/>[Component: Spring MVC RestController]<br/>职责：向已认证客户返回账户余额与近期流水概览"]:::comp
        SecComp["<b>安全与权限核验模块 (Security Component)</b><br/>[Component: Spring Bean]<br/>职责：统一校验密码哈希、会话令牌与权限接缝"]:::comp
        CoreAdapter["<b>核心账务系统防腐适配器 (Mainframe Banking System Facade)</b><br/>[Component: Spring Bean]<br/>职责：封装大型机遗留 XML 协议，在接缝处对外提供稳定领域接口"]:::comp
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

![Simon Brown C4 Official Level 3 Component Diagram](../../../参考资料/Diagram_Skills_Research/assets/03_C4_Official_L3_Components.png)

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

![James Reason Swiss Cheese Barrier Model](../../../参考资料/Diagram_Skills_Research/assets/05_Swiss_Cheese_Fault_Barrier.png)

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

![Joseph Novak Official IHMC Concept Map](../../../参考资料/Diagram_Skills_Research/assets/06_Novak_Official_Concept_Map.png)

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

    P == "① 正变换 φ：两边取自然对数 ln |·|<br/>【适用条件：x ≠ 1, 2, 3 且根号内非负】" ==> T1
    T1 == "② 变换域降维运算 D：对数性质将乘除幂降阶为线性加减" ==> T2
    T2 == "③ 逆变换 φ⁻¹：两边同乘原函数 f(x) 还原回原空间 (φ⁻¹ ∘ D ∘ φ = d/dx)" ==> Q
```

![First Isomorphism Theorem Commutative Diagram](../../../参考资料/Diagram_Skills_Research/assets/07_Commutative_Diagram_First_Isomorphism.png)

![Mathematical Commutative Diagram](assets/08_math_commutative_diagram.png)

---

## 5. Disclosed References, Completion Gate & Subroutine Return Contract (Recency Peak)

- **Disclosed Type References (Load on Demand)**: [Flowcharts](references/flowcharts.md) · [Sequence Diagrams](references/sequence-diagrams.md) · [C4 Diagrams](references/c4-diagrams.md) · [Domain & Deep-Module Contracts](references/class-diagrams.md) · [ER & Data Ledgers](references/erd-diagrams.md) · [Cloud Topology](references/architecture-diagrams.md) · [Styling & De-Boxing](references/advanced-features.md) · [Batch Rendering (`render-batch.mjs`)](references/rendering.md)
- **Bundled Layout & Routing References**: [Algorithm Selection](references/algorithm-selection.md) · [Layout Families (`TB`/`LR`, Tree, Force, Radial)](references/layered-tree-force-and-radial-layouts.md) · [Routing, Overlap & Quality](references/routing-overlap-and-quality.md) · [Diagram_Skill_Validation.md](../../../参考资料/Diagram_Skills_Research/Diagram_Skill_Validation.md)

### Completion Gate & Subroutine Return Contract
Before delivering any diagram or returning to a calling host skill, verify all 3 checks:
1. **Scale & Visual Hygiene**: `5–15` core nodes, `<= 1` `subgraph` level (`0` in Novak/Commutative views), active-verb edges, and `style SubgraphID` free of `font-weight:bold`.
2. **Single-Track Artifact Delivery**: Deliver either a standalone `.md` file link (`[Diagram Title](file:///...md)`) or a `2x .png` image link/embed via `render-batch.mjs` — keep chat responses free of duplicate inline Mermaid code fences.
3. **Immediate Subroutine Return Rule**: When invoked as a visual subroutine by [Global_Agent_Rules.md](../../Global_Agent_Rules.md), [`develop`](../develop/SKILL.md), [`improve-codebase-architecture`](../improve-codebase-architecture/SKILL.md), [`math-teaching`](../math-teaching/SKILL.md), or [`pr`](../pr/SKILL.md), emit the `[Diagram Title](file:///...)` link and immediately resume the calling container's active phase inline.
