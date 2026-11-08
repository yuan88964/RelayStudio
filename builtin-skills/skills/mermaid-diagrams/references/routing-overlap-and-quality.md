# Routing, Overlap, and Quality

> **Unified Rules**: See [SKILL.md](../SKILL.md) for the 3-step layout decision pipeline and 4-check completion contract.

## Edge Routing

- **Orthogonal routing** is the primary choice for ERDs, database schemas, state machines, block diagrams, and port-aware system views because it creates unambiguous entry and exit directions at box boundaries.
- **ELK Layered** supports orthogonal routing with explicit port constraints (`FIXED_SIDE`, `FIXED_ORDER`, `FIXED_POS`) for block diagrams and schematics.
- **Dedicated connector routing** (such as ELK's Libavoid integration) recomputes connector paths around manually placed boxes without disturbing node positions.
- **Spline routing** fits sparse overview graphs where smooth curves aid continuous eye tracking.

## Crossing Reduction and Planarization

- Purchase's empirical study established that **minimizing edge crossings** has the largest positive effect on human comprehension, ahead of bend minimization and symmetry.
- Reorder peer nodes within ranks (or flatten unnecessary outer `subgraph` wrappers) to eliminate avoidable crossings; apply planarization heuristics when non-planar density dominates.

## Overlap Removal & Port Constraints

- Run **proximity-preserving overlap removal** (such as Prism or VPSC displacement minimization) so node and label bounding boxes clear one another while preserving the mental map.
- Enforce **port constraints and semantic field order** on tables, swimlanes, and C3 module contracts so connectors attach to predictable sides.

## Routing & Quality Checklist

1. **Low crossings**: Connectors cross zero unrelated node bodies and minimize edge-edge intersections.
2. **Clean bends**: Orthogonal paths avoid unnecessary doglegs and keep return loops on outer channels.
3. **Clear labels**: Edge labels sit in unobstructed spans with zero overlap against boxes or table rows.
4. **Obvious directionality**: Arrowheads and entry/exit ports remain legible at normal zoom; wide or dense views split into macro + zoom-in facets rather than shrinking text.

## Source Links

- [Which aesthetic has the greatest effect on human understanding?](https://doi.org/10.1007/3-540-63938-1_67)
- [On Embedding a Graph in the Grid with the Minimum Number of Bends](https://doi.org/10.1137/0216030)
- [Advances in the Planarization Method: Effective Multiple Edge Insertions](https://doi.org/10.7155/jgaa.00264)
- [How to Draw a Planarization](https://doi.org/10.7155/jgaa.00506)
- [Efficient, Proximity-Preserving Node Overlap Removal](https://doi.org/10.1007/s00453-009-9348-7)
- [Node Overlap Removal Algorithms: an Extended Comparative Study](https://doi.org/10.7155/jgaa.00532)
- [ELK Layered](https://eclipse.dev/elk/reference/algorithms/org-eclipse-elk-layered.html) · [ELK port constraints](https://eclipse.dev/elk/reference/options/org-eclipse-elk-portConstraints.html) · [ELK crossing minimization](https://eclipse.dev/elk/reference/options/org-eclipse-elk-layered-crossingMinimization-strategy.html) · [ELK Libavoid](https://eclipse.dev/elk/blog/posts/2022/22-11-17-libavoid.html)
- [Graphviz overlap removal](https://graphviz.org/docs/attrs/overlap/)

---

**Return to Caller**: Return with the verified connector routing and overlap parameters to [SKILL.md](../SKILL.md) (§2) to emit the 4-check layout plan, then resume the calling diagram workflow.
