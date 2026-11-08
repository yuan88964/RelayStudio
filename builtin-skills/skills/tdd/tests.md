# Observable-Behavior vs. Implementation-Coupled Test Exemplars

> **Unified Rules**: See [SKILL.md](SKILL.md) (`§1–§3`) for test seam selection, the vertical `RED → GREEN → REFACTOR` loop, and the anti-pattern replacement table.

## 1. Observable Behavior at the Public Seam (Target)

Test capability through the public interface so internal refactors never break the test:

```typescript
// GOOD: Verifies user-observable outcome at the public seam
test("user can checkout with valid cart", async () => {
  const cart = createCart();
  cart.add(product);
  const result = await checkout(cart, paymentMethod);
  expect(result.status).toBe("confirmed");
});
```

## 2. Implementation-Detail & Side-Channel Coupling (Replace)

```typescript
// BAD: Mocks internal collaborator and asserts on internal call wiring
test("checkout calls paymentService.process", async () => {
  const mockPayment = jest.mock(paymentService);
  await checkout(cart, payment);
  expect(mockPayment.process).toHaveBeenCalledWith(cart.total);
});

// BAD: Bypasses the module interface to verify via raw DB side channel
test("createUser saves to database", async () => {
  await createUser({ name: "Alice" });
  const row = await db.query("SELECT * FROM users WHERE name = ?", ["Alice"]);
  expect(row).toBeDefined();
});

// GOOD: Verifies persistence through the module's own retrieval interface
test("createUser makes user retrievable", async () => {
  const user = await createUser({ name: "Alice" });
  const retrieved = await getUser(user.id);
  expect(retrieved.name).toBe("Alice");
});
```

## 3. Independent Literal vs. Tautological Recomputation

```typescript
// BAD: Recomputes expected value using the same formula as production code
test("calculateTotal sums line items", () => {
  const items = [{ price: 10 }, { price: 5 }];
  const expected = items.reduce((sum, i) => sum + i.price, 0);
  expect(calculateTotal(items)).toBe(expected);
});

// GOOD: Asserts against an independent, known literal from the spec
test("calculateTotal sums line items", () => {
  expect(calculateTotal([{ price: 10 }, { price: 5 }])).toBe(15);
});
```

**Return to Caller**: Use these observable-behavior and independent-literal patterns to write the failing test in [SKILL.md](SKILL.md) (`§2`).
