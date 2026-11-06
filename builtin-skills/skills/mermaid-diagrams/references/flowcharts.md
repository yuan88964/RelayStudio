# Flowcharts (`flowchart TB` / `LR`)

Use `flowchart TB` (or `LR` for shallow trees) when illustrating **C4 Level 2/3 Architecture Contracts**, **James Reason / SRE Swiss Cheese Fault Barriers**, **Novak Proposition Concept Maps**, or **Mathematical Commutative Diagrams**.

## 1. Semantic Node Shapes by Role (Organic Granularity)

Match node syntax and line count to its structural role rather than forcing every node into the same two-line box:

| Role | Syntax | Canonical Example |
|---|---|---|
| **Composite Container / Deep Module (C2/C3)** | `id["<b>名称 [类型]</b><br/>一句话对外职责与接口契约"]` | `api["<b>订单编排服务 [Container]</b><br/>幂等创建订单并协调库存预占"]` |
| **Actor / Entry / Terminal State** | `id(["单行角色或终态名"])` | `user(["👤 终端客户 (Web / App)"])` |
| **Single Operational Action / Concept** | `id("单行动作或概念名")` | `verify("核验支付签名与幂等键")` |
| **Decision / Guard Condition** | `id{"单行守卫判据?"}` | `guard{"3DS 风控挑战是否通过?"}` |
| **Persistent Database / Ledger** | `id[("单行数据库/账本名")]` | `db[("🗄️ 订单主数据库 (PostgreSQL)")]` |
| **Swiss Cheese Breach vs. Barrier** | `❌ 原防线漏洞` / `🛡️ 修复屏障` | `hole["❌ 原防线漏洞：未校验配置体积上限"]` |

## 2. Edge Contracts (Simon Brown & Novak Rules)

| Edge Type | Syntax | Meaning |
|---|---|---|
| **Primary Call / Proposition** | `A -->|"主动动词 + 业务契约"| B` | Synchronous request, dependency, or Novak proposition link |
| **Highlighted Core Path / Breach** | `A ==>|"关键变换 / 故障穿透"| B` | Dominant derivation path or fault penetration path |
| **Async Callback / Blocked Intuition / Cross-link** | `A -.->|"异步通知 / 受阻直觉"| B` | Webhook callback, feedback loop, or blocked naive path |

## 3. Scale & Subgraph Discipline (C4 & arc42 Rules)

- Control single-diagram complexity to **5–15 core nodes** and **at most 1 level of `subgraph`** (`Whitebox contains Blackboxes`); use **0 `subgraph` boxes** in Novak concept maps and mathematical commutative diagrams.
- Keep `style SubgraphID` free of `font-weight:bold` so SVG header text width is measured accurately without right-edge clipping.
