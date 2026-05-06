# Tasks: Source-in-Timeline + Track-Header Redesign + Tristate Sync-Lock

**Feature**: 015-source-in-timeline
**Branch**: `015-source-in-timeline`
**Inputs**:
- [`plan.md`](./plan.md) (required) — tech context, structure, Phase 2 strategy
- [`research.md`](./research.md) — 9 research findings
- [`data-model.md`](./data-model.md) — entities, schema deltas, validation matrix
- [`contracts/command-specs.md`](./contracts/command-specs.md) — command SPECs C1–C9
- [`contracts/signals.md`](./contracts/signals.md) — signal contracts (`source_loaded_changed`, `source_tab_visibility_changed`, `displayed_tab_changed`, `active_sequence_changed`, `patch_changed`, `sync_mode_changed`, `track_preference_changed`, plus existing `track_mix_changed`)
- [`contracts/schema-migration.md`](./contracts/schema-migration.md) — SQL deltas
- [`quickstart.md`](./quickstart.md) — 17-step end-to-end script
- [`spec.md`](./spec.md) — FRs 001–048; Clarifications 2026-05-03

## Format: `[ID] [P?] Description`
- **[P]**: Can run in parallel — different files, no shared mutation, no upstream dependency in this phase.
- Each task lists exact file paths and the FRs / contracts it implements.
- Per ENGINEERING.md rule 2.20: every test task lands a FAILING test BEFORE the implementation task that makes it pass. Verify failure (run the test; observe red) before proceeding.
- Per rule 2.8: commit attribution `Authored-By: Joe Shapiro <joe@shapiro.net> With-Help-From: Claude`.

---

## Phase 3.1: Setup

- [ ] **T001** Verify branch `015-source-in-timeline` is checked out, working tree is clean (`git status` reports nothing other than what THIS task and downstream tasks add). If pre-existing untracked files exist that you don't recognize, STOP and ask Joe (per CLAUDE.md "REFACTOR SAFEGUARD" / parallel-Claude-session rule).

- [ ] **T002** Confirm `make -j4` is green on current `master` reference (so we can recognize a regression introduced by this feature vs a pre-existing failure). Capture the baseline test count to a scratch file `/tmp/015_baseline_test_count.txt`.

- [X] **T003** [P] ~~Decide the mechanism for the `undoable = false` SPEC flag~~ — **PRE-RESOLVED**: `command_manager.lua` already implements `spec.undoable == false` (search: `undoable == false` in command_manager.lua). No new flag needed. All downstream tasks use the existing flag as-is. No research.md update required.

---

## Phase 3.2: Tests First (TDD) — MUST COMPLETE BEFORE 3.3

**CRITICAL** (Constitution III): every test in this phase MUST be written and MUST FAIL before any implementation in 3.3 or later. Run each test, observe the failure (red), then proceed.

### Schema & migration tests

- [X] **T004** [P] Write schema migration test at `tests/test_schema_migration_015.lua` per `contracts/schema-migration.md` § "Migration test contract". Verify post-migration: `tracks.sync_mode` column exists with CHECK constraint, `patches` table exists with documented columns and CASCADE, `UNIQUE(sequence_id, source_track_index)` enforced, `record_track_index` may exceed track count, `snapshots` schema unchanged, `clip_links` schema unchanged, `schema_version` bumped, existing tracks have `sync_mode='ripple'` default. Run; verify FAIL.

### Command framework + bug-fix regression tests

- [X] **T005** [P] Write `undoable = false` flag smoke test at `tests/test_undoable_flag.lua`. Register a minimal test command with `SPEC.undoable = false`. Execute it. Assert: no `snapshots` row created for the command's sequence_number; per-sequence undo cursor not advanced; Cmd-Z (via `command_manager.undo()`) does NOT revert it. **Run; verify PASS** — the mechanism already exists in command_manager.lua. This is a characterization test to lock in the existing behavior before new commands depend on it.

- [X] **T006** [P] **FR-040a regression test** at `tests/test_track_preference_non_undoable.lua`. **THIS TEST MUST FAIL ON CURRENT CODEBASE — that is the proof the bug exists.** For each of `muted`, `soloed`, `locked`, `enabled`: invoke `SetTrackProperty` (current command), assert that `tracks.<property>` was updated, then assert NO `snapshots` row was created and `command_manager.undo()` does NOT revert. Today, the test will fail at the "no snapshots row" or "undo does not revert" step. Run; capture the failure output to `/tmp/015_t006_failure.txt`; commit the failing test before any fix.

