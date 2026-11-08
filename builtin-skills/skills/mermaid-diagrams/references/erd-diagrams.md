# Data Ledger & Entity Relationships (`erDiagram`)

> **Unified Rules**: See [SKILL.md](../SKILL.md) (§2.2) for node scale (`5–15` core nodes) and single-track delivery.

Use `erDiagram` when explaining **which persistent ledgers exist, what truth each ledger owns, and how their cardinality contracts relate** (`||--||` exact one, `||--o{` zero-or-many, `||--|{` one-or-many, `||--o|` zero-or-one), using clear domain terms rather than raw physical column types (`varchar_64`, `bytea`).

## Canonical Example: Multi-Frequency Order & Audit Ledgers

```mermaid
erDiagram
    CUSTOMER_ACCOUNT ||--o{ ORDER_LEDGER : "发起并归属"
    ORDER_LEDGER ||--|{ ORDER_LINE_ITEM : "包含商品明细"
    ORDER_LEDGER ||--o{ PAYMENT_ATTEMPT_LOG : "关联扣款尝试与回执"
    ORDER_LEDGER ||--o| SHIPMENT_DISPATCH : "支付成功后触发履约"

    CUSTOMER_ACCOUNT {
        string 客户唯一标识 PK "全局客户主标识"
        string 实名认证状态 "低频变更：身份与风控等级"
    }

    ORDER_LEDGER {
        string 订单唯一编号 PK "业务主单号"
        string 客户端幂等键 UK "防重复下单唯一凭据"
        string 订单当前状态 "待支付 / 处理中 / 已支付 / 已取消"
    }

    ORDER_LINE_ITEM {
        string 明细项编号 PK "单品行号"
        string 锁定单价与数量 "下单瞬间的价格快照"
    }

    PAYMENT_ATTEMPT_LOG {
        string 支付流水号 PK "对应支付网关 PaymentIntent"
        string 渠道受理回执状态 "已认领 / 需3DS验证 / 已入账 / 拒付"
    }

    SHIPMENT_DISPATCH {
        string 履约发货单号 PK "仓储发货凭据"
        string 物流追踪状态 "待出库 / 运输中 / 已签收"
    }
```

![Order & Audit Ledgers ER Diagram](../assets/10_order_erd_ledgers.png)

---

**Return to Caller**: Return with the selected `erDiagram` ledger schema to [SKILL.md](../SKILL.md) (§2 & §5) to complete single-track artifact delivery, then resume the calling host workflow.
