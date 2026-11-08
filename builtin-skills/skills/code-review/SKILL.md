---
name: code-review
description: "Review the changes since a fixed point (commit, branch, tag, or merge-base) along two axes: Standards (does the code follow this repo's documented coding standards?) and Spec (does the code match what the originating issue/spec asked for?). Runs both reviews in parallel sub-agents and reports them side by side. Use when the user wants to review a branch, a PR, work-in-progress changes, or asks to \"review since X\"."
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/code-review/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-07"
---

# Two-Axis Code Review (`code-review`)

Focused worker skill that evaluates a diff between `HEAD` and a fixed point along two independent axes (`Standards` and `Spec`) in parallel read-only sub-agents (or two sequential passes when subagents are unavailable) and aggregates the findings side by side.

- **`Standard` (Committed candidate snapshot + resolvable base ref)**: Run Steps 1–5 across both `Standards` and `Spec` (`Effective Spec = Original Spec ⊕ Accepted Amendments`).
- **`Normalize` (Dirty worktree, missing fixed point, or missing spec)**: Commit or explicitly capture staged/unstaged/untracked files alongside `<fixed-point>...HEAD` so zero files are missed; resolve the merge-base against `integration` or `main` when no fixed point is given; if no spec exists anywhere, run the `Standards` axis alone and record `"Spec axis: skipped (no spec source found)"`.
- **`Bailout` (Unresolvable git ref or empty diff)**: Abort before spawning sub-agents and emit `Error: <unresolvable ref or empty diff>` + `Route: amend-spec | ask-user`.

---

## 0. Why Two Separate Axes (`Standards` vs. `Spec`)

A change can pass one axis and fail the other:
- Code that follows every convention and deep-module rule but implements the wrong behavior $\to$ **Standards pass, Spec fail.**
- Code that delivers the exact user story requested but introduces shallow pass-through wrappers or breaks repo conventions $\to$ **Spec pass, Standards fail.**

Running and reporting the two axes separately prevents compliance on one axis from masking a failure on the other.

---

## 1. Process

### 1. Pin the fixed point & verify worktree cleanliness

Use the fixed point provided by the caller or user (commit SHA, branch name, tag, `main`, `integration` base SHA, `HEAD~1`). When omitted, resolve the merge-base against `integration` or `main` / `master`.

Run `git status --porcelain` before capturing the diff:
- In standard orchestrated runs, all candidate changes (including newly created files) are committed to `HEAD` before `code-review` starts so `git diff <fixed-point>...HEAD` inspects an immutable snapshot.
- If the worktree is dirty and uncommitted work is under review, create a candidate checkpoint commit first or explicitly include staged, unstaged, and untracked files alongside `git diff <fixed-point>...HEAD` and `git log <fixed-point>..HEAD --oneline`.
- Confirm `git rev-parse <fixed-point>` succeeds and the candidate diff is non-empty (`Bailout` immediately if empty).

### 2. Identify the `Effective Spec` source

Locate the originating spec and any recorded `## Accepted Amendments & Internal Adaptations` (`Effective Spec = Original Spec ⊕ Accepted Amendments`), in priority order:
1. A spec or ticket path passed by the caller (dispatch brief or user argument).
2. Issue references in commit messages (`#123`, `Closes #45`, GitLab `!67`), including appended amendments/comments.
3. A spec or ticket file under `docs/`, `specs/`, or `.scratch/` matching the branch or feature.
4. If none exists, skip the **Spec** sub-agent without blocking and report `"Spec axis: skipped (no spec source found)"`.

### 3. Identify the standards sources & smell baseline (`1-Line Baseline` vs. `module-design` Subroutine)

Collect every repo file documenting coding conventions (`CODING_STANDARDS.md`, `CONTRIBUTING.md`, `GLOSSARY.md`, relevant ADRs) and pair them with the 12-smell Fowler baseline below:
- **Repo standards override the baseline**, and anything already enforced by deterministic linters/typecheckers is skipped.
- **1-Line Baseline (Localized smells)**: For localized naming, dead parameter, or single-hunk duplication issues, report the direct 1-line fix inline.
- **Bounded Subroutine Call to [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A`)**: When a cluster of smells (`Shotgun Surgery`, `Divergent Change`, `Middle Man`, `Repeated Switches`, or implementation-coupled tests) indicates a shallow module or flawed seam, invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A`, `Operation A1`) as a subroutine during aggregation to attach a **5-Line Module Blueprint** (`Route: use module-design: <target seam>`) and immediately resume Step 5.

