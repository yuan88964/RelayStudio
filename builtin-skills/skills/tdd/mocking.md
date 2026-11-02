# 何时使用替身与模拟（Mock）

仅在**系统外部边界**处使用 Mock：

- 外部第三方 API（支付、邮件等服务）
- 数据库（按需使用；优先使用真实测试数据库或内存**接缝适配实现**）
- 时间与随机源
- 文件系统（按需使用）

不要 Mock：

- 你自己的类或**模块**
- 模块内部协作者
- 任何由你自身掌控的代码

## 为可替换与易模拟性而设计

在系统边界处，将**接口契约**设计在清晰的**可替换接缝**上，使其易于注入测试替身：

**1. 使用依赖注入**

通过参数显式传入外部依赖，而非在函数内部硬编码创建：

```typescript
// Easy to mock
function processPayment(order, paymentClient) {
  return paymentClient.charge(order.total);
}

// Hard to mock
function processPayment(order) {
  const client = new StripeClient(process.env.STRIPE_KEY);
  return client.charge(order.total);
}
```

**2. 优先设计 SDK 风格的接口契约，而非泛用请求器**

为每项外部操作提供语义明确的具体函数，而非暴露需要条件分支判定的泛用请求入口：

```typescript
// GOOD: Each function is independently mockable
const api = {
  getUser: (id) => fetch(`/users/${id}`),
  getOrders: (userId) => fetch(`/users/${userId}/orders`),
  createOrder: (data) => fetch('/orders', { method: 'POST', body: data }),
};

// BAD: Mocking requires conditional logic inside the mock
const api = {
  fetch: (endpoint, options) => fetch(endpoint, options),
};
```

采用 SDK 风格的**接口契约**意味着：

- 每个测试替身只需返回固定的数据结构
- 测试准备阶段无需编写复杂的条件分支逻辑
- 一眼即可看出测试触发了哪些具体操作入口
- 每个操作入口都具备独立的类型安全保障
