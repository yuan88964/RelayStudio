---
name: domain-modeling
description: Build and sharpen a project's domain model. Use when discussing codebase terminology, writing or editing a GLOSSARY.md, or recording or editing an ADR.
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/engineering/domain-modeling/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-07"
---

# Domain Modeling (`domain-modeling`)

Shared domain-modeling subroutine for sharpening codebase vocabulary, maintaining `GLOSSARY.md`, and recording load-bearing Architecture Decision Records (`docs/adr/`). Merely reading `GLOSSARY.md` is a 1-line baseline habit inside every skill; invoke `domain-modeling` when creating, challenging, or updating domain terms or ADRs during design (`wayfinder`, `improve-codebase-architecture`, `to-spec`, `teach`, or direct user invocation).

- **`Standard` (Single-context repo with resolved domain term or trade-off)**: Update `/GLOSSARY.md` inline via [GLOSSARY-FORMAT.md](GLOSSARY-FORMAT.md) or record an ADR under `/docs/adr/` via [ADR-FORMAT.md](ADR-FORMAT.md), then emit the **Glossary / ADR Delta** (`§3`).
- **`Normalize` (Missing files or multi-context repo)**: Create `GLOSSARY.md` or `docs/adr/` lazily only when the first term or ADR is ready to write; if `/GLOSSARY-MAP.md` exists at the root, route the update to the matching bounded context (`src/<context>/GLOSSARY.md` and `src/<context>/docs/adr/`).
- **`Bailout` (General programming concept or easily reversible implementation detail)**: Skip writing to `GLOSSARY.md` or `docs/adr/` and return `No domain-model write needed (<reason>)` to the calling workflow.

---

## 1. Repository Layout (Single-Context vs. Multi-Context)

```text
Single-Context Repo (Default):          Multi-Context Repo (When GLOSSARY-MAP.md Exists):
/                                       /
├── GLOSSARY.md                         ├── GLOSSARY-MAP.md
├── docs/adr/                           ├── docs/adr/                     ← system-wide ADRs
│   ├── 0001-event-sourced-orders.md    └── src/
│   └── 0002-postgres-write-model.md        ├── ordering/
└── src/                                    │   ├── GLOSSARY.md
                                            │   └── docs/adr/             ← context-local ADRs
                                            └── billing/
                                                ├── GLOSSARY.md
                                                └── docs/adr/
```

---

## 2. Five-Step Domain Modeling Operator

Apply these five moves inline as concepts crystallize during conversation or architecture review:

1. **Challenge conflicts against `GLOSSARY.md`**: When a term contradicts an existing definition in `GLOSSARY.md`, surface the conflict immediately (*"Your glossary defines `Cancellation` as X, whereas here it means Y—which should be canonical?"*).
2. **Sharpen overloaded language**: When a vague term (`account`, `item`, `record`, `manager`) covers distinct domain concepts, propose distinct canonical names and list the rejected synonyms under `_Avoid_`.
3. **Stress-test boundaries with concrete edge scenarios**: Invent specific boundary scenarios (e.g., partial order cancellation after shipment dispatch) and cross-reference against current code so concept boundaries are exact.
4. **Update `GLOSSARY.md` inline ([GLOSSARY-FORMAT.md](GLOSSARY-FORMAT.md))**: Write resolved domain definitions immediately using pure domain language (what the concept *is* in the business domain, keeping implementation details, schemas, and file paths out of `GLOSSARY.md`).
5. **Offer ADRs selectively ([ADR-FORMAT.md](ADR-FORMAT.md))**: Propose an ADR in `docs/adr/NNNN-slug.md` **only when all 3 criteria hold**:
   - **Hard to reverse**: changing course later carries high migration cost;
   - **Surprising without context**: a future reader would wonder *"why did they do it this way?"*;
   - **Result of a real trade-off**: genuine alternatives existed and one was chosen for load-bearing reasons.

---

## 3. Subroutine Output & Return Contract (`Recency Peak`)

Complete the domain-modeling pass by emitting a concise **Glossary / ADR Delta**:

```text
1. Glossary Updates: <path to GLOSSARY.md + added/updated canonical terms and _Avoid_ aliases, or "none">
2. ADR Updates: <path to docs/adr/NNNN-slug.md + 1-line decision summary, or "none (criteria not met)">
```

**Immediate Return Rule**: Once the **Glossary / ADR Delta** is written to disk and summarized above, **this subroutine is complete**—immediately return control to the calling container (`wayfinder`, `improve-codebase-architecture`, `to-spec`, `teach`, or the active design session) at the exact step that invoked `domain-modeling`.
