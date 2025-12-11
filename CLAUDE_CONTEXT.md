# Claude Context

## Timeline Track Heights (2025-10-14)
- Track header heights are now persisted per sequence in the new SQLite table `sequence_track_layouts` (JSON payload keyed by `track_id`). `timeline_state` writes to this table whenever a height changes and reloads it during `init`.
- The most recently edited sequence also updates `project_settings.track_height_template`. Fresh sequences that do not yet have a saved layout must adopt this template before they persist their own heights, guaranteeing consistent defaults across the project.
- The automated regression `tests/test_track_height_persistence.lua` exercises both behaviors (per-sequence persistence + template seeding) and should be extended whenever the timeline panel changes how it manages track headers.
- Template adoption now happens during `CreateSequence`: the command seeds the project’s most recent height template directly into the new sequence’s `sequence_track_layouts` row, so switching back to older sequences no longer re-applies the template mid-session.

## Timeline Reload Guard (2025-10-14)
- `timeline_state.reload_clips/2` now suppresses unsolicited sequence switches; it only calls `init` when the requested `sequence_id` matches the currently loaded timeline (or when `allow_sequence_switch` is explicitly passed).
- Rename commands/background batch operations can no longer steal timeline focus. Regression `tests/test_timeline_reload_guard.lua` verifies reloading `seq_b` while `seq_a` is active is a no-op, while reloading `seq_a` still succeeds.

## BatchRippleEdit Refactor & Test Hooks (2025-12-07)
- The BatchRippleEdit executor was decomposed into helper phases (`build_clip_cache`, `materialize_gap_edges`, `analyze_selection`, `compute_constraints`, `process_edge_trims`, `compute_downstream_shifts`, etc.) so the function now reads like an algorithm per engineering rules 2.26/2.27.
- Temporary comparisons against infinity now use symbolic gap source bounds defined in `ui_constants.TIMELINE` (`GAP_SOURCE_MIN_FRAMES`/`MAX`), replacing the previous ±1e15 literals in `create_temp_gap_clip`.
- Regression coverage lives in `tests/test_batch_ripple_regressions.lua` covering gap_before drags, gap roll behavior, forced constraint conflicts, partner clip rolls, retry clamping, and multi-track shift previews. The test suite creates small SQLite timelines via `build_manual_timeline` to control clip layouts.
- Two test-only command parameters are recognized by BatchRippleEdit to exercise otherwise hard-to-trigger paths: `__force_conflict_delta` forces the constraint solver to clamp the delta to zero, and `__force_retry_delta` drives the downstream-shift retry path by overriding the computed shift. These hooks are only set inside the new regression tests to avoid polluting real command behavior.
- Track shift calculation now distinguishes real clips from gap placeholders: clip tracks use the drag direction combined with their bracket orientation, while gap tracks continue to mirror the applied gap delta. This keeps opposing bracket clips moving in mirrored directions (per Rule 11) without regressing the gap drag scenarios covered by the asymmetric tests.
## Project Bin Commands (2025-10-14)
- `NewBin`/`DeleteBin` mark themselves with `__skip_sequence_replay`, and `command_manager.replay_events` now honors this by skipping those commands while rebuilding timeline state. This prevents bin mutations from being re-executed during undo/redo timeline replays (which previously failed because bin state isn’t part of the timeline database reset).
- Keeping the commands in the main undo tree preserves the user expectation that “Undo” reverts bin edits, without letting them corrupt timeline reconstruction.

## Default Tracks for New Sequences (2025-10-14)
- `CreateSequence` seeds three video (V1–V3) and three audio (A1–A3) tracks via the Track model immediately after persisting the sequence row, guaranteeing that an empty timeline still renders usable lanes.
- This behavior is covered by `tests/test_create_sequence_tracks.lua`, which fails if either media type is missing or miscounted.

## Outstanding Large Items
1. Persist per-sequence track heights – **implemented** (see above).
2. Relink command & dialog wiring – **not started** (still pending from plan).
3. Editing shortcuts (Top/Tail, Extend to Playhead) – **not started**.

