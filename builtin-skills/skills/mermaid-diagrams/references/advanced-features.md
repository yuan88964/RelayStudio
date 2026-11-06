# Semantic Styling & Tufte De-Boxing Syntax

> **Unified Rules**: See [SKILL.md](../SKILL.md) for official node scale (`5–15` core nodes per diagram) and `subgraph` nesting boundaries.

## 1. Semantic Color Palettes (`classDef`)

Pair soft pastel backgrounds with saturated `1.5px–2px` borders and dark high-contrast text (`#1E3A8A` / `#14532D` / `#7F1D1D` / `#1A202C`) so roles and states are distinguishable at a glance without excessive outer `subgraph` boxes (Edward Tufte's *Layering & Separation*):

```mermaid
%% Architecture & Concept Roles
classDef actor fill:#EFF6FF,stroke:#2563EB,stroke-width:2px,color:#1E3A8A
classDef coreMod fill:#F0FDF4,stroke:#16A34A,stroke-width:2px,color:#14532D
classDef transformSpace fill:#EDE9FE,stroke:#7C3AED,stroke-width:1.5px,color:#4C1D95
classDef ledger fill:#FEFCE8,stroke:#CA8A04,stroke-width:2px,color:#713F12
classDef extSys fill:#F8FAFC,stroke:#64748B,stroke-width:1.5px,stroke-dasharray: 5 5,color:#334155

%% Swiss Cheese Fault Breach vs. Defense Barrier
classDef hole fill:#FEE2E2,stroke:#DC2626,stroke-width:2px,color:#7F1D1D
classDef barrier fill:#DCFCE7,stroke:#16A34A,stroke-width:2px,color:#14532D
```

## 2. Subgraph Title Styling Note

When styling a `subgraph` boundary (`style SubgraphID fill:#FFFFFF,stroke:#2B6CB0,stroke-width:2px,color:#1E3A8A`), omit `font-weight:bold` so Mermaid's pre-measured `<foreignObject>` label box never clips the rightmost character.
