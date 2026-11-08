---
name: prototype
description: Build a throwaway prototype to answer a design question. Use when the user wants to sanity-check whether a state model or logic feels right, or explore what a UI should look like.
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/prototype/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-07"
---

# Throwaway Design Prototype (`prototype`)

Shared rapid-experimentation subroutine that builds **throwaway code to answer a specific design question**, captures the validated decision shape for `to-spec` / `develop`, and archives the prototype on a throwaway branch out of `main`.

- **`Standard` (Clear design question)**: Route immediately by the question type:
  - **"Does this logic / state model feel right?"** $\to$ read [LOGIC.md](LOGIC.md) and build a single self-contained HTML file (pure portable reducer/state-machine module + free-play buttons + tabbed guided walkthroughs).
  - **"What should this look like?"** $\to$ read [UI.md](UI.md) and build 3–5 structurally distinct UI variants on a single route switchable via `?variant=` and a floating bottom bar.
- **`Normalize` (Ambiguous question when running unattended or user is AFK)**: Select the branch matching the surrounding target (`backend/domain module` $\to$ [LOGIC.md](LOGIC.md); `page/component` $\to$ [UI.md](UI.md)) and state the explicit question and branch assumption in line 1 of the prototype header.
- **`Bailout` (Question is a factual API/library lookup rather than an experiential design trade-off)**: Skip building a prototype and emit `Error: factual lookup does not require a throwaway prototype` + `Route: use research`.

---

## 1. Six Universal Prototype Invariants

1. **Throwaway from day one, clearly named**: Co-locate the prototype next to the module or route it explores so context is obvious, and include `prototype` in the filename or route path so no reader mistakes it for production code.
2. **One-step execution**: A logic demo opens directly by double-clicking a single `.html` file; a UI prototype runs from one existing project command (`pnpm dev`, `bun <path>`, `python <path>`).
3. **In-memory state by default**: Keep state in memory (or a clearly labeled `PROTOTYPE-wipe-me` scratch file/DB when persistence itself is under test) with zero production mutations.
4. **Zero production ceremony**: Skip unit tests, deep error-recovery wrappers, and premature abstractions so the prototype answers its question in minutes.
5. **Visible live state**: Render the full relevant state panel after every action ([LOGIC.md](LOGIC.md)) or on every `?variant=` switch ([UI.md](UI.md)) so state transitions and layout trade-offs are immediately inspectable.
6. **Lift the decision, archive the shell**: Once the user settles the question, lift only the validated decision shape (the pure reducer/state-machine excerpt or chosen layout structure) into the spec or production module, commit the full prototype to a throwaway branch (`prototype/<slug>`), and keep `main` clean.

---

## 2. Completion & Subroutine Return Contract (`Recency Peak`)

A `prototype` pass is complete when the runnable artifact is handed over and, once evaluated, produces this 3-line **Prototype Verdict Summary**:

```text
1. Question & Branch: <the design question tested + LOGIC.md (.html) or UI.md (?variant=)>
2. Validated Decision Excerpt: <winning UI variant structure or pure reducer/state-machine/type shape to inline into SPEC.md / production>
3. Archive Pointer: <prototype file path or throwaway branch prototype/<slug> removed from main>
```

**Immediate Return Rule**: When invoked as a subroutine by `wayfinder`, `to-spec`, or `grilling`, emit the runnable prototype path (or the **Prototype Verdict Summary** once evaluated) and **immediately resume the calling workflow inline**.
