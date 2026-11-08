---
name: writing-for-agents
description: Writing documents and structuring knowledge bases for agents. Use when creating or editing skills, modifying AGENTS.md or CLAUDE.md, structuring prompt orchestrators, reorganizing knowledge-base directories or index notes, or pruning bloated agent rules.
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/meta/writing-for-agents/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-07"
---

# Writing for Agents (`writing-for-agents`)

Container workflow and prompt-engineering craft for authoring any document or directory system an agent consumes: a skill (`SKILL.md`), a standing rule file (`Global_Agent_Rules.md` / `AGENTS.md`), a knowledge-base index, or a disclosed reference doc.

- **`Standard` (Single-file prose or rule tuning)**: Apply the attention physics (`§0`) and micro-level prompt craft (`§2`) directly, then run the bottom verification gate (`§3`).
- **`Normalize` (New multi-file skills, splitting bloated files, or directory restructuring)**: First invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch B`) as a subroutine to run `Gather → Split → Polish` across the four module roles (`Router / Orchestrator / Worker / Subroutine`) and emit a **5-Line Module Blueprint**; when configuring skill frontmatter, `disable-model-invocation`, or callable subroutine locking, read [SKILL-MECHANICS.md](SKILL-MECHANICS.md); then resume here at `§2` to craft the prose and pointers.
- **`Bailout`**: When asked to modify active files before user go-ahead or when requirements conflict, abort edits at line 1 and emit `Error: <reason>` + `Route: ask-user | amend-spec`.

---

## 0. Why Agent Text Works Differently: Attention Physics, The Two Loads & Four-Quadrant Steering

The physical law governing LLM behavior is **context-as-sample**: every token in the active window—examples, legacy code, old notes, error logs, and the rule document itself—serves as an implicit stylistic and structural sample that the model imitates. High signal-to-noise produces clean output; stale drafts, contradictory patches, or heavy prohibitory prose cause **context contamination** (attention dilution, mechanical template-stamping, and style contagion). Fold stylistic expectations directly into the document's own formatting (connected prose for causal derivation, lists for $\le 5$ linear steps, tables for $\ge 3$ parallel dimensions, diagrams for cross-seam flows) so the document exemplifies the exact style it expects.

When an agent reads a file via a tool call, the tool appends the **entire file snapshot** to the bottom of the context scroll, and self-attention scans the whole scroll in parallel during prefill before emitting the next action. Across that scroll, attention weight follows a **U-shaped curve** (*Lost in the Middle*):
- **Top of scroll (`Primacy Bias`)**: The user's request and the calling container skill's active step anchor the global goal.
- **Middle of scroll (`Query-Key Selective Focus`)**: Middle sections activate reliably when keyed by terms already present at the top of the scroll (such as the calling container's name or a repeated leading word) and formatted as scannable tables or concise lists.
- **Bottom of scroll (`Recency Peak` at the generation cursor)**: The final 10–30 lines immediately above the generation cursor exert the strongest control over the model's immediate output format and next tool call. Because every newly read subfile lands at the very bottom of the scroll—pushing the main file's ending upward—every disclosed sibling file must end with a 1-line **`Return to Caller`** anchor redirecting attention back to the main file's exit gate.

Every document and pointer spends one of two budgets:
- **Context load**: the cost of always-loaded material on the agent's window (`Global_Agent_Rules.md` lines, active skill descriptions, or inlined rules), spending tokens and attention on every turn whether or not it fires.
- **Cognitive load**: the cost on the human—remembering which documents exist and when to reach for each. Spend it where human judgment matters; remove it where it does not.

Choose between **implicit steering** (clean exemplars + compact leading words) and **explicit steering** (ordered steps + script gates + fallback routes) based on **model capability** and **context cleanliness**:

| Dimension | Clean, High-Quality Context | Noisy Legacy Context or Heavy History |
| :--- | :--- | :--- |
| **Strong Model**<br>*(infers intent, generalizes well)* | **Implicit steering first**<br>• Compact leading words + 1–2 gold exemplars<br>• Specify the completion bar; leave intermediate steps open | **Implicit steering + Subagent isolation + Script gate**<br>• Dispatch a read-only subagent to digest noisy sources and return a clean summary<br>• State positive replacement rules (`old pattern → new pattern`)<br>• Enforce hard invariants with a deterministic check script |
| **Weak Model**<br>*(misses subtle pointers, drifts easily)* | **Lightweight steps + Exemplar**<br>• Explicit ordered steps + gold exemplar<br>• Checkable completion criterion at the end of each step | **Stepwise window split + External script check**<br>• Keep rules in a single source of truth<br>• Split into separate stage windows so each step sees only its own rules<br>• Offload objective checks to deterministic scripts |

---

## 1. Module & File Topology Checkpoint (1-Line Baseline vs. `module-design` Branch B)

Treat every skill folder or knowledge-base directory as a deep module:
- **1-Line Baseline (80% routine edits, zero jumps)**: Keep each rule in one canonical source of truth with one top-level entry file per folder (`SKILL.md` or folder index), leave 1-command lookups (`package.json`, directory layout, `--help`) to the runtime environment (`Environment as truth`), keep disclosed sibling files strictly **1 hop deep (`SKILL.md → sibling.md`)** with a bottom `Return to Caller` anchor, and keep a 1-sentence baseline invariant locally inside caller skills so routine runs finish in 1 read.
- **On-Demand Subroutine Call (20% structural or multi-file work)**: Whenever creating a multi-file skill, splitting a bloated document (`>300` lines) to cure **sprawl**, extracting a shared subroutine, or assigning the four module roles (`Router / Orchestrator / Worker / Subroutine`), invoke [`../module-design/SKILL.md`](../module-design/SKILL.md) (`Branch B`) to execute `Gather → Split → Polish` and return a **5-Line Module Blueprint** before drafting prose.

---

## 2. Micro-Level Prompt Craft: Pointers, Information Hierarchy, Steps & Positive Steering

Once module boundaries and file roles are locked, craft the text inside each file using four levers:

### Context Pointers
A **context pointer** is a compact reference held in active context (a skill's `description` or a routing line in `Global_Agent_Rules.md`) that names out-of-context material and encodes the **branches** (distinct cases) that should trigger reading it. Sharpen a pointer's wording so it fires reliably:
1. **Front-load the leading word** where it does its triggering work.
2. **One trigger per branch**: collapse synonyms that rename the same branch.
3. **Cut identity the body already carries.**

### In-File Information Hierarchy
Rank material inside a single file across a three-rung ladder by how immediately the agent needs it:
1. **In-file step** (primary tier): ordered actions the agent performs, placed on the main spine.
2. **In-file reference**: definitions, decision tables, or concise caller-keyed branches (`10–30` lines) consulted on demand inside the main file.
3. **Disclosed 1-hop reference**: heavy tables or branch-specific protocols pushed into a private sibling file behind an internal pointer, loaded only when that branch fires.

### Steps & Completion Criteria
End every step (and every callable subroutine) on a checkable, exhaustive **completion criterion** that tells the agent the step is done and where control moves next:
- **Clarity** resists **premature completion**: sharpen a vague bound ("understanding reached") into an observable artifact or state (such as emitting a 5-line blueprint or emptying a decision frontier) before resorting to a sequence split.
- **Demand** drives **legwork** (the digging the agent does within the work, latent in the wording rather than written as extra steps): phrasing like *"every modified file accounted for"* or *"every link verified"* enforces thoroughness across both sequential steps and reference tables.

### Leading Words, Positive Steering & Pruning
- **Leading words**: A **leading word** is a compact concept already living in the model's pretraining (_lesson_, _fog of war_, _tracer bullets_, _tight_, _red_, _seam_) that the agent thinks with while running the document. Repeat it as a single canonical token across pointers and body to anchor execution:
  - `"fast, deterministic, low-overhead"` → _tight_ (a _tight_ loop).
  - `"a loop you believe in"` → _red_, turning a fuzzy gate into a binary observable state (the loop goes _red_ on the bug, or it doesn't).
- **Prompt the positive**: State the desired action directly so attention locks onto the target behavior rather than activating a forbidden habit (*Don't think of an elephant*):
  - **Mutually exclusive target (default)**: When doing the target action naturally leaves no room for the unwanted one, state only the positive action (`"lead with the conclusion"`, `"write one-line comments"`).
  - **Additive overreach or pre-activated default (boundary guardrail)**: When the agent could complete the positive action *and still* continue into an unapproved next step, or when the host pre-activates a conflicting tool, state the boundary and close the sentence on the positive exit action (`"Before user go-ahead, run read-only research and stop after listing the change plan"`).
- **Prune sediment and no-ops**: Delete sentences the model already obeys by default, and keep historical migration logs in Git or archival folders rather than active rule files.

---

## 3. Completion Criterion & Verification Gate (`Recency Peak`)

Before finishing any creation or modification of an agent rule, skill, or knowledge-base index, verify all 4 completion checks:
1. **Boundary & 1-Hop Discipline**: Every skill/directory exposes a single top-level entry file, internal sibling files are at most `1 hop` deep, and every sibling file ends with a 1-line `Return to Caller` anchor.
2. **Attention & Exemplar Alignment**: The top of `SKILL.md` states the entry contract, the middle uses scannable tables ($\ge 3$ dimensions) or short lists ($\le 5$ steps) with positive phrasing, and the bottom holds the concrete exit gate.
3. **Deterministic Architecture Gate (`1–3s`)**: Run `python "D:/docmonts/Obsidian Vault/Agent全局配置/Skills/writing-for-agents/scripts/check_architecture.py" --local` (and default mode when touching shared rules) and confirm `errors: []` and `warnings: []`.
4. **Public Vault Sync (when touching public skills or rules)**: Run `python "D:/docmonts/Obsidian Vault/Agent全局配置/Skills/writing-for-agents/scripts/publish_public_vault.py"` so `D:/tool/AgentVault-public/` stays in lockstep.
