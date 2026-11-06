# Design It Twice

When the user wants to explore alternative interfaces for a chosen deepening candidate, use this parallel sub-agent pattern. Based on "Design It Twice" (Ousterhout): your first idea is unlikely to be the best.

Uses the vocabulary in [SKILL.md](SKILL.md): **module**, **interface**, **seam**, **adapter**, **leverage**, **locality**.

## Process

### 1. Frame the problem space

Before spawning sub-agents, write a brief user-facing summary of the problem space for the chosen candidate:

- The constraints and invariants any new interface would need to satisfy
- The dependencies it would rely on, and which category they fall into (see [DEEPENING.md](DEEPENING.md))
- A rough illustrative sketch to ground the constraints—not a proposal, just a way to make the constraints concrete

Show this to the user, then immediately proceed to Step 2. The user reads and thinks while the sub-agents work in parallel.

### 2. Spawn sub-agents

Spawn 3–4 sub-agents in parallel. Each must produce a **radically different** interface for the deepened module.

Prompt each sub-agent with a separate technical brief (file paths, coupling details, dependency category from [DEEPENING.md](DEEPENING.md), what sits behind the seam). Give each agent a different design constraint:

- **Agent 1 (Minimal surface)**: "Minimize the interface: aim for 1–3 entry points max. Maximise leverage per entry point."
- **Agent 2 (Composable / extensible)**: "Maximise flexibility: support many use cases and composition across caller contexts."
- **Agent 3 (Zero-friction default path)**: "Optimise for the most common caller: make the default case trivial with zero configuration."
- **Agent 4 (Ports & adapters, if applicable)**: "Design around ports & adapters for cross-seam dependencies (production adapter + in-memory test adapter)."

Include both [SKILL.md](SKILL.md) vocabulary and `GLOSSARY.md` vocabulary in the brief so each sub-agent names things consistently with the architecture language and the project's domain language.

Each sub-agent outputs:

1. Interface (types, methods, params, plus invariants, ordering, error modes)
2. Usage example showing how callers use it
3. What complexity the implementation hides behind the seam
4. Dependency strategy and adapters (see [DEEPENING.md](DEEPENING.md))
5. Trade-offs: where leverage is high, where it's thin

### 3. Compare and recommend

Lead with your own recommendation: which design (or hybrid synthesis) you think is strongest and why it wins on **depth** (leverage at the interface), **locality** (where change concentrates), and **seam placement**. Be opinionated: the user wants a strong read, not a menu.

Follow with a single Markdown comparison table across all options:

| Option & design posture | Interface & usage | Hidden complexity | Seam & test strategy | Trade-offs (leverage & locality) |
| :--- | :--- | :--- | :--- | :--- |
