# Layered, Tree, Force, and Radial Layouts

> **Unified Rules**: See [SKILL.md](../SKILL.md) for the 3-step layout decision pipeline and 4-check completion contract.

## Layered Layouts

- The Sugiyama framework is the default for directional diagrams because it separates cycle breaking, layer assignment, crossing minimization, node placement, and edge routing.
- Gansner, Koutsofios, North, and Vo operationalized this into a four-pass directed-graph pipeline using network simplex for rank assignment, heuristic rank ordering to reduce crossings, coordinate assignment, and spline/orthogonal routing.
- Layered layout is the primary choice for state machines, dependency maps, workflows, class hierarchies, ERDs, and UML-like directed diagrams.
- Crossing reduction relies on fast heuristics such as barycenter, median, layer sweeps, greedy switches, and local transpositions.

## Tree Layouts

- Reingold and Tilford introduced tidy tree drawing that preserves level alignment, child order, parental centering, and mirror symmetry.
- Subtree composition is the right default for decision trees and rooted trees because it preserves the hierarchical metaphor directly.
- Buchheim, Junger, and Leipert gave a linear-time refinement that preserves tidy layouts for trees of unbounded degree.

## Force and Stress Layouts

- Kamada-Kawai formulates layout as energy minimization based on graph-theoretic distances for small undirected graphs.
- Fruchterman-Reingold aims for uniform edge lengths with attractive and repulsive forces.
- Stress majorization provides stable stress-based layouts (Graphviz `neato`), while multilevel force methods scale to large undirected graphs (Graphviz `sfdp`).
- Use these layouts when cluster structure, relative proximity, or undirected neighborhood exploration matter more than a single global flow direction.

## Radial and Circular Layouts

- Use **radial layout** when the key story is hop distance from a chosen root or center with compact labels.
- Use **circular layout** when cycles, ring topology, or repeated ordering around a hub is the primary invariant.

## Family Selection Guardrails

- Pair **flowcharts, schemas, and state machines** with layered (`TB`/`LR`) layouts so causal order is explicit.
- Pair **undirected social or similarity networks** with force or stress layouts so no artificial hierarchy is implied.
- Pair **long multi-line labels** with horizontal boxes in layered or tree layouts rather than angled radial spokes.
- Combine **filtering or macro/zoom-in views** (`<= 15` core nodes per view) with layout selection when a graph is too dense for a single canvas.

## Source Links

- [Methods for Visual Understanding of Hierarchical System Structures](https://doi.org/10.1109/TSMC.1981.4308636)
- [A Technique for Drawing Directed Graphs](https://doi.org/10.1109/32.221135)
- [Simple and Efficient Bilayer Cross Counting](https://doi.org/10.7155/jgaa.00088)
- [A Fast and Simple Heuristic for Constrained Two-Level Crossing Reduction](https://michael.forster.pro/publication/constrained-crossing-reduction/)
- [Tidier Drawings of Trees](https://reingold.co/tidier-drawings.pdf)
- [Improving Walker's Algorithm to Run in Linear Time](https://doi.org/10.1007/3-540-36151-0_32)
- [An algorithm for drawing general undirected graphs](https://doi.org/10.1016/0020-0190(89)90102-6)
- [Graph drawing by force-directed placement](https://doi.org/10.1002/spe.4380211102)
- [Graph Drawing by Stress Majorization](https://graphviz.org/documentation/GKN04.pdf)
- [Graphviz `dot`](https://graphviz.org/docs/layouts/dot/) · [`neato`](https://graphviz.org/docs/layouts/neato/) · [`fdp`](https://graphviz.org/docs/layouts/fdp/) · [`sfdp`](https://graphviz.org/docs/layouts/sfdp/) · [`twopi`](https://graphviz.org/docs/layouts/twopi/)

---

**Return to Caller**: Return with the selected layout family and flow direction (`TB`/`LR`) to [SKILL.md](../SKILL.md) (§2) to emit the 4-check layout plan, then resume the calling diagram workflow.
