---
name: research
description: Investigate a question against high-trust primary sources and capture the findings as a Markdown file in the repo. Use when the user wants a topic researched, docs or API facts gathered, or reading legwork delegated to a background agent.
---

Spin up **background subagents** (`explorer` in local CLI/IDE, host defaults in web hosts) to do the research, so you keep working while they read. When a question spans multiple independent vendors, APIs, or sub-topics, fan out parallel read-only subagents to investigate them concurrently rather than running one long serial chain.

Their job:

1. Investigate the question against **primary sources** (official docs, source code, specs, first-party APIs and local configs), not a secondary write-up of them. Follow every claim back to the source that owns it, and **stop once verified**—do not reverse-engineer minified bundles or source code when official docs or first-party configs already confirm the fact.
2. Write the findings to a single concise, high-density Markdown file (lead with the conclusion, use tables for multi-item comparisons, and cite each claim's source). Return a brief pointer summary ($\le 15$ lines) to the parent agent rather than repeating the full file in the handoff message.
3. Save the file in a **dedicated subfolder**, never scattered in a root directory:
   - **Repo-specific research**: save where the repo already keeps research notes (or `.scratch/research/`), matching the repo's convention.
   - **Cross-project AI models, tools, platforms, or engineering research**: save under the central knowledge base's research notes folder (e.g., `docs/research/`) and register the new note's link in its reference index.
