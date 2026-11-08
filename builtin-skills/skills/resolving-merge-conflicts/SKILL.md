---
name: resolving-merge-conflicts
description: Resolve in-progress Git merge or rebase conflicts cleanly. Use when a branch merge, rebase, or worktree integration hits conflicting hunks that must be reconciled and verified.
---

# Resolving Merge & Rebase Conflicts (`resolving-merge-conflicts`)

Focused worker skill for reconciling Git merge or rebase conflicts across worktree branches and `integration` while preserving module seam contracts.

- **`Standard` (Orthogonal or spec-arbitrated conflict hunks)**: Reconcile conflicted files via Steps 1–5 and verify at the `1–3s` module seam.
- **`Normalize` (Stale worktree state or unmerged submodules/lockfiles)**: Inspect `git status --porcelain` and `git log --merge -p` first; regenerate lockfiles via the package manager after merging manifest changes rather than hand-editing lockfile conflict markers.
- **`Bailout` (Genuine spec contradiction between `HEAD` and incoming branch)**: Leave the conflict state intact (or abort only when instructed by the caller) and emit `Error: conflicting behavioral contracts on <seam>` + `Route: ask-user <decision>`.

---

## Process

1. **Inspect current merge or rebase state**: Run `git status --porcelain` and `git log --merge -p` to list every conflicted file and identify the two diverging commits across the integration seam (`Seam`).
2. **Trace each side's primary source of truth**: Read the commit messages, ticket files, and `Effective Spec` (`Original Spec ⊕ Accepted Amendments`) for both `HEAD` and the incoming branch so you understand the exact invariant each side establishes.
3. **Reconcile each conflicted hunk**:
   - Combine both sides cleanly whenever their changes are orthogonal;
   - When the two sides touch the same lines with competing shapes, select the side that conforms to the locked interface seam and `Effective Spec`, keeping behavior strictly within the approved specification.
4. **Verify at the module seam (`1–3s` Tight Loop + static typecheck)**: Run the target module's `1–3s` `Tight Loop` test command, static typechecker, and formatter in order, fixing any broken imports or contract mismatches introduced by the merge.
5. **Complete the merge or rebase**: Stage all resolved files (`git add`), verify zero `<<<<<<<` / `=======` / `>>>>>>>` conflict markers remain (`git diff --check`), and complete the commit or `git rebase --continue`.

---

## Completion & Caller Return Gate (`Recency Peak`)

Conflict resolution is complete when:
1. `git diff --check` and `git status --porcelain` report zero remaining conflict markers or unmerged paths;
2. The target module's `1–3s` `Tight Loop` test file and static typechecker exit `0`;
3. **Immediate Caller Return**: When invoked mid-flight by `develop` (e.g., during worktree pre-report merge of `integration`), immediately resume the caller's step to emit the 6-line handoff or advance the integration frontier.
