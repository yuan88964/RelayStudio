---
name: writing-for-agents
description: Writing documents and structuring knowledge bases for agents. Use when creating or editing skills, modifying AGENTS.md or CLAUDE.md, structuring prompt orchestrators, reorganizing knowledge-base directories or index notes, or pruning bloated agent rules.
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/meta/writing-for-agents/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-06"
---

# Writing for Agents

Reference for writing any document or directory system an agent consumes: a skill, an `AGENTS.md` / `CLAUDE.md`, a knowledge-base index, or a doc reached by a pointer. The packaging differs; the writing does not: the same levers make each one predictable, since the agent takes the same _process_ every run rather than producing the same output.

- **Skill mechanics & invocation**: When authoring or editing a skill's frontmatter, invocation mode (`disable-model-invocation`), or router skill structure, read [SKILL-MECHANICS.md](SKILL-MECHANICS.md).
- **Deep-module seam design & concurrency**: When designing cross-module seams, flattening complex `if/else` branching, or coordinating parallel subagent workflows, consult [`../codebase-design/SKILL.md`](../codebase-design/SKILL.md).
- **Adjacent workflows**: To mine friction from past session transcripts before editing rules, use [`../retro/SKILL.md`](../retro/SKILL.md); to package and lint standalone managed skills with isolated environments, use [`../skill-authoring/SKILL.md`](../skill-authoring/SKILL.md).

## 0. Context-as-Sample, The Two Loads & Four-Quadrant Steering

The physical law governing LLM behavior is **context-as-sample**: every token in the active window—examples, legacy code, old notes, error logs, and the rule document itself—serves as an implicit sample that the model imitates. High signal-to-noise produces clean output; stuffing the window with stale drafts, contradictory patches, or heavy prohibitory prose causes **context contamination** (attention dilution, mechanical template-stamping, and style contagion). Fold stylistic expectations directly into the document's own formatting (connected prose for causal derivation, lists for $\le 5$ linear steps, tables for $\ge 3$ parallel dimensions, diagrams for cross-seam flows) and delete prose lectures about style.

Every document and pointer spends one of two budgets:
- **Context load** is the cost of always-loaded material on the agent's window (`AGENTS.md` lines, active skill descriptions, or inlined rules), spending tokens and attention on every turn whether or not it fires.
- **Cognitive load** is the cost on the human: remembering which documents exist and when to reach for each. It is the price of human agency; spend it where human judgment matters, remove it where it does not.

Choose between **implicit steering** (clean exemplars + compact leading words) and **explicit steering** (ordered steps + script gates + fallback routes) based on **model capability** and **context cleanliness**:

| Dimension | Clean, High-Quality Context | Noisy Legacy Context or Heavy History |
| :--- | :--- | :--- |
| **Strong Model**<br>*(infers intent, generalizes well)* | **Implicit steering first**<br>• Compact leading words + 1–2 gold exemplars<br>• Specify the completion bar; leave intermediate steps open | **Implicit steering + Subagent isolation + Script gate**<br>• Dispatch a read-only subagent to digest noisy sources and return a clean summary<br>• State positive replacement rules (`old pattern → new pattern`)<br>• Enforce hard invariants with a script or test gate |
| **Weak Model**<br>*(misses subtle pointers, drifts easily)* | **Lightweight steps + Exemplar**<br>• Explicit ordered steps + gold exemplar<br>• Checkable completion criterion at the end of each step | **Stepwise window split + External script check**<br>• Keep rules in a single source of truth<br>• Split into separate stage windows so each step sees only its own rules<br>• Offload objective checks to deterministic scripts |

## 1. Gather: Single Source of Truth, Co-location & Context Pointers

