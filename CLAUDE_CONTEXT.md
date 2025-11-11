# Claude Context

## Timeline Track Heights (2025-10-14)
- Track header heights are now persisted per sequence in the new SQLite table `sequence_track_layouts` (JSON payload keyed by `track_id`). `timeline_state` writes to this table whenever a height changes and reloads it during `init`.
- The most recently edited sequence also updates `project_settings.track_height_template`. Fresh sequences that do not yet have a saved layout must adopt this template before they persist their own heights, guaranteeing consistent defaults across the project.
- The automated regression `tests/test_track_height_persistence.lua` exercises both behaviors (per-sequence persistence + template seeding) and should be extended whenever the timeline panel changes how it manages track headers.
- Template adoption now happens during `CreateSequence`: the command seeds the project’s most recent height template directly into the new sequence’s `sequence_track_layouts` row, so switching back to older sequences no longer re-applies the template mid-session.

## Timeline Reload Guard (2025-10-14)
- `timeline_state.reload_clips/2` now suppresses unsolicited sequence switches; it only calls `init` when the requested `sequence_id` matches the currently loaded timeline (or when `allow_sequence_switch` is explicitly passed).
- Rename commands/background batch operations can no longer steal timeline focus. Regression `tests/test_timeline_reload_guard.lua` verifies reloading `seq_b` while `seq_a` is active is a no-op, while reloading `seq_a` still succeeds.

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
