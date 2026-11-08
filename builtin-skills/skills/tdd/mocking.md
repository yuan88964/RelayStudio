# Boundary Port & Mocking Exemplars

> **Unified Rules**: See [SKILL.md](SKILL.md) (`§1`) and `module-design` (`Branch A, Operation A1`) for the 4-category dependency stand-in matrix (`In-process` real objects, `Local-substitutable` temp/in-memory adapters, `Remote but owned` ports & adapters, and `True external` boundary mocks) and constructor/parameter dependency injection.

## Prefer SDK-Style Boundary Ports Over Generic Fetchers

At true external system boundaries (payment gateways, email providers, third-party HTTP APIs), define specific port functions for each domain operation rather than mocking a generic `fetch(endpoint, options)` client:

```typescript
// GOOD: Each boundary operation is an explicit, independently mockable port method
const api = {
  getUser: (id: string) => fetch(`/users/${id}`),
  getOrders: (userId: string) => fetch(`/users/${userId}/orders`),
  createOrder: (data: OrderInput) => fetch('/orders', { method: 'POST', body: JSON.stringify(data) }),
};

// BAD: Mocking requires URL-matching conditional logic inside test setup
const api = {
  fetch: (endpoint: string, options?: RequestInit) => fetch(endpoint, options),
};
```

Why the SDK-style port keeps tests deep and maintainable:
- Each test stub returns one deterministic shape with zero conditional `if (url === ...)` branching in test setup;
- Call sites declare exactly which external capabilities they exercise;
- Static typechecking enforces input/output contracts per operation at the seam.

**Return to Caller**: Apply the SDK-style port pattern at true external boundaries and return to [SKILL.md](SKILL.md) (`§2`) to write the next vertical `RED → GREEN → REFACTOR` slice.
