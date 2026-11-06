# Batch PNG Rendering (`render-batch.mjs`)

> **Unified Delivery Rules**: See [SKILL.md](../SKILL.md) for the single-track either/or delivery contract (default to a standalone `.md` diagram document only; never generate both `.md` and `.png`).

## Single-Browser Batch Renderer (`render-batch.mjs`)

Invoke `scripts/render-batch.mjs` **only** when the user explicitly requests high-resolution `.png` images or when archiving finalized diagrams into Obsidian `.md` notes (do not run this script when delivering the default standalone `.md` diagram document). It launches **1 single Headless Chrome instance** to render all `.mmd` files in a single batch at `-s 2` (`deviceScaleFactor: 2`, white background):

```powershell
# Render 1 or more explicit input->output pairs in a single shared browser (~1.5s–2.5s total):
node "scripts/render-batch.mjs" "in1.mmd" "out1.png" "in2.mmd" "out2.png"

# Or render .mmd files in-place to .png (foo.mmd -> foo.png):
node "scripts/render-batch.mjs" "diagram1.mmd" "diagram2.mmd"
```
