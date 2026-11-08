# UI Prototype (`?variant=` Multi-Layout Route Switcher)

> **Unified Rules**: See [SKILL.md](SKILL.md) (`§0–§2`) for branch selection (`UI.md` vs. `LOGIC.md`), the 6 universal prototype invariants (in-memory/stub state, zero tests, throwaway branch archiving), and the bottom subroutine return contract.

Generate **3–5 structurally distinct UI variations** on a single route, switchable live in the browser via a `?variant=` URL search parameter and a floating bottom bar.

## 1. Two Sub-Shapes (Prefer Sub-Shape A)

| Sub-Shape | When to Use | Mounting Pattern |
| :--- | :--- | :--- |
| **Sub-Shape A: Existing Host Page (Default)** | Whenever a plausible host route already exists (or the new surface lives inside an existing dashboard, settings page, or flow). | Render variants on the **existing route** gated by `?variant=`, keeping real header, sidebar, data fetching, and density intact so variants are judged in realistic context. |
| **Sub-Shape B: Throwaway New Route (Last Resort)** | Only when prototyping a brand-new top-level surface with no existing page to host it. | Mount a clearly named throwaway route (`/prototype/<name>`) using the project's existing router convention and the same `?variant=` switcher. |

## 2. Process

### 1. State the plan and pick $N$ (`3–5` variants)
Default to **3 variants** (capped at 5 so every option remains structurally distinct). State the 1-line plan in a top comment:
> *"Three structurally distinct variants of `<surface>`, switchable via `?variant=A|B|C` on `<route>`."*

### 2. Draft structurally distinct variants (`VariantA`, `VariantB`, `VariantC`)
Use the project's existing styling/component system (`Tailwind`, `shadcn`, `MUI`, plain CSS) and hold each variant to a **radically different layout, information hierarchy, and primary affordance** (e.g., `A: Split master-detail`, `B: Dense command table`, `C: Stepwise card flow`) rather than superficial color or copy tweaks. Keep mutations wired to in-memory stubs.

### 3. Wire the route switcher & floating bottom bar

```tsx
const variant = searchParams.get('variant') ?? 'A';
return (
  <>
    {variant === 'A' && <VariantA {...data} />}
    {variant === 'B' && <VariantB {...data} />}
    {variant === 'C' && <VariantC {...data} />}
    <PrototypeSwitcher variants={['A', 'B', 'C']} current={variant} />
  </>
);
```

Build `<PrototypeSwitcher>` as a fixed bottom-center high-contrast pill with:
- **Left / Right cycle buttons** (`←` / `→`) that update the `?variant=` URL search param (reload-stable and shareable) and support keyboard `ArrowLeft` / `ArrowRight` (ignoring key events when `<input>`, `<textarea>`, or `[contenteditable]` is focused);
- **Variant label** showing the active key and layout posture (e.g., `B (Sidebar layout)`);
- **Production guard**: gated on `process.env.NODE_ENV !== 'production'` so the switcher never renders in production builds.

### 4. Hand over, fold winner & archive
Surface the runnable URL and `?variant=` keys. Once the user selects a winner (or hybrid combination such as *"header from B + table from C"*), rewrite the winning structure cleanly into the real route, drop the losing variants and switcher from `main`, and archive the full multi-variant prototype on `prototype/<slug>`.

**Return to Caller**: Surface the runnable `?variant=` route (and once chosen, the winning layout structure) and return to [SKILL.md](SKILL.md) (`§2`) to emit the **Prototype Verdict Summary** and resume the calling workflow.
