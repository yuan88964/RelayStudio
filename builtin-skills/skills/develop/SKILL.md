---
name: develop
description: End-to-end software development and concurrency orchestrator. Use for any coding, feature implementation, bug fix, refactoring, or test execution task, from a single direct slice to a multi-ticket concurrent spec graph.
disable-model-invocation: true
---

# Software Development & Concurrency Orchestrator (`develop`)

Top-level orchestrator for software implementation, refactoring, bug fixing, and verification. It sizes incoming requests, calls [`module-design`](../module-design/SKILL.md) to lock module seams and partition concurrency, drives atomic execution parts (`tdd`, `code-review`, `diagnosing-bugs`, `resolving-merge-conflicts`, `pr`) across either a single slice or a concurrent multi-ticket graph, and returns the verified branch, three-tier verification report, and any quarantined decisions.

---

## 0. Why Orchestrate: Seam-First Concurrency & Unattended Flow

Running a small localized edit through a heavy multi-ticket ledger wastes time; running a large multi-module build serially in one context window is slow and causes context rot; but dispatching parallel subagents without first cutting clean module boundaries causes **file collisions, mid-flight interface drift, redundant $N \times$ full-suite test timeouts, and one wedged task halting the entire build**.

This orchestrator solves all four failure modes through four governing rules:
1. **Seam-First Concurrency (via [`module-design`](../module-design/SKILL.md))**: Safe concurrency requires orthogonal module boundaries. Before dispatching parallel work—or whenever an interface is shallow or tangled—invoke [`module-design`](../module-design/SKILL.md) to obtain a **5-Line Module Blueprint**, lock shared interfaces on the `integration` baseline first, run **disjoint modules in parallel**, and queue **overlapping modules serially**.
2. **Local Tight Loop (`1–3s`), Single Global Gate**: Individual slices and worktree subagents run only their 1:1 `1–3s` test file plus static typecheck (`Tight Loop`); cross-module `Blast Radius` and the full test suite run **once** at branch or `integration` closeout ([testing.md](testing.md)).
3. **Unattended Bulkhead & Single-Writer Ledger**: Once the user gives go-ahead ("开工 / 执行" or `/develop`), execution runs **unattended without stopping mid-flight**. Non-breaking internal adaptations (Category 1) and approved blast-radius test syncs (Category 2) are decided autonomously and logged by the orchestrator (single writer) under `## Accepted Amendments & Internal Adaptations`; user-visible conflicts (Category 3) or branches still blocked after 1 clean-room relay (`two_strike_stop`) are isolated as `quarantined` while all unblocked work continues ([protocol.md](protocol.md)).
4. **Stage-Gated Internal Disclosure**: Read private sibling files strictly at the stage that needs them:
   - **[hosts.md](hosts.md)** — read **before dispatching subagents, launching `>45s` commands, or recording ledger checkpoints**;
   - **[testing.md](testing.md)** — read **when configuring test scope (`Worktree` vs. `Single-Slice` vs. `Integration Gate`) or accelerating slow suites**;
   - **[protocol.md](protocol.md)** — read **when processing 6-line subagent handoffs, recording amendments, or relaying `two_strike_stop` / `quarantined` branches**.

---

## 1. Three-State Entry Contract & Request Sizing (`Normalize / Standard / Bailout`)

