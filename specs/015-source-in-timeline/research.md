# Phase 0 Research: Source-in-Timeline + Track-Header Redesign + Tristate Sync-Lock

**Feature**: 015-source-in-timeline
**Date**: 2026-05-03

This document records the existing-system probes performed before drafting the plan, with each decision and the alternatives considered.

---

## R1: Snapshot mechanism in `command_manager.lua`

**Question**: How does the existing command framework decide whether to create a `snapshots` row for a command?

**Probe**: `rg -n "snapshot|skip_clip_snapshot|skip_selection_snapshot|force_snapshot" src/lua/core/command_manager.lua`

**Findings**:
- Two opt-out flags exist on a command's `SPEC`: `skip_clip_snapshot` (skips the per-clip mutation snapshot at `command_manager.lua:1482`) and `skip_selection_snapshot` (skips the selection snapshot at `:1383, :1543`).
- A `force_snapshot` flag exists at `:1652` for the inverse case.
- These flags govern WHAT is captured in the snapshot, not WHETHER the command is undoable. Commands are undoable by virtue of having a registered `command_undoers[<name>]` entry (see `set_track_property.lua:85` for an example).

**Decision**: Add a NEW `undoable = false` SPEC flag that the command framework respects to (a) skip writing the `commands` table row that anchors undo, OR (b) write the row but mark it as not on the per-sequence undo stack. (Specific implementation detail deferred to /tasks; the contract is: `SPEC.undoable = false` ⇒ Cmd-Z does not revert the command and no `snapshots` row is created.)

**Rationale**:
- Adding a single flag is consistent with the existing `skip_clip_snapshot` / `skip_selection_snapshot` / `force_snapshot` flag family. (Constitution V — template-based consistency.)
- Avoids per-command bypass code that duplicates the existing dispatch logic.
- The 6 toggle commands (FR-040: patch on/off, patch drag-redirect, sync-mode, solo, mute, lock) all gain the flag; everything else is unaffected.

**Alternatives considered**:
- *Don't register undoers for non-undoable commands.* Rejected — this leaves the command in the `commands` table but with a missing undoer; any future undo walk that hits the row would fail without a clear error. (Constitution VI — fail-fast asserts.)
- *Split `SetTrackProperty` into two commands (one undoable, one not).* This is still a possibility for the FR-040a fix (see R2), but the framework-level `undoable = false` flag is needed regardless because patch and sync-mode commands are net-new.
- *Use a separate `non_undoable_commands` table.* Rejected — extra schema for a property that fits naturally on the command SPEC.

---

## R2: Existing solo/mute/lock command path (FR-040a bug)

**Question**: Where does the current solo/mute/lock toggle land, and why is it on the undo stack today?

**Probe**: `rg -ln "soloed|muted\b|locked" src/lua/core/commands/` → `set_track_property.lua` and `delete_sequence.lua`. Read `set_track_property.lua` in full.

**Findings**:
- `SetTrackProperty` at `src/lua/core/commands/set_track_property.lua` handles `muted`, `soloed`, `locked`, `enabled`, `volume`, `pan`.
- SPEC has `skip_clip_snapshot = true` (line 40) — correctly avoids the heavy per-clip snapshot.
- BUT `command_undoers["SetTrackProperty"]` is registered at line 85, and the executor opens `command:set_parameter("__skip_sequence_replay", true)` (line 78) but does NOT skip the `commands` table row creation. Result: the command IS recorded with `previous_value` and Cmd-Z reverts it via the registered undoer.
- This is the pre-existing bug Joe verified.

