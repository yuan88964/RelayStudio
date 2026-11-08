---
name: module-design
description: Foundational deep-module design operator and shared vocabulary. Use when designing or deepening a module's interface, deciding where a seam goes, partitioning orthogonal modules for concurrency, flattening if/else branching, making code, AI skills, or method systems more testable and navigable, or when invoked as a subroutine by another skill.
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/codebase-design/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-07"
---

# Module Design (`module-design`)

Foundational operator for designing **deep modules**: a lot of behaviour behind a small interface, placed at a clean seam, verifiable in `1–3s` through that interface. Upper container skills (`develop`, `tdd`, `to-spec`, `to-tickets`, `code-review`, `diagnosing-bugs`, `improve-codebase-architecture`, `writing-for-agents`, `math-teaching`) pass an unshaped or tangled target into this skill, run the **Universal Stem** (`§0–§1`) plus the matching **Domain Branch** (`§2`), emit the **5-Line Module Blueprint** (`§3`), and immediately resume their own workflow.

---

## 0. Why Deep Modules Matter: Complexity, Leverage & `1–3s` Verification

System complexity stems from two roots: **dependencies** (when a piece cannot be understood or modified in isolation) and **obscurity** (when critical assumptions and invariants are hidden across files). Together they cause **change amplification** (one logical change forces edits across many sites), **cognitive and context load** (callers must read the whole implementation just to use it), and **unknown unknowns**.

Producing a globally correct complex system in one shot is hard for both humans and LLMs, but **verifying a candidate at a clean seam is fast (`1–3s` tight loop)**. We fight complexity by building **deep modules** instead of shallow ones:

```text
Deep module = small interface + deep implementation (Target):
┌─────────────────────┐
│   Small Interface   │  ← Few entry points, simple params, explicit 3-state contract
├─────────────────────┤
│                     │
│  Deep Implementation│  ← Complex rules, state transitions, and edge cases hidden inside
│                     │
└─────────────────────┘

Shallow module = large interface + thin implementation (Avoid):
┌─────────────────────────────────┐
│       Large Interface           │  ← Many methods, pass-through params, boolean mode flags
├─────────────────────────────────┤
│  Thin Implementation            │  ← Just forwards calls or exposes internal wiring
└─────────────────────────────────┘
```

Deep modules pay back in three ways:
- **High leverage for callers**: Callers learn a minimal surface while exercising massive underlying capability.
- **Strong locality for maintainers**: Bugs, invariants, and future edits stay confined inside one module rather than rippling across callers.
- **Fast isolated verification & safe concurrency**: Because clean seams hide internal state and eliminate cross-module coupling, each module can be tested in `1–3s` at its seam and developed in parallel without colliding on shared state.

---

## 1. Canonical Glossary & Universal Three-Step Operator (`Gather → Split → Polish`)

### Canonical Glossary

Use these terms exactly—do not substitute `"component"`, `"service"`, `"API"`, or `"boundary"`:

- **Module**: anything with an **Interface** and an **Implementation**. Scale- and substrate-agnostic: a function, class, or package in code; an AI skill folder or knowledge-base subsystem; or a mathematical method module.
- **Interface**: everything a caller must know to use the module correctly—not just the type signature or entry pointer, but also preconditions, invariants, ordering constraints, and error modes.
- **Implementation**: what sits inside the module behind its interface. Reach for **Adapter** when the seam is the topic; **Implementation** otherwise.
- **Depth**: leverage at the interface—the amount of behaviour a caller (or test) exercises per unit of interface they must learn. Measure depth by **leverage**, never by implementation line count.
- **Seam** _(Michael Feathers)_: a place where behaviour can be observed or altered without editing in that place; the exact location where a module's interface lives.
- **Adapter**: a concrete implementation that satisfies an interface at a seam (describes the *role* it fills, such as a production Postgres adapter vs. an in-memory test adapter).
- **Leverage**: what callers get from depth (more capability per unit of interface learned, amortized across $N$ call sites and $M$ tests).
- **Locality**: what maintainers get from depth (changes, bugs, and verification concentrate in one place).
- **Three-State Interface Contract (`Standard / Normalize / Bailout`)**:
  1. **`Standard`**: inputs meeting preconditions execute directly on the critical path;
  2. **`Normalize`**: non-standard or partial inputs are normalized ($M \to 1$) into canonical form at the entry before reaching core logic;
  3. **`Bailout`**: out-of-scope inputs, violated preconditions, missing capabilities, or blocked states (`two_strike_stop`) abort the main path at line 1 and emit both a one-line `Error` and a structured next-step `Route` (`use | need | drop | amend-spec | ask-user`).

