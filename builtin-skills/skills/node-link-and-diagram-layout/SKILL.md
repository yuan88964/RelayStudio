---
name: node-link-and-diagram-layout
description: 改善静态流程图、结构图、状态图和依赖图的布局。当分支、回路、嵌套分组、较长标签或连线交叉妨碍理解时，依据阅读任务选择排列、分组和连线路径，辅助当前绘图方式。
metadata:
  upstream: openai/plugins
  upstream-commit: 0722921d5542fc593105c27bd52630babd8b8c2a
  local-adaptation: "2026-11-01"
---

# Node-Link and Diagram Layout

> **Unified Rules**: See [mermaid-diagrams](../mermaid-diagrams/SKILL.md) for when to draw, node scale (`5–15` core nodes per diagram), and `subgraph` nesting limits. Use this skill when selecting layout algorithms, directional flow (`TB` vs `LR`), and connector routing.

## Layout decisions

1. Identify the graph and reading task: parent-child depth, a directional process, state transitions, dependencies, or undirected relationships. Tree, layered, radial, and force layouts serve different purposes; use [algorithm selection](references/algorithm-selection.md) when the choice is unclear.
2. Match placement and flow direction (`TB` vs `LR`) to the natural topology of the structure. Directional workflows, state transitions, and dependencies usually benefit from layered layout; rooted trees from tree layout. Force and stress methods fit undirected neighborhood exploration. See [layout families](references/layered-tree-force-and-radial-layouts.md) for cases that need a comparison.
3. Treat connector routing separately: choose clear entry/exit sides where supported, reserve space for branch labels, and keep return paths traceable. Orthogonal routing often helps grouped structure; sparse graphs may be clear with simple lines. See [routing and quality](references/routing-overlap-and-quality.md) for crossings, ports, and overlap problems.
4. Use the current renderer's supported controls. Mermaid can arrange nodes automatically but does not expose every layout constraint. Confirm configuration support before relying on it. Revise direction, grouping, or view decomposition when those changes clarify the same information; keep relations between split views explicit.

## Quality and completion

Review the visible result when available: the main reading direction is clear; text is complete; nodes and labels fit; links can be traced clearly with crossings visually distinct from junctions. Reserve dedicated padding for group titles above internal nodes and route incoming connectors around title bands so titles stay separated from node borders and connector lines. When a diagram mixes macro containers with fine-grained steps, keep peer nodes within each container at a consistent abstraction level and use split overview/detail views to represent cross-level relationships.

## Source and maintenance

Adapted from OpenAI's layout skill (`plugins/build-web-data-visualization/skills/node-link-and-diagram-layout`). Retains its graph-family, geometry, routing, and readability methods and three core references.
