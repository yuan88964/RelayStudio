---
name: develop
description: End-to-end software development and testing orchestrator. Use for any coding, feature implementation, bug fix, refactoring, or test execution task, from a single direct change to a multi-ticket spec graph.
disable-model-invocation: true
---

# Software Development & Testing Module

Single entry point for software implementation, refactoring, bug fixing, and verification. Callers provide a request, settled conversation decisions, a bug report, or a `SPEC.md` + ticket graph; this module sizes the work, drives its reusable execution parts (`tdd`, `code-review`, `codebase-design`, `diagnosing-bugs`, `resolving-merge-conflicts`, `pr`) across either a single slice or a multi-ticket graph, and returns the resulting branch, three-tier verification report, and any quarantined decisions requiring user input.

Once invoked after user go-ahead, execution runs **unattended without stopping to ask mid-flight**: non-breaking internal adaptations (Category 1) and approved blast-radius test syncs (Category 2) are decided autonomously and logged under `## Accepted Amendments & Internal Adaptations`; issues that would alter user-visible behavior or weaken acceptance assertions (Category 3) or exceed 1 clean-room relay (`two_strike_stop`) are marked `quarantined` while all remaining unblocked work continues, then surfaced together at the end ([protocol.md](protocol.md)).

## Scope, Normalization, and Transfer Contract

1. **Typical inputs (handle directly)**:
   - **Small / single-slice change**: a single localized ticket or small feature/fix with settled decisions, without a multi-ticket dependency graph.
   - **Multi-ticket spec graph**: a `SPEC.md` and associated tickets with blocking relationships (`Blocked by`).
2. **Non-typical inputs (normalize first, then handle)**:
   - **Homogeneous bulk scan or mechanical transform ($\ge 20$ independent files)**: normalize into a local worker script (`max_workers=4`) and dispatch subagents only for flagged exceptions.
   - **Module boundary, state ledger, or interface redesign**: normalize interface seams, flatten case-by-case branching, and design concurrency isolation first using the [`codebase-design`](../codebase-design/SKILL.md) skill before writing code.
   - **Hard bug without a reproduction loop**: normalize via the `diagnosing-bugs` skill to establish a single red command before attempting fixes.
3. **Out-of-bounds or blocked cases (stop note + transfer route)**:
   - Unattended execution never blocks on the user. When a step hits two consecutive same-root-cause failures (`two_strike_stop`), misses a required capability, or encounters a spec/credential conflict, it halts cleanly and outputs a one-line `Error` and structured `Route` (`use`, `need`, `drop`, `amend-spec`, or `ask-user`) per [protocol.md](protocol.md).

## Internal Reference Files (Load on Demand by Branch)

- **[testing.md](testing.md)**: Three-tier test cadence (`Tight Loop` + static typecheck vs `Blast Radius` vs single `Integration` run), isolated fixtures, `>45s` background session observation via the **Long-Command Session Seam**, and the slow-test acceleration toolbox.
- **[protocol.md](protocol.md)**: Unattended execution rule, unified lowercase status vocabulary, 6-line handoff schema, `Route` transfer actions, clean-room relay brief rules, three-category change digestion, single-writer `## Accepted Amendments`, failure signal classification, and the **Task Progress Ledger Seam**.
- **[hosts.md](hosts.md)**: Concrete host adapter matrix for the three abstract host capability seams (**Subagent Dispatch Seam**, **Long-Command Session Seam**, **Task Progress Ledger Seam**) and single-tunnel snapshot/patch contention offloading.

---

## Workflow

### 1. Size the Request

Inspect the prompt and workspace:

- **Single localized ticket or small agreed change (no multi-ticket dependency graph)** → run **Branch A (Small / Single-Slice Flow)**.
- **Multi-ticket task graph (`SPEC.md` + tickets with blocking edges)** → run **Branch B (Multi-Ticket Task Graph Flow)**.

