# Handoff Protocol, Change Digestion, and Ledger Seam

Internal protocol reference for the `develop` module and its execution parts (`tdd`, `code-review`, `diagnosing-bugs`). All host adapters ([hosts.md](hosts.md)) consume this single canonical symbol set so models never translate between multiple vocabularies.

## 1. Unattended Execution Rule & Canonical Status Vocabulary (Lowercase Only)

Once the user authorizes execution ("开工 / 执行" or invokes `/develop`), execution runs **unattended without stopping to ask mid-flight** across both Branch A (single-slice) and Branch B (multi-ticket). Any question that would alter user-visible behavior or require missing credentials is recorded as `Status: quarantined` (`Route: ask-user <decision>`) so unblocked work continues to completion and all pending user decisions are presented together at the very end.

Use these exact lowercase tokens across 6-line handoffs, ticket files, and the **Task Progress Ledger Seam** ([hosts.md](hosts.md)):

| Token | Meaning | Where Used |
| :--- | :--- | :--- |
| `completed` | Ticket or slice passed implementation, tight-loop/blast-radius tests, static typecheck, and two-axis `code-review`. | 6-line handoff `Status: completed`, ticket status, and Task Progress Ledger terminal status. |
| `two_strike_stop` | Subagent hit 2 consecutive attempts on the same root error without reducing failing test count, reverted to last green commit, and logged to `Attempt Log`. | 6-line handoff `Status: two_strike_stop` (remains `in_progress` in the Task Progress Ledger while awaiting 1 clean-room relay). |
| `quarantined` | Blocked after 1 relay attempt, or hit an unattended spec/credential conflict (`Route: ask-user`). | 6-line handoff `Status: quarantined`, ticket status, and Task Progress Ledger terminal status. |
| `in_progress` | Currently executing or being relayed. | Ticket status and Task Progress Ledger. |
| `pending` | Waiting on unmerged blockers or not yet started. | Ticket status and Task Progress Ledger. |

---

## 2. Six-Line Subagent Handoff & `Route` Transfer Contract