**Fowler Smell Baseline (paste in full into the Standards sub-agent prompt)**:
- **Mysterious Name**: name hides what the symbol does or holds $\to$ rename clearly; if no honest name fits, deepen the abstraction (`module-design`).
- **Duplicated Code**: identical logic shape in multiple hunks $\to$ gather shared secret into one module (`Gather`).
- **Feature Envy**: method reaches into another object's data more than its own $\to$ move method onto the envied data (`Gather`).
- **Data Clumps**: same fields/params travel together repeatedly $\to$ bundle into one domain type.
- **Primitive Obsession**: raw primitive/string standing in for a domain concept $\to$ introduce a small domain type.
- **Repeated Switches**: same `switch` / `if-else` cascade recurs across sites $\to$ flatten via a table-driven seam adapter (`Polish`).
- **Shotgun Surgery**: one logical change scatters edits across many files $\to$ gather what changes together into one deep module (`Gather`).
- **Divergent Change**: one module is edited for unrelated reasons $\to$ split horizontally by domain secret (`Split`).
- **Speculative Generality**: parameters or single-adapter ports added for unrequested future needs $\to$ inline back until two real adapters exist.
- **Message Chains**: long `a.b().c().d()` navigation $\to$ hide traversal behind one method on the boundary object.
- **Middle Man**: shallow pass-through class/function that only delegates $\to$ fails the deletion test; inline and call target directly (`Gather`).
- **Refused Bequest**: subclass/implementer overrides or ignores inherited contract $\to$ replace inheritance with composition.

### 4. Dispatch both review axes

- **Parallel sub-agents (default when available)**: Launch two read-only sub-agents concurrently (host defaults with no model/effort overrides in web hosts; `reviewer` role in local CLI/IDE hosts).
- **Serial main-window fallback**: Run the Standards pass and Spec pass sequentially in the current window and note `subagent dispatch: none — serial execution` in the header.

| Sub-Agent Axis | Required Context Injected | Evaluation & Output Brief (`< 400` words, single context, zero nested sub-agents) |
| :--- | :--- | :--- |
| **1. `Standards` Axis** | Full diff command, commit list, repo standards files, and the 12-smell baseline from Step 3 pasted in full. | Report per file/hunk: (a) documented-standard breaches (cite file + rule; hard violation), and (b) baseline code smells (quote hunk; judgement call unless repo standard overrides). Skip linter-enforced rules. |
| **2. `Spec` Axis** | Full diff command, commit list, and `Effective Spec` (`Original Spec ⊕ Accepted Amendments`). | Evaluate diff against `Effective Spec` (Categories 1 & 2 recorded under `Accepted Amendments & Internal Adaptations` that preserve user-visible behavior and existing assertions are valid, not scope creep). Report with exact spec line / test hunk quotes: (a) missing/partial requirements, (b) unrequested user-visible scope creep, (c) incorrect implementation, (d) tautological tests, weakened assertions, or internal-collaborator mocks. |

---

## 2. Aggregation Gate & Caller Override Seam (`Recency Peak`)

### Step 5: Aggregate & Completion Criterion
Present the findings under separate `## Standards` and `## Spec` headings without merging or reranking across axes. Review is complete when:
1. Both axes (or `Standards` + explicit `Spec: skipped` note) are reported with file/hunk citations;
2. Any structural shallow-module or test-seam finding includes a `Route: use module-design: <target seam>` recommendation (backed by a **5-Line Module Blueprint** when refactoring is required);
3. The report closes with a **1-line summary** stating total findings per axis and the highest-severity issue within each axis.

### Caller Override Seam
When invoked by an upper orchestrator (such as `develop`), accept the caller's injected **Fixed Point** (`integration` or base SHA), **Effective Spec Source** (`Original Spec ⊕ Accepted Amendments`), and **Dispatch Mode** without interactive prompts, and immediately return the aggregated two-axis report to the caller.
