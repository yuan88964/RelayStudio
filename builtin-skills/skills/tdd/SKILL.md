---
name: tdd
description: Test-driven development. Use when the user wants to build features or fix bugs test-first, mentions "red-green-refactor", or wants integration tests.
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/tdd/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-06"
---

# Test-Driven Development

TDD is the red → green loop. This skill is the reference that makes that loop produce tests worth keeping: what a good test is, where tests go, the anti-patterns, and the rules of the loop. Every section applies on every cycle: consult them before and during the loop, not after.

When exploring the codebase, read `GLOSSARY.md` (if it exists) so test names and interface vocabulary match the project's domain language, and respect ADRs in the area you're touching.

## What a good test is

Tests verify behavior through public interfaces, not implementation details. Code can change entirely; tests shouldn't. A good test reads like a specification: "user can checkout with valid cart" tells you exactly what capability exists, and it survives refactors because it doesn't care about internal structure.

See [tests.md](tests.md) for examples and [mocking.md](mocking.md) for mocking guidelines.

## Seams: where tests go

A **seam** is the public boundary you test at: the interface where you observe behavior without reaching inside. Tests live at seams, never against internals.

**Test only at pre-agreed seams.** When the caller (`develop`, `SPEC.md`, a ticket file, or a dispatch brief) specifies the seams under test, use those seams directly. If no seam was specified, select the highest existing public seam that exercises the target behavior and record that choice under `## Accepted Amendments & Internal Adaptations` (or state it as an explicit assumption) rather than stopping mid-run to ask the user.

When the shape of that interface is itself in question (how deep the module is, where the seam belongs, what the interface should expose, or how to flatten branching), call the Skill tool with `"codebase-design"` ([`../codebase-design/SKILL.md`](../codebase-design/SKILL.md)). It is the shared source of the module, interface, depth, seam, adapter, leverage, and locality terms, plus the `Gather / Split / Polish` deepening rules, and it is a reference to consult, not a session to run.

## Anti-patterns

- **Implementation-coupled**: mocks internal collaborators, tests private methods, or verifies through a side channel (querying the database instead of using the interface). The tell: the test breaks when you refactor but behavior hasn't changed.
- **Tautological**: the assertion recomputes the expected value the way the code does (`expect(add(a, b)).toBe(a + b)`, a snapshot derived by hand the same way, a constant asserted equal to itself), so it passes by construction and can never disagree with the code. Expected values must come from an independent source of truth: a known-good literal, a worked example, the spec.
- **Horizontal slicing**: writing all tests first, then all implementation. Bulk tests verify _imagined_ behavior: you test the _shape_ of things rather than user-facing behavior, the tests go insensitive to real changes, and you commit to test structure before understanding the implementation. Work in **vertical slices** instead: one test → one implementation → repeat, each test a **tracer bullet** that responds to what the last cycle taught you.

## Rules of the loop

- **Red before green.** Write the failing test first, then only enough code to pass it. Don't anticipate future tests or add speculative features.
- **One slice at a time.** One seam, one test, one minimal implementation per cycle.
- **Tight feedback.** Run only the single 1:1 test file under edit (`Tight Loop`, `1–3s`) on each cycle, plus the project's static typechecker (if configured) once the slice is green; defer broader verification (`Blast Radius` or full suite) to the scope configured by the caller (see `## Container Seams` below).
- **Isolated fixtures.** Bind each test to its own temp directory, config, and ephemeral port (`127.0.0.1:0`), and tear down spawned processes or headless browsers in `finally` / `teardown` so parallel worktrees never collide.
- **Specification-bound assertions.** Fix production code to pass existing tests; update an existing assertion only when the requirement at that seam genuinely changed (Category 2 test-radius sync or user-approved amendment recorded under `Accepted Amendments & Internal Adaptations`).
- **Two-strike stop (`two_strike_stop`).** After two consecutive attempts on the same root error without progress (failing test count not decreasing; excluding normal red-green steps and transport timeouts), revert the broken edit to the last green commit (`git reset --hard`), log the falsified approach in the ticket's `Attempt Log`, and exit via the Blocked/Failure Exit seam (`Status: two_strike_stop`, `Error`, and `Route`).
- **Refactoring is not part of the loop.** It belongs to the review stage (see the `code-review` skill), not the red → green implementation cycle.

## Container Seams (Unattended & Orchestrated Execution)

`tdd` leaves five execution seams open so any caller (an orchestrator, a worktree subagent, or direct invocation) can plug in without interactive human prompts:

| Seam | Caller Override (When Orchestrated) | Unattended Default (When Unspecified) |
| :--- | :--- | :--- |
| **1. Decision / Seam Source** | `SPEC.md` (`Original Spec + Accepted Amendments`), ticket file, or dispatch brief. | Pick the highest existing public interface seam and log it under `## Accepted Amendments & Internal Adaptations`; never block on user confirmation. |
| **2. Tight-Loop Command** | Passed in the dispatch brief (with worktree-local `PYTHONPATH` / module path and optional static typecheck command). | Discover from repo config (`package.json`, `pytest.ini`, `pyproject.toml`, `tsconfig.json`) targeting only the single test file under edit plus static typecheck if configured. |
| **3. Verification Scope** | **Worktree Mode**: `1–3s` 1:1 `Tight Loop` test file + static typecheck only.<br>**Single-Slice Mode**: `Tight Loop` + static typecheck + `Blast Radius` + closeout full suite. | Run the 1:1 `Tight Loop` test file and static typecheck (if configured) only. |
| **4. Blocked / Failure Exit** | Revert to last green commit (`git reset --hard`), log 3 lines in `Attempt Log`, and emit `Status: two_strike_stop` or `Status: quarantined` (`Route: ask-user <decision>`). | Same (`git reset --hard` + emit `Error` and `Route`; never pause mid-loop waiting for human input). |
| **5. Output / Ledger Destination** | Caller-specified handoff schema (e.g. 6-line handoff) + ticket file (`Accepted Amendments` / `Attempt Log`). | Concise summary of slices completed, test files verified, and any `Error` / `Route`. |