1. **`Normalize` (establish clean boundaries at entry before coding)**:
   - **1-Line Baseline (80% routine runs)**: When `SPEC.md` or the conversation has already locked the public interface, 3-state contract (`Standard / Normalize / Bailout`), dependency stand-in, and orthogonal file set, proceed directly to `Standard`.
   - **Unsettled requirements or missing multi-ticket breakdown**: run the upfront specification chain ([`grilling`](../grilling/SKILL.md) $\to$ [`to-spec`](../to-spec/SKILL.md) $\to$ [`to-tickets`](../to-tickets/SKILL.md)) to crystallize `SPEC.md` and vertical-slice tickets.
   - **Unsettled module seams, interface redesign, or concurrency partitioning**: invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A`, `Operation A1/A2`) as a bounded subroutine to emit a **5-Line Module Blueprint** (`1. Modules & Scope`, `2. Public Interface & 3-State Seam`, `3. Hidden Internals & Adapters`, `4. Orthogonality & Concurrency`, `5. Tight Verification Gate (1–3s)`), then immediately resume here and consume Lines 1–3 & 5 for test seams and Line 4 for frontier partitioning.
   - **Hard bug without a fast reproduction loop**: invoke [`diagnosing-bugs`](../diagnosing-bugs/SKILL.md) first to establish a `1–3s` red-capable command before attempting code fixes.
   - **Homogeneous mechanical transform ($\ge 20$ independent files)**: normalize into a local worker script (`max_workers=4`) and dispatch subagents only for flagged exceptions.
2. **`Standard` (route by module concurrency topology)**:
   - **Single localized slice or small agreed change (no multi-ticket dependency graph)** $\to$ run **Branch A (Single-Slice Direct Flow)**.
   - **Multi-ticket task graph (`SPEC.md` + tickets with blocking edges)** $\to$ run **Branch B (Seam-Locked Concurrent Flow)**.
3. **`Bailout` (abort blocked slice cleanly with `Error` + `Route`)**:
   - When a slice hits `two_strike_stop` (after 1 clean-room relay), misses a required capability, or hits a Category 3 user-visible conflict, halt that slice cleanly and emit a one-line `Error` and structured `Route` (`use | need | drop | amend-spec | ask-user`) per [protocol.md](protocol.md).

---

## 2. Execution Workflows

### Branch A: Single-Slice Direct Flow (Fast Path, Zero Ticket Ceremony)

1. **Lock the test seam**:
   - Read `GLOSSARY.md` and relevant ADRs if present (if an existing ticket file was passed, mark it `in_progress`, otherwise work directly on the current branch without creating a temporary `.scratch/` ticket file).
   - **1-Line Baseline**: When the public interface, 3-state contract, dependency stand-in, and `1–3s` test command are already locked in conversation or ticket, proceed directly to Step 2. When unsettled, invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A`, `Operation A1/A2`) as a bounded subroutine returning a **5-Line Module Blueprint**, consume Lines 1–3 & 5 inline to lock the seam, and immediately continue here.
2. **Drive red-green slices with [`tdd`](../tdd/SKILL.md) (`Single-Slice Mode`)**:
   - Invoke [`tdd`](../tdd/SKILL.md) with `Caller Override: Verification Scope = Single-Slice Mode` ([testing.md](testing.md)):
     - Run **only** the single 1:1 target test file (`1–3s` `Tight Loop`) during red-green cycles, plus static typecheck once green;
     - Once all slices are green, run direct caller tests (`Blast Radius`) and a single closeout suite (using the **Long-Command Session Seam** in [hosts.md](hosts.md) if `> 45s`).
   - **Mid-flight architectural deepening**: If implementation or test setup exposes pass-through layers, parameter threading, or sprawling `if/else` cascades (`Route: use module-design`), pause coding, invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A`) as a bounded subroutine to deepen the seam first, and resume `tdd` inline.
   - If implementation hits `two_strike_stop`, revert to the last green commit (`git reset --hard`) and follow the 1-relay / `quarantined` protocol in [protocol.md](protocol.md).
3. **Commit candidate snapshot and run two-axis [`code-review`](../code-review/SKILL.md)**:
   - Commit all modified and newly created files (`git status --porcelain` clean) and run [`code-review`](../code-review/SKILL.md) against the base commit and `Effective Spec` (`Original Request/Spec ⊕ Accepted Amendments`).
   - Fix any hard Standards or Spec findings with another `tdd` slice (calling [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A`) if a finding requires structural deepening) and re-verify.
4. **Close out and report**:
   - If the workflow uses GitHub PRs, invoke [`pr`](../pr/SKILL.md) to write or update the PR, then complete the verification gate in `§3`.

---

### Branch B: Seam-Locked Concurrent Flow (`SPEC.md` + Multi-Ticket Graph)

