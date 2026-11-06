---
name: code-review
description: "Review the changes since a fixed point (commit, branch, tag, or merge-base) along two axes: Standards (does the code follow this repo's documented coding standards?) and Spec (does the code match what the originating issue/spec asked for?). Runs both reviews in parallel sub-agents and reports them side by side. Use when the user wants to review a branch, a PR, work-in-progress changes, or asks to \"review since X\"."
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/code-review/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-06"
---

Two-axis review of the diff between `HEAD` and a fixed point:

- **Standards**: does the code conform to this repo's documented coding standards?
- **Spec**: does the code faithfully implement the originating issue / spec?

Both axes run as **parallel sub-agents** when subagent dispatch is available (or as two separate serial passes in the main window when running on a host without subagents), then this skill aggregates their findings.

## Process

### 1. Pin the fixed point

Use the fixed point provided by the caller or user (a commit SHA, branch name, tag, `main`, `integration` base SHA, `HEAD~1`, etc.). If none was specified, resolve the merge-base against the default base branch (`integration` or `main` / `master`) rather than blocking on user input.

Before capturing the diff, run `git status --porcelain` to verify whether uncommitted modifications or untracked new files exist in the worktree:
- In the standard ticket workflow, all candidate changes (including newly created files) must be committed to `HEAD` on the ticket branch *before* `code-review` is called so `git diff <fixed-point>...HEAD` inspects the exact immutable snapshot.
- If the worktree is dirty and the caller intended to review uncommitted work, either create a candidate checkpoint commit on the branch first or explicitly capture staged, unstaged, and untracked files alongside `<fixed-point>...HEAD` so no modified or newly created file is silently omitted.

Capture the diff command once: `git diff <fixed-point>...HEAD` (three-dot, so the comparison is against the merge-base). Also note the list of commits via `git log <fixed-point>..HEAD --oneline`.

Before going further, confirm the fixed point resolves (`git rev-parse <fixed-point>`) and the candidate diff is non-empty. A bad ref or empty diff should fail here, not inside two parallel sub-agents.

### 2. Identify the spec source

Look for the originating spec and any recorded `## Accepted Amendments & Internal Adaptations` (`Effective Spec = Original Spec ⊕ Accepted Amendments`), in this order:

1. A spec or ticket path passed by the caller (dispatch brief or user argument).
2. Issue references in the commit messages (`#123`, `Closes #45`, GitLab `!67`, etc.), fetched via the workflow in the tracker doc (including appended amendments/comments).
3. A spec or ticket file under `docs/`, `specs/`, or `.scratch/` matching the branch name or feature.
4. If nothing is found, do **not** block waiting for the user: skip the **Spec** sub-agent and explicitly report `"Spec axis: skipped (no spec source found)"` in the final report.

### 3. Identify the standards sources

Search the repo for every file that documents how code should be written. When `CODING_STANDARDS.md` or `CONTRIBUTING.md` exists, it must be on the list.

On top of whatever the repo documents, the Standards axis always carries the **smell baseline** below: a fixed set of Fowler code smells (_Refactoring_, ch.3) that applies even when a repo documents nothing. Two rules bind it:

- **The repo overrides.** A documented repo standard always wins; where it endorses something the baseline would flag, suppress the smell.
- **Always a judgement call.** Each smell is a labelled heuristic ("possible Feature Envy"), never a hard violation. Like any standard here, skip anything tooling already enforces.

Each smell reads *what it is* → *how to fix*; match it against the diff:

- **Mysterious Name**: a function, variable, or type whose name doesn't reveal what it does or holds. → rename it; if no honest name comes, the design's murky.
- **Duplicated Code**: the same logic shape appears in more than one hunk or file in the change. → extract the shared shape, call it from both.
- **Feature Envy**: a method that reaches into another object's data more than its own. → move the method onto the data it envies.
- **Data Clumps**: the same few fields or params keep travelling together (a type wanting to be born). → bundle them into one type, pass that.
- **Primitive Obsession**: a primitive or string standing in for a domain concept that deserves its own type. → give the concept its own small type.
- **Repeated Switches**: the same `switch`/`if`-cascade on the same type recurs across the change. → replace with polymorphism, or one map both sites share.
- **Shotgun Surgery**: one logical change forces scattered edits across many files in the diff. → gather what changes together into one module.
- **Divergent Change**: one file or module is edited for several unrelated reasons. → split so each module changes for one reason.
- **Speculative Generality**: abstraction, parameters, or hooks added for needs the spec doesn't have. → delete it; inline back until a real need shows.
- **Message Chains**: long `a.b().c().d()` navigation the caller shouldn't depend on. → hide the walk behind one method on the first object.
- **Middle Man**: a class or function that mostly just delegates onward. → cut it, call the real target direct.
- **Refused Bequest**: a subclass or implementer that ignores or overrides most of what it inherits. → drop the inheritance, use composition.

