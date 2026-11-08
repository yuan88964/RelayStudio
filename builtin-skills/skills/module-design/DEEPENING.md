# Deepening Code Modules Across Dependencies

Code-specific operation (`Operation A1`) for [`module-design`](SKILL.md). Use when deepening a cluster of shallow code modules, choosing test stand-ins across a seam, or pruning redundant unit tests after a refactor. Assumes the vocabulary in [SKILL.md](SKILL.md): **Module**, **Interface**, **Seam**, **Adapter**, **Depth**, **Leverage**, **Locality**.

## 1. Four Dependency Categories & Adapter Strategy

When assessing a code candidate for deepening, classify its external dependencies. The category determines where the **Seam** goes and how the deepened module is verified in a `1–3s` tight loop:

| Dependency Category | Examples | Seam & Adapter Strategy | Tight-Loop (`1–3s`) Verification |
| :--- | :--- | :--- | :--- |
| **1. In-process** | Pure computation, in-memory state machines, parsers, domain rules with no I/O | **No adapter needed.** Merge the shallow modules and test directly through the new public interface. | Direct function/method calls against the external interface. |
| **2. Local-substitutable** | Postgres (`PGLite` / SQLite in-memory), filesystem (in-memory FS / `tmp_path`) | **Internal seam only.** Do not pollute the module's public interface with a port just for testing; swap the local stand-in inside the test fixture. | Run the module against the fast local stand-in (`tmp_path`, `127.0.0.1:0`). |
| **3. Remote but owned**<br>*(Ports & Adapters)* | Your own microservices, internal RPC/HTTP APIs, message queues | **Define a Port (interface) at the seam.** The deep module owns the business logic; inject transport as an **Adapter** (HTTP/gRPC adapter in production, in-memory adapter in tests). | Plug the in-memory adapter into the port and verify end-to-end domain behavior in milliseconds. |
| **4. True external**<br>*(Third-party Mock)* | Stripe, Twilio, OAuth providers, external LLM APIs | **Injected Port + Mock Adapter.** Take the third-party boundary as an injected port and provide a deterministic SDK-style mock or recorded replay adapter in tests. | Assert observable domain outcomes and outbound port payloads without live network calls. |

## 2. Seam Discipline

- **One adapter means a hypothetical seam; two adapters mean a real one.** Never introduce an abstract interface/port unless at least two concrete adapters exist (typically production transport + fast test stand-in, or multi-host adapters). A single-adapter port is pure pass-through indirection.
- **Internal seams vs. external seams.** A deep module may use internal seams private to its implementation, but never expose internal collaborators on the public interface just so existing shallow tests can reach them.

## 3. Testing Strategy: Replace, Don't Layer

- **Delete obsolete shallow tests**: Once behavior is covered by tests at the deepened module's public interface, old unit tests targeting merged internal helpers become implementation-coupled waste—**delete them** rather than maintaining two layers.
- **The interface is the test surface**: Assert strictly on observable return values, state transitions, and outbound port calls across the public seam.
- **Survive internal refactors**: If restructuring private helpers inside the module breaks a test while external behavior is unchanged, the test is reaching past the seam—rewrite or delete it.

**Return to Caller**: Fold the selected dependency category, adapter strategy, and list of shallow tests to replace into Line 3 and Line 5 of the **5-Line Module Blueprint** in [SKILL.md](SKILL.md), then resume the calling workflow (`tdd`, `develop`, `to-spec`, or `improve-codebase-architecture`).
