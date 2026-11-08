---
name: research
description: Investigate a question against high-trust primary sources and capture the findings as a Markdown file in the repo. Use when the user wants a topic researched, docs or API facts gathered, or reading legwork delegated to a background agent.
metadata:
  upstream: mattpocock/skills
  upstream-path: skills/productivity/research/SKILL.md
  upstream-commit: 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d
  local-adaptation: "2026-11-07"
---

# Primary-Source Research (`research`)

Shared primary-source investigation subroutine that delegates heavy reading across official docs, source repositories, papers, and first-party configs to read-only subagents, persists a structured Markdown report, and returns a compact pointer summary (`<= 15` lines) to the calling window.

- **`Standard` (Focused single-source or single-vendor question)**: Verify directly against the authoritative primary source, write the structured report (`§1`), and return the `<= 15`-line summary (`§2`).
- **`Normalize` (Multi-vendor comparison, multi-repo survey, or noisy documentation)**: Fan out parallel read-only subagents (using host defaults with zero model/effort overrides in web hosts, or `explorer` in CLI/IDE hosts)—one subagent per independent vendor, API, or sub-topic—so the main window stays clean while subagents gather primary evidence concurrently.
- **`Bailout` (Paywalled source, missing auth credential, or unreachable private endpoint)**: Halt speculative guessing and emit `Error: primary source <target> unreachable (<reason>)` + `Route: need <credential|access> | ask-user`.

---

## 1. Research & Persistence Rules

1. **Primary sources first, stop once verified**: Trace every claim back to the authoritative source that owns it (official documentation, upstream source code/Issues/PRs, RFCs/papers, or local machine configs/help output). Once an official doc or first-party config confirms the fact, stop—never reverse-engineer minified bundles for facts already documented upstream.
2. **Conclusion-first, high-density Markdown**: Lead the report with the core conclusion, use Markdown tables for $\ge 3$ parallel options/dimensions, cite exact source URLs or `file://` direct links, and attach a `参考资料（来源 + 网址）` section at the bottom for time-sensitive external facts.
3. **Save in the canonical dedicated directory**:
   - **Repo-local technical research**: Save in the repo's existing research folder (or `.scratch/research/<slug>.md`).
   - **Cross-project AI models, tools, platforms, or engineering research in the Vault**: Save under `参考资料/<Topic>.md` and register its wikilink entry in `参考资料/00 参考资料导览.md`.

---

## 2. Completion & Subroutine Return Contract (`Recency Peak`)

Before finishing `research`, verify all 3 completion gates and return control immediately:
1. **Primary-Source Report Persisted**: The Markdown report is written to its dedicated subfolder with primary-source citations;
2. **Vault Index & Architecture Check (when writing to `参考资料/`)**: The new note is linked in `参考资料/00 参考资料导览.md` and `python "D:/docmonts/Obsidian Vault/Agent全局配置/Skills/writing-for-agents/scripts/check_architecture.py" --local` passes with `0` errors;
3. **Subroutine Output (`<= 15` Lines) & Immediate Return**: Emit a concise **Primary-Source Summary (`<= 15` lines)** containing the core conclusion, key comparison table/bullets, and a clickable `file://` link to the saved report—then **immediately resume the calling workflow (`wayfinder`, `proxy-finder`, `deep-research-report`, or main session) inline without pasting the full report into the chat window**.