- **Single source of truth & single public entry**: Author each rule in one canonical place and expose **one top-level entry file** (`SKILL.md` or folder entry index) per skill or knowledge-base directory. External callers and global rules link only to that top-level entry file, never reaching into internal subfiles or copying secondary summaries across files.
- **Environment as truth**: Leave one-file or one-command lookups (`package.json`, directory layout, `--help`) to the runtime environment; document only unwritten conventions and non-obvious gotchas.
- **Co-location (within-file gathering)**: Keep a concept's definition, rules, and caveats under one heading with one canonical term (`GLOSSARY.md`) rather than scattered across a file, so reading one part brings its neighbors with it. (Duplication repeats one meaning in two places; scattering fragments one meaning across many.)
- **Context pointers**: A **context pointer** is a compact reference held in the agent's context (a skill's `description` or a routing line in `AGENTS.md`) that names out-of-context material and encodes the **branches** (distinct cases) that should trigger reading it. Material reached through a pointer escapes context load at the price of the pointer's own line. Because its _wording_ decides when and how reliably the agent reaches the target, sharpen a weak pointer before inlining its target:
  - **Front-load the leading word** where it does its triggering work.
  - **One trigger per branch**: collapse synonyms that rename the same branch.
  - **Cut identity the body already carries.**

## 2. Split: Inside-Module Disclosure vs. Cross-Module Splitting

Treat each skill folder or knowledge-base directory as a **deep module**: the top-level `SKILL.md` (or folder index) is its public interface and main controller, while sibling files inside the folder are private encapsulated internals. Splitting documents happens at two distinct levels:

- **Inside a module — Information hierarchy & progressive disclosure**: A document mixes **steps** (ordered actions the agent performs) and **reference** (definitions, rules, facts consulted on demand) across a three-rung **information hierarchy** ranked by how immediately the agent needs the material:
  1. **In-file step** (primary tier): what the agent does, in order.
  2. **In-file reference**: consulted on demand (often a flat peer-set on one rung).
  3. **Disclosed reference**: pushed into an internal sibling file behind a context pointer, loaded only when that pointer fires.
  **Progressive disclosure** moves branch-specific detail down the ladder into private sibling files so the top-level `SKILL.md` keeps its organization simple and avoids **sprawl** (excess length that thins attention even when every line is unique). Inline what every branch needs; push behind an internal pointer what only some branches reach.
- **Across modules — When to split into separate skills**: Splitting one module into two separate skills spends one of the two loads, so split across modules only when keeping them in one folder hurts execution:
  - **By domain & invocation**: split into a separate skill when a capability belongs to an orthogonal domain, has a distinct trigger word the user or agent invokes directly, or is reused by multiple callers (see [SKILL-MECHANICS.md](SKILL-MECHANICS.md)).
  - **By sequence**: split a run of steps across separate skills or subagent windows when visible **post-completion steps** tempt the agent into **premature completion** (rushing the current step to reach the final output). Hiding later stages across a real context boundary (a hand-off or subagent dispatch) drives thorough **legwork** on the current stage.

## 3. Polish: Role-Specific Structure, Completion Criteria & Leading Words

### Shape by Document Role

Polish each file from outside in according to the role it plays in the system:

