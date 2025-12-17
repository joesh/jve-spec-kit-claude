# Ripple Edge Preview Payload Spec

## Problem

The timeline renderer currently relies on two fallbacks when rendering edge-drag previews:

1. **Clamp-hint fallback**: if the delta is clamped but no specific limiting edge is known, the renderer tints edges as “limited” anyway.
2. **Missing-clamped-edge fallback**: if `clamped_edges` contains keys that weren’t drawn through normal edge-preview generation, the renderer does a second pass to draw them.

These fallbacks exist because the UI does **not** have a single authoritative list of:

- which edges should be rendered for the preview, and
- which edges are the actual limiters.

This leads to incorrect “red” edges and missing implied edges, especially when:

- the limiter is an **implied zero-length gap** (adjacent clips), and/or
- downstream motion is represented by **shift blocks** instead of enumerated `shifted_clips`.

## Goals

- Provide a **single authoritative edge list** for the UI to render during edge drags.
- Encode **selection vs implied** vs limiter information explicitly.
- Support implied edges even when:
  - the track shift is represented only by `shift_blocks`, and/or
  - the limiter is a **zero-length gap**.
- Keep existing payload fields (`shifted_clips`, `shift_blocks`, `clamped_edges`, etc.) initially for compatibility, but make the UI able to ignore fallbacks when the new fields exist.

## Non-goals

- Changing ripple/roll semantics (Rule 1–12) or constraint math.
- Replacing `shift_blocks` preview optimization.

## Definitions

### Edge Key

Canonical string key format:

`<clip_id>:<edge_type>`

Where `edge_type ∈ {in, out, gap_before, gap_after}`.

### Gap Anchoring

Gaps are modeled as boundary handles anchored to a real clip id:

- `gap_after` is anchored to the **left clip** (the clip ending at the boundary).
- `gap_before` is anchored to the **right clip** (the clip starting at the boundary).

Zero-length gaps (adjacent clips) are still represented using these same edge types.

Timeline start boundary:

- If a boundary occurs at timeline start and there is no clip to the left, anchor implied `gap_after` to the first clip at/after the boundary (so the UI still has something to draw).

## New Payload: `edge_preview`

`BatchRippleEdit` dry-run should return a new object `edge_preview` that is sufficient for the UI to render edge handles without heuristics/fallbacks.

### Top-level

```lua
edge_preview = {
  requested_delta_frames = <int>,
  clamped_delta_frames = <int>,

  -- All handles the UI should draw for this drag (selected + implied + limiter-only).
  edges = { <EdgeRenderEntry> ... },

  -- Optional: for debugging / tooling.
  limiter_edge_keys = { ["clip:gap_before"] = true, ... },
}
```

### `EdgeRenderEntry`

```lua
EdgeRenderEntry = {
  edge_key = "clip_id:edge_type",

  clip_id = <string>,         -- anchor clip id
  track_id = <string>,        -- track containing the anchor clip

  raw_edge_type = <string>,   -- in/out/gap_before/gap_after (for geometry anchoring)
  normalized_edge = <string>, -- in/out (bracket orientation)

  -- Classification
  is_selected = <bool>,       -- explicitly selected by the user
  is_implied  = <bool>,       -- not selected; implied by Rule 8.5
  is_limiter  = <bool>,       -- this edge is an actual limiting edge for the clamped delta

  -- Per-edge preview delta (already includes per-edge negation, roll/ripple rules, etc.)
  applied_delta_frames = <int>,
}
```

### Invariants

- Exactly one of `{is_selected, is_implied}` should be true.
  - Exception: if an edge is selected and also a limiter, it is still `is_selected=true` and `is_implied=false`.
- `is_limiter=true` implies the edge key is present in `limiter_edge_keys` (when provided).
- The UI should render **only** `edge_preview.edges` when present.
  - It must not use clamp-hint tinting.
  - It must not do the “draw missing `clamped_edges` keys” pass.

## Command Responsibilities (BatchRippleEdit dry-run)

The command already computes:

- global clamp delta,
- track shift vectors,
- limiter edges (`clamped_edges`),
- preview geometry drivers (`affected_clips`, `shifted_clips`, `shift_blocks`).

It should additionally:

1. Populate `edge_preview.requested_delta_frames` and `edge_preview.clamped_delta_frames`.
2. Produce `edge_preview.edges` by combining:
   - **Selected edges** (`edge_infos`, after gap materialization).
   - **Implied edges from track shift amounts** (Rule 8.5), including tracks represented only in `shift_blocks`.
   - **Limiter-only edges** when the limiter is not selected and not otherwise implied.
3. Ensure implied edges follow the canonical gap anchoring rules, including zero-length gaps.

## UI Responsibilities (Timeline View Renderer)

When `edge_preview` exists:

- Render handles from `edge_preview.edges` only.
- Compute color from `{is_selected,is_implied,is_limiter}`:
  - `is_limiter=true` → limit color
  - `is_implied=true` → dim
  - Combine: implied+limiter = dimmed limit color
- Geometry should use:
  - `raw_edge_type` for gap anchoring,
  - `normalized_edge` for bracket direction,
  - `applied_delta_frames` for preview delta.

## Backward Compatibility Plan

Phase 1:

- Command returns `edge_preview` in dry-run, while keeping existing fields (`clamped_edges`, etc.).
- UI prefers `edge_preview` if present; otherwise, it uses legacy behavior (including fallbacks).

Phase 2:

- Remove clamp-hint and missing-clamped-edge fallbacks once `edge_preview` is always present for edge drags.

## Test Coverage

- Unit test for UI implied edge generation should move from “derive from shifted_clips/shift_blocks” to “render from edge_preview”.
- Integration tests should include scenarios:
  - limiter is zero-length gap on unselected track → limiter edge appears as implied + limiter
  - track shifts represented only via shift_blocks → implied edges still present
  - selected edge clamps by media → selected edge is limiter, not implied

