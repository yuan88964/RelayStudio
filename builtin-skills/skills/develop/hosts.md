# Host Capability Seams & Thin Adapter Matrix

Internal host-adapter reference for the `develop` module. Core workflow files ([SKILL.md](SKILL.md), [testing.md](testing.md), [protocol.md](protocol.md)) depend only on the three abstract host capability seams below and never reference specific host internals or tool names directly.

## 1. Three Host Capability Seams & Concrete Adapter Matrix

Select the first matching adapter in the active runtime environment:

| Host Capability Seam | Abstract Contract | Adapter A: MCP-Bridged Web / Desktop Host (e.g., RelayStudio) | Adapter B: IDE / Local CLI Host (e.g., Antigravity / Codex CLI / Claude Code) | Adapter C: Minimal Fallback (No Subagent or External Ledger Tools) |
| :--- | :--- | :--- | :--- | :--- |
| **1. Subagent Dispatch Seam** | Accept a sparse pointer brief, execute in an isolated context/worktree, and return the 6-line handoff ([protocol.md](protocol.md)). | Spawn the host's built-in cloud subagents with **host defaults only** (never pass model or reasoning-effort arguments). Subagents work in isolated git worktrees. | Invoke native IDE subagents or local CLI role subagents (`explorer`, `implementer`, `implementer_deep`, `reviewer`; model and reasoning effort resolve from `~/.codex/agents/*.toml`). | Execute the per-ticket `tdd` + `code-review` flow serially in the main window and state `"Subagents: none (serial main-window execution)"` in the final report. |
| **2. Long-Command Session Seam** | Run commands expected to take `> 45s` asynchronously in a background session returning a session ID; inspect live status/output on timeout or disconnect before retrying ([testing.md](testing.md)). | Launch via `exec_command` (`execution_mode="auto"` or `"async"`, which returns a background `session_id`); on timeout/disconnect, inspect via `session_observe` (`action="status"` or `"list"`). | Launch via the host's background command tool (e.g., `run_command` + `manage_task`, or CLI background task) and query status before retrying. | Check running OS processes / background job output before re-running any timed-out command. |
| **3. Task Progress Ledger Seam** | Synchronize lowercase status tokens (`pending`, `in_progress`, `completed`, `two_strike_stop`, `quarantined`) and single-line milestone summaries ([protocol.md](protocol.md)). | Call `task_manage(action="create")` at task start and `task_manage(action="checkpoint", step_id=..., status=..., summary="<中文阶段进展（含 7 位短 SHA）> \|\| <正斜杠文件或提交指针>")` on each ticket merge or quarantine. | Record status tokens, `Accepted Amendments`, and the 3-line `Attempt Log` directly in the local ticket `.md` files. | Record status tokens, `Accepted Amendments`, and the 3-line `Attempt Log` directly in the local ticket `.md` files. |

---

## 2. Concurrency Discipline & Single-Tunnel Contention Offloading

Schedule parallel worktrees by blast-radius independence and tunnel load rather than an arbitrary static cap:

1. **Non-overlapping frontier concurrency**:
   - Dispatch ready tickets in parallel only when their touched files and shared interfaces are disjoint.
   - Tickets modifying the same files or the same shared contract run serially, after locking the shared interface on `integration`.
2. **Single-tunnel contention offloading ($\ge 3$ web cloud subagents)**:
   - When multiple web cloud subagents share a single local MCP bridge tunnel and $\ge 3$ concurrent subagents heavily invoke local file/shell tools simultaneously (causing tunnel queueing or 60s stream timeouts), switch to **Snapshot + Patch Hybrid Mode**:
     1. Main window packages the relevant source snapshot and publishes it to the cloud sandbox (`publish_artifact`);
     2. Cloud subagents compute edits in their cloud sandbox and write unified `.patch` files back to `D:/Temp/`;
     3. Main window applies each `.patch` locally and runs the `1–3s` `Tight Loop` test file and static typecheck.