| Document / Directory Role | `1. Gather` (Scope & Seam) | `2. Split` (Hierarchy & Isolation) | `3. Polish` (Internal Structure & Entry Behavior) |
| :--- | :--- | :--- | :--- |
| **A. Standing Global Rules & Top Indexes**<br>(`AGENTS.md`, `README.md`, folder entry indexes) | Consolidate universal invariants and top-level routing in one master file; expose one entry index per folder. | Keep always-loaded text ultra-compact; push domain workflows behind one-line context pointers; separate active specs from archival logs. | State core collaboration invariants and a flat 1-hop domain routing list or table; define the global runtime `Error + Route` fallback once in the master rule file (place a redirect banner at the top of archival folders). |
| **B1. Multi-Branch Domain Orchestrators**<br>(`develop`, `math-teaching`, `mermaid-diagrams`) | Package tightly coupled workflows and shared protocols behind one top-level `SKILL.md`. | Inline the 90% routing spine in `SKILL.md`; disclose heavy protocols (`testing.md`, `protocol.md`, `hosts.md`) in private sibling files. | Open with a compact entry scope & routing block (`Typical direct path / Non-typical entry normalization / Out-of-bounds Error + Route`) to dispatch sub-skills and guard domain boundaries. |
| **B2. Focused Pipeline Skills**<br>(`code-review`, `diagnosing-bugs`, `tdd`) | Keep all steps for one cohesive pipeline in `SKILL.md`, with zero reverse links to parent orchestrator internals. | Inline the ordered pipeline steps; disclose large example banks (`tests.md`, `mocking.md`) in sibling files. | Start directly with the ordered workflow; weave $M \to 1$ entry normalization (e.g., default git refs or building a `red` loop), idempotent skip rules, and `Error + Route` bailouts directly into Step 1 and each step's completion criterion. |
| **C. Pure Reference Docs & Domain Notes**<br>(`writing-for-agents`, `codebase-design`, domain notes) | Co-locate each concept's definition, rule, and caveat under one heading; maintain one canonical term per concept (`GLOSSARY.md`). | Push low-frequency sub-branch mechanics (`SKILL-MECHANICS.md`, `DEEPENING.md`, `DESIGN-IT-TWICE.md`) behind internal pointers. | Format the document itself as the stylistic exemplar: flatten `if/else` prose into top-to-bottom decision trees or comparison tables ($\ge 3$ parallel dimensions), anchor concepts with leading words, and phrase rules positively. |

### Steps, Completion Criteria & Script Gates

Every step ends on a **completion criterion** that tells the agent the work is done. The strongest criteria are both checkable and exhaustive:
- **Clarity** resists **premature completion**: sharpen a vague bound ("understanding reached") into an observable state before resorting to a sequence split.
- **Demand** drives **legwork** (the digging the agent does within the work, latent in the wording rather than written as its own step): "every modified model accounted for" or "every rule applied" enforces thoroughness across both sequential steps and flat reference.
- **Deterministic script & test gates**: Turn objective red lines—mechanical formatting, static link/anchor checks, and `1–3s` tight-loop tests ([`../develop/SKILL.md`](../develop/SKILL.md))—into deterministic scripts that cost zero context load until they fail. After two consecutive same-root-cause failures (`two_strike_stop`), revert and relay in a clean window rather than looping in polluted context.

### Leading Words, Positive Steering & Pruning

- **Leading words**: A **leading word** is a compact concept already living in the model's pretraining (_lesson_, _fog of war_, _tracer bullets_, _tight_, _red_, _seam_) that the agent thinks with while running the document. Repeated as a single token rather than a restated sentence, it recruits pretrained priors to anchor _execution_ in the body and _invocation_ in pointers:
  - `"fast, deterministic, low-overhead"` → _tight_ (a _tight_ loop).
  - `"a loop you believe in"` → _red_, turning a fuzzy gate into a binary observable state (the loop goes _red_ on the bug, or it doesn't).
- **Prompt the positive**: Naming a forbidden behavior drags it into attention (*Don't think of an elephant*), where the strongly-activated concept overruns the weak negation. Choose between pure positive phrasing and a bounded guardrail by testing whether the positive action alone rules out the failure:
  - **Mutually exclusive target (default)**: When doing the target action naturally leaves no room for the unwanted one, state only the positive action so the banned one is never spoken (`"lead with the conclusion"`, `"write one-line comments"`).
  - **Additive overreach or pre-activated default (boundary guardrail)**: When the agent could complete the positive action *and still* continue into an unapproved next step, or when the host/context already pre-activates a conflicting tool or legacy habit, state the boundary and close the sentence on the positive exit action (`"Before user go-ahead, do not edit files—run read-only research and stop after listing the change plan"`).
- **Delete sediment and no-ops**: Delete any sentence the model already obeys by default, and keep historical migration logs in Git or archival folders rather than active rule files.
