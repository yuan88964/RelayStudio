---
name: resolving-merge-conflicts
description: Resolve in-progress Git merge or rebase conflicts cleanly. Use when a branch merge, rebase, or worktree integration hits conflicting hunks that must be reconciled and verified.
---

# Resolving Merge & Rebase Conflicts

1. **Inspect current merge or rebase state (`Standard` / `Normalize`)**: Run `git status --porcelain` and inspect `git log --merge -p` to list every conflicted file and identify the two diverging commits across the integration seam (`Seam`).

2. **Trace each side's primary source of truth**: Read the commit messages, ticket files, and Effective Spec (`Original Spec ⊕ Accepted Amendments`) for both `HEAD` and the incoming branch so you understand the exact invariant each side was trying to establish.

3. **Reconcile each conflicted hunk**:
   - Preserve both sides' intent whenever they are orthogonal;
   - When the two sides are mutually exclusive, select the side that conforms to the locked interface seam and Effective Spec, and document the rationale;
   - **Never invent unrequested behavior** during conflict resolution, and never run `--abort` to abandon the integration unless triggering a structured **`Bailout`** (`Error` + `Route: ask-user`) on a genuine spec contradiction.

4. **Verify at the module seam (`Tight Loop` + static typecheck)**: Run the target module's `1–3s` `Tight Loop` test command, static typechecker, and formatter in order, fixing any broken imports or contract mismatches introduced by the merge.

5. **Complete the merge or rebase**: Stage all resolved files (`git add`) and complete the commit or `git rebase --continue` until all commits replay cleanly and `git status --porcelain` is empty.
