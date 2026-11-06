---
name: to-spec
description: "Turn the current conversation into a spec and publish it to the project issue tracker: no interview, just synthesis of what you've already discussed."
disable-model-invocation: true
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/to-spec/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-06"
---

This skill takes the current conversation context and codebase understanding and produces a spec. Do NOT interview the user; just synthesize what you already know.

The issue tracker and triage label vocabulary should have been provided to you. If not, default to local Markdown files under `docs/specs/` or `.scratch/<feature-slug>/SPEC.md` (or tell the user to run `/setup-matt-pocock-skills` if an external tracker is required).

## Process

1. Explore the repo to understand the current state of the codebase, if you haven't already. Use the project's domain glossary vocabulary (`GLOSSARY.md`) throughout the spec, and respect any ADRs in the area you're touching.

2. Sketch out the seams at which you're going to test the feature. Existing seams should be preferred to new ones. Use the highest seam possible. If new seams are needed, propose them at the highest point you can. The fewer seams across the codebase, the better - the ideal number is one.

Check with the user that these seams match their expectations.

3. Write the spec using the template below. Before writing or publishing, run a **pre-publish self-check**: verify that `SPEC.md` contains **zero** file paths (`src/...`, `*.py`, `*.ts`), line numbers, shell test commands, or implementation code blocks (other than minimal prototype decision shapes under the explicit exception below). Keep concrete file paths and test commands for `develop` dispatch briefs, and keep line-number debugging evidence in diagnostic reports. Publish the clean spec and apply the `ready-for-agent` triage label.

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

A list of implementation decisions that were made, expressed using domain module names (`GLOSSARY.md`), module responsibilities, interface contracts, invariants, and observable behaviors:

- The modules that will be built/modified (by domain role/name, not file path)
- The interfaces of those modules that will be modified (inputs, outputs, invariants, error handling)
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths, line numbers, test commands, or code snippets. They go stale quickly and couple the spec to physical layout; concrete file paths and test commands belong in `develop` dispatch briefs, and line-number root-cause evidence belongs in diagnostic reports.

Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it within the relevant decision and note briefly that it came from a prototype. Trim to the decision-rich parts, not a working demo, just the important bits.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior at the agreed seam, not implementation details)
- Which modules/seams will be tested
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
