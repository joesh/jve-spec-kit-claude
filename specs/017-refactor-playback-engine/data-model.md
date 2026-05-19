# Phase 1 Data Model: Two-Engine Playback Refactor

**Feature**: 017-refactor-playback-engine
**Date**: 2026-05-16

## Persisted entities (DB schema)

### `sequences` table — UNCHANGED
Per-sequence transport state already lives here. No new columns; no migration. Fields the refactor relies on:
- `playhead_frame INTEGER NOT NULL` — read by `engine:load(seq_id)`; written by engine on stop/park (FR-007) and throttled during play (FR-007a).
- `mark_in_frame INTEGER`, `mark_out_frame INTEGER` — read by engine; written by `SetMark*` commands (existing, unchanged).
- `start_timecode_frame INTEGER NOT NULL DEFAULT 0` — read at engine load. Existing `or 0` fallback in `playback_engine.load_sequence` is DELETED (rule 2.13); column is NOT NULL with DB default 0, so the value is always present.

### `projects.settings` JSON column — NEW KEY
No persisted target. Revised 2026-05-16: the transport target is **derived** from UI state on every query (see `contracts/transport.md` design note). There is no `transport_target` key in `projects.settings`, no read at `transport.init`, no write-through. The first draft of this data model proposed a stored + persisted target; that draft is superseded.

FR-008a's "default to `record`" outcome is preserved structurally: `transport.get_target()` returns `"record"` whenever neither the source viewer is focused nor a source tab is displayed. On first project open with no source-side UI state, that condition holds and `get_target()` returns `"record"` without any persisted default to consult.

## In-memory entities (Lua module state)

### `transport` module state (`src/lua/core/playback/transport.lua`)
```
M.source_engine    : PlaybackEngine | nil  -- constructed in M.init, nil pre/post
M.record_engine    : PlaybackEngine | nil  -- constructed in M.init, nil pre/post
M._project_id      : string | nil          -- nil pre-init / post-shutdown
```
Invariants:
- After `init`, both engines exist; `_project_id` is the non-empty project id.
- After `shutdown`, all three fields are nil.
- There is **no `_target` field**. The target is computed on demand by `get_target()` as a projection of `focus_manager.get_focused_panel()` and `timeline_state.get_displayed_tab_kind()`.

Public accessors over the private state: `is_bootstrapped() -> bool`, `bound_project_id() -> string|nil`. External readers MUST go through these rather than poking `M._project_id` directly.

**No coalesce slot, no in-flight flag, no `_pending_target`.** FR-009a's coalescing is structural: the target is recomputed per query, so rapid UI clicks settle on the final UI state by definition. There is nothing to queue.

### `PlaybackEngine` instance state (`src/lua/core/playback/playback_engine.lua`)
Existing fields retained: `_playback_controller`, `_tmb`, `sequence` (model row cache), `fps_num`, `fps_den`, `total_frames`, `start_frame`, `state`, `direction`, `speed`, `transport_mode`, `_position`, `_last_committed_frame`, `_video_track_indices`, `_audio_track_indices`, `_effective_video_track_indices`, `_clip_info_by_id`, `max_media_time_us`, `audio_sample_rate`, `_writeback_throttle_last_ts` (NEW, for FR-007a).

NEW immutable fields:
```
self.role               : "source" | "record"   -- set at construction
self._log_tag           : string                -- "role:firstn" — recomputed on load
```

RENAMED:
- `self.sequence_id` → `self.loaded_sequence_id` (string | nil; nil before first `load`).

DELETED:
- `self._audio_owner : boolean`
- `self:activate_audio()`, `self:deactivate_audio()` methods.

Invariants:
- If `loaded_sequence_id` is non-nil, `_tmb` MUST be non-nil and `_playback_controller` MUST be configured for that sequence's fps/audio rate.
- If `state == "playing"`, this engine MUST equal `audio_playback._owning_engine` (FR-011 structural invariant).

### `audio_playback` module state (`src/lua/core/media/audio_playback.lua`)
```
M._owning_engine : PlaybackEngine | nil   -- the one engine currently bound to the device; nil = device idle
```
Invariants:
- `_owning_engine` is non-nil iff the audio device is producing samples (real or silent) on behalf of that engine.
- `_owning_engine` is nil iff the device is idle (no samples being produced).
- At most one engine is `_owning_engine` at any moment (FR-011 — structural, not flag-based).
- Two public functions transition the state: `acquire_for(engine)` (nil → engine) and `halt_current()` (engine → nil). Both synchronous; both assert on failure.

