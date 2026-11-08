---
name: to-spec
description: "Turn the current conversation into a spec and publish it to the project issue tracker: no interview, just synthesis of what you've already discussed."
disable-model-invocation: true
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/to-spec/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-07"
---

# To Spec (`to-spec`)

Focused synthesis worker that turns settled conversation context and codebase understanding into a durable, path-free specification (`SPEC.md` or tracker issue) without re-interviewing the user.

- **`Standard` (Requirements & domain seams settled in conversation)**: Synthesize the conversation and codebase state directly into `<spec-template>` (`Steps 1–3`) and publish to the configured tracker (or `docs/specs/` / `.scratch/<feature-slug>/SPEC.md` locally).
- **`Normalize` (Module seams, 3-state contracts, or test stand-ins not yet locked)**: Invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A, Operation A1/A2`) as a bounded subroutine in Step 2 to obtain a **5-Line Module Blueprint**, map its lines into `## Implementation Decisions` and `## Testing Decisions`, and continue synthesis inline.
- **`Bailout` (Core user-facing requirements still contradictory or unasked)**: Abort spec synthesis and emit `Error: unsettled user-facing decisions <list>` + `Route: use grilling: resolve open design frontier before writing SPEC.md`.

---

## Process

1. **Ground in domain vocabulary**: Explore the repo if not already done. Use the canonical terms from `GLOSSARY.md` and respect existing ADRs across all sections.
2. **Lock module seams (`1-Line Baseline` vs. `module-design` Subroutine)**:
   - **1-Line Baseline**: When the conversation already locked the highest public interface, 3-state contract (`Standard / Normalize / Bailout`), and dependency stand-in strategy (`In-process`, `Local-substitutable`, `Remote but owned`, `True external`), write them directly into the spec.
   - **Bounded Subroutine Call**: When module boundaries or testability seams are unsettled, invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A, Operation A1/A2`) as a subroutine to produce a **5-Line Module Blueprint**. Map **Lines 1–3** (`Modules & Scope`, `Public Interface & 3-State Seam`, `Hidden Internals & Adapters`) into `## Implementation Decisions` and **Lines 3 & 5** (`Adapters / Stand-Ins` & `Tight Verification Gate`) into `## Testing Decisions`, then immediately resume Step 3. (Confirm seams briefly with the user when run standalone interactively; proceed directly when invoked unattended by `develop`.)
3. **Draft and publish the path-free spec**: Populate `<spec-template>` below, verify the **Completion Criterion** (`Recency Peak`), publish to the configured tracker (or local `.md` path), and apply the `ready-for-agent` triage label.

<spec-template>

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A LONG, numbered list of user stories. Each user story should be in the format of:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

This list of user stories should be extremely extensive and cover all aspects of the feature.

## Implementation Decisions

A list of implementation decisions that were made, expressed using domain module names (`GLOSSARY.md`), module responsibilities, 3-state interface contracts, invariants, and observable behaviors:

- The modules that will be built/modified (by domain role/name, not file path)
- The interfaces of those modules that will be modified (inputs, outputs, `Standard / Normalize / Bailout` behavior, invariants)
- Technical clarifications from the developer
- Architectural decisions and adapter ports
- Schema changes
- API contracts
- Specific interactions

Keep this section durable and layout-independent: express decisions via domain module roles and contracts rather than physical file paths, line numbers, shell test commands, or implementation code blocks (concrete file paths and test commands belong in `develop` dispatch briefs, and line-number evidence belongs in diagnostic reports).

Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline the decision-rich excerpt and note briefly that it came from a prototype.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior at the agreed seam, not implementation details)
- Which modules/seams will be tested and their dependency stand-in strategy
- Prior art for the tests (describe the pattern and domain seam rather than hardcoding fragile file paths)

## Out of Scope

A description of the things that are out of scope for this spec.

## Accepted Amendments & Internal Adaptations

An append-only ledger (written only by the orchestrator during wave merge) for user-approved mid-execution requirement changes, non-breaking internal implementation adaptations (Category 1), and approved blast-radius test updates (Category 2). Both implementers and `code-review` evaluate against `Effective Spec = Original Spec ⊕ Accepted Amendments`.

| ID | Location / Ticket | Original Spec | Actual / Amended | Rationale (Zero Existing Assertions Weakened) |
| :--- | :--- | :--- | :--- | :--- |

## Further Notes

Any further notes about the feature.

</spec-template>

---

## Completion Criterion & Caller Override Seam (`Recency Peak`)

### Completion Criterion (Pre-Publish Verification Gate)
Before publishing `SPEC.md` or returning to the caller, verify all 4 checks:
1. **Path-Free Durability**: `SPEC.md` contains **zero** physical file paths (`src/...`, `*.py`, `*.ts`), line numbers, or raw shell test commands (only domain module names from `GLOSSARY.md` and optional prototype type/state-machine excerpts).
2. **Locked Seams & 3-State Contracts**: `## Implementation Decisions` and `## Testing Decisions` explicitly state each modified module's public interface, `Standard / Normalize / Bailout` contract, and dependency stand-in category.
3. **Append-Only Amendment Ledger Present**: `## Accepted Amendments & Internal Adaptations` table header is included for downstream single-writer updates.
4. **Published & Labeled**: The spec is written to the configured tracker (with `ready-for-agent` label) or `.scratch/<feature-slug>/SPEC.md` / `docs/specs/`.

### Caller Override Seam
When invoked unattended by an upper orchestrator (such as `develop`), synthesize and write `SPEC.md` directly without interactive confirmation prompts, and immediately return the published spec path/identifier to the caller.