1. **Read task graph & lock shared seams**:
   - Read `SPEC.md` and all tickets to determine blocking edges and the initial ready **frontier**; initialize tracking via the **Task Progress Ledger Seam** ([hosts.md](hosts.md)). If codebase-wide discovery is needed first, dispatch a read-only exploration subagent ([hosts.md](hosts.md)) to write a shared note outside the repo.
   - Create or switch to the `integration` branch. **1-Line Baseline**: When `SPEC.md` and ticket boundaries already lock shared interfaces and disjoint file sets, proceed directly to Step 2. When shared seams or module orthogonality are unsettled, invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A`, `Operation A1/A2`) as a bounded subroutine returning a **5-Line Module Blueprint**, consume Lines 1–3 inline to land shared interface definitions on `integration` first, and consume Line 4 (`Orthogonality & Concurrency`) in Step 2 to partition the frontier.
2. **Dispatch across the non-overlapping frontier ([hosts.md](hosts.md))**:
   - Partition ready frontier tickets using Line 4 (`Orthogonality & Concurrency`): dispatch tickets with **disjoint files and seams in parallel**, and queue tickets touching the **same files or shared contract serially**.
   - Read [hosts.md](hosts.md) and dispatch each ready ticket through the **Subagent Dispatch Seam** with a sparse pointer brief (`SPEC.md`, ticket path, `integration` base SHA, target files, and `Caller Override: Verification Scope = Worktree Mode [1–3s Tight Loop + static typecheck only], Return = 6-line handoff`).
   - Require each worktree subagent to follow this exact 3-step lifecycle:
     1. **Baseline check**: confirm the worktree branch is based on the latest `integration` tip and `git status --porcelain` is clean.
     2. **Worktree `tdd` & static typecheck**: execute [`tdd`](../tdd/SKILL.md) in **Worktree Mode** ([testing.md](testing.md): run only the 1:1 `1–3s` test file + static typecheck, skipping cross-module `Blast Radius` and full-suite runs; call [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A`) if local interface deepening is needed), then commit its branch snapshot.
     3. **Pre-report merge of `integration` tip**: merge the latest `integration` tip into the ticket branch (invoking [`resolving-merge-conflicts`](../resolving-merge-conflicts/SKILL.md) if conflicts arise, then re-running the 1:1 `Tight Loop` test and static typecheck) and emit the 6-line handoff ([protocol.md](protocol.md)).
3. **Process handoffs, digest amendments & advance frontier ([protocol.md](protocol.md))**:
   - Read [protocol.md](protocol.md) to handle each 6-line handoff:
     - **`Status: completed`**: merge the ticket branch into `integration` (open a Draft PR after the first merge if PRs are used), append any `Route: amend-spec` rows to `SPEC.md` under `## Accepted Amendments & Internal Adaptations` as **single writer**, propagate shared-seam updates if any, record a ledger checkpoint ([hosts.md](hosts.md)), and dispatch newly unblocked frontier tickets.
     - **`Status: two_strike_stop`** (including `Route: use module-design`): if `N_relay == 0`, rewrite `Route` as a positive instruction in a fresh clean-room brief (omitting failed diffs/stack traces) and dispatch **1** relay attempt; if `N_relay == 1` or missing a capability, mark `quarantined`.
     - **`Status: quarantined` (`Route: ask-user`)**: mark `quarantined` in the ledger, block only its direct/transitive dependents, and immediately continue dispatching all remaining unblocked frontier tickets.
4. **Single integration gate, two-axis `code-review` & closeout ([testing.md](testing.md))**:
   - Once all unblocked tickets merge into `integration`, read [testing.md](testing.md) and run the full test suite and static typecheck **once** on `integration` (using the 4-worker LPT runner and **Long-Command Session Seam** in [hosts.md](hosts.md) if `> 45s`).
   - Run [`code-review`](../code-review/SKILL.md) across the `integration` diff against the base branch and `Effective Spec` (`Original Spec ⊕ Accepted Amendments`). Fix any cross-ticket regressions or review violations via a `tdd` slice (calling [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A`) if structural deepening is needed) and re-verify.
   - Clean up temporary worktrees, update the PR via [`pr`](../pr/SKILL.md) if used, resolve completed tickets in the **Task Progress Ledger Seam** ([hosts.md](hosts.md)), and complete the verification gate in `§3`.

---

## 3. Completion Criterion & Verification Gate (`Recency Peak`)

Before declaring `develop` (Branch A or Branch B) complete and presenting the final report to the user, verify all 4 completion gates:
1. **Clean Git & Committed Snapshot**: `git status --porcelain` is empty, temporary worktrees are cleaned up, and the target branch or `integration` head commit SHA is recorded.
2. **Three-Tier Verification Summary ([testing.md](testing.md))**: Report exact outcomes across `Tier 1 (Synthetic / Automated Tests + Static Typecheck)`, `Tier 2 (Live External API / Tunnel Integration)`, and `Tier 3 (Real-Machine UI / Desktop Interaction)`, marking any unrun tier explicitly as `Not run (<reason>)`.
3. **Two-Axis `code-review` Clean**: Both `Standards` and `Spec` review axes report zero unresolved violations against `Effective Spec` (`Original Spec ⊕ Accepted Amendments`).
4. **Consolidated Ledger & Decision Tables ([protocol.md](protocol.md))**: Include the `Accepted Amendments & Internal Adaptations` table (Categories 1 & 2) and, if any slice or ticket was quarantined, a consolidated `Quarantined Decisions` table (`Ticket/Slice`, `Error`, `Route: ask-user <decision>`) for user resolution.