Every implementer or diagnostic subagent returns **at most six lines** (all stack traces, diffs, and reasoning stay on disk in the ticket's `Attempt Log`):

```text
Status: completed | two_strike_stop | quarantined
Pointers: <7-char commit sha>, <ticket-path>#attempt-log
Verified: <test files + typecheck run> -> <pass/fail counts>
Error: <one line: failing check, symptom, location, or "none". No stack trace.>
Route: <exactly one form below, or "none">
ResidualRisk: <one line>
```

### Canonical `Route` Forms (Pick One)

- `use <tool | skill | role>: <why>` — You know the exact tool, skill, or agent role that will unblock the task.
- `need <capability>: <what it must do>` — You know what capability is missing, not which tool provides it; the orchestrator selects.
- `drop <approach>: <evidence>` — This approach is falsified; state the 1-line evidence so the orchestrator never dispatches it again.
- `amend-spec <seam>: <why>` — Non-breaking internal adaptation or approved blast-radius test sync (Categories 1 & 2 below) to be recorded by the orchestrator in `SPEC.md` (or the ticket file in Branch A).
- `ask-user <decision>` — Requires human judgment (Category 3 spec conflict or missing external credential); triggers immediate `quarantined` in unattended mode.
- `none` — Standard completion with no follow-up routing needed.

### Orchestrator Action on `Route`

| `Route` Returned | Orchestrator Action |
| :--- | :--- |
| `use <X>: <why>` | If `N_relay == 0`, relay once with a fresh clean-room brief instructing the new agent to use `X`. |
| `need <cap>: <what>` | If an installed skill/tool covers `<cap>`, relay once with it; otherwise mark `quarantined` and report the missing capability. |
| `drop <path>: <ev>` | If `N_relay == 0`, rewrite the constraint positively in a fresh brief and relay once along an alternative path; if no alternative exists, mark `quarantined`. |
| `amend-spec <seam>: <why>` | Merge the branch and append the adaptation row to `SPEC.md` under `## Accepted Amendments & Internal Adaptations`. |
| `ask-user <decision>` | Mark `quarantined` immediately, bypass dependent tickets, and surface `<decision>` in the final report. |
| `none` (on `two_strike_stop`) | If `N_relay == 0`, relay once to `implementer_deep` (or a fresh native subagent) with a clean brief. |

### Clean-Room Relay Brief Rule

When relaying a `two_strike_stop` ticket (`N_relay == 0`), the orchestrator writes a **fresh brief** containing only:
1. The ticket goal and interface contract;
2. Verified baseline facts and green commit SHA;
3. The `Route` converted into a **positive instruction** (e.g., `"Use the headless browser harness for this check"` or `"Keep confidence non-negative across retries"`).
Never paste the failed diff, raw stack trace, or narrative of the abandoned attempt into the relay brief.

---

## 3. Three-Category Change Digestion & Single-Writer Amendments

During implementation, deviations from `SPEC.md` (or the ticket's agreed contract) fall into three categories:

| Category | Criterion | Subagent / Implementer Action | Orchestrator Action on Merge |
| :--- | :--- | :--- | :--- |
| **1. Internal Adaptation** | Preserves all user-visible behavior and existing acceptance assertions (e.g., helper extraction, internal signature adjustment, picking the highest existing public test seam when unspecified). | Decide autonomously; log in ticket under `## Accepted Amendments & Internal Adaptations`, return `Status: completed` with `Route: amend-spec <location>: <adaptation & reason>`. | Append row to `SPEC.md` `## Accepted Amendments & Internal Adaptations`. |
| **2. Approved Spec Blast-Radius Test Sync** | Updating legacy caller assertions that directly contradicted an already-approved spec change. | Update the legacy caller test, log the exact file/assertion in the ticket, and return `Route: amend-spec <test>: <sync reason>`. | Append row to `SPEC.md` `## Accepted Amendments & Internal Adaptations`; `code-review` verifies against `Original Spec + Accepted Amendments`. |
| **3. User-Visible or Acceptance Change** | Alters user-visible behavior or weakens an acceptance assertion without prior approval. | Never stop mid-run to ask the user: revert breaking edits on this slice and return `Status: quarantined` + `Route: ask-user <decision>`. | Mark ticket `quarantined`, continue all unblocked work, and collect `<decision>` for the final user report. |

### Single-Writer Rule & Shared-Seam Broadcast

1. **Single writer for `SPEC.md`**: Worktree subagents **never edit `SPEC.md` directly** (preventing merge conflicts across parallel branches). Subagents record adaptations in their own ticket file and in `Route: amend-spec ...`; the orchestrator is the sole writer that appends rows to `SPEC.md` under `## Accepted Amendments & Internal Adaptations` when merging into `integration`:
   ```markdown
   ## Accepted Amendments & Internal Adaptations

   | ID | Location / Ticket | Original Spec | Actual / Amended | Rationale (Zero Existing Assertions Weakened) |
   | :--- | :--- | :--- | :--- | :--- |
   | A1 | §2.1 `parse()` | ... | ... | ... |
   ```
2. **Shared-seam ripple handling**: If an accepted amendment modifies a shared interface contract that other tickets depend on:
   - Pause dispatch of unstarted downstream tickets and update their dispatch briefs with the new contract;
   - Instruct any already-running affected subagents to merge the latest `integration` tip before finishing their tight loop.

---

## 4. Failure Signal Classification (Before Retrying)

When a tool call or command fails during execution, classify the signal before taking action:

| Observed Signal | Supported Judgment | Next Action |
| :--- | :--- | :--- |
| **Explicit safety, permission, or scope refusal** | Action is outside authorized bounds, not a code bug. | Stop the refused action immediately; diagnose within authorized scope or return `Route: ask-user <decision>`. |
| **Missing parameter, syntax error, or non-unique target** | Local call typo or stale line context. | Fix the parameter or re-read surrounding lines; never widen permissions to force a write. |
| **File content or version hash changed since read** | Write basis is stale due to concurrent edit. | Re-read current file state and merge cleanly; never overwrite blindly. |
| **Transport timeout / EOF / stream disconnect (60–120s)** | Local process may still be running or already finished. | Inspect the active background session via the host's **Long-Command Session Seam** ([testing.md](testing.md), [hosts.md](hosts.md)); never immediately re-submit the same command. |
| **Exit code `0` but output violates target behavior** | Process exited cleanly without achieving the business goal. | Read the actual output artifact or test assertion and fix the logic. |

---

## 5. Task Progress Ledger Seam

Progress tracking sits behind the **Task Progress Ledger Seam** owned exclusively by `develop` and mapped to concrete host adapters in [hosts.md](hosts.md):

1. **Lifecycle Synchronization**:
   - Register planned ticket steps at the start of `develop` (`pending` / `in_progress`).
   - Record a checkpoint whenever a ticket merges into `integration` (`completed`) or halts after relay/conflict (`quarantined`).
2. **Canonical Single-Line Checkpoint Summary**:
   - Format every milestone checkpoint on a single line using `||` to separate the human-readable Chinese progress (including the 7-char short commit SHA) on the left from forward-slash file or commit pointers on the right:
     `<中文阶段进展（含 7 位短 SHA）> || <正斜杠文件或提交指针>`
3. **On-Disk Ticket Artifact**:
   - Regardless of whether the host provides an external ledger tool, always record `Accepted Amendments & Internal Adaptations` and the 3-line `Attempt Log` (`[1] tried`, `[2] error`, `[3] Route`) in each ticket markdown file so clean-room relays and `code-review` have a self-contained workspace record.
