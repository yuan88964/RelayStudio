# ADR Format (`docs/adr/NNNN-slug.md`)

> **Unified Rules**: See [SKILL.md](SKILL.md) (`§1–§2`, Step 5) for the 3 mandatory ADR admission criteria (`Hard to reverse`, `Surprising without context`, `Result of a real trade-off`) and single- vs. multi-context directory placement.

## 1. Numbering & Lazy Creation

Create `docs/adr/` lazily when the first qualifying ADR is written. Scan `docs/adr/` for the highest existing 4-digit prefix (`0001-slug.md`, `0002-slug.md`) and increment by `1`.

## 2. Minimal ADR Template

An ADR can be a single high-density paragraph—its value lies in recording *what* was decided and *why*, not ceremony:

```markdown
# {Short Title of the Decision}

{1–3 sentences stating the context, the decision taken, and the load-bearing trade-off behind it.}
```

### Optional Sections (Include Only When They Add Signal)

- **`Status` frontmatter** (`proposed | accepted | deprecated | superseded by ADR-NNNN`): include when revisiting or superseding an earlier ADR;
- **`Considered Options`**: include when rejected alternatives had non-obvious flaws future readers would otherwise re-propose;
- **`Consequences`**: include when downstream operational or boundary trade-offs need explicit visibility.

## 3. Qualifying Decision Archetypes

| Archetype | Concrete Example |
| :--- | :--- |
| **Architectural shape** | *"Write model is event-sourced; read model is projected into Postgres."* |
| **Cross-context integration** | *"Ordering and Billing communicate via asynchronous domain events rather than synchronous HTTP."* |
| **High-lock-in technology choice** | Database engine, message bus, auth provider, or runtime target that would take weeks to swap. |
| **Context ownership boundary** | *"Customer PII is owned exclusively by the Customer context; downstream contexts store `CustomerId` only."* |
| **Deliberate deviation from convention** | *"Using manual SQL in the reporting hot path instead of the repo ORM to meet the 200ms partner SLA."* |

**Return to Caller**: Write the numbered ADR file under `docs/adr/`, then return to [SKILL.md](SKILL.md) (`§3`) to emit the **Glossary / ADR Delta** and resume the calling workflow.