## Tag-Backed Bins (2025-11-10)
- Project organization is now exclusively tag-driven. The `bin` namespace in `tag_namespaces/tags/tag_assignments` replaces the old `project_settings.bin_hierarchy` + `media_bin_map` blobs; any missing tag tables must hard-fail rather than silently falling back to settings JSON.
- `tag_service` and `database` helpers always use the tag tables and raise fatal errors if the schema is absent. UI tree views (Project Browser, importers, clipboard actions) must treat “bins” as a filtered view over tags instead of bespoke folders.
- Commands/importers assign master clips by calling `tag_service.assign_master_clips`, which writes to `tag_assignments`. Undo/redo of bin drags sticks to tag assignments as well.
- Tests that fabricate SQLite schemas must create `tag_namespaces`, `tags`, and `tag_assignments`; there is no backward compatibility layer for legacy DBs.

## Timeline Refactor Status (2025-11-11)
- Phase 1 is implemented: drag/nudge code now batches per-track move blocks and feeds occlusion trims into mutation buckets (`src/lua/core/command_implementations.lua:300-334` and `4172-4270`), while `command_manager.execute` applies those buckets directly to `timeline_state.apply_mutations` (`src/lua/core/command_manager.lua:1552-1595`).
- Instrumentation required by Phase 2 already exists via `profile_scope` around `timeline_state.apply_mutations`, `notify_listeners`, and `reload_clips` plus `command_manager.notify_listeners` (`src/lua/ui/timeline/timeline_state.lua:509-548,754-820,1607-1650`).
- Reload fallbacks still fire because commands like Insert/Overwrite/RippleEdit do not emit `__timeline_mutations`; `command_manager.lua:1588-1595` logs the fallback, and `tests/test_import_fcp7_xml.lua:400-520` shows only Nudge/Toggle currently exercise the mutation path.
- `clip_mutator.resolve_occlusions` still queries SQLite per invocation (`src/lua/core/clip_mutator.lua:70-210`), so Phase 3’s cache reuse work has not started.
- Commands that skip sequence replay (e.g., `ToggleClipEnabled`) now register manual undo/redo hooks that reapply their database changes and immediately flush timeline mutation buckets through `timeline_state.apply_mutations`, keeping the UI cache hot even when the command isn’t replayed (`src/lua/core/command_implementations.lua:3360-3458`, `src/lua/core/command_manager.lua:2835-3070`).
- Timeline commands that previously fell back to full reloads now emit explicit mutations: `RippleDeleteSelection` publishes delete/update payloads (and its undo flushes inserts), while `Cut` records deletes instead of forcing `timeline_state.reload_clips`. Regressions cover both behaviors via `tests/test_clipboard_timeline.lua`.
- RippleEdit now treats clamped-to-zero operations as no-ops: when the delta collapses to 0ms, the command flags itself with `__skip_timeline_reload`/`__skip_sequence_replay` so command_manager doesn’t hit the reload fallback. `tests/test_ripple_noop.lua` locks this behavior in place.

### Mutation Hydration (2025-11-12)
- Timeline state now hydrates missing clips on-demand instead of bailing out when mutation buckets reference clip IDs that aren’t currently cached. The database layer exposes `load_clip_entry`, and `timeline_state` injects the fetched clip into its cache before applying the update so the UI no longer falls back to a full reload when editing large timelines that were loaded via replay/import.
- Regression `tests/test_timeline_mutation_hydration.lua` exercises this path by removing a clip from `timeline_state` and verifying RippleEdit updates succeed without triggering the reload fallback. Use this test as the template when covering future mutation resiliency fixes.

## Overwrite Command Mutations (2025-11-13)
- `Overwrite` now captures occlusion metadata (trims/inserts/deletes) plus optional reused-clip snapshots before it modifies the database, and it persists those blobs into the command record (`src/lua/core/command_implementations.lua:2965-3125`).
- Undo skips sequence replay by default (`__skip_sequence_replay_on_undo`) and instead deletes the newly inserted clip, restores reuse targets from their stored snapshots, replays occlusion actions in reverse, and immediately flushes the accumulated mutation bucket to `timeline_state` (`src/lua/core/command_implementations.lua:3127-3185`).
- `revert_occlusion_actions` and `delete_clips_by_id` now emit insert/update/delete mutations as they manipulate the database so undo/redo receivers stay hot without falling back to `timeline_state.reload_clips` (`src/lua/core/command_implementations.lua:900-950`).
- Regression `tests/test_overwrite_mutations.lua` stubs `timeline_state` and asserts that Overwrite emits the correct mutation buckets on execute and undo, proving we no longer rely on brute-force reloads for that command.