### View state (per view widget — source_viewer, timeline_monitor, source-tab timeline view, record-tab timeline view)
```
self.role                       : "source" | "record"   -- which engine to observe
self.sequence_id                : string | nil          -- what this view wants to display
self._cached_last_frame         : opaque                 -- last frame received while engine.loaded_sequence_id == self.sequence_id
self._cached_last_frame_for_seq : string | nil          -- the seq id the cached frame belongs to
```
View rendering decision (FR-016):
```
engine := transport.engine_for_role(self.role)
if engine.loaded_sequence_id == self.sequence_id:
    if engine.state == "playing": render engine's hot-path frame
    else: render engine's last decoded frame (parked)
elif self._cached_last_frame_for_seq == self.sequence_id:
    render self._cached_last_frame
else:
    render documented empty-state placeholder (NEVER a stale frame from another sequence)
```

## State transitions

### Engine: `unloaded → loaded → unloaded`
```
constructed                               -- loaded_sequence_id = nil
  ↓  load(seq_id)
loaded, parked at saved playhead          -- loaded_sequence_id = seq_id
  ↓  play()
loaded, playing                           -- audio_playback._owning_engine == self
  ↓  stop() / hit_content_end / handover-pulls-device-away
loaded, parked (playhead written back)
  ↓  unload() / load(other_id)
unloaded again OR loaded with other_id
  ↓  project close
torn down (release TMB, decoders, PlaybackController)
```
Every transition asserts on precondition violation (e.g., `play()` while `loaded_sequence_id == nil` asserts per FR-027).

### Audio device: `idle → playing → idle`
```
idle                                      -- _owning_engine = nil
  ↓  audio_playback.acquire_for(engine)
playing                                   -- _owning_engine = engine, samples producing
  ↓  audio_playback.halt_current()
idle                                      -- _owning_engine = nil
```
The handover (FR-012) is `playing(old) → idle → playing(new)`: `halt_current` brings the device to idle, then `acquire_for` re-arms it for the new engine. Both calls assert on failure. The intermediate "idle" state is observable (potentially zero-duration if `halt_current` was a no-op because the old engine wasn't producing audio).

Two invariants hold across the transition (FR-012):
- **I1**: at every sample-instant, the output stream is from at most one engine.
- **I2**: the new engine does not deliver any video frame before `acquire_for` returns.

Internal details (drain, release, reconfigure, channel layout swap) are implementation-bounded; the only mandated observable behaviors are I1 and I2.

### `transport_target`: `source ⇄ record` (derived, not stored)
Derived on every `transport.get_target()` call from `focus_manager.get_focused_panel()` + `timeline_state.get_displayed_tab_kind()`. No state transition in the data-model sense — the value flips whenever the underlying UI state flips. FR-008a's default `"record"` outcome is the projection's result when neither source-side condition holds (initial UI state on first project open).

## Relationships

```
transport (module)
  ├─→ source_engine ── 1:1 ── PlaybackController (C++) ── 1:1 ── TMB ── decoders
  │                       └── 1:1 ── log_tag "source:xxxxxxxx"
  ├─→ record_engine ── 1:1 ── PlaybackController (C++) ── 1:1 ── TMB ── decoders
  │                       └── 1:1 ── log_tag "record:xxxxxxxx"
  └─→ audio_playback._owning_engine ── 0..1 ── (one of the two engines)

source_engine.loaded_sequence_id ──→ sequences (master kind)
record_engine.loaded_sequence_id ──→ sequences (non-master kind, == active_sequence_id)

view (source_viewer)            ─observes→ transport.engine_for_role("source")
view (timeline-panel source tab)─observes→ transport.engine_for_role("source")
view (timeline_monitor)         ─observes→ transport.engine_for_role("record")
view (timeline-panel record tab)─observes→ transport.engine_for_role("record")
```

Two views per role observe one engine. Engine signals are broadcast; views filter by `loaded_sequence_id == self.sequence_id` (R1 contract).

## Validation rules (derived from FRs)

| Rule | Enforced where | Assertion |
|------|----------------|-----------|
| `transport.get_target() ∈ {"source","record"}` | the projection itself (focus + displayed_tab_kind) | falls through to `"record"` when neither source-side condition holds (FR-008a outcome) — no separate stored value to validate |
| Engine `role` immutable post-construction | constructor only setter | no setter exists |
| `loaded_sequence_id` matches a `sequences.id` row | `engine:load(id)` | `assert(Sequence.load(id), ...)` |
| Source-engine loads only `kind = "master"` | `engine:load(id)` (source role) | assert on kind |
| Record-engine loads only `kind = "sequence"` | `engine:load(id)` (record role) | assert on kind |
| `audio_playback._owning_engine` is current playing engine | `engine:play()` enter / `engine:stop()` exit | assert pre/post |
| Writeback throttle ≥ 1 second between writes | `engine._writeback_throttle_last_ts` check | drop, don't queue |
| I1 (no-overlap) across handover | audio-stream tap during `--test` handover scenarios | assert on dual-tagged sample-instant |
| I2 (audio-before-video) across handover | first-video-frame-ts ≥ first-audio-sample-ts post-handover | assert if video precedes audio |
| `halt_current` 100 ms timeout | `audio_playback.halt_current` body | assert with elapsed + roles |