**Decision**: The fix for FR-040a is to mark the command as `undoable = false` per R1 when the property being set is `muted`, `soloed`, `locked`, or `enabled`. `volume` and `pan` keep their current undoable behavior (out of scope for this feature; if they should also be non-undoable, that's a separate clarification — for now they are unchanged).

Two implementation paths considered:
1. **Per-call dispatch**: SetTrackProperty's executor inspects `args.property` and reads from a static `NON_UNDOABLE_PROPERTIES` table. If present, the executor calls `command_manager` with `spec.undoable = false` at runtime. The framework respects the flag.
2. **Split into two commands**: introduce `ToggleTrackPreference` (handles muted/soloed/locked/enabled, `SPEC.undoable = false`) and keep `SetTrackProperty` for volume/pan only (still undoable). UI dispatches to the appropriate command based on which property.

**Recommended path**: Path 2 (split) — better aligns with rule 1.4 (single responsibility) and rule 2.21 (statically-verifiable: the flag is on the command spec, not a runtime decision). Also makes the regression test surface cleaner — `test_track_preference_non_undoable.lua` targets only `ToggleTrackPreference` and never produces a snapshot for any of its arguments.

**Alternatives considered**:
- Keep `SetTrackProperty` as-is and special-case in `command_manager`. Rejected — magic property-name coupling between `command_manager` and individual commands violates rule 1.10.

---

## R3: Tab system in `timeline_panel.lua`

**Question**: How are existing tabs managed, and how does the SourceTab fit?

**Probe**: `grep -n "open_tabs\|apply_tab_style\|update_tab_styles\|close_tab" src/lua/ui/timeline/timeline_panel.lua` — found at lines 392, 401, 467, 478, 481, 643, 676, etc.

**Findings**:
- `open_tabs` is a Lua table keyed by `sequence_id`. Each value contains `{button, close_button, sequence_id}`.
- `apply_tab_style(tab, is_active)` toggles between active/inactive styling.
- `update_tab_styles(active_sequence_id)` re-applies styling across all tabs based on which sequence is active.
- `close_tab(sequence_id)` removes a tab from the strip and from `tab_order` (the persisted list of open sequences).
- Active tab text color: `selection_color = #e64b3d` (line 73).

**Decision**: SourceTab is an annotation on the existing `open_tabs` system, not a parallel tab structure. A SourceTab is a normal tab whose `sequence_id` matches the source-monitor's loaded `master_seq_id`. `apply_tab_style()` is extended to consult the source monitor at style-application time and emit blue accent if its sequence is the loaded master, else red accent (the existing `selection_color`).

Specifically:
- Add a `tab_role` property derived at render time: `'source'` if the tab's `sequence_id` equals `panel_manager.get_sequence_monitor("source_monitor"):get_loaded_master_seq_id()`, else `'record'`.
- Active styling reads `tab_role` for the accent color.
- "Show Source Tab" command opens (or re-opens) the source monitor's loaded master in the tab strip via the existing tab-open path — single side-effect command.
- Closing the SourceTab via × removes the tab but does not unload the source monitor.

**Rationale**: matches rule 1.9 ("respect the architecture; don't bypass existing systems") and rule 1.4 (modular, single responsibility — the tab strip is one system, not two).

**Alternatives considered**:
- A separate `source_tab` field on `timeline_panel` distinct from `open_tabs`. Rejected — introduces a second tab manager with duplicate close/restore/style logic.

---

## R4: Source viewer integration

**Question**: How does the source monitor expose its loaded master sequence to other systems?

**Probe**: read `src/lua/ui/source_viewer.lua` in full. Confirmed `M.load_master_clip(master_seq_id, opts)` is the public entry; it routes through `panel_manager.get_sequence_monitor("source_monitor")` and `source:load_sequence(master_seq_id)`.

**Findings**:
- The loaded master is stored on the sequence_monitor instance, queryable via the panel_manager.
- No existing signal fires on master-load/unload.

**Decision**: Add a new signal `source_loaded_changed` emitted from `source_viewer.load_master_clip()` (and from a corresponding `unload`/`clear` path if one exists; if not, "unload" requires an addition). The SourceTab styling logic listens on this signal and re-renders.

**Rationale**: rule 3.0 (MVC) — views pull from the model on signal, not by polling.

**Alternatives considered**:
- Polling. Rejected per rule 3.0.
- Direct push from `source_viewer` into `timeline_panel`. Rejected — couples the source viewer to the timeline, violating rule 1.4.

---

## R5: Ripple pipeline dispatch hook

**Question**: Where in the existing ripple pipeline does the per-track sync_mode dispatch insert?

**Probe**: read `src/lua/core/ripple/batch/pipeline.lua` (38 lines, very tight) and the relevant section of `src/lua/core/commands/batch_ripple_edit.lua` (lines 440–500).

**Findings**:
- `pipeline.run(ctx, db, ops)` calls `prepare.snapshot_edge_infos`, `ops.build_clip_cache`, `ops.prime_neighbor_bounds_cache`, `ops.inject_implicit_gap_edges`, `ops.assign_edge_tracks`, `ops.determine_lead_edge`, `ops.analyze_selection`, `ops.compute_constraints`, `ops.process_edge_trims`, `ops.compute_downstream_shifts`, `ops.build_planned_mutations`, `ops.finalize_execution`.
- `inject_implicit_gap_edges(ctx)` is the existing point where ripple propagates to all tracks. Its docstring (`batch_ripple_edit.lua:488`) confirms it's the "implicit gap edge" injection that makes single-track ripple propagate without explicit linked selection.

**Decision**: Insert a NEW pipeline step `apply_per_track_sync_mode_dispatch(ctx)` BEFORE `ops.inject_implicit_gap_edges(ctx)` in `pipeline.run`. The new step:
- Walks `ctx.track_clip_map` (already built by `build_clip_cache`).
- For each track, reads `track.sync_mode` (default `'ripple'`).
- For `'off'` tracks: marks them excluded from the implicit-gap injection (so they ripple-pass-through unaffected).
- For `'cut'` tracks: identifies any clip spanning the trim point and inserts a split edge into the existing edge-list (same data structure `inject_implicit_gap_edges` uses). After the split, the downstream half participates in normal `'ripple'` propagation.
- For `'ripple'` tracks: no-op (existing behavior preserved).

**Rationale**: hook point is the smallest change that integrates with the existing pipeline at its single canonical multi-track propagation step. Rule 1.4 (modular, extend not replace).

**Alternatives considered**:
- Add the dispatch INSIDE `inject_implicit_gap_edges`. Rejected — that function already has a clear single responsibility ("propagate the ripple to other tracks"); adding mode dispatch inside it would mix concerns (rule 2.5).
- Add the dispatch in a new top-level command wrapping `BatchRippleEdit`. Rejected — adds a parallel command for a per-track concern.

---

## R6: PersistentWidget (rule 1.6) — the actual mechanism

**Question**: ENGINEERING.md rule 1.6 says "MANDATORY universal state persistence — all widgets inherit PersistentWidget." Is there a literal `PersistentWidget` class in JVE today?

**Probe**: `rg -ln "PersistentWidget" src/lua/` → no matches.

**Findings**:
- No literal `PersistentWidget` class. The "rule" describes an aspirational pattern: all widget state must persist somewhere.
- Existing concrete persistence:
  - **Project-scoped widget state** persists via the project DB (`sequences`, `tracks`, `sequence_track_layouts.track_heights_json`, `project_settings` JSON column).
  - **App-scoped (per-user) preferences** persist as JSON files in `~/.jve/`: `recent_projects.json`, `find_dialog_settings.json`, `find_replace_dialog_settings.json`, `file_browser_paths.json`, `last_project_path`, `keymaps/`, `probe_cache.json`.

**Decision**:
- Sequence-scoped state introduced by this feature (`patches`, `tracks.sync_mode`) persists in the project DB (forward-only schema migration FR-046).
- The per-user `source_routing_view` preference (FR-029c) and the source-tab open/closed state per project persist via:
  - `source_routing_view` → new `~/.jve/source_routing_view.json` (or a new `~/.jve/preferences.json` umbrella file).
  - SourceTab open/closed per project → extend `tab_order` persistence in `project_settings.open_sequence_ids` (existing) so the SourceTab's tab-strip presence is part of `tab_order` exactly like a Record tab.

**Rationale**: matches existing patterns; no new persistence frameworks introduced.

**Alternatives considered**:
- Build a literal `PersistentWidget` base class now. Rejected — out of scope for this feature; would be a cross-cutting refactor, rule 2.16 (no shortcuts) says do the right scope, not a side mission.
- Persist user prefs in the project DB. Rejected — they're per-user, not per-project. Would couple user prefs to whichever project they last opened.

---

## R7: Auto-create record track at edit time (FR-029b)

**Question**: How is a new track currently created in JVE, and can it be invoked from inside another command's transaction?

**Probe**: `ls src/lua/core/commands/ | grep track` → `add_track.lua`, `move_clip_to_track.lua`, `set_track_heights.lua`, `set_track_property.lua`. Read `add_track.lua`'s SPEC (header).

**Findings** (preliminary): `AddTrack` is an existing undoable command. It accepts `sequence_id`, `track_type`, `track_index` (or implicit append), and creates the track row.

**Decision**: FR-029b's auto-create-record-track step calls `AddTrack` from inside the same outer command's executor (the edit-trigger command, e.g. `Insert` or `Overwrite`). The outer command opens an undo group; the inner `AddTrack` call lands in the same undo group so the user's single Cmd-Z reverts both the edit and the track creation as one user-visible action.

**Rationale**: matches the existing pattern of nested command calls within an undo group (per CLAUDE.md memory `mutation_generation_semantics.md`: "mutation_generation = ONE BUMP PER USER ACTION").

**Alternatives considered**:
- Inline the track-creation SQL directly in the edit-trigger command. Rejected — bypasses the command framework, violates rule 1.10.
- Refuse the edit if the destination track doesn't exist. Rejected — Joe's clarification (Q2 / FR-029a) explicitly chose auto-create behavior.

---

## R8: Snapshot `clips_state` extension — REVISITED

**Question (FR-046.3 originally)**: Does `snapshots.clips_state` need to extend to capture `tracks.sync_mode` and `patches`?

**Decision**: **No.** Per Clarifications 2026-05-03 Q1 (and FR-040), all 6 toggle commands are non-snapshotting. They write directly to their target tables and produce no `snapshots` row. Therefore the snapshot mechanism does NOT need to extend. The schema migration (FR-046) is purely additive (new column + new table); the existing `snapshots.clips_state` JSON shape is unchanged.

**Rationale**: simplification follows directly from Q1's resolution. No undo means no snapshot extension.

**Alternatives considered**:
- Extend `clips_state` to a multi-table state blob anyway, "for future-proofing." Rejected — rule 2.16 (no shortcuts in the wrong direction; don't build infrastructure for hypothetical future features).

---

## R9: Performance characteristics — tab switch

**Question**: FR-007a requires perceived-instant tab switch (no observable storage round-trip). What's the existing tab-switch path's cost?

**Findings**: existing tab switch in `timeline_panel.lua` calls `load_sequence_into_timeline()` (or similar) which reads from in-memory `timeline_state` rather than the DB. Tab metadata (`open_tabs`, `tab_order`) is fully in-memory. Existing performance is already perceived-instant.

**Decision**: SourceTab's switch reuses the same in-memory path. The source monitor's loaded master is already in memory (loaded by `source_viewer.load_master_clip`); SourceTab simply pulls from that. No new I/O introduced.

**Rationale**: rule 3.0 (MVC pull-on-activation) is already the existing pattern.

---

## R10: Frame quantization function for Cut-branch splits

**Question**: FR-027 requires the Cut branch to reuse "the existing quantization handling for splits used by manual blade/split tools." Which function?

**Probe** (to be performed before T014/T033 fan out): `rg "frame_quantize|round_to_frame|snap_to_frame|quantize" src/lua/core/` and inspect existing blade/split commands (likely `src/lua/core/commands/split_clip.lua` or similar) for the canonical helper.

**Decision (to be filled at task start)**: TBD. Pin the function name and module path in this section before T014 / T033 begin so all parallel implementers reference the same function. If no canonical function exists today, that's a separate finding and warrants a clarification — DO NOT invent a new helper without surfacing.

**Rationale**: avoids two parallel implementers duplicating quantization logic with subtle differences.

---

## Summary

All NEEDS CLARIFICATION resolved at spec stage (Clarifications 2026-05-03). Phase 0 research surfaces no additional unknowns at the spec-coverage level; R10 documents a function-name lookup deferred to task start. Plan is consistent with the existing JVE architecture; the new entities (`patches` table, `tracks.sync_mode` column, `undoable = false` SPEC flag, SourceTab annotation) extend rather than replace existing systems.
