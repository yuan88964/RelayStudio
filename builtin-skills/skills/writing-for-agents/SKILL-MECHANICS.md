# Skill mechanics

The skill-specific branch of [`writing-for-agents`](SKILL.md): what changes when the document is a skill (frontmatter, the invocation choice, callable primitive subroutines, and router skills). Everything else about writing it is the universal reference in `SKILL.md`.

## Invocation

Two choices, trading the two loads:

- A **model-invoked** skill keeps a `description`, so the agent can fire it autonomously, and other skills can reach it. You can still type its name: model-invocation always _includes_ user reach; a description only ever adds agent discovery, never removes the human's. The description is the skill's top-level context pointer, forced to stay loaded at all times: permanent context load in exchange for discoverability. A model-invoked skill whose content is all reference or a shared operator is also the canonical home for shared capability: another skill can invoke it, so rules and operators needed by several skills live in one place. Mechanics: omit `disable-model-invocation`, and write a model-facing description carrying the trigger branches (the pointer-writing rules in `SKILL.md` apply in full).
- A **user-invoked** skill strips the description from the agent's autonomous reach: only the human typing its name (or an authorized parent orchestrator following a direct file-path pointer after user go-ahead) can invoke it, never autonomous description-matching. Zero always-loaded context load, at the price of cognitive load: you are the index that must remember it exists. Mechanics: set `disable-model-invocation: true`; the `description` becomes human-facing: a one-line summary, trigger lists stripped.

Pick model-invocation only when the agent must reach the skill on its own, or another skill must. If it only ever fires by hand, make it user-invoked and pay no context load.

Shared reference that two user-invoked skills both need can live in neither: with no descriptions, neither can fire the other. Push it to a model-invoked shared skill or a plain file outside the skill system: external reference any skill can point at.

## Splitting by invocation & callable primitive subroutines

The invocation cut of splitting (the sequence cut lives in `SKILL.md`): split off a model-invoked skill when you have a distinct leading word that should trigger it on its own (a trigger word you actually use in your prompts), or when multiple upper container skills must reach it as a shared subroutine (`Star-Topology Subroutine`, such as `module-design` or `grilling`). You pay context load for the new always-loaded description, so that independent reach has to be worth it.

When a model-invoked skill serves as a shared subroutine called mid-workflow by upper container skills (`tdd`, `develop`, `to-spec`, `writing-for-agents`, `math-teaching`), prevent the agent from getting trapped inside the subroutine or losing the caller's step via **dual-side locking and flat 1-hop return anchors**:
1. **Caller-side framing (1-line baseline + bounded jump)**: Keep a 1-sentence baseline rule inside the caller skill so routine 80% tasks never jump; trigger the jump only when boundaries/seams are unsettled, and state explicitly at the call site that the target skill is a **subroutine/reference to consult, not an open-ended conversation session**.
2. **Caller-keyed middle branches & flat 1-hop subfiles**: Inside the subroutine's `SKILL.md`, place universal principles at the top (`§0–§1`), inline concise branches keyed by the calling container's name in the middle (`§2`, leveraging the caller identity already sitting at the top of the context window), and keep any heavy sibling files (`DEEPENING.md`, `DESIGN-IT-TWICE.md`) strictly **1 hop deep**. Place a 1-line **`Return to Caller`** instruction at the very bottom of every sibling file so the recency peak at the generation cursor redirects attention back to `SKILL.md`'s output template.
3. **Callee-side return contract (Fixed-shape output + inline resume)**: Close the subroutine's `SKILL.md` (`§3`) with a fixed-shape output template (e.g., `5-Line Module Blueprint`) as its checkable completion criterion, and instruct the agent to **immediately resume the calling container inline** at the suspended step in the current context window—without calling `read_file` a second time on the caller's `SKILL.md`.

## Router skills

When user-invoked skills multiply past what you can remember, that piled-up cognitive load is cured by a **router skill**: one user-invoked skill that names the others and when to reach for each, so the human has one skill to remember instead of many. It can only hint, never fire them: user-invoked skills have no description, so nothing but the human can reach them.

**Return to Caller**: Apply the selected invocation mode, frontmatter fields, or subroutine locking rules to the target skill, then return to [`SKILL.md`](SKILL.md) (`§2–§3`) to complete prose polishing and run the verification gate.
