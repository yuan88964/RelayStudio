# C4 Architecture Diagrams (C1 System Context, C2 Container, C3 Component)

> **Unified Rules**: See [SKILL.md](../SKILL.md) for C4 zoom discipline (`C1`–`C3` stop at deep modules), arc42 blackbox/whitebox boundaries (`Whitebox contains Blackboxes`), and **Template 1 (C4 Level 3 Component / Deep Module View)**.

---

## 1. Canonical C4 Level 1: System Context View (Simon Brown's *Big Bank plc*)

Lock the target software system inside **1 central blackbox** and show only external human roles (`[Person]`) and external software systems (`[External Software System]`), with unidirectional active-verb contracts on every edge:

```mermaid
flowchart TB
    classDef person fill:#08427B,stroke:#052E56,stroke-width:2px,color:#FFFFFF
    classDef sys fill:#1168BD,stroke:#0B4884,stroke-width:2px,color:#FFFFFF
    classDef ext fill:#F8FAFC,stroke:#64748B,stroke-width:1.5px,stroke-dasharray: 5 5,color:#334155

    Customer(["👤 个人网银客户 (Personal Banking Customer)<br/>[Person: 银行零售客户]"]):::person

    BankingSys["<b>🏦 网上银行系统 (Internet Banking System)</b><br/>[Software System: 目标核心系统黑盒]<br/>职责：向个人客户提供账户余额查询、流水浏览与转账汇款能力"]:::sys

    Mainframe["<b>🏛️ 银行核心账务大型机 (Mainframe Banking System)</b><br/>[External Software System]<br/>职责：存管全部客户主数据、账户账本与核心资金清算记录"]:::ext
    EmailSys["<b>🌐 外部邮件服务 (E-mail System)</b><br/>[External Software System]<br/>职责：向客户投递安全认证提醒与交易结果通知邮件"]:::ext

    Customer -->|"① 浏览账户余额并发起转账汇款 [HTTPS]"| BankingSys
    BankingSys -->|"② 查询客户账户资料并提交记账指令 [XML/HTTPS]"| Mainframe
    BankingSys -.->|"③ 委托发送交易提醒与安全通知邮件 [SMTP]"| EmailSys
    EmailSys -.->|"④ 投递电子邮件通知至客户收件箱"| Customer
```

![Simon Brown C4 Official Level 1 System Context Diagram](../../../参考资料/调研笔记/Diagram_Skills_Research/assets/01_C4_Official_L1_SystemContext.png)

---

## 2. Canonical C4 Level 2: Container View (Simon Brown's *Big Bank plc*)

Open the target system as **1 single system boundary (`subgraph`)** to reveal its independently deployable runtime containers (Web UI, Mobile App, Backend API, Database), keeping each container's internal code hidden as a blackbox:

```mermaid
flowchart TB
    classDef person fill:#08427B,stroke:#052E56,stroke-width:2px,color:#FFFFFF
    classDef cont fill:#EBF8FF,stroke:#2B6CB0,stroke-width:2px,color:#1A202C
    classDef db fill:#FEFCE8,stroke:#B7791F,stroke-width:2px,color:#1A202C
    classDef ext fill:#F8FAFC,stroke:#64748B,stroke-width:1.5px,stroke-dasharray: 5 5,color:#334155

    Customer(["👤 个人网银客户 (Personal Banking Customer)<br/>[Person: 银行零售客户]"]):::person

    subgraph SysBoundary ["【C2 系统边界】网上银行系统 (Internet Banking System)"]
        direction TB
        WebApp["<b>Web 前端引导应用 (Web Application)</b><br/>[Container: Java & Spring MVC]<br/>职责：投递静态网关入口并下发单页应用资源"]:::cont
        SPA["<b>单页网页应用 (Single-Page Application)</b><br/>[Container: JavaScript & Angular]<br/>职责：在客户浏览器中提供全部网银交互界面"]:::cont
        MobileApp["<b>移动端原生应用 (Mobile App)</b><br/>[Container: Xamarin]<br/>职责：在移动设备上提供账户查询与快捷转账子集功能"]:::cont
        ApiApp["<b>网上银行后端接口服务 (API Application)</b><br/>[Container: Java & Spring MVC]<br/>职责：通过 JSON/HTTPS 对外提供网银核心业务契约"]:::cont
        UserDB[("<b>🗄️ 用户与凭证数据库 (Database)</b><br/>[Container: Oracle Database Schema]<br/>职责：存储客户注册信息、加密凭证与访问审计日志")]:::db
    end

    Mainframe["<b>🏛️ 银行核心账务大型机 (Mainframe Banking System)</b><br/>[External Software System]<br/>职责：管理客户核心账本与资金清算交易"]:::ext
    EmailSys["<b>🌐 外部邮件服务 (E-mail System)</b><br/>[External Software System]<br/>职责：向客户发送安全与交易通知邮件"]:::ext

    Customer -->|"① 访问网银域名入口 [HTTPS]"| WebApp
    WebApp -->|"② 下发单页应用到客户浏览器"| SPA
    Customer -->|"③ 浏览账户并发起转账操作"| SPA
    Customer -->|"④ 在手机端查询余额与转账"| MobileApp
    SPA -->|"⑤ 调用网银业务接口契约 [JSON/HTTPS]"| ApiApp
    MobileApp -->|"⑥ 调用网银业务接口契约 [JSON/HTTPS]"| ApiApp
    ApiApp -->|"⑦ 读写客户凭证与安全审计流水 [JDBC]"| UserDB
    ApiApp -->|"⑧ 查询账户余额并提交记账指令 [XML/HTTPS]"| Mainframe
    ApiApp -.->|"⑨ 触发交易提醒邮件发送请求 [SMTP]"| EmailSys
    EmailSys -.->|"⑩ 投递电子邮件至客户收件箱"| Customer

    style SysBoundary fill:#FFFFFF,stroke:#2B6CB0,stroke-width:2px,stroke-dasharray: 6 4,color:#1E3A8A
```

![Simon Brown C4 Official Level 2 Container Diagram](../../../参考资料/调研笔记/Diagram_Skills_Research/assets/02_C4_Official_L2_Containers.png)
