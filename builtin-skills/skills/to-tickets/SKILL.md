---
name: to-tickets
description: Break a plan, spec, or the current conversation into a set of tracer-bullet tickets, each declaring its blocking edges, published to the configured tracker (edges as text in one file per ticket locally, or native blocking links on a real tracker).
disable-model-invocation: true
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/to-tickets/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-07"
---

# To Tickets (`to-tickets`)

Focused decomposition worker that breaks a settled `SPEC.md` or plan into tracer-bullet vertical-slice tickets with explicit blocking edges (`Blocked by`) and concurrency-safe module boundaries.

- **`Standard` (Orthogonal feature slices)**: Slice into end-to-end **tracer bullets** (`Steps 1–5`), ordering any shared-seam prefactoring ticket first (`01`) so downstream tickets branch from a locked interface in parallel.
- **`Normalize` (Unsettled module orthogonality or wide mechanical refactor)**:
  - *Unsettled concurrency boundaries*: Invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A`) as a bounded subroutine in Step 2 to obtain a **5-Line Module Blueprint**, mapping Line 1 & Line 4 to blocking edges.
  - *Wide mechanical refactor (renaming a column or retyping a shared symbol across many call sites)*: Sequence as an **Expand–Contract** DAG instead of a single vertical slice:
    1. **Expand (`01`)**: Add the new symbol/schema beside the old one so existing callers stay green.
    2. **Migrate Batches (`02..N`, blocked by `01`)**: Migrate call sites in blast-radius batches (per package or directory), each batch landing green independently.
    3. **Contract (`N+1`, blocked by `02..N`)**: Delete the deprecated form once zero callers remain (or merge via a shared `integration` branch gate when batches cannot pass alone).
- **`Bailout` (Missing spec or unsettled architectural trade-offs)**: Abort ticket creation and emit `Error: <missing spec or unresolved seam>` + `Route: use to-spec | grilling`.

---

## Process

### 1. Gather context
Read the passed `SPEC.md`, tracker issue, or settled conversation context, along with `GLOSSARY.md` and local ADRs.

### 2. Partition module seams & concurrency (`1-Line Baseline` vs. `module-design` Subroutine)
- **1-Line Baseline**: When `SPEC.md` already defines orthogonal module seams, shared prefactoring blockers, and disjoint capabilities, slice directly in Step 3.
- **Bounded Subroutine Call**: When module overlap or parallelization safety is unclear, invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A`) as a subroutine to return a **5-Line Module Blueprint**. Consume **Line 1 (`Modules & Scope`)** and **Line 4 (`Orthogonality & Concurrency`)** inline:
  - Extract any shared interface definition or prefactoring blocker ("Make the change easy, then make the easy change") into ticket `01` so parallel worktrees branch from a locked seam;
  - Leave slices touching **disjoint deep modules with zero shared mutable state** unblocked relative to each other (parallel frontier), and link slices touching **overlapping seams or contracts** with explicit `Blocked by` edges (serial execution).

### 3. Draft vertical tracer-bullet slices
Ensure every non-wide-refactor ticket satisfies all 4 vertical-slice invariants:
1. **End-to-end vertical cut**: Cuts a narrow, complete path through schema, logic, boundary, and tests (never a horizontal single-layer ticket).
2. **Independently verifiable (`1–3s`)**: Demoable and testable on its own at its agreed public seam.
3. **Single-window sized**: Fits comfortably in one fresh subagent context window.
4. **Explicit DAG edges**: Declares exact `Blocked by` dependencies (plus a note whenever two tickets touch overlapping contracts so `develop` serializes them).

### 4. Confirm or publish breakdown
When invoked standalone interactively, present the proposed numbered list (`Title`, `Blocked by`, `What it delivers`) for user confirmation before publishing. When invoked unattended by `develop` after user go-ahead, proceed directly to Step 5.

### 5. Publish tickets to the configured tracker
Publish in dependency order (`01` blockers first) without closing or modifying any parent issue:
- **Local files (default when no external tracker is configured)**: Write one file per ticket under `.scratch/<feature-slug>/issues/<NN>-<slug>.md` using `<local-ticket-template>`.
- **External issue tracker (GitHub, Linear)**: Publish one issue per ticket in dependency order using `<issue-template>`, link native blocking relationships (and sub-issue parent links), and apply the `ready-for-agent` triage label.

<local-ticket-template>

# <NN>: <Ticket title>

**What to build:** the end-to-end behaviour this ticket makes work, from the user's perspective, not a layer-by-layer implementation list.

**Blocked by:** the numbers/titles of the tickets that gate this one, or "None (can start immediately)".

**Status:** pending
<!-- Valid execution statuses: pending | in_progress | completed | two_strike_stop | quarantined -->

- [ ] Acceptance criterion 1
- [ ] Acceptance criterion 2

## Accepted Amendments & Internal Adaptations

- (Append Category 1 internal non-breaking adaptations or Category 2 approved test-radius updates here; the `develop` orchestrator consolidates these into `SPEC.md` on wave merge.)

## Attempt Log & Quarantine Status

- (If a subagent hits `two_strike_stop` or `quarantined`, record: [1] approach tried, [2] falsifying error/evidence, [3] `Route` constraint for the relay agent or user decision needed.)

</local-ticket-template>

<issue-template>

## Parent

A reference to the parent issue on the tracker (if the source was an existing issue, otherwise omit this section).

## What to build

The end-to-end behaviour this ticket makes work, from the user's perspective, not layer-by-layer implementation.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Blocked by

- A reference to each blocking ticket, or "None (can start immediately)". Omit this section when blockers were set as native edges.

## Accepted Amendments & Internal Adaptations

- (Append Category 1 internal adaptations or Category 2 approved test-radius updates here.)

## Attempt Log & Quarantine Status

- (Record falsified approaches on `two_strike_stop` or blocking reasons if `quarantined`.)

</issue-template>

---

## Completion Criterion & Caller Override Seam (`Recency Peak`)

### Completion Criterion
Before finishing `to-tickets`, verify all 4 checks:
1. **One Ticket Per File / Issue in Dependency Order**: Tickets are numbered from `01` with shared-seam prefactoring blockers first and explicit `Blocked by` edges on every dependent slice.
2. **Path-Free Domain Vocabulary**: Ticket bodies use `GLOSSARY.md` domain module names and contain zero hardcoded physical file paths or raw code dumps (other than concise prototype type/state-machine excerpts).
3. **Unattended Ledger Sections Present**: Every ticket includes `Status: pending`, `## Accepted Amendments & Internal Adaptations`, and `## Attempt Log & Quarantine Status`.
4. **Concurrency Frontier Clear**: The initial unblocked frontier (`Blocked by: None`) is ready for immediate parallel dispatch by `develop`.

### Caller Override Seam
When invoked unattended by an upper orchestrator (such as `develop`), publish the ticket files/issues directly without interactive prompts and immediately return the ordered ticket list and initial ready frontier to the caller.