### Universal Three-Step Operator (Work Top to Bottom: `1 → 2 → 3`)

#### 1. Gather: Scope by Shared Secrets & Pass the Deletion Test
Group pieces by **Parnas's information-hiding criterion** (whether they share a private design secret), never by execution order:
- **Gather shared secrets (cure *Temporal Decomposition* & *Information Leakage*)**: If two steps rely on the same private data structure, wire/file format, or core mechanism (changing one always forces editing the other), merge them into one module even if they run at different stages.
- **Apply the deletion test (cure *Pass-Through Layers* & *Conjoined Methods*)**: Imagine deleting the module. If complexity vanishes, it was a shallow pass-through wrapper—delete or inline it. If complexity reappears scattered across $N$ callers, the module is earning its keep.
- **Single source of truth & narrow `Context`**: Keep shared rules, schemas, or reference data in one authoritative master. Keep domain inputs and outputs explicit on the interface; bundle only cross-cutting runtime infrastructure (timeouts, read-only config snapshots, injected adapters) into `Context`.

#### 2. Split: Separate by Frequency Vertically & by Domain Horizontally
Deepening never means stuffing unrelated features into a monolith. When a module grows bloated, split along two orthogonal axes:
- **Vertical split — High-frequency general core vs. low-frequency special cases**: Extract high-frequency mechanisms into a *somewhat general-purpose* core whose interface stays free of rare options; push low-frequency special cases up to callers or out to on-demand disclosed files.
- **Horizontal split — Orthogonal domains for safe concurrency**: Even when two steps run sequentially (`A -> B`), keep them in separate modules behind a clean seam if they hide different domain secrets or change at different rates. Ensure horizontal modules share **zero mutable state** so once their shared seam is locked, they can run or be built in parallel; serialize work touching the same module or shared contract.

#### 3. Polish: Refine the Interface & Internals from Outside In
Once scope is bounded by Steps 1 and 2, polish the module from its external seam inward:
1. **Enforce the 3-state contract at the entry**: Guard out-of-scope inputs first (`Bailout`), normalize $M$ input variants into $1$ canonical internal representation (`Normalize`), then run core logic (`Standard`).
2. **Flatten `if/else` branching**: Replace multi-target `else if` chains with a static lookup table of thin **Adapters** at the seam, and choose internal data models that treat edge cases as ordinary cases (e.g., an empty selection as length `0`).
3. **Pull complexity downwards & eliminate errors safely**: Auto-compute internal mechanism parameters rather than exporting config knobs; provide zero-config defaults for the 90% case. Apply *defining errors out of existence* (silent convergence, such as deleting an already-absent item) and *low-level retry masking* **strictly to idempotent operations**; trigger a `Bailout` (`Error` + `Route`) on broken invariants or non-idempotent failures.
4. **Write the interface comment first as a complexity canary**: State preconditions, invariants, and observable outcomes before writing the body. If the interface is hard to name or takes a paragraph of caveats to explain, the module is still shallow—reshape it before implementing.

---

## 2. Domain Branches & Specific Operations (Select by Caller Container)

After applying the Universal Stem (`§1`), follow the branch matching the calling container:

### Branch A: Software Code & Architecture Containers
*(Used when called by `develop`, `tdd`, `to-spec`, `to-tickets`, `code-review`, `diagnosing-bugs`, `improve-codebase-architecture`, or `setup-ts-deep-modules`)*

