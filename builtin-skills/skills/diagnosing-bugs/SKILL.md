---
name: diagnosing-bugs
description: Diagnosis loop for hard bugs and performance regressions. Use when the user says "diagnose"/"debug this", or reports something broken/throwing/failing/slow.
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/diagnosing-bugs/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-07"
---

# Diagnosing Bugs (`diagnosing-bugs`)

Six-phase diagnosis worker for hard bugs and performance regressions. Explore `GLOSSARY.md` and local ADRs first, and redact every secret (`<REDACTED>`) in commands, logs, and captured traces before quoting them.

- **`Standard` (Reproducible symptom in local environment)**: Execute Phases 1–6 sequentially, advancing to the next phase only after the current phase's observable completion gate passes.
- **`Normalize` (Auth-bearing traces or flaky / non-deterministic bugs)**: Strip credentials into environment variables (`<REDACTED>` in outputs) and quote only signal-bearing lines; for intermittent bugs (`1%` flake), loop the trigger `100×` with parallel stress or narrowed timing windows until the reproduction rate is high enough (`>= 50%`) to debug deterministically.
- **`Bailout` (Unable to build a red-capable loop or missing unredacted access)**: Halt before Phase 2/3 hypothesis generation and emit `Error: unable to construct red-capable loop after trying <approaches>` + `Route: need <environment|artifact|instrumentation>: <specific access, HAR/log dump, or permission needed>` (or `Route: ask-user <question>`).

---

## Phase 1: Build a Tight, Red-Capable Feedback Loop

**This is the core skill.** A **tight** (`1–3s`), **red-capable** pass/fail command that reliably goes red on _this specific bug_ makes bisection, hypothesis testing, and verification mechanical.

### 10 Loop Construction Patterns (Try from Fastest to Broadest)

1. **Failing test** at the closest public seam that reaches the bug (unit, integration, e2e).
2. **Curl / HTTP script** against a running dev server.
3. **CLI invocation** with fixture input, diffing stdout against a known-good snapshot.
4. **Headless browser script** (Playwright) driving UI and asserting on DOM/console/network.
5. **Captured trace replay** feeding a saved network payload or event log into the code path in isolation.
6. **Throwaway minimal harness** spinning up one module with boundary stand-ins via a single call.
7. **Property / fuzz loop** running `1000` seeded inputs to trigger intermittent wrong output.
8. **Automated bisection harness** (`git bisect run <script>`) between a known-good and known-bad state.
9. **Differential loop** running identical inputs through old vs. new versions and diffing outputs.
10. **Structured HITL script** (`scripts/hitl-loop.template.sh`) when human UI interaction is unavoidable.

### Tighten the Loop (`1–3s` Target)
Once a raw loop exists, sharpen it before moving on:
- **Speed**: Cache setup, skip unrelated initialization, and run only the single target check (`1–3s`).
- **Determinism**: Pin time, seed RNG, isolate `tmp_path`, freeze network, or stress-loop flaky triggers (`100×`).
- **Signal**: Assert on the user's exact symptom rather than generic exit status.

### Phase 1 Gate (Required Before Phase 2)
Phase 1 is complete only when you have **already run one command** (shown with redacted output) that is:
- [ ] **Red-capable**: drives the bug path and fails on the user's exact symptom;
- [ ] **Deterministic**: produces a consistent verdict (or pinned high flake rate);
- [ ] **Fast (`1–3s`)** and **Agent-runnable** unattended.
*(If no red-capable command can be constructed, trigger the `Bailout` contract above and stop.)*

---

## Phase 2: Reproduce & Minimise

Run the Phase 1 command, watch it go red, and shrink the reproduction to the **smallest load-bearing scenario** by cutting inputs, callers, config, and steps **one at a time** (re-running the loop after each cut).

### Phase 2 Gate (Required Before Phase 3)
- [ ] The loop reproduces the exact failure mode the user reported across runs;
- [ ] **Every remaining element is load-bearing**: removing any single remaining input or step makes the loop go green.

---

## Phase 3: Hypothesise (`3–5` Falsifiable Predictions)

Generate **3–5 ranked hypotheses** before testing any single idea so attention stays unanchored. Express every hypothesis as a falsifiable prediction:

> **Format**: `"If <X> is the cause, then <changing Y> will make the Phase 1 loop go green / <changing Z> will shift the symptom to <W>."`

Share the ranked list briefly with the user when interactive (continuing immediately with the top-ranked hypothesis when running unattended).

---

## Phase 4: Instrument One Variable at a Time

Map each probe to a specific Phase 3 prediction and change **one variable at a time**:
1. **Debugger / REPL inspection** at the boundary when supported.
2. **Targeted boundary logs** tagged with a unique prefix (`[DEBUG-a4f2]`) at the exact seam that distinguishes hypotheses so cleanup is a single `grep`.
3. **Performance regression branch**: Establish a baseline timing/profiler/query-plan measurement first, then bisect.

---

## Phase 5: Fix + Regression Test at a Deep Seam (`1-Line Baseline` vs. `module-design`)

Write the regression test from the minimised Phase 2 repro **before applying the fix**:
- **1-Line Baseline (Existing deep seam)**: When the existing public interface already exercises the real multi-caller or stateful bug pattern in `1–3s`, turn the minimised repro directly into a failing test at that seam.
- **Bounded Subroutine Call to [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A, Operation A1`)**: When the available seam is too shallow to reproduce the real call chain (or requires mocking internal collaborators), invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch A, Operation A1`) as a subroutine (or emit `Route: use module-design: deepen seam so bug pattern is testable`), consume Lines 2, 3, and 5 of the returned **5-Line Module Blueprint** inline to deepen the seam, and immediately resume Step 1 below:
  1. Write the minimised repro as a failing test at the seam and watch it fail (`diff` against pristine state if you mutated code/fixtures to verify the test catches the bug).
  2. Apply the minimal production fix and watch the test go green.
  3. Re-run the Phase 1 feedback loop against the original un-minimised scenario.

---

## Phase 6: Cleanup Gate & Caller Override Seam (`Recency Peak`)

### Phase 6 Completion Gate
Verify all 5 checks before declaring diagnosis and fix complete:
- [ ] Original un-minimised Phase 1 reproduction loop passes green;
- [ ] Minimised regression test passes at the public seam (`1–3s`);
- [ ] All `[DEBUG-...]` logs and throwaway harnesses are removed (`grep` verified clean);
- [ ] Every secret in the diagnostic report/commit is replaced with `<REDACTED>`;
- [ ] The confirmed root-cause hypothesis and falsifying evidence are stated concisely in the commit/PR or diagnostic report.

### Caller Override Seam
When invoked by an upper orchestrator (such as `develop`), report blocked loops via the caller's 6-line handoff contract (`Error` + `Route`), keep file-path and line-number root-cause evidence in the ticket's `Attempt Log` or diagnostic note rather than `SPEC.md`, and immediately return control to the caller once the Phase 1 loop or Phase 6 fix is complete.
