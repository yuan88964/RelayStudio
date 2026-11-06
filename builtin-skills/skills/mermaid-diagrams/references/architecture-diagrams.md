# Cloud & Deployment Topology (`flowchart TB` Deployment View)

> **Unified Rules**: See [SKILL.md](../SKILL.md) for C4/arc42 deployment seams, Tufte semantic layering, and unidirectional verb + `[协议]` edge contracts.

## Canonical Example: Edge-to-Database Cloud Deployment Topology

Use `flowchart TB` with semantic color palettes (`edge` / `app` / `data`) and role badges (`[边缘接入层]` / `[核心容器层]` / `[数据存储层]`) so every network hop carries an explicit action verb and transport protocol without outer box clutter:

```mermaid
flowchart TB
    classDef edge fill:#EFF6FF,stroke:#2563EB,stroke-width:2px,color:#1E3A8A
    classDef app fill:#F0FDF4,stroke:#16A34A,stroke-width:2px,color:#14532D
    classDef data fill:#FEFCE8,stroke:#CA8A04,stroke-width:2px,color:#713F12

    CDN["<b>🌐 边缘内容分发网络 (CDN)</b><br/>[边缘接入层 · Cloudflare Edge]<br/>职责：就近缓存静态资源并吸收大流量攻击"]:::edge
    WAF["<b>🛡️ 安全接入与限流网关 (WAF / API Gateway)</b><br/>[边缘接入层 · Envoy Ingress]<br/>职责：统一卸载 TLS、校验访问令牌并执行速率限制"]:::edge

    API["<b>⚙️ 交易编排服务集群 (Order API Pods)</b><br/>[核心容器层 · Stateless Containers]<br/>职责：同步处理客户结账请求并协调库存预占"]:::app
    Worker["<b>🔄 异步履约工作节点 (Fulfillment Workers)</b><br/>[核心容器层 · Background Consumers]<br/>职责：异步消费支付成功事件并生成电子凭证"]:::app

    Cache[("<b>⚡ 分布式内存缓存 (Redis Cluster)</b><br/>[数据存储层] 职责：存储高频会话与幂等防重锁")]:::data
    DB[("<b>🗄️ 高可用主从关系库 (PostgreSQL HA)</b><br/>[数据存储层] 职责：持久化订单主账本与资金流水")]:::data
    Store[("<b>📦 电子凭证对象存储 (S3 Bucket)</b><br/>[数据存储层] 职责：归档已签发的 PDF 结算单")]:::data

    CDN -->|"① 回源转发动态业务请求 [HTTPS/TLS 1.3]"| WAF
    WAF -->|"② 路由已鉴权流量至内部服务 [gRPC]"| API
    API -->|"③ 校验并写入幂等防重锁 [RESP]"| Cache
    API -->|"④ 事务写入订单主账本 [JDBC/TLS]"| DB
    API -.->|"⑤ 异步派发待履约任务消息"| Worker
    Worker -->|"⑥ 读取订单明细并更新履约状态 [JDBC]"| DB
    Worker -->|"⑦ 上传归档生成的电子结算单 [HTTPS API]"| Store
```

![Edge-to-Database Cloud Deployment Topology](../assets/11_cloud_deployment_topology.png)
