# Phase 1 — Data Model

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Date**: 2026-05-19

019 adds **no new schema**, **no new entities**, and modifies no existing column semantics. The data model below documents the existing entities the feature reads/writes plus the per-module in-memory state (source_viewer mode + live_clip_id, edit_mode trim_mode).

---

## Entities

### Existing — `clips` row (`schema.sql:261-324`)

Live-bound mode reads and mutates the following columns:

| Column | Type | Mutated by | Read by |
|---|---|---|---|
| `id` | TEXT (UUID) | — | `OverwriteTrimEdge`, source_viewer state |
| `name` | TEXT (nullable) | — | source_viewer title (FR-016f) |
| `sequence_id` | TEXT (FK sequences.id) | — | source_viewer binds playback via `SequenceMonitor:load_sequence(clip.sequence_id)` in live-bound mode |
| `owner_sequence_id` | TEXT (FK sequences.id) | — | source_viewer title (FR-016f, "in <owner_sequence_name>") |
| `track_id` | TEXT (FK tracks.id) | — | RippleTrimEdge / OverwriteTrimEdge (track context) |
| `source_in_frame` | INTEGER | OverwriteTrimEdge (left edge), RippleTrimEdge (via BatchRippleEdit) | source_viewer mark display, effective_source pass-through (FR-016d) |
| `source_out_frame` | INTEGER | OverwriteTrimEdge (right edge), RippleTrimEdge (via BatchRippleEdit) | source_viewer mark display, effective_source pass-through (FR-016d) |
| `duration_frames` | INTEGER | OverwriteTrimEdge, RippleTrimEdge (recomputed from `source_out - source_in` on the source-sequence timebase) | timeline renderer |
| `sequence_start_frame` | INTEGER | OverwriteTrimEdge (only on left-edge trim; right-edge trim leaves this unchanged per FR-014) | timeline renderer |

No new columns, no new constraints, no migrations.

### Existing — `sequences` row (`schema.sql:94-178`)

Staged mode behavior is unchanged. 019 reads:

| Column | Read for |
|---|---|
| `name` | source_viewer title (staged mode: `"Source: <sequence_name>"`); live-bound mode owner-sequence-name component (FR-016f) |
| `kind` | activation-routing in browser (`'master'` → source viewer; `'sequence'` → timeline panel; will rename to `'media'` / `'clip'` post-020) |
| `mark_in_frame`, `mark_out_frame` | staged-mode marks; UNCHANGED by 019 |
| `playhead_position` | unchanged; persistence unchanged |

### No new entities

The scope-trim 2026-05-19 dropped the in-memory holding-sequence wrap. Live-bound mode reuses the existing `SequenceMonitor:load_sequence(clip.sequence_id)` path; the source viewer just remembers `clip_id` alongside the loaded sequence_id, so the mark-setter and selection_hub publish know to read from clip columns instead of sequence-row marks.

Lifecycle:

```
       (no clip loaded)                                            mode = "neutral"
            |
            |  source_viewer.load_clip(clip_id)
            v
       Load clip row + its source sequence                         mode = "live_bound_clip"
       Call SequenceMonitor:load_sequence(clip.sequence_id)        live_clip_id = clip_id
       Publish item_type="clip" to selection_hub
            |
            |  user retrims (FR-013/014) — mutates clip.source_in/out via Ripple/OverwriteTrimEdge
            |  signal: clip mutation → FR-004b refresh
            |     → reload clip + source sequence
            |     → recompute title, re-bind playback if rate/duration changed
            |     → republish selection_hub
            |
            |  user mutates other clip fields (rate, enabled, etc.)
            |  → same FR-004b refresh path
            |
            |  user deletes the clip
            |  signal: clip deletion → unload + source_loaded_changed(nil, prev) (FR-004a)
            v
       (no clip loaded)                                            mode = "neutral"
            |
            |  source_viewer.load_clip(other_clip_id)
            v
       Replaces previous state (live_clip_id overwritten)
```

---

## State (source_viewer module)

```
SourceViewerState {
    mode            : "neutral" | "staged_sequence" | "live_bound_clip"
    staged_seq_id   : string | nil                     -- only when mode == "staged_sequence"
    live_clip_id    : string | nil                     -- only when mode == "live_bound_clip"
    panel_id        : "source_monitor"                 -- constant; matches focus_manager + selection_hub keying
}
```

Invariants (asserted on every mode transition):
- `mode == "staged_sequence"` ⟹ `staged_seq_id ~= nil`, `live_clip_id == nil`
- `mode == "live_bound_clip"` ⟹ `live_clip_id ~= nil`, `staged_seq_id == nil`
- `mode == "neutral"` ⟹ all three are nil

---

## State (`core/edit_mode` module, NEW)

```
EditModeState {
    trim_mode : "overwrite" | "ripple"     -- default "overwrite"
}
```

- Reset to `"overwrite"` on every process start (FR-010); never written to disk.
- Mutated only via `set_trim_mode(mode)`, which asserts on enum validity (FR-009) and emits `trim_mode_changed` signal.

---

## Relationships modified by 019

```
ClipRow(source_in, source_out)  ←─── (single source of truth)
        ↑                                  │
        │ mutated by                       │ read by
        │                                  ↓
RippleTrimEdge / OverwriteTrimEdge   effective_source.get()  ──→ Insert / Overwrite into record timeline
        ↑                                  ↑
        │ dispatched by                    │ pass-through carries (in, out) overrides
        │                                  │ when source_viewer is live-bound (FR-016d)
        │                                  │
SourceViewer mark-setter (live-bound mode, FR-013)
```

The diagram captures the single-source-of-truth point: `clips.source_in_frame` / `source_out_frame` are the only columns that hold mark state in live-bound mode; both the retrim mutator and the effective-source reader use them directly. No second value to keep synchronized.

---

## No schema migration

019 does NOT bump the project DB schema version. All columns it reads/writes already exist. The spec 020 rename will touch column names (`master_layer_track_id` → `source_video_track_id`, etc.) but 019 leaves them alone.
