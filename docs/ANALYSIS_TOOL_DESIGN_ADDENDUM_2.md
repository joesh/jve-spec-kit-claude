# Structural Analysis Enhancements for Refactor-Planning Tool (Boilerplate-Corrected)

## Purpose

Upgrade the existing Lua structure analysis tool so that it:

1. Identifies real refactor leverage, not cosmetic clusters
2. Prefers silence over weak claims
3. Ranks extraction candidates by engineering cost and risk
4. Surfaces required interfaces mechanically
5. Simulates extraction order to guide safe refactors

This tool exists to **discover the latent potential for good code inside messy code**, not to perform post‑hoc classification or narrative forensics.

---

## Terminology (Authoritative)

### Boilerplate

**Boilerplate** refers to logic that is:
- lifecycle setup
- registration / wiring
- handler dispatch
- glue code necessary for operation

Boilerplate is:
- necessary
- non‑structural
- signal‑suppressing
- never a nucleus

Boilerplate must *reduce* confidence, never increase it.

The word **“orchestration” is deprecated** and must not be used in analysis or output.

---

## Non‑Goals (Hard Constraints)

The tool must not:
- invent semantic intent
- dilute language to hedge uncertainty
- emit clusters without a defensible structural nucleus
- treat boilerplate as architectural structure
- suggest extraction when timeline and selection are entangled
- guess domain meaning

Everything must be mechanical, observable, and auditable.

---

## Enhancement 1: Nucleus Scoring

A **nucleus** is a function that plausibly represents the center of a responsibility.

It is not:
- the most called function
- a lifecycle hook
- a registration hub

### Nucleus Score (0–1)

Raw nucleus signal:

```
raw_nucleus_signal(f) =
    0.40 * inward_call_weight(f)
  + 0.30 * shared_context_weight(f)
  + 0.20 * internal_cluster_participation(f)
```

Final nucleus score:

```
nucleus_score(f) = raw_nucleus_signal(f) * (1 - boilerplate_score(f))
```

#### Components

- **inward_call_weight**
  - normalized fan-in
  - callers must not all be boilerplate

- **shared_context_weight**
  - overlap of context roots with neighbors
  - table roots only (e.g. `browser_state.*`)

- **internal_cluster_participation**
  - proportion of calls inside the candidate group

### Gate


If no function has:

```
nucleus_score ≥ 0.45
```

→ Emit **no cluster**
→ Output: “No stable structural nucleus detected.”

Silence is correct behavior.

---

## Enhancement 2: Boilerplate Detection

Boilerplate refers to logic that is necessary for wiring and lifecycle but does **not** represent a responsibility.
It actively suppresses structural signal and must never be mistaken for architecture.

### Boilerplate Score (0–1)

Each function is assigned a **boilerplate score**. Higher means more structural noise.

```
boilerplate_score(f) =
    0.40 * fanout_weight(f)
  + 0.25 * call_density_weight(f)
  + 0.20 * registration_pattern_weight(f)
  + 0.15 * lifecycle_position_weight(f)
```

#### Components (all mechanical)

- **fanout_weight**
  - `min(1.0, f.fanout / FANOUT_HIGH_WATERMARK)`
  - `FANOUT_HIGH_WATERMARK ≈ 8–10`

- **call_density_weight**
  - ratio of calls in body to non-call statements

- **registration_pattern_weight**
  - additive weight if body contains:
    - `register_*`
    - handler hookup
    - widget construction
    - command registration

- **lifecycle_position_weight**
  - function name matches `create`, `init`, `setup`, `ensure`
  - exported entrypoint
  - called exactly once externally

### Hard Rules

- If `boilerplate_score(f) ≥ 0.6`, the function **cannot be a nucleus**
- Boilerplate-heavy functions reduce confidence of any group they dominate
- If all high-centrality functions in a group have `boilerplate_score ≥ 0.6`, **emit no cluster**

---

## Enhancement 3: Extraction Cost Model (Editor‑Specific)

Extraction cost reflects **how much real editor behavior is at risk**.

```
extraction_cost(f) =
    0.30 * timeline_coupling
  + 0.25 * selection_coupling
  + 0.20 * command_graph_coupling
  + 0.15 * media_identity_coupling
  + 0.10 * global_state_touch
```

### Coupling Heuristics

- **Timeline coupling**
  - tokens: track, clip, frame, time, offset, ripple, insert, trim

- **Selection coupling**
  - selected_* access
  - selection_context usage

- **Command graph coupling**
  - undo/redo
  - command execution or registration

- **Media identity coupling**
  - master clip IDs
  - metadata decode

- **Global state touch**
  - writes to module‑level mutable state

### Hard Stop

If:

```
timeline_coupling > 0.6 AND selection_coupling > 0.4
```

→ Emit warning and **no extraction advice**

---

## Enhancement 4: Parameter Surfacing (Interface Discovery)

For each extraction candidate group:

1. Collect free variables (read/write/call)
2. Classify each

Emit:

```
Required inputs:
  - selection_snapshot (READ)
  - project_id (READ)
  - command_executor (CALL)

Writes:
  - selection_state (INDIRECT)

Hidden globals eliminated:
  - M.selected_items
```

If surfaced parameters > 5 → stop and warn.

---

## Enhancement 5: Leverage Score

```
leverage_score = centrality(f) * (1 - extraction_cost(f))
```

Only rank candidates that pass nucleus and cost gates.

---

## Enhancement 6: Extraction Order Simulation

Simulate extraction without modifying code:

- stub candidate
- recompute unresolved references
- count callers affected
- count new parameters
- count new cross‑module edges

### Blast Radius

```
blast_radius =
    callers_affected
  + parameters_added
  + new_cross_module_edges
  + timeline_risk_penalty
```

Emit comparative advice **only if difference is meaningful**.

---

## Mandatory Stop Conditions

The tool must emit no clusters if:

- no nucleus ≥ threshold
- competing nuclei within ±0.05
- boilerplate dominates group
- interface explosion
- timeline + selection entanglement

When stopping, explain why in one sentence.

---

## Output Language Rules

- Language must be earned by signal
- No hedging phrases
- Boilerplate is named explicitly
- Silence is valid and correct

Correct:
> “This group is dominated by lifecycle boilerplate. No extractable structure detected.”

Incorrect:
> “This cluster may represent a coordination module.”

---

## Acceptance Criteria

This spec is satisfied only if:

- Large meaningless clusters disappear
- Boilerplate hubs are never nuclei
- The tool sometimes recommends **no action**
- Extraction advice correlates with low real engineering risk
- Output becomes sparser but more trustworthy

### Golden Output Check (Required)

When run on a monolithic, pre-refactor file dominated by lifecycle boilerplate (e.g. `project_browser.lua`), the tool **must accept silence** as a correct outcome.

Minimal acceptable output:

```
No stable structural nuclei detected.

Findings:
- High-centrality functions are dominated by lifecycle boilerplate
- Timeline and selection semantics are tightly interwoven

Actionable guidance:
- Reduce boilerplate dominance
- Decouple selection mutation from timeline mutation
- Re-run analysis after structural simplification

No extraction is recommended at this time.
```

If the tool emits confident clusters organized around lifecycle functions, the implementation is incorrect.

