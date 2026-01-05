# Design Addendum: Operational Definitions for the Lua Analysis Tool

This document provides **precise, mechanical definitions** for the concepts used by the analysis tool. Its purpose is to eliminate ambiguity during implementation while preserving the tool’s goal: **discovering actionable refactor leverage points without inventing intent**.

---

## 1. Context Roots

### Definition
A **context root** is a stable table or module qualifier that appears across multiple functions and carries semantic meaning.

Examples:
- `M.activate_selection` → `M`
- `browser_state.update_selection` → `browser_state`
- `tree_context.selected_items` → `tree_context`
- `qt_constants.WIDGETS.CREATE_VBOX` → `qt_constants`, `WIDGETS`

### Extraction Rule
- Detect `X.Y` tokens
- Record `X` as a context root
- Ignore trivial or non-semantic roots (`self`, loop variables, temporary locals)

**Important**
- Context roots are **not** filename-based
- Context roots are **not** simple prefixes
- They are semantic carriers inferred from usage

---

## 2. Structural Boilerplate Detection

Structural boilerplate is **necessary glue**, not bad code. It obscures structure when it dominates.

### Boilerplate Signals (additive)
A function accumulates boilerplate weight if it:

- Registers handlers, listeners, or commands
  - `register_*`, `add_listener`, `bind_*`
- Constructs UI widgets or layouts
  - Calls into `qt_constants`, `WIDGETS`, `CREATE_*`
- Delegates without transformation
  - Body dominated by calls to other functions
- Touches many unrelated context roots
  - High context-root fanout

### Boilerplate Score
```
boilerplate_score =
  0.4 * delegation_ratio +
  0.3 * context_root_fanout +
  0.3 * registration_or_ui_signal
```

Threshold:
- `≥ 0.6` → boilerplate-heavy

**Note**
`M.create`-style lifecycle functions often score high. This is expected and not a judgment.

---

## 3. Nucleus Score (Meaning Concentration)

A **nucleus** is where semantic meaning concentrates, not merely where control flows.

### Required Signals
1. **Inward reference strength**
   - Other cluster functions call *into* this function
2. **Shared context participation**
   - Shares non-boilerplate context roots with peers
3. **Low boilerplate score**
   - Otherwise the function is glue

### Nucleus Score Formula
```
nucleus_score =
  0.45 * inward_call_centrality +
  0.35 * shared_context_overlap -
  0.20 * boilerplate_score
```

Normalize to `[0,1]`.

Threshold:
- `≥ 0.65` → eligible nucleus

If no function meets the threshold:
> “No clear nucleus detected.”

There is **no fallback nucleus**.

---

## 4. Leverage Point

A **Leverage Point** is a restructuring handle: a place where change propagates cleanly.

### Required Properties
- Moderate-to-high centrality (not a leaf, not the dominant hub)
- High count of inappropriate connections
- Low nucleus score

### Leverage Score
```
leverage_score =
  0.4 * centrality +
  0.4 * inappropriate_connections -
  0.2 * nucleus_score
```

Select **only the top candidate**, unless statistically tied.

---

## 5. Inappropriate Connections

An **inappropriate connection** is a strong linkage that lacks structural justification.

### Operational Definition
For functions `A` and `B`:

- `coupling(A,B) ≥ (cluster_mean + 1σ)`
- AND:
  - no shared nucleus
  - no shared non-boilerplate context root

Then:
→ `A ↔ B` is an inappropriate connection

This does **not** mean wrong code.
It means **structurally unjustified coupling**.

---

## 6. Explicit Non-Inferences

The tool must **not**:
- Infer domain meaning from names
- Privilege filenames or directories
- Treat orchestration as bad code
- Emit guidance when thresholds are not met

Silence is preferable to weak signal.

---

## 7. Output Language Contract

The following terms are **intentional and must be used**:

- Algorithm
- Nucleus
- Structural Boilerplate
- Leverage Point
- Inappropriate Connections

Do **not** soften language to hedge uncertainty.
Instead, suppress output when signal is insufficient.

---

## Final Constraint

> If any term cannot be justified numerically, do not emit it. The tool must earn its language.

This contract aligns the implementation with the tool’s purpose: discovering real architectural potential, not performing forensic narration.

