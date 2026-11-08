# Batch PNG Rendering (`render-batch.mjs`)

> **Unified Delivery Rules**: See [SKILL.md](../SKILL.md) (§2.1) for the single-track delivery contract (deliver a standalone `.md` diagram document by default, or run `render-batch.mjs` for high-res `2x .png` output on demand).

## Single-Browser Batch Renderer (`render-batch.mjs`)

Invoke `scripts/render-batch.mjs` when the user requests high-resolution `.png` images or when archiving finalized diagrams into persistent Obsidian `.md` notes. It launches **1 single Headless Chrome instance** to render all `.mmd` files in a single batch at `-s 2` (`deviceScaleFactor: 2`, white background):

```powershell
# Render 1 or more explicit input->output pairs in a single shared browser (~1.5s–2.5s total):
node "scripts/render-batch.mjs" "in1.mmd" "out1.png" "in2.mmd" "out2.png"

# Or render .mmd files in-place to .png (foo.mmd -> foo.png):
node "scripts/render-batch.mjs" "diagram1.mmd" "diagram2.mmd"
```

---

**Return to Caller**: Return with the rendered `2x .png` artifact path to [SKILL.md](../SKILL.md) (§2 & §5) to complete single-track delivery, then resume the calling host workflow.
