# 好测试与坏测试

## 好测试

**契约集成风格**：通过真实的对外**接口契约**进行验证，而非拆碎模拟**模块**内部部件。

```typescript
// GOOD: Tests observable behavior
test("user can checkout with valid cart", async () => {
  const cart = createCart();
  cart.add(product);
  const result = await checkout(cart, paymentMethod);
  expect(result.status).toBe("confirmed");
});
```

核心特征：

- 验证用户或调用方真正关心的可观测行为
- 仅通过对外公开的**接口契约**（**接口测试面**）交互
- 在**内部实现**重构时保持稳健
- 描述“做什么（WHAT）”，而非“怎么做（HOW）”
- 每条测试聚焦一个逻辑断言

## 坏测试

**耦合实现细节的测试**：与模块的**内部实现**结构强绑定。

```typescript
// BAD: Tests implementation details
test("checkout calls paymentService.process", async () => {
  const mockPayment = jest.mock(paymentService);
  await checkout(cart, payment);
  expect(mockPayment.process).toHaveBeenCalledWith(cart.total);
});
```

危险信号：

- 模拟内部协作者
- 直接测试私有方法
- 对内部调用次数或调用顺序做断言
- 重构后外部行为未变，测试却随之失败
- 测试名称描述内部实现步骤（HOW），而非业务能力（WHAT）
- 绕过**接口契约**通过旁路通道验证状态

```typescript
// BAD: Bypasses interface to verify
test("createUser saves to database", async () => {
  await createUser({ name: "Alice" });
  const row = await db.query("SELECT * FROM users WHERE name = ?", ["Alice"]);
  expect(row).toBeDefined();
});

// GOOD: Verifies through interface
test("createUser makes user retrievable", async () => {
  const user = await createUser({ name: "Alice" });
  const retrieved = await getUser(user.id);
  expect(retrieved.name).toBe("Alice");
});
```

**同义反复测试**：期望值直接复述了被测代码的**内部实现**逻辑，导致测试天然通过、失去校验能力。

```typescript
// BAD: Expected value is recomputed the way the code computes it
test("calculateTotal sums line items", () => {
  const items = [{ price: 10 }, { price: 5 }];
  const expected = items.reduce((sum, i) => sum + i.price, 0);
  expect(calculateTotal(items)).toBe(expected);
});

// GOOD: Expected value is an independent, known literal
test("calculateTotal sums line items", () => {
  expect(calculateTotal([{ price: 10 }, { price: 5 }])).toBe(15);
});
```
