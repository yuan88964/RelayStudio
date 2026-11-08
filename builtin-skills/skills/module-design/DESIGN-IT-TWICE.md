# Design It Twice (Parallel Interface Exploration)

Code-specific operation (`Operation A2`) for [`module-design`](SKILL.md). Based on John Ousterhout's *Design It Twice* principle: your first interface idea is rarely the deepest. Use this operation when designing a major new module or refactoring a tangled subsystem where multiple interface shapes are plausible.

Uses the vocabulary in [SKILL.md](SKILL.md): **Module**, **Interface**, **Seam**, **Adapter**, **Depth**, **Leverage**, **Locality**, and **Three-State Contract (`Standard / Normalize / Bailout`)**.

## Process

### 1. Frame the Problem Space

Before spawning subagents, write a concise 4-bullet summary of the candidate module's constraints:
- Core responsibility and what complexity it must hide;
- Invariants and 3-state requirements (`Standard`, `Normalize`, `Bailout`) any interface must satisfy;
- Dependency category from `DEEPENING.md` (`In-process`, `Local-substitutable`, `Remote but owned`, `True external`);
- A rough baseline sketch to ground the constraints.

### 2. Spawn Parallel Subagents Across Distinct Design Postures

Dispatch 3–4 read-only subagents in parallel (using host defaults in web hosts, or `explorer` in CLI/IDE hosts). Give each subagent the technical brief (file paths, coupling points, `GLOSSARY.md` terms, dependency category) and assign each a **radically different design posture**:

- **Option 1 (Minimal Surface)**: *"Minimize the interface to 1–2 entry points max. Pull all configuration and edge-case normalization downwards to maximize leverage per entry point."*
- **Option 2 (Composable / Data-Driven)**: *"Design around a canonical $M \to 1$ data representation and table-driven composition so callers can combine operations without adding mode flags."*
- **Option 3 (Zero-Friction 90% Default Path)**: *"Optimize for the most common caller so the default path requires zero configuration while rare cases route cleanly through `Normalize`."*
- **Option 4 (Ports & Adapters, when cross-seam I/O exists)**: *"Design around an explicit port at the seam with a production adapter and an in-memory test adapter for `1–3s` verification."*

Each subagent returns:
1. **Interface & 3-State Contract** (types, entry signature, `Standard / Normalize / Bailout` behavior);
2. **Caller Usage Snippet** (3–6 lines showing how a caller invokes it);
3. **Hidden Complexity** (what disappears behind the seam);
4. **Seam & `1–3s` Test Strategy** (adapter choice per `DEEPENING.md`);
5. **Trade-offs** (where leverage and locality are strongest vs. thinnest).

### 3. Compare, Recommend & Emit Blueprint

Lead with an opinionated recommendation: which design (or hybrid synthesis) wins on **depth** (leverage at the interface), **locality** (where change concentrates), and **seam placement**. Follow with a single comparison table:

| Option & Posture | Interface & 3-State Contract | Hidden Complexity | Seam & `1–3s` Test Strategy | Trade-offs (Leverage & Locality) |
| :--- | :--- | :--- | :--- | :--- |

**Return to Caller**: Encode the winning interface into the **5-Line Module Blueprint** in [SKILL.md](SKILL.md) and return control to the calling container (`develop`, `tdd`, `to-spec`, or `improve-codebase-architecture`).
