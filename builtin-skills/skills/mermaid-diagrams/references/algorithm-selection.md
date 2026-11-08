# Algorithm Selection

> **Unified Rules**: See [SKILL.md](../SKILL.md) for the 3-step layout decision pipeline and 4-check completion contract.

## Key Takeaways

- Trees are distinct from general DAGs: use tidy tree algorithms for rooted ordered trees and decision trees.
- Layered layouts serve UML-like flow, schema, state, and dependency diagrams better than generic force layouts.
- Force-directed and stress-based methods fit undirected exploration when cluster shape or approximate distance matters.
- Port-constrained block diagrams and ERDs require layout engines that account for boxes, ports, and routing constraints.
- Crossing minimization, overlap removal, and edge routing operate as separate passes.

## Recommended Defaults

- **Rooted ordered tree or decision tree**: Reingold-Tilford or Buchheim-style tidy tree layout.
- **DAG, workflow, state machine, dependency graph, class hierarchy, schema dependency**: Sugiyama / layered layout (`TB` or `LR`).
- **Port-aware block diagram, ERD, database schema, actor-like graph**: Layered layout plus orthogonal routing and fixed-side or fixed-order ports.
- **General undirected network**: Stress majorization, Kamada-Kawai, or Fruchterman-Reingold family.
- **Large undirected network**: Multilevel force layout.
- **Root-distance view**: Radial or concentric layout.
- **Cycle-heavy view where circular order is primary**: Circular layout.
- **Non-planar graph where minimizing crossings dominates**: Planarization-based workflow.

## Selection Heuristics & Guardrails

- Start with **layered layout** when readers trace top-to-bottom (`TB`) or left-to-right (`LR`) causal flow, state machines, or schemas.
- Start with **tidy tree layout** when readers trace parent-child depth or decision branches.
- Start with **force or stress layout** when readers explore undirected neighborhood clusters.
- Enforce **port-aware orthogonal routing** when readers trace connectors entering specific sides of schemas or block diagrams.
- Prefer **stable constrained layout** when users compare revisions or edit interactively.
- Pass **measured node dimensions and table widths** into the layout algorithm upfront, and space disconnected components with clear visual margins.

## Source Links

- [Methods for Visual Understanding of Hierarchical System Structures](https://doi.org/10.1109/TSMC.1981.4308636)
- [A Technique for Drawing Directed Graphs](https://doi.org/10.1109/32.221135)
- [Tidier Drawings of Trees](https://reingold.co/tidier-drawings.pdf)
- [Graph drawing by force-directed placement](https://doi.org/10.1002/spe.4380211102)
- [An algorithm for drawing general undirected graphs](https://doi.org/10.1016/0020-0190(89)90102-6)
- [Graph Drawing by Stress Majorization](https://graphviz.org/documentation/GKN04.pdf)
- [ELK Layered](https://eclipse.dev/elk/reference/algorithms/org-eclipse-elk-layered.html)
- [Graphviz layout engines](https://graphviz.org/docs/layouts/)

---

**Return to Caller**: Return with the selected layout algorithm to [SKILL.md](../SKILL.md) (§2) to emit the 4-check layout plan, then resume the calling diagram workflow.
