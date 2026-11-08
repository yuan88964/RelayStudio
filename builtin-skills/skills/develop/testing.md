# Testing Cadence, Long-Command Sessions, and Slow-Test Acceleration

> **Unified Rules**: See [SKILL.md](SKILL.md) for the top-level `develop` orchestration spine (`Branch A / B`) and completion gates. Internal testing reference defining how `develop` fills the **Verification Scope** and **Tight-Loop Command** seams across single-slice and multi-ticket execution.

## 1. Three-Tier Test Cadence (Eliminating Concurrent Redundancy)

To prevent $N$ concurrent worktree subagents from redundantly running the same cross-module test suites and hitting single-call streaming timeouts:

| Execution Context (`tdd` Verification Scope Seam) | What to Run | What to Skip |
| :--- | :--- | :--- |
| **1. Worktree Mode** (`tdd` dispatched by `develop` Branch B inside a ticket worktree) | **Tight Loop (`1–3s`) + Static Typecheck**: bind `PYTHONPATH` / module resolution to the worktree root, run **only** the single test file 1:1 bound to the ticket (`## Tight Loop`), and run the project's static typechecker (e.g., `tsc --noEmit`, `pyright`, `mypy`, `cargo check`, if configured) once green and after merging `integration`. | **Skip cross-module `Blast Radius` scans and full-suite runs** inside individual worktrees. Cross-module regressions are caught once on `integration`. |
| **2. Single-Slice Mode** (`tdd` called by `develop` Branch A without a multi-ticket integration branch) | **Tight Loop + Static Typecheck + Blast Radius + Closeout Suite**: run the single test file during red-green cycles and static typecheck once green; then trace direct callers/importers of modified interfaces (`Blast Radius`) and run a single full-suite check at branch closeout. | Skip unrelated slow suites during red-green cycles. |
| **3. Integration Gate** (`develop` Branch B step 6, after all unblocked tickets merge into `integration`) | **Single Full-Suite & Typecheck Run**: run the full test suite and static typecheck **once** on `integration` (default 4-worker LPT parallel batch). | Do not re-run per-ticket tight loops separately if covered by the full suite. |

---

## 2. Test Seam & Fixture Discipline

- **Pre-agreed seams**: In unattended execution, `tdd` reads high-level test seams from `SPEC.md` (`Original Spec + Accepted Amendments`) or the ticket/dispatch brief. If a ticket requires a seam not listed in `SPEC.md`, test against the module's highest existing public interface, propose `Route: amend-spec <seam>: <why>` in the handoff, and note it in `ResidualRisk` without blocking.
- **Isolated fixtures**: Every test must bind to its own temporary directory (`tmp_path`), isolated config, and ephemeral port (`127.0.0.1:0`), tearing down any spawned subprocesses or headless browsers in `finally` / `teardown` so parallel worktrees never collide.
- **Specification-bound assertions**: Fix production code to satisfy existing assertions. Update an existing test assertion only when the requirement at that seam genuinely changed under an approved amendment (Category 2 change digestion).

---

## 3. Long Commands (>45s) & Session Observation Seam

Web hosts and tool bridges enforce a ~60–120s single-call streaming timeout. A transport timeout does **not** mean the local command failed.

1. **Pre-empt the 60s deadline via the Long-Command Session Seam**: Any command or test batch expected to take `> 45s` must be launched asynchronously in a background session via the host's **Long-Command Session Seam** (`hosts.md`), capturing the returned background session ID.
2. **Observe the existing session before retrying**: After any timeout, EOF, or stream disconnect:
   - Query the existing background session via the host's session observation tool (`hosts.md`) first.
   - If the command is still running in the background session, wait and poll its status until completion rather than starting a duplicate process.
   - If the session already completed for the current candidate commit, reuse its exit status and output directly.
   - Re-run only after confirming the previous session terminated without completing.

---

## 4. Slow-Test Acceleration Toolbox (Enable Only When `setup > 1s` or Suite Tail `> 60s`)

Keep standard fast tests on native `tmp_path` fixtures. Apply these zero-conflict techniques only when measured setup or tail latency demands it:

| Technique | When to Use | Zero-Conflict Implementation |
| :--- | :--- | :--- |
| **1. 4-Worker LPT Parallel Queue** | Default for the final full-suite run on `integration` or large module regressions | Sort test modules by historical real duration descending (Longest Processing Time first, avoiding small-file overwrite distortion) across 4 worker processes; no test source changes. |
| **2. Read-Only Master + Fast Copy** (`copytree` / `browser.newContext`) | Only when a module repeatedly runs identical heavy initialization (`setup > 1s`, e.g., DB schema + synthetic fixture seeding or browser launch) | Build 1 read-only master per module/process; copy via `copytree` or `browser.newContext()` per test in milliseconds. Tests requiring special empty/corrupt states keep native fixtures. |
| **3. External Manifest NodeID Sharding** (`manifest.json`) | When a single test file takes `> 60s` and drags the parallel tail | Never physically split `.py` test files. Partition the file's `nodeids` into 2–3 balanced groups in the runner's `manifest.json` (keeping parameterized cases of the same function together). |

---

## 5. Three-Tier Final Verification Reporting

At the close of `develop` (Branch A or Branch B), report verification explicitly across three tiers:
1. **Tier 1 (Synthetic / Automated Tests)**: exact test files or suite run, static typecheck status, pass/fail counts, duration.
2. **Tier 2 (Live External API / Tunnel Integration)**: real network/tunnel verification if applicable.
3. **Tier 3 (Real-Machine UI / Desktop Interaction)**: live UI or browser verification if applicable.
Explicitly mark any unrun tier as `Not run (<reason>)` rather than implying full coverage.

**Return to Caller**: Apply the selected test cadence (`Worktree`, `Single-Slice`, or `Integration Gate`) and 3-tier verification reporting and return to [SKILL.md](SKILL.md) (`§2` & `§3`).