- **Core Code Rules**:
  - **Depth is a property of the interface, not the implementation.** A deep module can be internally composed of small, testable parts; keep **internal seams** private and never expose them on the public interface.
  - **The interface is the test surface.** Callers and `1–3s` tight-loop tests cross the exact same external seam.
  - **One adapter means a hypothetical seam; two adapters mean a real one.** Introduce an injected port only when at least two adapters are justified (typically production + test stand-in).
- **Three Testability Patterns at the Interface**:
  1. **Accept dependencies, don't create them internally**:
     ```typescript
     // Testable at the seam (Deep)          // Hard to test (Hidden coupling)
     function processOrder(order, gateway)   function processOrder(order) {
     { ... }                                   const gateway = new StripeGateway();
                                             }
     ```
  2. **Return results, don't mutate arguments in place**:
     ```typescript
     // Testable pure outcome                // Side-effect mutation
     function calculateDiscount(cart): Money function applyDiscount(cart): void {
     { ... }                                   cart.total -= discount;
                                             }
     ```
  3. **Minimize surface area**: Fewer methods and simpler parameter types mean fewer tests and near-zero test setup.
- **1-Hop Code Operations (Read Sibling File on Demand)**:
  - **Operation A1 — Dependency classification, stand-in selection & replacing shallow tests**: When deciding how to isolate dependencies (`In-process`, `Local-substitutable`, `Remote but owned [Ports & Adapters]`, `True external [Mock]`) or pruning old unit tests after deepening (`replace, don't layer`), read [DEEPENING.md](DEEPENING.md).
  - **Operation A2 — Exploring alternative interfaces in parallel ("Design It Twice")**: When designing a major new module or refactoring a tangled interface with multiple plausible shapes, read [DESIGN-IT-TWICE.md](DESIGN-IT-TWICE.md) to spawn parallel subagents across 3–4 design postures and compare trade-offs.

### Branch B: Agent Skills, Prompts & Knowledge-Base Containers
*(Used when called by `writing-for-agents` or `mermaid-diagrams`)*

- **1. Gather (Single Source of Truth & Single Entry)**: Treat each skill folder (`Skills/<name>/`) or knowledge-base directory as a deep module. Its public interface is its always-loaded **context pointer** (YAML `description` or routing row in `Global_Agent_Rules.md`) plus **one top-level entry file** (`SKILL.md` or folder index). Co-locate each concept's definition, rules, and caveats under one heading; external callers link only to the top-level entry file, never reaching into internal subfiles.
- **2. Split (Flat `1-Hop` Disclosure & Subroutine / Sequence Cuts)**:
  - **Vertical split inside a module**: Inline the 90% execution spine (and short 10–30 line caller branches) in `SKILL.md` so routine runs finish in 1 read; push heavy reference tables or protocols into **strictly 1-hop sibling files** (`testing.md`, `SKILL-MECHANICS.md`, `references/*.md`), ending every sibling file with a 1-line `Return to Caller` anchor.
  - **Horizontal split across modules**: Keep a 1-sentence baseline invariant locally inside each container skill (`1-line baseline + on-demand subroutine cut`) and extract shared operators (`module-design`, `grilling`, `domain-modeling`) into model-invoked subroutine skills; split sequential stages across separate skills or subagent windows when visible post-completion steps tempt premature completion.
- **3. Polish by Module Role (`Router / Orchestrator / Worker / Subroutine`) & Tight Gate**:

