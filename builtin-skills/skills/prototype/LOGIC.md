# Logic Prototype (Single-File Shareable State Machine Demo)

> **Unified Rules**: See [SKILL.md](SKILL.md) (`§0–§2`) for branch selection (`LOGIC.md` vs. `UI.md`), the 6 universal prototype invariants (in-memory state, zero tests, throwaway branch archiving), and the bottom subroutine return contract.

Build a single, self-contained HTML file that lets anyone (developer, designer, PM, or domain expert) drive a business state model by clicking buttons and watching state transitions live.

## 1. When This Shape Fits

- *"Does this state machine handle the edge case where X happens before Y?"*
- *"Does this data model cleanly represent partial cancellations / retries?"*
- *"What should the module interface and state transitions feel like before locking `SPEC.md`?"*

## 2. Process

### 1. State the question at the top of the demo
Write one visible paragraph at the top of the HTML page stating the exact state model and edge-case question under test.

### 2. Isolate the domain logic in a pure, liftable `<script>` module
Write the core logic in a self-contained `<script>` block as a pure module with zero DOM or `document` references so the validated logic can be lifted directly into `SPEC.md` or production code:
- **Pure reducer**: `(state, action) => state` for discrete event streams;
- **Explicit state machine**: enumerated states, legal transitions, and guard conditions;
- **Pure transformation functions** over a canonical domain type;
- **Stateful class with a minimal method interface** when internal state ownership is the question.

### 3. Build the self-contained HTML shell (Zero Bundler / Zero Server)
Keep all HTML, CSS, and JS inline in a single `.html` file that opens by double-click, using `GLOSSARY.md` domain labels (never raw code identifiers) in a 4-part vertical layout:
1. **Title & 1-line question statement** (from Step 1).
2. **Live state panel**: readable labeled fields (not a raw JSON dump), re-rendered after every click with a visual highlight on what just changed.
3. **Free-play action buttons**: one button per domain action so the user can probe transitions in any order.
4. **Tabbed guided walkthroughs**: one tab per edge-case scenario (happy path, awkward boundary case, rejected illegal transition), each tab resetting to a deterministic initial state and providing ordered step buttons to click through.

### 4. Hand over & capture the validated decision
Open or link the `.html` file for the user, iterate on any discovered state bugs, and once settled, lift the pure logic module into the spec/codebase and archive the `.html` demo on `prototype/<slug>`.

**Return to Caller**: Hand over the self-contained `.html` demo (and once validated, the portable reducer/state-machine excerpt) and return to [SKILL.md](SKILL.md) (`§2`) to emit the **Prototype Verdict Summary** and resume the calling workflow.
