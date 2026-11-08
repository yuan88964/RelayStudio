---
name: tdd
description: Test-driven development. Use when the user wants to build features or fix bugs test-first, mentions "red-green-refactor", or wants integration tests.
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/tdd/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-07"
---

# Test-Driven Development (`tdd`)

Focused worker skill that drives the `RED → GREEN → REFACTOR` loop at a clean module seam (`1–3s` tight feedback). When exploring the codebase, read `GLOSSARY.md` (if present) so test names and interface vocabulary match the project's domain language, and respect ADRs in the area touched.

- **`Standard` (Pre-agreed seam & dependency stand-in)**: When `SPEC.md`, the ticket, or conversation already locked the public interface, 3-state contract, and `1–3s` test command, execute the vertical `RED → GREEN → REFACTOR` loop (`§2`) directly.
- **`Normalize` (Unsettled test seam, hard-to-mock setup, or shallow internals)**: Invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A, Operation A1`) as a bounded subroutine (`§1`) to obtain a **5-Line Module Blueprint**, consume Lines 2, 3, and 5 inline to lock the seam or replace shallow tests, then resume the loop here.
- **`Bailout` (`two_strike_stop` or blocked environment)**: After 2 consecutive attempts on the same root error without reducing the failing test count, revert the broken edit to the last green commit (`git reset --hard`) and emit a one-line `Error` and structured `Route` (`use | need | drop | amend-spec | ask-user`).

---

## 1. Seams & Dependency Stand-Ins (`1-Line Baseline` vs. `module-design` Subroutine)

A **seam** is the public boundary where callers and tests observe behavior without reaching inside implementation details. See [tests.md](tests.md) for observable-behavior exemplars and [mocking.md](mocking.md) for SDK-style boundary ports.

1. **1-Line Baseline (Routine cruise)**: Test directly at the highest agreed public interface using real in-process objects or local stand-ins (`tmp_path`, in-memory DB) and inject boundary ports only for true external I/O.
2. **Bounded Subroutine Call to [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A, Operation A1`)**:
   - **Pre-RED (Before writing the failing test)**: When no seam was specified, the interface signature is unsettled, or test setup requires mocking internal collaborators, invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A, Operation A1`) as a subroutine. Consume the returned **5-Line Module Blueprint** inline—**Line 2** (`Public Interface & 3-State Seam`), **Line 3** (`Hidden Internals & Adapters`), and **Line 5** (`Tight Verification Gate (1–3s)`)—and immediately write the failing test at that seam.
   - **Post-GREEN (`REFACTOR` / Deepening)**: When passing a slice exposes pass-through wrappers, parameter threading, or sprawling `if/else` cascades, invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A, Operation A1`) to deepen the module and apply `replace, don't layer` (delete obsolete shallow internal unit tests while keeping the external seam test green).

---

## 2. The Vertical `RED → GREEN → REFACTOR` Loop

Execute one vertical **tracer bullet** slice at a time (one behavior through schema, logic, and boundary):

1. **`RED` (Write one failing test at the seam)**: Write a single specification-style test (`"user can checkout with valid cart"`) against the public interface using an independent expected literal (`tests.md`), run the `1–3s` 1:1 test command, and watch it fail on the expected assertion.
2. **`GREEN` (Minimal implementation)**: Write only enough production code to pass the failing test, binding fixtures to isolated resources (`tmp_path`, isolated config, ephemeral port `127.0.0.1:0` with `finally` / `teardown` cleanup). Run the `1–3s` 1:1 test file plus the project's static typechecker (if configured) to confirm green.
3. **`REFACTOR` (Deepen & clean while green)**: Extract shared secrets, flatten `if/else` chains, or invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A, Operation A1`) to deepen shallow seams, re-running the `1–3s` tight loop after each move.
4. **Specification-bound assertions**: Fix production code to satisfy existing assertions; update an existing test assertion only when the requirement at that seam genuinely changed under an approved amendment.

---

## 3. Test Guardrails & Anti-Patterns to Replace

| Anti-Pattern | Observable Tell | Positive Replacement at the Seam |
| :--- | :--- | :--- |
| **Implementation-coupled** | Mocks internal collaborators, calls private methods, or queries a side channel (raw DB row instead of `getUser()`). Breaks on internal refactors. | Assert observable outputs returned through the public interface ([tests.md](tests.md)). |
| **Tautological assertion** | Recomputes the expected value using the same formula as production code (`expect(add(a, b)).toBe(a + b)`). | Assert against an independent known-good literal or worked spec example ([tests.md](tests.md)). |
| **Horizontal bulk testing** | Writes all tests up front before any implementation, testing imagined structure. | Slice vertically: one failing test $\to$ one green implementation $\to$ repeat. |
| **Generic conditional mock** | Mocks a single `fetch(url, opts)` with `if/else` URL branches inside test setup. | Define an explicit SDK-style port with one method per external operation ([mocking.md](mocking.md)). |

---

## 4. Completion Criterion & Caller Override Seam (`Recency Peak`)

### Completion Criterion
A `tdd` run is complete when:
1. Every requested behavior slice has a passing observable-behavior test at its public seam;
2. The `1–3s` 1:1 test command and static typechecker exit `0` with zero leaked background processes or temp state;
3. Any internal adaptation or blast-radius test sync is logged under `## Accepted Amendments & Internal Adaptations` (or returned via `Bailout` `Error` + `Route` on `two_strike_stop`).

### Caller Override Seam
When `tdd` is invoked by an upper orchestrator (such as `develop`), follow the caller's injected parameters for **Verification Scope** (`Worktree Mode` running only the `1–3s` 1:1 test file + static typecheck vs. `Single-Slice Mode` adding `Blast Radius` and closeout checks) and **Return Format** (recording internal adaptations under `## Accepted Amendments & Internal Adaptations` and returning a 6-line handoff) and immediately return control to the caller. When invoked standalone, run the `1–3s` tight loop + static typecheck and report the verified test files directly.