| Document / Directory Role | Scope & Public Seam (`Gather`) | Hierarchy & Isolation (`Split`) | Internal Structure & Entry Contract (`Polish`) |
| :--- | :--- | :--- | :--- |
| **1. Router**<br>`Global_Agent_Rules.md`, `README.md`, folder indexes | Consolidate global invariants and top-level routing in one master file; expose one index per folder. | Keep always-loaded text ultra-compact; push domain workflows behind 1-line context pointers; separate active specs from archives. | State core collaboration invariants and a flat 1-hop routing list/table; define the global `Bailout` (`Error` + `Route`) contract once in the master rule file. |
| **2. Orchestrator**<br>`develop`, `writing-for-agents`, `math-teaching`, `mermaid-diagrams` | Package domain workflows and shared protocols behind one top-level `SKILL.md`. | Inline the 90% routing/execution spine in `SKILL.md`; disclose heavy protocols (`testing.md`, `protocol.md`, `SKILL-MECHANICS.md`) in 1-hop sibling files. | Open with a Three-State Interface Contract (`Standard / Normalize / Bailout`), delegate unsettled seams to `module-design`, and close with a checkable verification gate at the bottom (`Recency Peak`). |
| **3. Worker**<br>`tdd`, `code-review`, `diagnosing-bugs`, `to-spec`, `to-tickets` | Keep all steps for one focused worker in `SKILL.md`, with zero reverse links to parent orchestrators. | Inline ordered execution steps and 1-line baseline rules; disclose large example banks (`tests.md`, `mocking.md`) in 1-hop sibling files. | Start directly with entry normalization (`Normalize`), ordered steps, and `Bailout` exits; expose a compact `Caller Override Seam` at the bottom. |
| **4. Subroutine & Reference**<br>`module-design`, `grilling`, `domain-modeling`, domain notes | Co-locate universal concepts, glossary terms (`GLOSSARY.md`), and shared operators in one authoritative master. | Structure callable subroutines in 4 parts: **1. Top universal stem** $\to$ **2. Middle caller-keyed branches** $\to$ **3. Flat 1-hop sibling files with `Return to Caller`** $\to$ **4. Bottom fixed-shape output blueprint**. | Enforce dual-side locking: caller frames the jump as a bounded subroutine call, and the bottom section emits the fixed blueprint and immediately resumes the calling orchestrator inline without re-reading the caller's file. |

### Branch C: Pedagogical & Method-System Containers
*(Used when called by `math-teaching`)*

- **Gather (Method-centric curation)**: Gather problems that share the **same underlying mathematical breakthrough mechanism** into one canonical method module, replacing superficial problem-type catalogs.
- **Split (Orthogonal decoupling & load hierarchy)**: **Horizontally** isolate problems requiring unlearned cross-domain mechanisms (e.g., number-theoretic divisibility or pigeonhole bounds inside a function chapter) into dedicated micro-modules; **vertically** keep the classroom spine to **1 core method module + 3 representative problems** (one per state) and push bulk exercise sets / PDF slices into background problem-bank indexes.
- **Polish (Role-separated 3-state delivery)**: Structure teacher-prep indexes around the 3-state contract (`模块职责 / 1. 典型情景 Standard / 2. 非典型情景 Normalize / 3. 退路情景 Bailout [drop 死胡同 / use 转接 / need 缺前置]`), and internalize the progression invisibly into natural mathematical exposition in student-facing handouts.

---

## 3. Subroutine Output & Return Contract (Emit Blueprint, Then Resume Caller)

`module-design` is a **callable design subroutine, not an open-ended conversation session**. Complete the design pass by producing this compact **5-Line Module Blueprint**:

```text
1. Modules & Scope (Gather/Split): <merged shared secrets, cut pass-throughs, and resulting deep modules>
2. Public Interface & 3-State Seam: <entry signature + Standard / Normalize / Bailout contract at the seam>
3. Hidden Internals & Adapters: <encapsulated implementation / disclosed sibling files + adapter or test stand-in strategy>
4. Orthogonality & Concurrency: <disjoint modules safe for parallel execution vs. shared seams that must be locked first>
5. Tight Verification Gate (1–3s): <exact 1:1 test command, check_architecture.py command, or 3-state representative check>
```

**Completion & Immediate Return Rule**: As soon as the **5-Line Module Blueprint** above is produced (and passed the deletion test), **this subroutine is complete**—immediately return control to the calling container skill (`develop`, `tdd`, `to-spec`, `to-tickets`, `code-review`, `diagnosing-bugs`, `improve-codebase-architecture`, `writing-for-agents`, or `math-teaching`) at the exact step that invoked `module-design` and continue executing the caller's workflow.