---

### Branch A: Small / Single-Slice Flow

1. **Anchor decisions in a local ticket file**:
   - If a ticket file already exists, read it and set `Status: in_progress` via the **Task Progress Ledger Seam** ([hosts.md](hosts.md)).
   - If the request comes directly from settled conversation decisions without a written ticket, write a concise local ticket file first (under `.scratch/<slug>/issues/01-<slug>.md`, using the template in `to-tickets`) so test seams, acceptance criteria, `Accepted Amendments`, and `Attempt Log` have a persistent on-disk ledger.
2. **Explore and lock the test seam**:
   - Read `GLOSSARY.md` and relevant ADRs if present; consult `codebase-design` when designing or adjusting a module interface.
   - Use the test seam specified in the ticket/conversation, or select the highest existing public seam and record it under `## Accepted Amendments & Internal Adaptations` without stopping to ask the user.
3. **Drive red-green slices with `tdd` (Single-Slice Verification Scope)**:
   - Call the `tdd` skill on the current branch with `Verification Scope = Single-Slice Mode` ([testing.md](testing.md)):
     - Run **only** the single 1:1 target test file (`Tight Loop`, `1–3s`) on each red → green cycle, plus the project's static typechecker (if configured) once the slice is green;
     - Once all slices are green, run direct caller tests (`Blast Radius`) and a single closeout test run (using the **Long-Command Session Seam** in [hosts.md](hosts.md) if `> 45s`);
   - Record any Category 1 internal adaptation or Category 2 blast-radius test sync under `## Accepted Amendments & Internal Adaptations`.
   - If implementation hits `two_strike_stop` ([testing.md](testing.md)): revert to the last green commit (`git reset --hard`), record the 3-line entry in `Attempt Log`, and relay at most once (`N_relay <= 1`) with a clean-room brief rewritten from `Route` ([protocol.md](protocol.md)); if still blocked or hitting a Category 3 user-visible conflict, mark `Status: quarantined` with `Error` and `Route`.
4. **Commit candidate snapshot and run `code-review`**:
   - Commit all modified and newly created files on the branch, verify `git status --porcelain` is clean, and run the `code-review` skill against the base commit and Effective Spec (`Original Ticket/Spec ⊕ Accepted Amendments`).
   - Address any hard Standards or Spec findings with another `tdd` slice and re-verify.
5. **Close out and report**:
   - If the tracker or user workflow uses GitHub PRs, invoke the [`pr`](../pr/SKILL.md) skill to write the PR body and open or update the PR.
   - Mark the ticket `completed` (or `quarantined` if halted) via the **Task Progress Ledger Seam** ([hosts.md](hosts.md)) and report the branch/commit, three-tier verification status ([testing.md](testing.md)), `Accepted Amendments`, and any `quarantined` decision items.

---

### Branch B: Multi-Ticket Task Graph Flow (`SPEC.md` + Ticket Graph)

1. **Read the task graph and initialize ledger**:
   - Read `SPEC.md` and all tickets to determine blocking edges and the initial ready **frontier**.
   - Initialize step tracking via the **Task Progress Ledger Seam** ([protocol.md](protocol.md), [hosts.md](hosts.md)).
2. **Optional upfront exploration**:
   - If tickets require codebase-wide or external doc discovery, dispatch a read-only exploration subagent via the **Subagent Dispatch Seam** ([hosts.md](hosts.md)) to write a shared markdown note outside the repo so implementers stay focused on code.
3. **Create the `integration` branch and lock shared seams**:
   - Create or switch to the `integration` branch.
   - Land any shared interface definitions, types, or prefactoring blockers directly on `integration` first (consulting `codebase-design` if needed) so parallel frontier tickets branch from a locked seam.
