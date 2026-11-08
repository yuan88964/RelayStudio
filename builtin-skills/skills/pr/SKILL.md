---
name: pr
description: "Use when writing a PR body."
metadata:
  credits:
    skill: show-me
    author: Dex Horthy
    organisation: Humanlayer
    url: "https://github.com/humanlayer/skills/blob/main/plugins/show-me/skills/show-me/SKILL.md"
---

# Pull Request Body Authoring (`pr`)

Focused delivery worker that synthesizes a verified branch diff into a high-signal Pull Request body (`Summary`, `Evidence`, `Merge Danger`) using the project's domain vocabulary (`GLOSSARY.md`).

- **`Standard` (Committed branch diff + verification evidence ready)**: Select the smallest visual representation that makes the change clear (`§2`), attach `Before / After` evidence (`§3`), and assess `Door` & `Blast Radius` (`§4`).
- **`Normalize` (Multi-architecture or cross-module interaction PR)**: When the PR introduces a new cross-module protocol or state lifecycle that requires a standalone diagram artifact in the vault/repo, invoke [`../mermaid-diagrams/SKILL.md`](../mermaid-diagrams/SKILL.md) as a bounded subroutine, or embed a compact sequence/diff sketch directly in `## Summary`.
- **`Bailout` (Empty branch diff or unverified broken build)**: Abort PR creation and emit `Error: <empty diff or failing verification>` + `Route: use develop | tdd`.

---

## 1. PR Body Template

Use this structure with zero preamble and concise prose grounded in `GLOSSARY.md`:

```markdown
## Summary

<diagram, diff-sketch, or tree>

## Evidence

- **Before:** <screenshot/output/failing test run>
  **After:** <screenshot/output/passing test run>

## Merge Danger

**Door:** <one-way or two-way>

<optional: description>

**Blast Radius:** <one-word description>

<optional: potential ramifications of merge>
```

---

## 2. `Summary` Visual Menu (Pick the Smallest Clear View)

Place each visual immediately next to the short sentence it supports, keeping only the calls, files, props, states, and module boundaries that explain the change:

- **Logic or algorithm $\to$ Pseudocode**:
  ```text
  on(save)
    if content is unchanged
      return cached result
    write new content
    return fresh result
  ```
- **Runtime control flow $\to$ Call tree**:
  ```text
  submitForm
    createSession
      persistPrompt
      launchAgent
    navigateToSession
  ```
- **UI structure & state ownership $\to$ Component tree**:
  ```text
  <SessionPage> (apps/example/src/routes/session.tsx)
    useSessionEvents()
    <SessionToolbar>
      <RunSkillButton> (packages/ui)
  ```
- **Broad refactor or package layout $\to$ Shallow file tree**:
  ```text
  src/
  ├── commands/       # parses user actions
  ├── sessions/       # owns session state
  └── transport/      # sends API requests
  ```
- **Cross-module interaction $\to$ Mermaid sequence diagram**:
  ```mermaid
  sequenceDiagram
      autonumber
      box rgb(235, 248, 255) Client Layer
          participant User as User
          participant UI as SessionToolbar
      end
      box rgb(240, 255, 244) Runtime Layer
          participant Daemon as SkillDaemon
      end
      User->>+UI: Trigger RunSkillButton
      UI->>+Daemon: Dispatch expanded prompt & session context
      Daemon-->>-UI: Stream structured SkillResultCard events
      UI-->>-User: Render timeline update
  ```
- **Delta against an existing structure $\to$ Structural `diff`** (match the diff shape to a component tree, file tree, call tree, or pseudocode block):
  ```diff
   submitForm
     createSession
       persistPrompt
  +    expandSkillMention
       launchAgent
  -  navigateToSession
  +  navigateToSession
  +    subscribeToEvents
  ```
- **New self-contained contract $\to$ Short code block** when the reader needs the exact copyable target signature:
  ```ts
  function expandSkill(command: string): string {
    const skillName = command.slice(1);
    return `use the ${skillName} skill`;
  }
  ```

---

## 3. `Evidence` & `Merge Danger` Rules

- **Evidence (`Before` / `After`)**: Provide concrete proof that the change works—screenshots for visual UI changes (S-tier) or exact test/CLI outputs showing the prior failure mode and passing post-change run (A-tier).
- **Merge Danger (`Door` & `Blast Radius`)**:
  - **Door**: Mark **`two-way`** when cheap and safe to roll back; mark **`one-way`** when involving destructive data migrations, public contract breaks, or irreversible external side effects.
  - **Blast Radius**: Summarize the impact scope in one word (`Isolated`, `Package-local`, `Cross-module`, `System-wide`) followed by any concrete operational caveats.

---

## 4. Completion & Caller Return Gate (`Recency Peak`)

The PR body is complete when:
1. All three sections (`## Summary`, `## Evidence`, `## Merge Danger`) are populated using `GLOSSARY.md` domain terms;
2. The PR is created/updated on the tracker (or returned as Markdown when offline);
3. **Immediate Caller Return**: When invoked at the closeout of `develop`, immediately return the PR URL / body to `develop` (`§3`) to complete final verification reporting.
