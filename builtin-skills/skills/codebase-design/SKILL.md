---
name: codebase-design
description: Shared vocabulary and structural principles for designing deep modules across code, AI skills/prompt orchestrators, and knowledge bases. Use when the user wants to design or improve a module's interface, flatten complex if/else branching, find deepening opportunities, decide where a seam goes, make code or skills more testable, parallelizable, or AI-navigable, or when another skill needs the deep-module vocabulary.
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/codebase-design/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-06"
---

# Codebase Design

Design **deep modules**: a lot of behaviour behind a small interface, placed at a clean seam, testable through that interface. Use this language and these principles wherever code, skills, or knowledge-base subsystems are being designed or restructured. The aim is leverage for callers, locality for maintainers, and fast `1–3s` verification for everyone.

## Glossary

Use these terms exactly: don't substitute "component," "service," "API," or "boundary." Consistent language is the whole point.

**Module**: anything with an interface and an implementation. Deliberately scale-agnostic: a function, class, package, tier-spanning slice, an AI skill/prompt orchestrator, or a knowledge-base subsystem. _Avoid_: unit, component, service.

**Interface**: everything a caller must know to use the module correctly: the type signature, but also invariants, ordering constraints, error modes, required configuration, and performance characteristics. _Avoid_: API, signature (too narrow, they refer only to the type-level surface).

**Implementation**: what's inside a module, its body of code or internal workflow. Distinct from **Adapter**: a thing can be a small adapter with a large implementation (a Postgres repo) or a large adapter with a small implementation (an in-memory fake). Reach for "adapter" when the seam is the topic; "implementation" otherwise.

**Depth**: leverage at the interface. The amount of behaviour a caller (or test) can exercise per unit of interface they have to learn. A module is **deep** when a large amount of behaviour sits behind a small interface, **shallow** when the interface is nearly as complex as the implementation.

**Seam** _(Michael Feathers)_: a place where you can alter behaviour without editing in that place; the *location* at which a module's interface lives. Where to put the seam is its own design decision, distinct from what goes behind it. _Avoid_: boundary (overloaded with DDD's bounded context).