4. **Dispatch across the ready frontier**:
   - Select ready tickets whose touched files and shared contracts do not overlap. Tickets touching the same files or the same shared contract must run serially.
   - Dispatch each ticket through the **Subagent Dispatch Seam** ([hosts.md](hosts.md)) with a sparse pointer brief (`SPEC.md`, ticket path, `integration` base SHA, target file paths, and 1:1 `Tight Loop` test command).
   - Require each worktree subagent to follow this exact lifecycle:
     1. **Worktree baseline check**: before editing, verify the worktree branch is based on the latest `integration` branch (resetting onto `integration` if not) and that `git status --porcelain` is clean.
     2. **Worktree `tdd` & static typecheck**: execute `tdd` in **Worktree Mode** (`Verification Scope = 1:1 Tight Loop test file in 1–3s + static typecheck if configured`, skipping cross-module `Blast Radius` and full-suite runs inside the worktree; see [testing.md](testing.md)), then commit its branch snapshot.
     3. **Pre-report merge of `integration` tip**: before returning `Status: completed`, merge the latest `integration` branch tip into the ticket branch. If merge conflicts arise, invoke the [`resolving-merge-conflicts`](../resolving-merge-conflicts/SKILL.md) skill inside the worktree and re-run the 1:1 `Tight Loop` test file and static typecheck before emitting the 6-line handoff ([protocol.md](protocol.md)).
5. **Process handoffs, digest amendments, and advance the frontier**:
   - Read [protocol.md](protocol.md) for the exact transition rules on each 6-line handoff:
     - **`Status: completed`**: merge the ticket branch into `integration` (fast-forward or clean merge since `integration` was already merged into the ticket branch). After the first ticket merges into `integration`, open a GitHub Draft PR against the base branch if the tracker or user workflow uses PRs. If `Route` or the ticket logs non-breaking adaptations (`amend-spec`), append them to `SPEC.md` under `## Accepted Amendments & Internal Adaptations` as the **single writer**. If an amendment alters a shared seam depended on by other tickets, pause unstarted downstream tickets to update their dispatch briefs, and instruct in-flight affected tickets to merge the latest `integration` tip before continuing. Record a checkpoint via the **Task Progress Ledger Seam** ([hosts.md](hosts.md)).
     - **`Status: two_strike_stop`**: if the ticket has not been relayed yet (`N_relay == 0`), translate its `Route` (`use`, `need`, `drop`) into a positive instruction in a fresh clean-room brief (omitting failed diffs and stack traces) and dispatch **1** relay attempt. If `N_relay == 1` or the required capability is unavailable, mark the ticket `quarantined`.
     - **`Status: quarantined` (or `Route: ask-user`)**: mark the ticket `quarantined` in the **Task Progress Ledger Seam**, blocking only its direct and transitive downstream dependents. Never halt the overall run: immediately continue dispatching all remaining unblocked frontier tickets.
6. **Single integration full-suite gate & two-axis `code-review`**:
   - Once every unblocked ticket has merged into `integration`, run the full test suite and static typecheck **once** on `integration` using the 4-worker LPT runner and **Long-Command Session Seam** in [testing.md](testing.md) and [hosts.md](hosts.md).
   - Run `code-review` across the `integration` diff against the base branch and Effective Spec (`Original Spec ⊕ Accepted Amendments`). If cross-ticket regressions or review violations appear, fix them via an implementer subagent (or a `tdd` slice) and re-verify.
7. **Close out and report**:
   - Clean up all temporary worktrees.
   - If a Draft PR is open (or PRs are used), invoke the [`pr`](../pr/SKILL.md) skill to update the PR body and mark the PR ready for review.
   - Resolve completed tickets in the **Task Progress Ledger Seam** ([hosts.md](hosts.md)).
   - Deliver the final report: `integration` branch and head SHA, three-tier verification summary (synthetic automated tests, live external APIs, real-machine UI, explicitly noting any unrun tier), `Accepted Amendments`, and a consolidated decision table for any `quarantined` tickets (`Error` + `Route`).