### Command tests (per `contracts/command-specs.md`)

- [X] **T007** [P] Write `SetPatch` test at `tests/test_set_patch.lua` (C2). Cover: create-on-first-touch (no row exists → INSERT with identity defaults), update enabled, update record_track_index, both fields at once, UNIQUE constraint violation on duplicate (sequence_id, source_track_index), cross-track-type refusal (per FR-010a), no `snapshots` row, no undo revert, signal `patch_changed` emitted with correct payload, asserts fire on bad inputs (sequence_id missing, negative source_track_index) via `pcall`. Additionally (FR-035 intent-vs-silent-failure assertion): with source A1 patched to record A1 but `enabled=0`, perform an Insert that would otherwise route A1 content. The Insert MUST succeed (no error raised) AND record A1 MUST NOT receive A1 source content. Verify via SQL: no clip from source A1 is present on record A1 post-Insert. This proves the OFF-drop is the intended user-controlled exclusion (FR-029a, FR-035), distinct from a silent-failure mode where a routing mismatch silently drops content. Run; verify FAIL.

- [X] **T008** [P] Write `SetSyncMode` test at `tests/test_set_sync_mode.lua` (C3). Cover: each enum value (`'off'`, `'ripple'`, `'cut'`), invalid value triggers SQL CHECK error AND runtime assert (defense in depth), nonexistent track_id asserts, no snapshot, no undo revert, signal `sync_mode_changed` payload `(track_id, new, previous)`. Run; verify FAIL.

- [X] **T009** [P] Write `ToggleTrackPreference` test at `tests/test_toggle_track_preference.lua` (C4a). Cover: each property (`muted`, `soloed`, `locked`, `enabled`), boolean coercion, invalid property asserts, no snapshot, no undo revert, signal `track_preference_changed` payload. Run; verify FAIL.

- [X] **T010** [P] Write `SetTrackMixValue` test at `tests/test_set_track_mix_value.lua` (C4b). Cover: `volume` and `pan` numeric updates, undo IS supported (existing behavior preserved — Cmd-Z reverts), signal `track_mix_changed` still emitted. Run; verify FAIL.

- [X] **T011** [P] Write `ShowSourceTab` test at `tests/test_show_source_tab.lua` (C5). Cover: open with no source loaded (empty placeholder per FR-007b), open with source loaded (tab populated, blue accent), open while already-open (idempotent), close via `×` then re-open via command, signal `source_tab_visibility_changed` payload. Use `--test` mode per CLAUDE.md "Integration Testing with --test Mode". Run; verify FAIL.

### Ripple pipeline dispatch tests (per C7)

- [X] **T012** [P] Write Off-branch test at `tests/test_ripple_sync_off.lua` (FR-026 Off). Set up: 3-track sequence with sync_mode = `'off'` on track 2, `'ripple'` on the others. Ripple-trim a clip on track 1 by N=12 frames. Assert: track 2's track length unchanged, all clips on track 2 unchanged in absolute position. Assert: tracks 1 and 3 ripple normally. Run; verify FAIL.

- [X] **T013** [P] Write Ripple-branch test at `tests/test_ripple_sync_ripple.lua` (FR-026 Ripple). With all tracks `'ripple'` (default), confirm existing pipeline behavior is preserved post-feature: a ripple delta of N propagates uniformly. This test catches accidental regressions to the dispatch insertion. Run; verify FAIL on first run if the dispatch step is incorrectly inserting; otherwise verify it passes after T032 lands.

- [X] **T014** [P] Write Cut-branch test at `tests/test_ripple_sync_cut.lua` (FR-026 Cut, FR-027). Set up: a music clip spanning the trim point on track 4 (sync_mode `'cut'`); a dialog clip on track 1. Ripple-trim dialog by N=12 frames at the trim point that bisects the music clip. Assert: music split into two clips at the trim point; downstream half's `timeline_start` shifted by exactly N; no clip ends up shorter than one frame at sequence rate; gap between halves rendered via existing gap-clip mechanism (NO new "filler" entity); music's source-time content is contiguous across the split (the split-point's source frame on the upstream half = the split-point's source frame on the downstream half, modulo the standard JVE blade-tool quantization). Use non-trivial values (BWF non-zero TC origin recommended). Use the canonical frame-quantization function pinned in `research.md` R10 for computing expected split points (do NOT inline arithmetic — reference the same helper the implementation will use). Run; verify FAIL.

