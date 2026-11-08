# Domain Model & Deep Module Contracts (`classDiagram`)

> **Unified Rules**: See [SKILL.md](../SKILL.md) (§2.2) for scale discipline (`5–15` core nodes) and **Template 1 (C4 Level 3 Component View)**.

When using `classDiagram` for non-technical or cross-functional readers, represent **Domain Concepts and C3 Deep Module Interface Contracts** (in plain business language) rather than low-level data types (`uint64`, `varchar`) or private helper methods. Use ASCII identifiers with Chinese display labels (`class OrderService["订单编排模块"]`) for full parser compatibility.

## Canonical Example: E-Commerce Order & Payment Domain Contracts

```mermaid
classDiagram
    direction TB

    class OrderService["订单编排模块 (Order Service)"] {
        <<C3 深模块>>
        +执掌真相：订单全生命周期状态与幂等键
        +提交结账请求(购物车凭证, 幂等键) 订单摘要
        +处理支付成功回调(支付事件凭据) 履约指令
        +取消超时未付订单(订单号) 释放库存结果
    }

    class InventoryService["库存预占模块 (Inventory Service)"] {
        <<C3 深模块>>
        +执掌真相：可售库存水位与预占锁
        +预占商品库存(订单号, 商品清单) 预占凭据
        +确认扣减库存(预占凭据) 扣减结果
        +回滚释放库存(预占凭据) 释放结果
    }

    class PaymentAdapter["支付网关防腐适配器 (Payment Adapter)"] {
        <<C3 边界适配器>>
        +执掌真相：外部支付渠道协议映射与验签
        +创建支付意图(订单号, 应付金额) 客户端支付密钥
        +核验异步回调签名(原始报文, 签名头) 标准支付事件
    }

    OrderService --> InventoryService : ① 先锁定可售库存
    OrderService --> PaymentAdapter : ② 再创建支付意图 / 核验回调
```

![Domain Model & Deep Module Contracts](../assets/09_domain_class_contracts.png)

---

**Return to Caller**: Return with the selected `classDiagram` contract template to [SKILL.md](../SKILL.md) (§2 & §5) to complete single-track artifact delivery, then resume the calling host workflow.
