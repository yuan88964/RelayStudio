# Sequence Diagrams (`sequenceDiagram`)

Use `sequenceDiagram` for **arc42 Section 6 (Runtime View)** and **Stripe-style Cross-Actor Interaction Flows** where chronological request/response order, asynchronous callbacks (Webhooks), and conditional fallback branches (`alt / else`) across 3–5 participants matter.

## 1. Core Syntax & Industry Conventions

| Element | Syntax | Industry Best Practice (Stripe / arc42) |
|---|---|---|
| **Auto-numbering** | `autonumber` | Always enable `autonumber` so step numbers (`①②③`) match the prose walkthrough. |
| **Participants** | `actor` / `participant ID as 角色名` | Limit to 3–5 core swimlanes (e.g., Customer, Client UI, Backend Service, Database, External Gateway). |
| **Sync Request** | `A->>+B: 动词 + 业务契约载荷` | Solid arrow with activation bar (`+`/`-`) for synchronous calls. |
| **Sync Return** | `B-->>-A: 返回结果或凭据` | Dashed arrow for responses. |
| **Async Webhook / Event** | `B--)A: 异步推送事件通知` | Open arrow for non-blocking webhooks or message queue events. |
| **Branching & Fallback** | `alt 正常直通 ... else 异常降级 ... end` | Explicitly show both the Happy Path and the timeout/error recovery path. |

## 2. Canonical Example: Stripe PaymentIntent & Webhook Consistency Flow

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

![Stripe PaymentIntent Cross-Actor Sequence Diagram](../assets/04_stripe_payment_sequence.png)