**Adapter**: a concrete thing that satisfies an interface at a seam. Describes *role* (what slot it fills), not substance (what's inside).

**Leverage**: what callers get from depth. More capability per unit of interface they learn. One implementation pays back across N call sites and M tests.

**Locality**: what maintainers get from depth. Change, bugs, knowledge, and verification concentrate in one place rather than spreading across callers. Fix once, fixed everywhere.

## Why Deep Modules Matter

Complexity stems from **dependencies** (code that cannot be understood or modified in isolation) and **obscurity** (hidden assumptions and invariants), showing up as **change amplification**, **cognitive load**, and **unknown unknowns**. Deep modules fight complexity in three ways:

- **Fast verification at the seam (`1–3s` tight loop)**: Producing a globally correct solution in one shot is hard, but verifying a candidate at a clean seam is fast. When a module is deep, plugging a lightweight stand-in at its seam ([DEEPENING.md](DEEPENING.md)) lets a `1–3s` tight-loop test verify behaviour without booting the whole system.
- **High leverage and locality**: Callers learn a minimal interface while all edge cases, multi-step coordination, and state invariants stay locked inside the implementation.
- **Strategic refactoring trigger**: When a change forces you to copy branches across files, thread pass-through parameters across layers, or add boolean mode flags to an interface, stop patching tactically—compare alternatives first ([DESIGN-IT-TWICE.md](DESIGN-IT-TWICE.md)) and reshape the module.

## Three Rules to Deepen Modules: Gather, Split, Polish

Locate the friction in the overview table below, then work the decision tree **top to bottom (`1 → 2 → 3`)**: first bound the module's external scope (`1. Gather` and `2. Split`), then refine its interface and internals from outside in (`3. Polish`).

| Rule & Order | Smell (Trigger) | Core Move | Code Application | Skill & Knowledge-Base Application |
| :--- | :--- | :--- | :--- | :--- |
| **1. Gather: Scope Shared Secrets** | Two pieces always change together, or multiple sites maintain copies of the same rule or data | Merge steps that share a private design secret or align state at high frequency; consolidate shared data into a single source of truth | Merge protocol reading and parsing; cut pass-through wrappers; keep one authoritative config or state store | Package tightly coupled steps behind one orchestrator `SKILL.md`; keep one master file for global rules, `GLOSSARY.md`, and protocols |
| **2. Split: Separate Frequency & Domain** | A module mixes high/low-frequency features or distinct domains, activating on every task and forcing callers to hunt through noise | **Vertically** split high-frequency general mechanisms from low-frequency special cases; **horizontally** split distinct domains for high cohesion and low coupling | Extract a somewhat general-purpose lower core; isolate domain modules so unrelated requests never pile onto one class | **Horizontally** split top-level domain skills; **vertically** keep every-run core contracts in `SKILL.md` and push rare branches to on-demand files |
| **3. Polish: Refine from Outside In** | Sprawling `if/else` special cases, excessive config knobs, defensive exception storms, or convoluted docstrings | Enforce a 3-state contract, flatten `if/else` via seam adapters and canonical normalization, pull complexity down, and define errors out of existence | Guard out-of-scope inputs at line 1, normalize $M \to 1$ shapes at entry, auto-compute mechanism params, and absorb idempotent edge cases | Weave 3-state routing into orchestrators, step-1 defaults into pipeline skills, and flat routing tables into knowledge-base indexes; keep one canonical term per concept (see [`../writing-for-agents/SKILL.md`](../writing-for-agents/SKILL.md)) |

### The Tree (Work Top to Bottom)

#### 1. Gather: Scope by Shared Secrets & High-Frequency Alignment
Decide whether two pieces belong together by **Parnas's information-hiding criterion** (whether they share a private design secret), never by execution order:
- **Gather shared secrets (cure *Temporal Decomposition* & *Information Leakage*)**: If two steps rely on the same private data structure, wire/file format, or internal invariant (changing one always forces editing the other), merge them into one deep module even if they run at different times (e.g., reading and writing the same format).
- **Merge conjoined methods and cut pass-through layers (cure *Conjoined Methods* & *Pass-Through*)**: If understanding method A requires reading method B, or if a wrapper layer merely forwards arguments without changing the abstraction, merge them so every layer provides a distinct abstraction.
- **Consolidate duplicate copies and ambient context (*Single Source of Truth* & narrow `Context`)**: Keep shared rules, schemas, or reference data in one authoritative master. Bundle only cross-cutting runtime infrastructure (timeouts, read-only config snapshots, injected host adapters) into an explicit `Context`; keep domain inputs and outputs explicit on the interface signature so `1–3s` tight-loop tests need no heavy setup.

#### 2. Split: Separate by Frequency Vertically & by Domain Horizontally
Deepening never means stuffing unrelated features into a monolith. When a module grows bloated, split along two orthogonal axes:
- **Vertical split — High-frequency general core vs. low-frequency special cases (cure *Overexposure* & *Special-General Mixture*)**: Extract high-frequency mechanisms into a *somewhat general-purpose* deep module (implementation reflects only current needs, while its interface stays general and keeps the critical path free of rare options). Push low-frequency scenario rules into upper callers or disclosed on-demand files.
- **Horizontal split — Distinct business domains for high cohesion and low coupling**: Even when two steps run sequentially in a workflow (`A -> B`), keep them in separate deep modules behind a clean seam if they hide different domain secrets, serve different caller groups, or change at different rates. This prevents a single bloated module from activating on every scenario, forcing callers to search a massive context, and becoming a concurrency bottleneck.
- **Method-level split rule**: Split a method only into an independent low-level subtask that needs minimal parent state, or into two mode-free sibling methods; if readers must flip back and forth between them, join them back together.

#### 3. Polish: Refine the Interface & Internals from Outside In
Once scope is bounded by Steps 1 and 2, polish the module from its external seam inward:
1. **Three-state interface contract (`Standard / Normalize / Error + Route`)**:
   - *Standard path*: inputs meeting preconditions execute directly on the critical path;
   - *Normalize at entry*: non-standard or partial inputs are normalized into canonical form at the entry before reaching core logic;
   - *Guard & route at line 1 (`Error + Route`)*: out-of-scope inputs or blocked states are rejected at line 1 with a one-line `Error` and a structured next-step `Route` (`use`, `need`, `drop`, `amend-spec`, or `ask-user`).
2. **Flatten `if/else` branching from outside in**:
   - *Table-driven adapters at the seam*: replace multi-source or cross-host `else if` chains with a static lookup table of thin **Adapters**;
   - *Canonical entry normalization ($M \to 1$)*: convert $M$ heterogeneous input formats into $1$ canonical internal data structure at the entry;
   - *General internal model*: choose a data representation that treats edge cases as ordinary cases (e.g., representing an empty cursor as a selection of length `0`).
3. **Pull complexity downwards & eliminate errors safely**:
   - *Mechanism vs. policy*: auto-compute internal mechanism parameters (buffer sizes, backoff intervals, shard counts) from runtime state instead of exporting config knobs; keep domain policy configurable at the interface with zero-config defaults for the 90% case;
   - *Idempotent 4-tier error ladder*: (a) *Define errors out of existence* (silent target-state convergence, such as deleting an already-absent item) and (b) *low-level retry masking* apply **strictly to idempotent operations** that preserve data invariants; (c) *aggregate* remaining exceptions at a single top-level handler; (d) *fail fast* with `Error + Route` on non-idempotent side effects, broken invariants, or out-of-scope inputs.
4. **Write interface comments first as a complexity canary**:
   - Write interface comments (preconditions, units, invariants, with zero implementation details) before coding method bodies. If a module or parameter is *Hard to Pick a Name* for or *Hard to Describe* concisely, the abstraction is shallow—redesign it before coding.
   - Return results rather than mutating arguments, replace generic `Pair`/`Tuple` containers with named fields, and use one canonical term per concept (`GLOSSARY.md`).

- **Completion criterion for a module design pass**: (1) Passes the **deletion test** (deleting it would scatter complexity across callers); (2) Exposes a 3-state interface with table-driven adapters and $M \to 1$ entry normalization (or role-appropriate structure for agent docs and knowledge-base indexes per [`../writing-for-agents/SKILL.md`](../writing-for-agents/SKILL.md)); (3) Binds a 1:1 `1–3s` tight-loop test command (or deterministic link/index verification script for knowledge-base subsystems) at its public seam.

## Running Deep Modules in Parallel (Concurrent Tickets & Requests)

When multiple requests or tickets enter a system of deep modules simultaneously, run them through this four-stage pipeline:

| Stage | Concurrency Smell Prevented | System Mechanism | Software Runtime Execution | Multi-Ticket & Subagent Execution |
| :--- | :--- | :--- | :--- | :--- |
| **1. Lock Seams & Route** | Mid-flight interface drift forcing global rework; concurrent writes colliding on the same module | Lock shared **Seams** before branching; dispatch disjoint modules in parallel and queue tasks touching the same module or shared contract serially | Gateways shard requests by domain module; stateless/disjoint actors run in parallel while same-shard writes queue in order | Lock shared interfaces on the integration baseline first; dispatch non-overlapping frontier tickets in isolated worktrees and serialize overlapping tickets |
| **2. Isolated Tight Loop** | Loading full-system context and slow suites exhausts memory and buries workers in irrelevant noise | Load only the target module's minimal context and verify changes at its seam via a `1–3s` **Tight loop** | Worker threads/actors hold only local module state and validate steps locally without cross-service chatter | Each subagent receives a sparse pointer brief and runs only its 1:1 `1–3s` test file plus static typecheck inside its worktree |
| **3. Read/Write Split & Queues** | Contention on shared ledgers causing deadlocks or corruption; unbounded queues or polling exhausting resources | Serve high-frequency reads from **immutable snapshots** (lock-free); route shared ledger writes through a **single writer**; offload slow work via **bounded queues (with backpressure)** or snapshot/patch batches | Read paths query MVCC/read-only views; write paths go through a bounded single-writer queue; slow I/O uses async events instead of polling | Subagents read shared specs/glossaries immutable and log local adaptations in their handoff for the orchestrator (single writer) to record; `>45s` commands use background sessions |
| **4. Bulkhead & Staged Gate** | One wedged task halting the entire batch; green branches breaking when merged together | Roll back after two consecutive same-root-cause failures and isolate the blocked branch (**Bulkhead / Quarantine**) while unblocked work continues; sync baseline before merge and run one final gate | Failing modules trigger bounded retry and circuit-breaker bulkhead isolation, using idempotent commit or Saga compensation | After `two_strike_stop`, relay once in a clean window; if still blocked or needing human judgment, mark `quarantined`; merge latest integration tip before handoff and run the full suite once at the end |

## Relationships & Rejected Framings

- A **Module** has exactly one **Interface** (the surface it presents to callers and tests), living at a **Seam** and satisfied by an **Adapter**. **Depth** at that interface produces **Leverage** for callers and **Locality** for maintainers.
- **Rejected framings**:
  - *Depth as ratio of implementation-lines to interface-lines*: rewards padding the implementation; measure depth by **leverage** instead.
  - *"Interface" as only the type signature*: interface includes every invariant, ordering constraint, and error mode a caller must know.
  - *"Boundary"*: overloaded with DDD's bounded context; say **seam** or **interface**.

## Going deeper

- **Deepening a cluster given its dependencies**, see [DEEPENING.md](DEEPENING.md): the 4 dependency categories (`In-process`, `Local-substitutable`, `Remote but owned`, `True external`), seam discipline, and replace-don't-layer testing.
- **Exploring alternative interfaces**, see [DESIGN-IT-TWICE.md](DESIGN-IT-TWICE.md): spawn parallel sub-agents to design the interface several radically different ways, then compare on depth, locality, and seam placement.
