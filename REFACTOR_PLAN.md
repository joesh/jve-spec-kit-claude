# Timeline Refactor Plan

## Phase 1: Drag/Nudge Performance
- [x] Keep timeline state in memory and apply command mutations instead of reloading clips.
  - Evidence: `__timeline_mutations` buckets flow through `command_manager.execute` into `timeline_state.apply_mutations` (`src/lua/core/command_manager.lua:1552-1595`, `src/lua/ui/timeline/timeline_state.lua:1607-1650`).
- [x] Treat drag selection as per-track move blocks; only clamp against boundary neighbors.
  - Evidence: `Nudge` groups clips per track, computes block windows, and pushes them through `clip_mutator.resolve_occlusions` (`src/lua/core/command_implementations.lua:4172-4270`).
- [x] Record occlusion trims/deletes as timeline mutations so UI cache stays hot.
  - Evidence: `record_occlusion_actions` converts trim/delete actions into mutation payloads (`src/lua/core/command_implementations.lua:300-334`).
- [x] Instrument `Clip.save` and `clip_mutator` to verify DB costs.
  - Evidence: both modules print Krono timings after operations (`src/lua/models/clip.lua:301-310`, `src/lua/core/clip_mutator.lua:360-394`).

## Phase 2: UI Reload Profiling
- [x] Add timers around `timeline_state.apply_mutations`, `notify_listeners`, and `timeline_state.reload_clips` to measure repaint cost.
  - Evidence: `profile_scope` wrappers already surround these hotspots (`src/lua/ui/timeline/timeline_state.lua:509-548,754-820,1607-1650`) and `command_manager.notify_listeners` (`src/lua/core/command_manager.lua:1618-1629`).
- [ ] Eliminate reload fallbacks by extending mutation coverage so no timeline reload is needed after drag.
  - Current state: `command_manager.execute` still prints “Timeline reload fallback...” whenever commands omit mutations (`src/lua/core/command_manager.lua:1588-1595`). Regression `tests/test_import_fcp7_xml.lua:400-520` documents Toggle/Nudge progress but Insert/Overwrite still hit the fallback. `ToggleClipEnabled` undo/redo now emits mutation buckets directly, so it no longer forces timeline reloads (`src/lua/core/command_implementations.lua:3360-3458`).
- [ ] Inventory every command that mutates the timeline but never sets `__timeline_mutations` (Insert, Overwrite, RippleEdit, importer-generated actions, etc.) and add test coverage proving each one keeps the cache hot before moving on to Phase 3.

## Phase 3: Occlusion Optimization
- [ ] Reuse timeline-state track indexes in `clip_mutator.resolve_occlusions` instead of querying SQLite per move (currently reloads every clip via SQL, see `src/lua/core/clip_mutator.lua:70-150`).
- [ ] Cache per-track neighbors so block moves only check immediate stationary clips (pending once timeline-state data is wired into `clip_mutator`).

## Phase 4: Undo/Redo Replay
- Stop clearing clips/media on undo; clone snapshot state into memory and diff/persist deltas.
- Limit replay to the affected sequence instead of wiping the project’s tables.

## Phase 5: Selection/Playhead Persistence
- Profile `capture_pre/post_selection` and `save_undo_position`; make JSON writes incremental.

## Phase 6: Long-term
- Consolidate block-move logic for insert/overwrite/ripple so all timeline commands reuse the same cache-friendly path.
- Add integration tests to lock in mutation behavior (no reload builds) for large timelines.