### 4. Dispatch both review axes

Select the dispatch mode based on the active host's capabilities (or caller override):
- **Web-native or local role subagents available**: issue both read-only sub-agent calls together in parallel (in web hosts, use host defaults with no model or reasoning-effort arguments; in local CLI/IDE hosts, select the `reviewer` custom agent role).
- **Main-window serial fallback (no subagent tool exposed, or running inside a subagent worktree)**: execute the Standards pass and Spec pass sequentially as two independent checks in the current window, and state `subagent dispatch: none — serial execution` in the report header.

**Standards sub-agent prompt** should include:

- The full diff command and commit list.
- The list of standards-source files you found in step 3, **plus the smell baseline from step 3** pasted in full (the sub-agent has no other access to it).
- The brief: "Perform this review directly in this single context; never call skills or spawn sub-agents. Report, per file/hunk where relevant, (a) every place the diff violates a documented standard: cite the standard (file + the rule); and (b) any baseline smell you spot: name it and quote the hunk. Distinguish hard violations from judgement calls: documented-standard breaches can be hard, but baseline smells are always judgement calls, and a documented repo standard overrides the baseline. Skip anything tooling enforces. Under 400 words."

**Spec sub-agent prompt** should include:

- The diff command and commit list.
- The path or fetched contents of the spec, plus any entries recorded under `## Accepted Amendments & Internal Adaptations` (or mid-session user instructions).
- The brief: "Perform this review directly in this single context; never call skills or spawn sub-agents. Evaluate the diff against the Effective Spec (Original Spec ⊕ Accepted Amendments). Internal implementation adaptations (Category 1) or approved blast-radius test syncs (Category 2) recorded under `Accepted Amendments & Internal Adaptations` that preserve user-observable behaviour and existing acceptance criteria are valid implementation details and must NOT be flagged as scope creep. Report: (a) requirements the effective spec asked for that are missing or partial; (b) user-visible behaviour in the diff that wasn't asked for (scope creep); (c) requirements that look implemented but where the implementation looks wrong; (d) any test in the diff that is tautological, weakens pre-existing acceptance assertions without an approved amendment, or mocks internal collaborators under test instead of verifying the spec's behaviour at the agreed seam. Every finding must quote the exact spec line it violates (for a–c) or the flawed test hunk (for d). Under 400 words."

If the spec is missing, skip the Spec sub-agent and note this in the final report.

### 5. Aggregate

Present the two reports under `## Standards` and `## Spec` headings, verbatim or lightly cleaned. Do **not** merge or rerank findings, because the two axes are deliberately separate (see _Why two axes_).

End with a one-line summary: total findings per axis, and the worst issue _within each axis_ (if any). Don't pick a single winner across axes: that's the reranking the separation exists to prevent.

## Why two axes

A change can pass one axis and fail the other:

- Code that follows every standard but implements the wrong thing → **Standards pass, Spec fail.**
- Code that does exactly what the issue asked but breaks the project's conventions → **Spec pass, Standards fail.**

Reporting them separately stops one axis from masking the other.

## Container Seams (Unattended & Orchestrated Execution)

`code-review` exposes three seams so an orchestrator or direct caller can run it unattended without interactive prompts:

| Seam | Caller Override (When Orchestrated) | Unattended Default (When Unspecified) |
| :--- | :--- | :--- |
| **1. Fixed Point** | Base SHA of the ticket branch or `integration` branch. | Merge-base against `integration`, `main`, or `master` (`git merge-base HEAD <base>`). |
| **2. Effective Spec Source** | `SPEC.md` (`Original Spec ⊕ Accepted Amendments`) and/or the ticket file. | Search commit refs and `.scratch/`/`docs/`/`specs/`; if none found, skip Spec axis and note it in the report without blocking. |
| **3. Dispatch Adapter** | Parallel web-native subagents, parallel local `reviewer` subagents, or main-window serial two-pass review. | Parallel subagents if available; otherwise two sequential passes in the current window. |
