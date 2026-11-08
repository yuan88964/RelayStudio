# `GLOSSARY.md` Format & Multi-Context Map

> **Unified Rules**: See [SKILL.md](SKILL.md) (`§1–§2`) for lazy file creation, single- vs. multi-context discovery, and the rule keeping `GLOSSARY.md` strictly free of implementation details.

## 1. `GLOSSARY.md` Template

```markdown
# {Context Name}

{1–2 sentences describing what this bounded context owns and why it exists.}

## Language

**Order**:
A customer's confirmed request to purchase one or more line items.
_Avoid_: Purchase, transaction, cart

**Invoice**:
A formal request for payment issued to a Customer after shipment dispatch.
_Avoid_: Bill, payment request, receipt

**Customer**:
A person or organization that places Orders and holds billing responsibility.
_Avoid_: Client, buyer, account
```

## 2. Term Authoring Guardrails

1. **Be opinionated (`_Avoid_`)**: Pick one canonical term per concept and list competing synonyms under `_Avoid_` so code, tests, and specs never drift.
2. **Define what it *is*, not how it is implemented**: Keep definitions to 1–2 sentences in pure domain language (zero table names, class names, or file paths).
3. **Include only domain-specific concepts**: Exclude generic programming mechanisms (`Timeout`, `RetryPolicy`, `HttpClient`).
4. **Group under subheadings** only when natural sub-clusters emerge inside a large context.

**Return to Caller**: Apply this format to update `GLOSSARY.md`, then return to [SKILL.md](SKILL.md) (`§3`) to emit the **Glossary / ADR Delta** and resume the calling workflow.
