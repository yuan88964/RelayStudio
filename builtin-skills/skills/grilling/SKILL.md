---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/productivity/grilling/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-07"
---

# Relentless Design Interview (`grilling`)

Shared design-tree interview subroutine that walks every open decision branch until the **frontier** is empty and shared understanding is locked. Upper container workflows (`Global_Agent_Rules`, `develop`, `to-spec`, `wayfinder`, `triage`, `improve-codebase-architecture`, `math-teaching`, `writing-fragments`, `loop-me`, `grill-with-docs`) invoke this skill to batch all currently askable questions in a single plain-Markdown turn, emit the **Settled Decision Summary** (`§3`), and immediately resume their own workflow.

---

## 0. Three-State Entry Contract (`Standard / Normalize / Bailout`)

- **`Standard` (Facts verified, open decision frontier non-empty)**: Compute the current **frontier** (every decision whose prerequisites are already settled), batch all frontier questions into a single plain-Markdown message (`❓ **Qn**` + `➡️ <recommended answer>`) in the conversation body, and wait for the user's reply.
- **`Normalize` (Frontier depends on checkable codebase, runtime, or document facts)**: Dispatch read-only exploration subagents (or run direct single-point checks) to verify all environment facts first—never ask the user a question that the filesystem, codebase, or docs can answer. Ask any independent frontier questions immediately while downstream fact-dependent branches wait for the subagent report.
- **`Bailout` (Frontier already empty or running inside an unattended post-go-ahead execution wave)**:
  - *Frontier already empty*: Skip directly to `§3` and emit the **Settled Decision Summary**.
  - *Unattended execution wave (`develop` post-go-ahead)*: Abort interactive questioning at line 1 and emit `Error: user-visible decision required during unattended execution` + `Route: ask-user <decision>` (`Status: quarantined`).

---

## 1. Core Operator: Design-Tree Rounds & Plain-Markdown Batching

Map the problem space as a **design tree** where each high-level decision unlocks the downstream decisions that hang off it:

1. **Batch the entire current frontier into one plain-Markdown message**: Output all independent frontier questions together in the conversation body in place of any host modal or popup question tool (`ask_question` / `AskUserQuestion`) and in place of one-by-one trickling:

```markdown
❓ **Q1** - **<question title>**: <question body, context, and trade-offs across options>

➡️ **推荐方案**：<your recommended default answer, worded so "yes / 同意" accepts it directly>

---

❓ **Q2** - **<question title>**: <question body, context, and trade-offs across options>

➡️ **推荐方案**：<your recommended default answer, worded so "yes / 同意" accepts it directly>
```

2. **Advance the frontier round by round**: Each user reply settles the current tier and unblocks downstream branches. Recompute the newly exposed frontier and ask the next batched round until zero unsettled branches remain.

---

## 2. Caller-Keyed Branches (`Select by Calling Container`)

| Branch | Calling Containers | Completion & Go-Ahead Behavior |
| :--- | :--- | :--- |
| **Branch A: Standalone / Pre-Execution Decision Gate** | Direct user `/grill-me`, `Global_Agent_Rules` pre-execution gate, `develop` (`§1 Normalize`), `to-spec` | When the frontier reaches zero, emit the **Settled Decision Summary** (`§3`) and ask the user for explicit confirmation (`"以上决策是否对齐？确认后即可开工 / 生成规格书"`) before any file edits or spec synthesis. |
| **Branch B: Embedded Workflow Subroutine** | `wayfinder`, `triage`, `improve-codebase-architecture`, `math-teaching`, `writing-fragments`, `loop-me`, `grill-with-docs` | Keep rounds tightly scoped to the caller's active phase (e.g., module seam trade-offs in `improve-codebase-architecture`, thesis/story beats in `writing-fragments`, lesson scope in `math-teaching`). Once the scoped frontier is empty, emit the **Settled Decision Summary** (`§3`) and immediately resume the calling skill's next step. |

---

## 3. Subroutine Output & Return Contract (`Recency Peak`)

`grilling` completes as soon as the decision frontier is empty. Close the interview by emitting this 3-line **Settled Decision Summary**:

```text
1. Resolved Decisions: <numbered list of locked architectural, behavioral, or scope choices>
2. Assumed / Deferred Constraints: <verified environment facts + explicitly out-of-scope items>
3. Next Step / Go-Ahead Gate: <confirmation prompt in Branch A, or target step resumed in Branch B>
```

**Immediate Return Rule**: Once the **Settled Decision Summary** is emitted (and confirmed in Branch A), **this subroutine is complete**—immediately return control to the calling container workflow (`develop`, `to-spec`, `wayfinder`, `triage`, `improve-codebase-architecture`, `math-teaching`, `writing-fragments`, `loop-me`, or `grill-with-docs`) at the exact step that invoked `grilling` without re-reading the caller's `SKILL.md`.
