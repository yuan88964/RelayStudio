---
name: node-link-and-diagram-layout
description: Improve the layout of static flowcharts, architecture views, state diagrams, and dependency graphs. Use when branching, return loops, nested subgraphs, long labels, or connector crossings hurt readability and you need to select layout direction, grouping, or connector routing.
metadata:
  upstream: openai/plugins
  upstream-commit: 0722921d5542fc593105c27bd52630babd8b8c2a
  local-adaptation: "2026-11-06"
---

# Node-Link and Diagram Layout

> **Unified Rules**: See [`mermaid-diagrams`](../mermaid-diagrams/SKILL.md) for when to draw, node scale (`5–15` core nodes per diagram), and `subgraph` nesting limits (`<= 1` level). Use this child skill when selecting layout algorithms, directional flow (`TB` vs. `LR`), module seam grouping, and connector routing.

## Layout decisions

1. **Identify the graph topology and reading task (`Standard` vs. `Normalize`)**: Distinguish parent-child hierarchies, directional workflows across module seams (`Seam`), state transitions, dependency DAGs, and undirected concept networks. Tree, layered, radial, and force layouts serve distinct tasks; consult [algorithm selection](references/algorithm-selection.md) when the choice is non-obvious.
2. **Match placement and flow direction (`TB` vs. `LR`) to natural topology**: Directional workflows, state lifecycles, and dependency graphs default to layered top-to-bottom (`TB`) layout; short linear pipelines or rooted trees use left-to-right (`LR`) tree layout. Force and stress methods fit undirected neighborhood exploration. See [layout families](references/layered-tree-force-and-radial-layouts.md) for detailed comparisons.
3. **Route connectors cleanly across seams**: Choose clear entry/exit ports where supported, keep edge labels concise so they never wrap onto single-character orphan lines, and keep return paths traceable. Avoid wrapping multi-rank cross-edges inside an outer `subgraph` when Dagre adds excessive vertical rank gaps; flatten to top-level peer nodes instead. See [routing and quality](references/routing-overlap-and-quality.md) for crossings, ports, and overlap fixes.
4. **Normalize oversized views (`Normalize`) or trigger `Bailout` when unsupported**: Mermaid arranges nodes automatically and does not expose arbitrary coordinate pinning. When a view exceeds `15` core nodes or mixes macro containers with micro steps, normalize it into **"1 macro overview + 1 whitebox zoom-in"** with explicit seam names linking both views.

## Quality and completion criterion

Every layout pass is complete when the visible output satisfies four checks: (1) primary reading direction (`TB` or `LR`) is immediately clear; (2) all node and edge text is complete without truncation or single-character orphan wraps; (3) edges cross zero unrelated nodes and crossings are visually distinct from junctions; (4) peer nodes within each container sit at a consistent level of abstraction.