## Timebase Migration Prep (2025-11-19)
- Working baseline branch: `pre-timebase-stable` (before RationalTime migration). New Lua regressions were cherry-picked: `tests/lua/test_batch_command_contract.lua`, `tests/lua/test_batch_ripple_timeline_state_overlap.lua`, and `tests/lua/test_clip_occlusion_current.lua`.
- Removed unused C++ event log layer (`include/jve/eventlog/*`, `src/eventlog/*`) and the SQLite path helper (`src/core/sqlite_env.*`) to keep “logic in Lua” and reduce unused native surface area. CMake no longer builds or links `JVEEventLog`; the only remaining native libs are Qt/SQLite/Lua.
- Dropped unused C++ test `tests/unit/test_project_browser_rename.cpp` and the old eventlog golden test wiring.
- Makefile now drives `cmake --build` with an explicit `-j$(JOBS)` (default 4) so `make -j4` actually fans out the underlying build instead of collapsing to `-j1` with jobserver warnings.
- Current build configuration runs the Lua test suite via `lua_tests` during `make`; C++ tests are built but not executed automatically. All Lua tests currently pass on this branch; undo bugs remain to be investigated separately.

## Ripple Handle Restoration (2025-12-05)
- Ripple and roll logic must treat every draggable edge as a bracket: `[` for leading edges and `]` for trailing edges. Names like `gap_before`/`gap_after` are UI hints but must be normalized before commands apply deltas.
- Gaps are first-class timeline items. BatchRippleEdit materializes temporary gap clips only for the edges participating in the current command so that the same `apply_edge_ripple` helper trims clips and gaps without bespoke branches.
- Dragging `[` to the right shrinks the owning item (clip or gap) and shifts downstream clips left by exactly the drag distance. Dragging `]` to the right grows the item and shifts downstream clips right by the drag distance unless the edit is a roll.
- Rolls (`][` selections) stay local: both brackets reuse the requested delta while `apply_edge_ripple` handles the opposing trim math, so one item lengthens, the other shrinks, and no downstream propagation occurs. This matches `docs/RIPPLE-ALGORITHM-RULES.md` and the pre-rational behavior baseline.
- The UI now records which edge the user actually drags (`lead_edge`) so BatchRippleEdit can determine the master delta sign. RippleEdit shares the same clamp/sign logic (gap handles behave like brackets), and the Lua tests enforce that single-edge and batch commands both close gaps when positive deltas move the `[`. 
- Timeline view renderer synthesizes pseudo clips for `temp_gap_*` edge ids (track/start/end embedded in the id) so selected gap handles render even when no real clip owns that boundary. Regression `tests/test_timeline_view_gap_edge_render.lua` covers both clip-referenced and temp-gap-referenced selections.
- Timeline hover cursors now use bracket glyphs that match Resolve’s edit handles: `trim_left` renders `]`, `trim_right` renders `[`, and `split_h` renders `][`. Each glyph is drawn procedurally inside `src/lua/qt_bindings/misc_bindings.cpp` as a ~20 px tall white bracket (2 px stem, arms extend 3 px horizontally but remain 2 px thick) surrounded by an outward 1 px black contour generated with `QPainterPathStroker`, so the white fill keeps its intended thickness.

## Timeline Edge Selection Regression (2025-12-06)
- Clicking a bracket that is already part of the edge selection must not clear or mutate `state.selected_edges` unless modifiers request it; the selection remains untouched and the click simply arms a drag.
- Shift clicks now share the Command toggle semantics so users can add/remove specific edges without touching other edges already in the selection set.
- Regression `tests/test_timeline_edge_clicks.lua` loads `timeline_view_input.handle_mouse` with a mocked state/edge picker and proves both behaviors (existing selections remain, Shift toggles) so future UI tweaks cannot regress this contract.