- [X] **T015** [P] Write auto-create-record-track test at `tests/test_auto_create_record_track.lua` (FR-029b, C6). Set up: 8-channel source loaded (master sequence with 9 tracks: V1 + A1–A8); active record sequence has only V1 + A1–A3. Toggle source A4–A8 buttons ON (their record_track_index defaults to identity 4–8, exceeding the record's count). Perform an Insert/Overwrite. Assert: post-edit, the active sequence has tracks V1 + A1–A8 (auto-created); the auto-created tracks have default `sync_mode='ripple'`, `muted=0`, `soloed=0`, `locked=0`. Press undo. Assert: edit reverts AND the auto-created tracks are removed in the same Cmd-Z (single undoable unit per FR-029b). Additionally (FR-021d — no audio-track-type enforcement): on a single auto-created audio track, place a mono clip, then a stereo clip, then a 5.1 clip in succession. Assert all three placements succeed with no validation error and no channel-count rejection. Run; verify FAIL.

### UI / integration tests (use `--test` mode per CLAUDE.md)

- [ ] **T016** [P] Write displayed-tab vs active-sequence pointer test at `tests/test_displayed_vs_active_pointer.lua` (FR-005, scenarios 11). Open project with one Record sequence; load a source; open SourceTab. Click SourceTab. Assert: `timeline_state.displayed_tab_id` changed to SourceTab's sequence_id; `timeline_state.active_sequence_id` UNCHANGED. Click the Record tab. Assert: BOTH pointers updated. Trigger an edit while SourceTab is displayed. Assert: edit lands on the active Record sequence, NOT on the source's master sequence. Run; verify FAIL.

- [ ] **T017** [P] Write track-header layout test at `tests/test_track_header_layout.lua` (FR-008–FR-021d). Verify cell order LTR matches: `src-id button | rec-patch-id button | label | lock cell | sync-mode cell | S/M stack`. Verify NO P button. Verify NO R button. Verify L cell is an SVG icon (not text "L"). Verify channel count appears inline on audio rows. Use `--test` mode. Run; verify FAIL.

- [ ] **T018** [P] Write patch on/off + plain-drag-redirect test at `tests/test_patch_toggle_and_drag.lua` (FR-010, FR-010a plain drag, FR-029a). Toggle source A1 OFF; verify `patches.enabled = 0`; verify edit drops the channel. Plain-drag source A2 onto record A4's row; verify `patches.record_track_index = 4`. Test cross-track-type drag refusal (audio source onto video record → explicit error). Use `--test` mode. Run; verify FAIL.

- [ ] **T019** [P] Write modifier-drag stacking test at `tests/test_modifier_drag_stack.lua` (FR-010a stacking, FR-029a stacking). Set up: source A1 patched to record A1. Modifier-drag (Option/Alt by default) source A2 onto record A1. Assert: TWO `patches` rows now have `record_track_index=1` (one for source_track_index=1, one for source_track_index=2). Assert: edit produces a multi-channel clip on record A1 with channel order matching source-track-index ascending. Verify cross-track-type refusal applies to modifier-drag too. Use `--test` mode. Run; verify FAIL.

- [ ] **T020** [P] Write view-toggle modifier test at `tests/test_view_toggle_modifier.lua` (FR-029c, FR-029d). With `source_routing_view='per_channel'`, hold Option/Alt while hovering over a source row. Assert: rendered representation collapses to one button. Assert: `patches` rows unchanged in DB. Release; assert re-expansion. Switch preference to `'per_clip'`; default-display is one button. Hold modifier; assert expansion to N buttons. Use `--test` mode. Run; verify FAIL.

- [X] **T021** [P] Write `source_routing_view` preference persistence test at `tests/test_source_routing_view_pref.lua` (FR-029c). Set preference to `'per_clip'`, restart app (or re-init pref subsystem), assert preference persists. Verify storage path matches the choice resolved in T040 (single-purpose vs umbrella). Run; verify FAIL.

### Signal contract tests (per `contracts/signals.md`)

- [X] **T022** [P] Write signal contract tests at `tests/test_signals_015.lua`. Cover `source_loaded_changed` (emitted on master load AND on master unload), `source_tab_visibility_changed` (open + close), `displayed_tab_changed` (NOT emitted on no-op same-tab click; emitted on Source ↔ Record), `active_sequence_changed` (NOT fired on Source-tab click — proves FR-005 pointer decoupling), `patch_changed` (created / updated / deleted), `sync_mode_changed` (NOT emitted on no-op set-to-current-value), `track_preference_changed` (4 properties), `track_mix_changed` continues from `SetTrackMixValue`. Run; verify FAIL.

### 3-point math test

- [X] **T023** [P] Write 3-point math + ghost mark test at `tests/test_three_point_math.lua` (FR-036, FR-037, FR-038). Set src IN, src OUT, rec IN; verify computed rec OUT shows as a dashed mark on the sequence ruler at the expected absolute TC. Verify the inspector / status bar labels it `(computed)`. Switch to SourceTab; verify source marks (IN, OUT) still visible. Switch back; verify rec mark + ghost still visible. Set rec OUT instead and clear rec IN; verify computed rec IN now appears. Use non-trivial TCs (e.g. 25fps source onto 23.976 record — verify the math accounts for rate difference if the existing 3-point math handles it; if not, mark the test for clarification). Run; verify FAIL.

### Quickstart integration test

- [X] **T024** [P] Skeleton at `tests/test_quickstart_015.lua` that mechanizes `quickstart.md` Steps 1–17 against `--test` mode JVEEditor. Each step's "Expected" outcome becomes a Lua assertion. Initially many assertions will FAIL because implementation is not done — that's expected; this becomes the integration-level red-green target. Run; verify FAIL on every step. Save fail output to `/tmp/015_t024_initial_failures.txt`.

---

## Phase 3.3: Core Implementation (ONLY after Phase 3.2 tests are FAILING)

### Schema first

- [ ] **T025** Apply schema migration to `src/lua/schema.sql` per `contracts/schema-migration.md` §1–§3:
   - ALTER `tracks` ADD COLUMN `sync_mode TEXT NOT NULL DEFAULT 'ripple' CHECK (sync_mode IN ('off','ripple','cut'))`.
   - CREATE TABLE `patches` per the documented columns + UNIQUE + CASCADE + index.
   - INSERT `schema_version` row with the next integer.
   No backward-compat code; old projects need DB reset (rule 2.15). After this lands, T004 (schema test) passes.

### Command framework extension

- [X] **T026** ~~Implement `undoable = false` SPEC flag~~ — **PRE-RESOLVED**: `command_manager.lua` already checks `spec.undoable == false` at the dispatch point. New commands (SetPatch, SetSyncMode, ToggleTrackPreference, ShowSourceTab, etc.) simply set `undoable = false` in their SPEC table and the framework handles it. No changes to command_manager.lua required for this flag.

### FR-040a bug fix (the failing T006 turns green here)

- [ ] **T027** Refactor `src/lua/core/commands/set_track_property.lua`: SPLIT into two new files per `contracts/command-specs.md` C4:
   - `src/lua/core/commands/toggle_track_preference.lua` — handles `muted`/`soloed`/`locked`/`enabled`. SPEC has `undoable = false`. Emits `track_preference_changed`. NO undoer registered.
   - `src/lua/core/commands/set_track_mix_value.lua` — handles `volume`/`pan`. Existing undoable behavior preserved. Continues emitting `track_mix_changed`.
   - DELETE the old `set_track_property.lua` (rule 2.15 — no shim, no rename redirect).
   Migrate all existing call sites that referenced `SetTrackProperty` to the appropriate new command (search via `rg "SetTrackProperty" src/`). After this lands, T006 (FR-040a regression) passes — verify by re-running it.

### Models

- [ ] **T028** [P] Create `src/lua/models/patch.lua` per `data-model.md` §1.1. Module exposes `Patch.create({sequence_id, source_track_index, ...})`, `Patch.load(id)`, `Patch.find_by_sequence(sequence_id)` returning all patches for a sequence ordered by `source_track_index`, `Patch.find_one(sequence_id, source_track_index)`, `Patch:save()`, `Patch:delete()`. Asserts on every read/write per FR-047.1. Function shapes match `src/lua/models/track.lua` style.

- [ ] **T029** [P] Extend `src/lua/models/track.lua` with `sync_mode` field accessor. Add the field to load/save SQL. Default to `'ripple'`. Validate enum membership at the model layer (`assert(sync_mode == 'off' or sync_mode == 'ripple' or sync_mode == 'cut', ...)` — defense in depth alongside SQL CHECK). Reading/writing matches existing column patterns in this file.

### Commands

- [ ] **T030** [P] Implement `src/lua/core/commands/set_patch.lua` per `contracts/command-specs.md` C2. Apply the documented asserts verbatim. After this lands, T007 passes.

- [ ] **T031** [P] Implement `src/lua/core/commands/set_sync_mode.lua` per C3. Asserts verbatim. After this lands, T008 passes.

- [X] **T032** [P] Implement `src/lua/core/commands/show_source_tab.lua` per C5. Reads source monitor's loaded master via `panel_manager.get_sequence_monitor("source_monitor")`. Opens the SourceTab in `timeline_panel.open_tabs`. Emits `source_tab_visibility_changed`.

- [X] **T032a** Wire `ShowSourceTab` into the menu system at the appropriate menu (Window or View). Register via `menus.xml` and the existing menu_system handler chain. Per CLAUDE.md ABSOLUTE PROHIBITIONS: NO command-specific logic in `menu_system.lua` — the menu dispatches via `gather_context` then invokes the command. After T032 + T032a land, T011 passes (test exercises both the command and the menu invocation path).

### Ripple pipeline extension

- [ ] **T033** Extend `src/lua/core/ripple/batch/pipeline.lua` and `src/lua/core/commands/batch_ripple_edit.lua` per `contracts/command-specs.md` C7. Insert new `apply_per_track_sync_mode_dispatch(ctx)` step BEFORE `ops.inject_implicit_gap_edges(ctx)`. Implement the three branches (off skip, ripple no-op, cut auto-split spanning clips into edge list). Add post-condition asserts per FR-026 (no clip on a `cut`-mode track ends up spanning the trim point, downstream `timeline_start` shifted by exactly delta, no produced clip < one frame). Before implementing the Cut branch's split synthesis, complete research R10 in `research.md` (pin the canonical frame-quantization function name and module path). The Cut branch MUST reuse that function verbatim — no new quantization helper. After R10 + T033 impl land, T012, T013, T014 pass.

### timeline_state pointers + tab system extension

- [X] **T034** Extend `src/lua/ui/timeline/timeline_state.lua` with `displayed_tab_id` and `active_sequence_id` as INDEPENDENT pointers per `data-model.md` §3. Add accessors. The existing notion of "active sequence" must be tied to `active_sequence_id`; existing call sites continue to work but now read from the renamed/clarified pointer. Wire signal emission: clicking a Record tab fires both `displayed_tab_changed` and `active_sequence_changed`; clicking the SourceTab fires only `displayed_tab_changed`. After this lands, T016 passes (and unblocks T024 partial pass).

- [X] **T035** Extend `src/lua/ui/timeline/timeline_panel.lua` tab-strip code (lines 392–680 area, the existing `open_tabs` / `apply_tab_style` / `update_tab_styles` / `close_tab` paths). Add SourceTab styling: any tab whose `sequence_id` matches `panel_manager.get_sequence_monitor("source_monitor"):get_loaded_master_seq_id()` renders with blue accent (`--src` color). All other tabs continue with the existing red accent (`--rec` = `selection_color = #e64b3d`). Listen on `source_loaded_changed` to re-evaluate styling when the source monitor's master changes. After this lands, the Source-tab-styling parts of T024 pass.

### Source viewer extension (signal emission)

- [X] **T036** Add `source_loaded_changed` emission to `src/lua/ui/source_viewer.lua`. After `source:load_sequence(master_seq_id)` completes, emit `Signals.emit("source_loaded_changed", new_master_seq_id, previous_master_seq_id)`. Add a new public `M.unload()` path that clears the source monitor and emits the signal with `nil` for the new master (FR-007b empty-placeholder support). After this lands, T022's `source_loaded_changed` portion passes.

### Track-header refactor

- [X] **T037** Refactor track-header rendering in `src/lua/ui/timeline/timeline_panel.lua` lines 1029–1296 per FR-008. New cell order LTR: `src-track-id button | rec-patch-id button | label | lock cell | sync-mode cell | S/M vertical stack`. REMOVE the existing P button (lines 1041–1043, 1219–1221). REMOVE the R button (line 1287–1289). Replace letter "L" with an inline SVG lock icon (matches `design examples/source_in_timeline_v4.html` icon shape; mockup is structure-authoritative per spec). Add the sync-mode cell (cycles via `SetSyncMode` command on click). Add the vertical S/M stack (each invokes `ToggleTrackPreference`). Add the inline channel-count label on audio rows (FR-021). Listen on `sync_mode_changed` and `track_preference_changed` to re-render when sync_mode or solo/mute/lock changes. After this lands, T017 passes (and many T024 assertions).

- [ ] **T037a** Video Mute/Solo compositor (FR-019, FR-020). Locate the existing video composite pass — likely in `src/lua/ui/sequence_monitor.lua`, `src/lua/core/playback_controller.lua`, or the C++ render path under `src/cpp/`. Modify the topmost-track-selection logic to consult `tracks.muted` (skip muted tracks; lower non-muted promotes to topmost candidate per FR-019) and `tracks.soloed` (when ≥1 track is soloed, only soloed-AND-not-muted tracks participate top-down per FR-020 additive-soloed-set). Listen on `track_preference_changed` so the composite refreshes when these toggle. Add `tests/test_video_mute_solo_compositor.lua` (use `--test` mode) that places content on V1+V2+V3 with overlapping clips and asserts: (a) muting topmost track promotes the next non-muted track; (b) soloing one track makes it the only contributor to the composite; (c) soloing two tracks produces the documented additive-set behavior (only soloed tracks contribute, topmost-wins among them). Run; verify FAIL before impl. After impl, the test passes.

### Patch UI

- [ ] **T038** Implement paired src/rec id buttons + on/off toggle in track headers (FR-009, FR-010, FR-029a). The src-id button reflects the patch's `enabled` state (filled-blue when ON, outline-dim when OFF) when the SourceTab is displayed. The rec-id button reflects the role color of the displayed tab. Click on the src-id button: invokes `SetPatch(sequence_id=active, source_track_index=this_row, enabled=not current)`. Listen on `patch_changed` to re-render. After this lands, T018 passes.

- [ ] **T039** Implement plain-drag and modifier-drag for source-id buttons (FR-010a). Plain-drag: `SetPatch(record_track_index=destination_row)`. Modifier-drag (Option/Alt by default; configurable): same as plain-drag (the action is identical at the data layer because UNIQUE(sequence_id, source_track_index) means stacking is just multiple patches with the same `record_track_index`). Cross-track-type drag refused with explicit error — the executor asserts the destination's `track_type` matches the source's. After this lands, T018 + T019 pass.

### Per-channel vs per-clip view + modifier toggle

- [ ] **T040** Implement `source_routing_view` preference (FR-029c) — single-purpose JSON file at `~/.jve/source_routing_view.json` (decision: single-purpose; matches surrounding pattern of `recent_projects.json`, `find_dialog_settings.json`, etc., per research R6 alternatives). Default = `'per_channel'`. Render the source row's track headers per the preference. After this lands, T021 passes.

- [ ] **T041** Implement view-toggle modifier (FR-029d). When the user holds Option/Alt over a source row, temporarily flip the rendered representation (per_channel ↔ per_clip). Underlying `patches` rows MUST NOT be touched. Listen for keyboard modifier events; on key-down, re-render in the opposite mode; on key-up, revert. After this lands, T020 passes.

- [ ] **T041a** PersistentWidget audit (FR-021c, ENGINEERING.md rule 1.6). For each new or modified UI widget in T035, T037, T038, T039, T040, T041, document in a scratch file `/tmp/015_persistence_audit.md`: (a) what state the widget owns; (b) the persistence mechanism it uses (project DB row, `~/.jve/` JSON, transient/no-persistence-needed); (c) for transient state, justify why it does not need to persist. Identify any state that needs persistence but isn't wired; surface as a follow-up sub-task or fix in-place. The audit's output joins the post-task commit message.

### Auto-create record track at edit time

- [ ] **T042** Extend the edit commands that consume patches (Insert, Overwrite, and the 3-point edit dispatch — locate via `rg "patches\|3-point\|3_point\|three_point" src/lua/core/commands/`). For each, before the mutation step: iterate enabled patches, ensure a `tracks` row exists at every referenced `record_track_index`, calling `AddTrack` (existing command at `src/lua/core/commands/add_track.lua`) within the same undo group. After this lands, T015 passes.

### SourceTab open/close persistence

- [ ] **T043** Wire SourceTab's `×` close affordance through the existing `close_tab(sequence_id)` path. Add the SourceTab's sequence_id to `project_settings.open_sequence_ids` so close/open state persists per project. Do NOT close the SourceTab automatically when source unloads; FR-007b says it persists with the empty-placeholder state.

### 3-point math + ghost mark

- [ ] **T044** Implement (or extend existing) 3-point math + ghost-mark rendering per FR-036–FR-038. Source marks live on the loaded master sequence; sequence marks live on the active sequence. Computed 4th mark renders as a dashed mark on the appropriate ruler. Inspector / status bar labels it `(computed)`. After this lands, T023 passes.

---

## Phase 3.4: Integration

- [ ] **T045** Verify all FR-047 assert sites are wired with offending-id-in-message. Walk the 8 sites listed in spec:
   1. Patch lookup (T030 — confirm).
   2. Sync_mode dispatch (T033 — confirm).
   3. SourceTab display (T035 — confirm).
   4. Displayed-tab switch (T034 — confirm).
   5. Patch command (T030 — confirm).
   6. Edit-time routing (T042 — confirm).
   7. 3-point math (T044 — confirm).
   8. Patch/sync-mode command execution non-snapshot path (T026 — confirm).
   For any site missing the assert: open the file and add it. Each assert message MUST include the function/module name and the offending id (rule 1.14).

- [ ] **T046** Run quickstart Steps 1–17 manually against `./build/bin/JVEEditor`. Capture screenshots of the SourceTab styling, paired-button rendering, sync-mode icon cycle, S/M stack, and the auto-create-track behavior. Any "Expected" outcome that does not match is a bug; file it and fix before proceeding.

- [ ] **T047** Re-run T024 (`tests/test_quickstart_015.lua`) — every step should now pass. Compare against `/tmp/015_t024_initial_failures.txt` to confirm the gap closed.

---

## Phase 3.5: Polish

- [ ] **T048** [P] Run `make -j4` from repo root. Zero luacheck warnings (rule 2.4). Zero failing Lua tests. Zero failing C++ tests. The full test count must be ≥ baseline from T002 + the new tests added in 3.2.

- [ ] **T049** [P] Audit the diff: re-read every changed file against ENGINEERING.md rules 1.14, 2.5, 2.13, 2.15, 2.20, 2.21, 2.32, 3.14 per CLAUDE.md "AUDIT AGAINST ENGINEERING.md AFTER EVERY REFACTOR" memory. Report rule → finding → fix for any violation.

- [ ] **T050** [P] Update CLAUDE.md (project-root) to document any new patterns this feature introduced (the `undoable = false` SPEC flag is the most likely candidate). Use one line per pattern. Don't bloat.

- [ ] **T051** Commit each completed task as its own git commit per rule 2.20. Use the attribution format from rule 2.8: `Authored-By: Joe Shapiro <joe@shapiro.net>` `With-Help-From: Claude`. Between commits, verify nothing else changed (parallel-Claude-session safety per CLAUDE.md "REFACTOR SAFEGUARD"). Do NOT push to remote until Joe explicitly says so.

---

## Dependencies

```
T001, T002 (setup baselines)
       ↓
T003 ✓ PRE-RESOLVED — T026 ✓ PRE-RESOLVED (undoable = false exists in command_manager.lua)
       ↓
T004–T024 (all tests written + verified failing) [most are [P]]
       ↓
T025 (schema migration — first impl task)
       ↓
T027 (FR-040a fix — turns T006 green; new commands use existing undoable = false flag)
       ↓
T028, T029 (models — depend on T025)
       ↓
T030, T031, T032 (commands — depend on T026 + T028/T029)
       ↓
T033 (ripple pipeline — depends on T029)
       ↓
T034, T035, T036 (timeline_state + tab system + source viewer signal)
       ↓
T037 (track-header refactor — depends on T034 for sync-mode + S/M wiring through commands T031, ToggleTrackPreference T027)
       ↓
T037a (video Mute/Solo compositor — depends on `track_preference_changed` emission in T037)
       ↓
T038, T039 (patch UI — depend on T030 + T037)
       ↓
T040, T041 (preference + view-toggle — depend on T037)
       ↓
T042 (auto-create — depends on T030 + AddTrack reuse)
       ↓
T043, T044 (SourceTab persistence + 3-point math)
       ↓
T045, T046, T047 (integration verification)
       ↓
T048, T049, T050 (polish)
       ↓
T051 (commits)
```

---

## Parallel execution examples

**T003 + T026 pre-resolved. Fire all of these in parallel — independent files, no shared mutation:**
```
Task: "Run T004 — write tests/test_schema_migration_015.lua per contracts/schema-migration.md § Migration test contract"
Task: "Run T005 — write tests/test_undoable_flag.lua per contracts/command-specs.md C1 (verify PASS — mechanism exists)"
Task: "Run T006 — write tests/test_track_preference_non_undoable.lua (FR-040a regression — MUST FAIL on current codebase)"
Task: "Run T007 — write tests/test_set_patch.lua per C2"
Task: "Run T008 — write tests/test_set_sync_mode.lua per C3"
Task: "Run T009 — write tests/test_toggle_track_preference.lua per C4a"
Task: "Run T010 — write tests/test_set_track_mix_value.lua per C4b"
Task: "Run T011 — write tests/test_show_source_tab.lua per C5 (uses --test mode)"
Task: "Run T012 — write tests/test_ripple_sync_off.lua (FR-026 Off branch)"
Task: "Run T013 — write tests/test_ripple_sync_ripple.lua (FR-026 Ripple branch)"
Task: "Run T014 — write tests/test_ripple_sync_cut.lua (FR-026 Cut branch)"
Task: "Run T015 — write tests/test_auto_create_record_track.lua (FR-029b)"
Task: "Run T016 — write tests/test_displayed_vs_active_pointer.lua (FR-005)"
Task: "Run T017 — write tests/test_track_header_layout.lua (FR-008–FR-021d, --test mode)"
Task: "Run T018 — write tests/test_patch_toggle_and_drag.lua (FR-010, FR-010a plain, --test mode)"
Task: "Run T019 — write tests/test_modifier_drag_stack.lua (FR-010a stacking, --test mode)"
Task: "Run T020 — write tests/test_view_toggle_modifier.lua (FR-029d, --test mode)"
Task: "Run T021 — write tests/test_source_routing_view_pref.lua (FR-029c)"
Task: "Run T022 — write tests/test_signals_015.lua covering all 8 new/modified signals"
Task: "Run T023 — write tests/test_three_point_math.lua (FR-036–FR-038)"
Task: "Run T024 — skeleton tests/test_quickstart_015.lua mechanizing quickstart Steps 1–17"
```

**After T025 lands** (T026 pre-resolved), fire models in parallel:
```
Task: "Run T028 — create src/lua/models/patch.lua per data-model.md §1.1"
Task: "Run T029 — extend src/lua/models/track.lua with sync_mode field"
```

**After T028/T029 land**, fire commands in parallel:
```
Task: "Run T030 — implement src/lua/core/commands/set_patch.lua per C2"
Task: "Run T031 — implement src/lua/core/commands/set_sync_mode.lua per C3"
Task: "Run T032 — implement src/lua/core/commands/show_source_tab.lua per C5"
```

T033 (pipeline) is sequential because it touches the shared pipeline file — do it alone.

T034–T036 modify shared UI files (timeline_state, timeline_panel, source_viewer); evaluate dependencies before parallelizing — `timeline_panel.lua` is touched by T035, T037, T038, T039, so those four are sequential against each other. T036 (source_viewer.lua) is independent and CAN run in parallel with the timeline_panel chain.

T048–T050 (polish) are file-independent and parallelizable.

---

## Validation gate

Before marking this feature complete:

- [ ] All 51 tasks marked done in this file.
- [ ] `make -j4` green (rule 2.4, 2.7).
- [ ] All 18 test files added in 3.2 are passing in 3.4.
- [ ] T006 was committed FAILING before T027, demonstrating rule 2.20 was followed.
- [ ] Quickstart manual run-through (T046) reports no failed step.
- [ ] FR-047 assert sites all confirmed wired (T045).
- [ ] ENGINEERING.md audit (T049) reports zero violations.
- [ ] `git log` shows clean attribution per rule 2.8.

---

## Notes

- **T006 is the most important commit ordering rule in this plan.** The failing FR-040a regression test MUST land first, observed-failing, BEFORE the T027 fix. Per rule 2.20: "ALWAYS add a failing regression test BEFORE fixing a bug; PROVE the test fails by temporarily reverting or disabling the fix; ONLY then land the fix."
- **`--test` mode** for UI-touching tests (T011, T017, T018, T019, T020, T024) per CLAUDE.md "Integration Testing with --test Mode". Save output to `/tmp/` files; don't pipe to grep directly.
- **No `make -j4` between every task** — per `feedback_targeted_tests_not_full_suite.md` memory, run targeted tests during iteration; only run the full suite at gate points (T002 baseline, T046 integration, T048 final).
- **Refactor safeguard** (CLAUDE.md): if `git status` shows uncommitted/untracked files you don't recognize during this task chain, STOP. They likely belong to a sibling Claude session.
- **No graphify** — per memory, this project uses `rg`/Read/Grep, not `/graphify`.
