# Test Migration Analysis (2026-05-30)

Joe directive: rewrite all violating tests as smokes that drive JVE through
real OS-level input. Read each test → list high-level actions → identify
behavior under test → design new smoke. Build all analyses BEFORE running
anything.

Compiled from 7 parallel Explore-agent passes covering 60 binding/integration
violators, 35 existing smokes, 8 `--test`-exception candidates, plus a UI
primitives gap analysis.

## Scope tally

- **60** files in `tests/binding/` + `tests/integration/` that violate the rule.
- **9** smokes in `tests/live/cases/` that still use `command_manager.execute`.
- **26** other existing smokes (rule-compliant — confirmed).
- **8** `--test`-mode exception candidates (KEEP all 8 — pure parser/decoder).

## UI primitives inventory (to build before writing new tests)

| Primitive | Layer | Status |
|---|---|---|
| `clip_screen_rect(clip_id)` → {x,y,w,h} | Lua `debug_helpers` | TODO |
| `get_timeline_view_widget()` → widget ref | Lua `debug_helpers` | TODO |
| `get_ruler_widget()` → widget ref | Lua `debug_helpers` | TODO |
| `media_count()` | Lua `debug_helpers` (needs `Media.count()`) | TODO |
| `playhead_position()` | Lua `debug_helpers` (read-only) | TODO |
| `clip_source_in(id)` / `clip_source_out(id)` | Lua `debug_helpers` | TODO |
| `clip_field(id, field)` (generic) | Lua `debug_helpers` | TODO |
| `track_lock_btn_rect(track_id)` | Lua `debug_helpers` | TODO |
| `runner.click_clip(clip_id, button=1)` | Python runner | TODO |
| `runner.right_click_clip(clip_id)` | Python runner | TODO |
| `runner.move_playhead_to(frame)` (via ruler click) | Python runner | TODO |
| `runner.menu_pick("File>Import>Resolve Project (.drp)...")` | Python runner | TODO |
| `runner.pick_file_in_open_dialog(path)` | Python runner | TODO |
| `runner.type_text(s)` | Python runner | TODO |
| `runner.wait_for(lua_predicate, timeout=5)` | Python runner | TODO |

CGEventPost from external Python (osascript) DOES reach QShortcuts —
confirmed in `input_bindings.cpp` header comment (only in-process posts
fail). No new C++ binding needed for the runner-side; existing
`qt_send_mouse_click` in `input_bindings.cpp:198` can drive Lua-side
synthetic clicks if needed.

---

## GROUP A — DRP / FCP7 / Premiere / DRT importer binding tests (15)

**Batch theme:** All exercise importer parser + import-into-project + (often)
undo/redo. Shared substrate: anamnesis-template project + File→Import
keyboard dispatch. Most can group into one `TestImportBehaviors` class
sharing the template project; `test_e2e_retime_relink` stands alone
(slow, 600+ media). Common primitives needed: `menu_pick("File > Import
> X")`, `pick_file_in_open_dialog(path)`, `wait_for(import-complete)`,
`media_count()`, `sequence_count()`. The `test_drp_marker_decode*` and
`test_drp_fields_blob_tabs` are parser-only and stay as `--test`
exceptions (Group H).

### tests/binding/test_drp_marker_import.lua
- **What it does**: parses `markers_16color_edge.drp`, imports into scratch DB, queries `clip_markers` table for all 16 Resolve colors + edge cases.
- **Behavior pinned**: per-clip markers survive DRP import with exact fidelity (color, position, duration, name, note, custom_data).
- **UI primitives**: `menu_pick("File>Import>Resolve Project (.drp)...")`, `pick_file_in_open_dialog`, `wait_for`, helper to query clip_markers rows.
- **Notes**: pair with `test_drp_marker_reimport_idempotent`. Share TestDRPMarkers class.

### tests/binding/test_drp_marker_reimport_idempotent.lua
- **What it does**: imports same DRP twice into one project; asserts marker count stable.
- **Behavior pinned**: reimporting deduplicates markers per-UUID; no doubling.
- **UI primitives**: same as above + `wait_for` for second import.
- **Notes**: chains after `test_drp_marker_import` in same class.

### tests/binding/test_drp_playhead_invariant.lua
- **What it does**: converts `sample_project.drp` → `.jvp`; for each sequence asserts `playhead_position >= start_timecode_frame`.
- **Behavior pinned**: DRP import never emits a sequence with playhead below TC origin (would crash C++ playback assert).
- **UI primitives**: `menu_pick("File>Open Project...")` (or Import), `pick_file_in_open_dialog`, helper `sequence_playhead_invariant_holds()`.
- **Notes**: trivial assertion; one method.

### tests/binding/test_drt_historical_clip_ignored.lua
- **What it does**: parses anamnesis-GOLD DRT with `<OriginalClip>` history blocks; asserts (1) Windows phantom path not in media table, (2) real media present, (3) clip carries `original_clip` metadata, (4) survives import_into_project.
- **Behavior pinned**: substitution history (relink fallback) preserved as clip metadata; historical Windows paths don't pollute media catalog.
- **UI primitives**: `menu_pick("File>Import>Resolve Timeline (.drt)...")`, helper to query media file_paths + clip metadata property rows.
- **Notes**: format is .drt not .drp. Separate import path.

### tests/binding/test_e2e_retime_relink.lua  (SLOW)
- **What it does**: opens anamnesis DRP→JVP, fetches two retimed clips, runs `media_relinker.relink_media_batch()` against 600+ files, applies RelinkClips, asserts source_in math, VFX Set Timecode overrides come online.
- **Behavior pinned**: large-scale relink planner + applier workflow doesn't assert/crash; source_in math survives.
- **UI primitives**: menu_pick for relink command, `wait_for` (long), helpers to query clip.source_in + media metadata for VFX overrides.
- **Notes**: keep standalone (~2 min runtime); not groupable.

### tests/binding/test_import_fcp7_negative_start.lua
- **What it does**: imports anamnesis FCP7 XML with sentinel negatives; asserts no clip has `sequence_start_frame < 0`.
- **Behavior pinned**: FCP7 importer strips out-of-bounds sentinels.
- **UI primitives**: `menu_pick("File>Import>FCP7 XML...")`, `pick_file_in_open_dialog`, helper `count_clips_with_negative_start()`.
- **Notes**: regression test; one method.

### tests/binding/test_import_fcp7_xml.lua
- **What it does** (HEAVIEST, ~710 LOC): FCP7 import → assert master sequences/bins/master clips created → MatchFrame on imported clips → Nudge + ToggleClipEnabled → command replay (delete+redo) → post-replay Insert/SplitClip/DeleteClip/Undo regressions.
- **Behavior pinned**: FCP7 import idempotent; undo/redo/replay reproduce exact row counts; post-import edits flow correctly.
- **UI primitives**: import primitives + `click_clip` + Nudge/D/Insert/Split/Delete keys + Cmd+Z/Shift+Z.
- **Notes**: SPLIT INTO TWO smokes: (A) import + nudge + undo/redo, (B) insert+split+delete regressions on imported sequence. Share TestImportFCP7 class.

### tests/binding/test_import_resolve_drp.lua
- **What it does**: opens fresh project via `blank_project.open_fresh()`; attempts ImportResolveProject; asserts it refuses (architectural gate — DRP import only into empty DB; otherwise use File>Open which converts).
- **Behavior pinned**: ImportResolveProject won't overwrite a non-empty project; only File>Open's convert path handles the initial DRP load.
- **UI primitives**: `menu_pick("File>Import>Resolve Project (.drp)...")` (expect error dialog), `wait_for` error toast/dialog, helper `last_command_error()`.
- **Notes**: tests refusal path. Pair with a positive `File>Open` smoke for the same DRP.

### tests/binding/test_import_resolve_timeline.lua
- **What it does**: bootstraps host project + host sequence; imports DRT (merges, doesn't create new project); asserts host preserved, sequences added; undo removes imports, redo restores.
- **Behavior pinned**: ImportResolveTimeline is a merge op; undo cleans imports preserving host.
- **UI primitives**: `menu_pick("File>Import>Resolve Timeline (.drt)...")`, `pick_file_in_open_dialog`, `sequence_count()`, Cmd+Z/Cmd+Shift+Z.
- **Notes**: shares anamnesis template with other DRT tests.

### tests/binding/test_import_redo_restores_sequence.lua
- **What it does**: import FCP7 → switch to imported seq → ToggleClipEnabled → undo twice (toggle, import) → assert focus restored → redo import → assert sequence counts match.
- **Behavior pinned**: redo after import-undo restores sequence; tab-strip doesn't focus stale ID.
- **UI primitives**: import primitives + tab-strip focus query, `click_clip`, D key, Cmd+Z×2, Cmd+Shift+Z.
- **Notes**: group with import undo/redo cohort.

### tests/binding/test_import_undo_removes_sequence.lua
- **What it does**: import FCP7 → undo → assert imported sequence + media removed.
- **Behavior pinned**: undo of import cleans entities.
- **UI primitives**: import + `sequence_count`, `media_count`, Cmd+Z.
- **Notes**: short, can merge into TestImportUndo class.

### tests/binding/test_import_undo_restores_sequence.lua
- **What it does**: import → switch to imported seq → undo → assert tab-strip refocused to pre-import seq.
- **Behavior pinned**: undo restores pre-import active sequence (no stale focus).
- **UI primitives**: import + tab-strip focus query.
- **Notes**: group with above.

### tests/binding/test_import_undo_skips_replay.lua
- **What it does**: import → switch → monkey-patch `command_manager.replay_events` → undo → assert replay NOT invoked.
- **Behavior pinned**: undo deletes entities directly without replay (optimization).
- **UI primitives**: needs replay-call instrumentation hook.
- **Notes**: implementation-detail test. MAYBE DELETE — the replay path is internal; the observable contract (entities removed) is covered by `test_import_undo_removes_sequence`. FLAG for Joe.

### tests/binding/test_import_view_state_redo.lua
- **What it does**: import → switch → set viewport/playhead → persist → undo → redo → assert DB viewport+playhead restored, not clobbered by stale cache.
- **Behavior pinned**: view state persists through undo/redo; UI cache doesn't overwrite DB on persist.
- **UI primitives**: import + scroll/zoom via keys (Cmd+=/-) + `move_playhead_to` + tab switch via grave/click.
- **Notes**: tricky state-machine test; standalone.

### tests/binding/test_prproj_import_e2e.lua
- **What it does**: opens anamnesis Premiere `.prproj` (614 media, 2881 clips); asserts project metadata, fps, dimensions, media count, clip count, TC origin metadata, track count meet thresholds.
- **Behavior pinned**: Premiere import pipeline survives without errors; counts pass lower bounds.
- **UI primitives**: `menu_pick("File>Open Project...")` (or Import>Premiere XML), `pick_file_in_open_dialog`, count helpers.
- **Notes**: e2e smoke. Pair with DRP e2e under TestImportE2E.

---

## GROUP B — binding remainder + numbered integration smokes 001–018 (16)

**Batch theme:** Split into (1) seeded-DB pure-model tests that should
STAY in Lua (no UI surface) and (2) command-driven tests that need
smoke rewriting. Numbered smokes 001/005/006/008/009/010/012/013/014/018
are mostly pure model/resolver/timing/codec checks — KEEP as Lua. Real
candidates for smoke rewrite from this batch: `test_track_lock_end_to_end`,
`test_imported_ripple`, `test_import_reuses_existing_media_by_path`,
`test_019_source_viewer_integration`. `test_015_track_header_layout` and
`test_relink_planner` are pure spec/unit — KEEP as Lua.

### tests/binding/test_015_track_header_layout.lua
- **What it does**: seeds project, launches UI via `ui_test_env`, queries `timeline_panel.get_track_header_layout_for_test`, asserts cell order matches spec.
- **Behavior pinned**: track-header cell layout (src_btn, rec_btn, label, lock, sync_mode, sm_stack); lock is SVG, not text "L".
- **UI primitives**: none (pure layout introspection).
- **Notes**: **KEEP as `--test` exception**. Layout assertions need Qt engine but no real input. Add to Group H.

### tests/binding/test_015_f_key_source_load.lua
- **What it does**: seeds record + 2 master sequences; F-key (via `source_viewer.load_master_clip` call) loads master into source tab; asserts displayed↔active separation, tab count, FK validity on master↔master swap.
- **Behavior pinned**: F-key displays source master without changing active tab or losing playhead; only one source tab in strip.
- **UI primitives**: timeline focus, F-key, debug-helpers for `displayed_tab_kind`, `active_sequence_id`, `tab_count`.
- **Notes**: smoke rewrite — drive F-key via keyboard not direct call.

### tests/binding/test_019_source_viewer_integration.lua
- **What it does**: load_master_clip→staged, load_clip→live_bound, ToggleTrimMode, SetMarkAndTrimIfClip→trim head, unload→neutral.
- **Behavior pinned**: source-viewer mode transitions (neutral↔staged↔live_bound), trim-edge dispatch in @source_monitor, effective_source post-trim.
- **UI primitives**: keyboard for Shift+F load, I/O for trim, key for trim-mode toggle, debug-helpers `source_viewer_mode`, `effective_source_in/out`.
- **Notes**: 019 covers integration of multiple modes; consider keeping as one large method that chains states.

### tests/binding/test_imported_ripple.lua
- **What it does**: import FCP7 → assert structure (contiguous tracks, no overlaps, no FK errors) → ripple-trim 3 clips → assert downstream shifted.
- **Behavior pinned**: importer produces structurally-sound timeline; ripple shifts downstream by delta.
- **UI primitives**: import primitives + `click_clip` + trim-edge click + bracket keys for trim.
- **Notes**: smoke rewrite. Chains after import.

### tests/binding/test_import_reuses_existing_media_by_path.lua
- **What it does**: pre-seed media at path; import FCP7 referencing same path; assert importer reused row, didn't create duplicate; undo doesn't delete pre-existing media.
- **Behavior pinned**: importer dedupes media by file_path; undo doesn't orphan pre-existing.
- **UI primitives**: need a "pre-seed media before import" entry point that goes through real UI — File>Import>Media on first media file, then File>Import>FCP7 XML. Helpers to verify media row identity (`media_id_for_path()`).
- **Notes**: smoke rewrite; needs Media import via menu.

### tests/binding/test_track_lock_end_to_end.lua
- **What it does**: launch UI, seed clip, toggle lock on V1, pump renderer (no crash), try Insert into locked → refuse, try SetClipProperty on locked → refuse, unlock, edit, re-lock, undo bypasses lock.
- **Behavior pinned**: lock persists, locked-track Insert/Edit refuse, renderer survives lock overlay, undo walks past lock for pre-lock edits.
- **UI primitives**: click track header lock icon, F9 (Insert), `click_clip` + D toggle for clip property, Cmd+Z; helpers `track_locked(id)`, `last_error_message()`.
- **Notes**: smoke rewrite; needs lock-button click coords (`track_lock_btn_rect`).

### tests/binding/test_relink_planner.lua
- **What it does**: 9 unit scenarios of `relink_planner.build_plan()` (path collisions, priority, split entries, transitive cascade, input validation).
- **Behavior pinned**: relink planner disambiguates correctly.
- **UI primitives**: none — pure function.
- **Notes**: **KEEP as `--test` exception**. Pure unit test; add to Group H.

### tests/integration/test_001_m1_foundation_smoke.lua
- **What it does**: seed project DB; detach + re-init; assert round-trip of project/sequence/tracks/media.
- **Behavior pinned**: FR-001 SQLite data model round-trips across close/reopen.
- **UI primitives**: none — pure model.
- **Notes**: **KEEP as `--test`** (model-only). Add to Group H. **Alternative**: rewrite as smoke that does File>New Project, then File>Close, then File>Open Recent → assert same data. Joe's call.

### tests/integration/test_005_gap_as_clip_smoke.lua
- **What it does**: seed sequence with two clips separated by gap; assert resolver returns clips, no clip_kind="gap" entry; fully-in-gap range yields nothing.
- **Behavior pinned**: gap-as-clip abstraction.
- **UI primitives**: none — pure resolver.
- **Notes**: **KEEP as `--test`**.

### tests/integration/test_006_per_sequence_undo_smoke.lua
- **What it does**: 2 sequences, execute commands on each, undo on one, assert other's stack untouched.
- **Behavior pinned**: per-sequence undo independence.
- **UI primitives**: command-stack semantics — could rewrite as: in seq A, do nudge; switch tab to seq B, do nudge; switch back to A, Cmd+Z → A nudge reverted, B unchanged.
- **Notes**: smoke rewrite possible but pure model also fine. **FLAG**: defer to Joe — pure model is faster, but smoke proves the integration.

### tests/integration/test_008_bounded_edit_region_smoke.lua
- **What it does**: TrimHead on small + big sequence; asserts big/small ratio < 100× (bounded edit, not O(N)).
- **Behavior pinned**: edit cost bounded.
- **UI primitives**: needs perf measurement — could click trim edge + drag, but timing precision requires programmatic measurement.
- **Notes**: **KEEP as `--test`** (timing test, not UX).

### tests/integration/test_009_drp_file_original_tc_smoke.lua
- **What it does**: seed media row with metadata JSON containing TWO TC fields; assert `Media:get_file_original_timecode()` and `:get_start_tc()` distinct.
- **Behavior pinned**: independence of `file_original_timecode` vs `start_tc_value`.
- **UI primitives**: none — pure model getter.
- **Notes**: **KEEP as `--test`**.

### tests/integration/test_010_no_active_sequence_smoke.lua
- **What it does**: fresh timeline_state → no displayed/active; seed project without `last_open_sequence_id`; assert Sequence.load doesn't auto-mount tab.
- **Behavior pinned**: no-active-sequence is first-class state.
- **UI primitives**: smoke rewrite would be File>New Project (which now sets last_open_sequence_id per project_templates fix) — hmm, contradicts. KEEP as `--test`.
- **Notes**: **KEEP as `--test`**.

### tests/integration/test_012_inspector_clip_smoke.lua
- **What it does**: seed clip, create `Inspectable.clip(...)`, assert schema_id/display_name/iter_fields wired.
- **Behavior pinned**: inspector clip adapter wiring.
- **UI primitives**: none.
- **Notes**: **KEEP as `--test`** (could rewrite to "click a clip → inspector shows name in header" but adapter wiring isn't directly visible).

### tests/integration/test_013_nested_placement_smoke.lua
- **What it does**: Insert master into record sequence; assert V+A clips created pointing at master; resolver chains clips→master→media_refs→file.
- **Behavior pinned**: Insert creates linked V+A pair referencing master; resolver follows chain.
- **UI primitives**: `click_clip` to select master in browser (TODO: browser primitives), F10 (Overwrite) or F9 (Insert), helpers for clip queries.
- **Notes**: smoke rewrite valuable; needs browser interaction. FLAG: browser primitives — selecting a master in the project_browser via real input. Defer or use F-press-to-load-master approach.

### tests/integration/test_014_two_phase_project_switch_smoke.lua
- **What it does**: 2 projects in separate DBs; signal sequencing for project_will_close/changed; stale project_id write rejected.
- **Behavior pinned**: project-switch signal order + DB FK guard.
- **UI primitives**: File>Open Project on second project; `wait_for` signal observation (needs `signal_log()` helper).
- **Notes**: smoke rewrite possible. Useful for cross-project contamination surface.

### tests/integration/test_018_t054_overwrite_audio_audible_smoke.lua
- **What it does**: heavy — fixture media; Overwrite creates audio clip; decode 0.5s audio via EMP; assert RMS > 0.001 (audible); compare to direct decode (<5% RMS delta).
- **Behavior pinned**: T054 regression — Overwrite produces audible audio with correct source_in math.
- **UI primitives**: needs EMP integration; not real UI input.
- **Notes**: **KEEP as `--test`** (audio codec integration).

---

## GROUP C — integration A–M (13)

**Batch theme:** Real-world editing workflows: transport routing, marks,
navigation, match-frame, media offline status, peak cache. Most need
smoke rewrite. Recurring primitives: `move_playhead_to`,
`switch_to_source/record_tab` (via grave key), `click_clip`,
`focus_panel`, `wait_for(signal)`. No deletion candidates. Grouping:
GoTo* tests cluster (3); MatchFrame tests cluster (2); mark routing
standalone (1).

### tests/integration/test_browser_activation_routes_through_commands.lua
- **What it does**: project + 2 sequences + master; OpenSequenceInSourceMonitor → source_monitor.sequence_id flips; OpenSequenceInTimeline → timeline_state targets new + focus shifts; undo no-op.
- **Behavior pinned**: browser activation atomically switches view + focus; non-undoable.
- **UI primitives**: double-click sequence in project_browser → opens in timeline; right-click → "Open in Source"; `displayed_sequence_id` query.
- **Notes**: needs browser interaction primitives (double-click row in browser).

### tests/integration/test_editor_operations.lua
- **What it does**: opens anamnesis gold; runs 7-10 tests: roll V1, roll A3, ripple V1, gap-boundary roll, undo/redo, split clip, toggle enabled, nudge, large audio roll.
- **Behavior pinned**: roll/ripple preserve invariants; undo restores exact state; audio sample-unit conversions correct.
- **UI primitives**: import, `click_clip`, `click_edge`, bracket trim keys, comma/period nudge, B for blade, D for enable, Cmd+Z.
- **Notes**: SPLIT into ~4 smokes: roll, ripple, undo/redo, split/nudge.

### tests/integration/test_floating_window_key_isolation.lua
- **What it does**: launch UI; floating text-input field; j/k/l/Delete/Backspace/Cmd+A/C/V/X/Z must NOT dispatch timeline commands; Cmd+S MUST dispatch (global); non-text floating window → keys dispatch via stale focused_panel; Tab in main timeline → ToggleTimecodeFocus.
- **Behavior pinned**: floating-window key isolation; text-editing keys pass through; display-only windows transparent.
- **UI primitives**: open floating window (which one? presumably history/find/inspector floating mode); switch focus into a QLineEdit inside it; type keys; observe dispatch.
- **Notes**: tricky — needs floating-window helper. **FLAG**: not all floating windows exist as user-visible workflows; may need to KEEP `--test` for isolation guarantees.

### tests/integration/test_go_to_next_prev_edit.lua
- **What it does**: sequence with 2 clips + gap; park at 11 positions; Next/Prev → assert correct edit point; TC-origin sequence → Prev floors at start.
- **Behavior pinned**: GoToNextEdit/GoToPrevEdit traversal; Prev doesn't go below sequence start.
- **UI primitives**: `move_playhead_to`, Up/Down arrow keys (or whatever GoToNextEdit binds to — Up=GoToPrevEdit, Down=GoToNextEdit per dispatch log), `playhead_position` helper.
- **Notes**: GROUP with `test_go_to_edit_surfaces_playhead` + `test_timeline_edit_navigation` into TestGoToEdits.

### tests/integration/test_go_to_edit_surfaces_playhead.lua
- **What it does**: sequence with viewport [0,500); clips at 0-100 and 5000-5150 (gap 100-5000); GoTo* off-screen → assert viewport scrolled to contain new playhead.
- **Behavior pinned**: GoTo* emits playhead_changed, persists, AND surfaces off-screen playhead via viewport scroll.
- **UI primitives**: same as above + `viewport_start_frame()`, `viewport_duration_frames()` helpers.
- **Notes**: groups with above.

### tests/integration/test_keyboard_qshortcut_integration.lua
- **What it does**: launch UI; validate >50 QShortcuts registered; dispatch Shift+Z via registry; Escape/Right/F10 passthrough to Lua residual; Tab in timeline dispatches ToggleTimecodeFocus, Tab in project_browser doesn't; text-input bypass.
- **Behavior pinned**: QShortcut/residual key routing.
- **UI primitives**: Shift+Z, Escape, arrows, F10, Tab in different panel focuses; `last_dispatched_command()` helper or signal listener.
- **Notes**: meta test like `test_keymap_dispatch_no_crash`. Could merge.

### tests/integration/test_mark_routing.lua
- **What it does**: real transport; source engine at 42, record at 10; focus source_monitor + SetMark "in" → masterclip mark_in=42; undo; focus timeline + SetMark "in" → timeline mark_in=10.
- **Behavior pinned**: SetMark writes to focused-side sequence (transport.engine_for_target routing).
- **UI primitives**: `move_playhead_to` (per engine), `focus_panel("source_monitor")`/`focus_panel("timeline_monitor")`, I key, Cmd+Z, `seq_mark_in(seq_id)`.
- **Notes**: solid candidate.

### tests/integration/test_master_nonzero_tc_audio.lua
- **What it does**: patches BWF time_reference to non-zero TC; probes; builds master with dual TC; queries `seq:get_audio_at()` and `:get_audio_in_range()` → assert non-empty + source_in samples correct.
- **Behavior pinned**: masters with non-zero audio TC origins resolve audio entries correctly.
- **UI primitives**: needs fixture patching (file I/O) + EMP probe → not user-visible.
- **Notes**: **KEEP as `--test`** (codec/resolver test, no UI surface).

### tests/integration/test_match_frame.lua
- **What it does**: 12 scenarios for MatchFrame (F-key): gap → error; clip alone → load master; multi-clip → topmost wins; selection overrides; load_master_clip throws → error surfaces; video trumps audio; selected audio overrides; master marks/playhead derived from clip source range.
- **Behavior pinned**: MatchFrame resolution rules.
- **UI primitives**: `move_playhead_to`, `click_clip` (for selection), F key, helpers `source_monitor_seq_id`, `seq_mark_in/out`, `seq_playhead`.
- **Notes**: hefty — 12 methods. Group as TestMatchFrame.

### tests/integration/test_match_frame_partial_and_offline.lua
- **What it does**: 3 scenarios: partial-coverage master + clip out-of-range → clamped no crash; stale /Volumes path with offline_note → no failure; missing media + no note → viewer loads (offline overlay).
- **Behavior pinned**: MatchFrame degrades gracefully on partial/offline media.
- **UI primitives**: requires offline-file simulation (file removal/rename in fixture).
- **Notes**: groups with above.

### tests/integration/test_media_status_bg_probe.lua
- **What it does**: seed media (existing + moved); pre-seed cache claiming online; start background probe → wait for `media_status_changed` on moved → asserts flipped to offline; Scenario B: no-change probe → 0 schedule_persist calls.
- **Behavior pinned**: bg probe re-validates cache; no-change batches don't write.
- **UI primitives**: file fixture manipulation + signal listener (`wait_for_signal("media_status_changed")` helper); persist-call counter (introspection).
- **Notes**: smoke rewrite hard; persist-call counter needs hook. **FLAG**: maybe KEEP `--test`.

### tests/integration/test_move_clip_offline_repro.lua
- **What it does**: clip on V1 referencing offline media; live timeline cache reflects offline=true; MoveClipToTrack V1→V2 → asserts cache offline survived; ensure_clip_status → survives; delete+undo → still offline.
- **Behavior pinned**: cross-track moves and undo-restore preserve offline denormalization.
- **UI primitives**: `click_clip`, drag-clip-to-track (mouse drag — not yet supported), Delete key, Cmd+Z.
- **Notes**: needs mouse-drag primitive (`drag_clip(clip_id, target_track_y)`). Complex.

### tests/integration/test_peak_cache_coverage_regen.lua
- **What it does**: generates complete peaks for WAV; surgically truncates on-disk peak file's bin count; `peak_cache._try_load_existing_for_test()` → false (rejection); file deleted; complete file → loads.
- **Behavior pinned**: peak cache rejects insufficient-coverage files; deleted triggers regen.
- **UI primitives**: file I/O for peak header surgery; not user-visible.
- **Notes**: **KEEP as `--test`** (codec/peak-file internals).

---

## GROUP D — integration P–S (14)

**Batch theme:** Source viewer + monitor, source/record tab, relink,
playback routing, source_viewer marks. Most are wiring tests that go
through `source_viewer.load_master_clip`/`load_clip` — smoke rewrites
should use Shift+F (load clip into source viewer) and F (match-frame).
Recurring primitives: tab switch via grave, source-tab visibility query,
clip source_in/out queries.

### tests/integration/test_playback_routes_to_displayed_tab.lua
- **What it does**: init record/source pair + real transport; switch to source tab → `transport.engine_for_target()` = source; switch to record → record.
- **Behavior pinned**: Space (play) routes to source engine when source tab displayed (TSO 2026-05-13).
- **UI primitives**: grave key for tab toggle (or click tab), `transport_target()` helper.
- **Notes**: straightforward.

### tests/integration/test_relink_invalidates_peaks.lua
- **What it does**: clip with offline media → relink to WAV → peak gen fires (1) → reopen → load from disk (0) → relink byte-identical → reuse (0) → relink to tone WAV → regen (1) → reopen tone peaks.
- **Behavior pinned**: peak cache doesn't spuriously regen on relink if mtime unchanged; invalidates only on content change.
- **UI primitives**: relink command (Media>Relink menu?), `wait_for(peak_status == "ready")`, `peak_gen_count()` helper.
- **Notes**: needs relink-via-UI flow (Media menu).

### tests/integration/test_relink_trimmed_media.lua
- **What it does**: clip pointing at untrimmed MOV; relink to trimmed version (same TC range); assert clip.source_in/out unchanged (TC absolute); undo/redo cycles.
- **Behavior pinned**: relink to trimmed media preserves absolute TC; undo/redo round-trips path+TC atomically.
- **UI primitives**: relink-via-UI, `clip_source_in`, `clip_media_path`, Cmd+Z/Shift+Z.
- **Notes**: groups with above.

### tests/integration/test_relink_tc_resync.lua
- **What it does**: probe MOV; seed media with old TC; `Media.batch_set_file_paths()` with new probed TC; assert metadata reflects new + unrelated fields preserved; `batch_restore_file_state()` undoes.
- **Behavior pinned**: media row TC metadata resyncs atomically on relink; undo restores exactly.
- **UI primitives**: not directly UI — model-layer batch API.
- **Notes**: **KEEP as `--test`** (low-level metadata test) OR rewrite via relink-UI if the same path is exercised.

### tests/integration/test_set_mark_and_trim_if_clip_routes_to_trim.lua
- **What it does**: load clip into source viewer (live-bound); press I → trims clip.source_in; press O → trims source_out; press SetMark (plain) → writes sequence mark; collapse press (IN >= OUT) → no-op + log.
- **Behavior pinned**: live-bound I/O presses trim clip; plain SetMark writes timeline; collapse rejected.
- **UI primitives**: Shift+F to load clip into source viewer, `focus_panel("source_monitor")`, I/O keys, `move_playhead_to`, helpers `clip_source_in/out`, `seq_mark_in/out`.
- **Notes**: high-value test; pairs with existing `test_keymap_i_sets_mark_in`.

### tests/integration/test_show_source_tab.lua
- **What it does**: set source loaded → ShowSourceTab → strip displays source; not loaded → strip blank, no signal, no auto-seed; non-undoable; unregistered monitor → fail.
- **Behavior pinned**: ShowSourceTab only shows if source loaded; blanks otherwise; non-undoable.
- **UI primitives**: Shift+F to load (sets source), grave to toggle tab, `displayed_tab_kind`, signal observation for `source_tab_visibility_changed`.
- **Notes**: combine with below.

### tests/integration/test_show_source_tab_empty_blanks_body.lua
- **What it does**: rec displayed with one clip + bait master in DB; source empty; ShowSourceTab → body blanks, no auto-seed; ToggleSourceRecordTab same.
- **Behavior pinned**: empty source ShowSourceTab/ToggleSourceRecordTab blank body, never auto-seed (TSO 2026-05-17).
- **UI primitives**: grave key (toggles tab), `displayed_clips_count`.
- **Notes**: pairs with above.

### tests/integration/test_source_tab_rekey_no_orphan.lua
- **What it does**: load master_A → tabs = {R, A}; emit source_loaded_changed(B, A) → tabs = {R, B}; emit (nil, B) → tabs = {R}.
- **Behavior pinned**: source-tab rekey doesn't leave orphan tabs.
- **UI primitives**: Shift+F load A; Shift+F load B; close source via... (Cmd+W? Or unload key?); `open_tab_ids()` helper.
- **Notes**: needs unload primitive — check keybind.

### tests/integration/test_source_tab_and_viewer_set_transport_target.lua
- **What it does**: default target = record; switch_to_source_tab → target = source; switch back → record; load_master_clip → focus source + target = source; record engine independent.
- **Behavior pinned**: source tab display + source_viewer load set transport target to "source"; source engine binds to loaded master.
- **UI primitives**: grave key, Shift+F to load master, `transport_target()`, `source_engine_loaded_sequence_id()`.
- **Notes**: solid.

### tests/integration/test_source_viewer_load_clip.lua
- **What it does**: load_clip → mode=live_bound; source_mon.seq=clip's source master; selection_hub publishes item_type=clip+owner_seq_id; master.playhead = clip.source_in (clamped); rename clip → reload + retitle; delete clip → auto-unload + emit signal.
- **Behavior pinned**: load_clip enters live-bound, binds monitor to source seq, publishes clip-typed selection, parks playhead with clamp, reloads on owner changes, auto-unloads on delete.
- **UI primitives**: Shift+F, rename via F2 or inspector, Delete, signal observation, helpers `source_viewer_mode`, `selection_item_type`, `selection_clip_id`, `selection_owner_seq_id`.
- **Notes**: hefty; needs rename primitive (F2 on inspector name field).

### tests/integration/test_source_viewer_publishes_selection.lua
- **What it does**: load_master → publish timeline item; unload → cleared; load first then second → replaces; load_clip → publishes clip-typed.
- **Behavior pinned**: staged load publishes timeline item; live-bound publishes clip item with owner.
- **UI primitives**: Shift+F variants, unload, selection_hub query.
- **Notes**: groups with above.

### tests/integration/test_source_viewer_signal.lua
- **What it does**: load A → signal (A, nil); load B → signal (B, A); reload B → (B, B); unload → (nil, B); double unload → no signal; nil arg asserts.
- **Behavior pinned**: source_loaded_changed fires on all changes; nil arg asserts.
- **UI primitives**: Shift+F variants, signal listener.
- **Notes**: groups with above as TestSourceViewerLoadSignals.

### tests/integration/test_timeline_edit_navigation.lua
- **What it does**: 2-track 4-clip timeline; park at gap → GoToPrevEdit → 2400 (V2 clip_c end, multi-track); park at 3200 (inside V1 clip_b) → GoToNextEdit → 4500 (clip end); park at end → GoToNextEdit → no past-end.
- **Behavior pinned**: GoTo* walks multi-track edits; respects timeline bounds.
- **UI primitives**: groups with `test_go_to_next_prev_edit` + `test_go_to_edit_surfaces_playhead` as TestGoToEdits.
- **Notes**: same primitives.

### tests/integration/test_tmb_mute_exclusion.lua
- **What it does**: TMB with enabled clip → RMS>0; TMB with gap → nil; sequence model `get_audio_in_range` excludes disabled clips.
- **Behavior pinned**: TMB + Sequence model exclude disabled clips from audio.
- **UI primitives**: not UI — TMB internals + Sequence model.
- **Notes**: **KEEP as `--test`** (codec test).

---

## GROUP E — existing 35 smokes (audit)

**Audit summary**: 7 fully compliant. 28 violate (mostly setup-time
`command_manager.execute('SelectClips'|'SetPlayhead'|'SetMarkIn'|...)`).
The new primitive `click_clip` removes ~15 of the violations; `move_playhead_to`
removes ~12; canonical I/O-press setup helpers remove the rest. A few
edge cases: tests where the violated call IS the command under test
(`test_playhead_below_start_clamps`, `test_roll_in_edge_at_start_boundary_clamps`,
`test_keymap_undo_redo`'s D-press, `test_move_playhead_syncs_engine`) need
discussion — rule technically forbids it; spirit allows it.

### tests/live/cases/test_arrow_left_at_start_boundary_clamps.py
- **Compliance**: VIOLATES — `SetPlayhead` setup.
- **Exercise**: Left arrow at sequence start clamps playhead.
- **Migration**: replace SetPlayhead with `move_playhead_to(start)`.

### tests/live/cases/test_extend_edit_at_start_boundary.py
- **Compliance**: VIOLATES — `SelectEdges` + `SetPlayhead`.
- **Exercise**: ExtendEdit (E) at sequence floor.
- **Migration**: `click_edge(clip, "in")` + `move_playhead_to`.
- **Notes**: currently `@expectedFailure` — ExtendEdit silently no-ops.

### tests/live/cases/test_goto_mark_uses_live_clip_in_out.py
- **Compliance**: VIOLATES — direct `s.mark_in = ...` Lua mutation + `GoToMark` execute.
- **Exercise**: GoToMarkIn/Out read live-bound clip source_in/out, not master marks.
- **Migration**: I/O presses to set marks (canonical), Shift+I/Shift+O for GoTo (already keys).

### tests/live/cases/test_keymap_alt_i_o_x_clear_marks.py
- **Compliance**: VIOLATES — `SetMarkIn`/`SetMarkOut` setup.
- **Migration**: I/O keypress at chosen playhead positions.

### tests/live/cases/test_keymap_cmd_1234_select_panel.py
- **Compliance**: ✅ COMPLIANT.

### tests/live/cases/test_keymap_cmd_a_shift_a_selection.py
- **Compliance**: VIOLATES (minor) — `timeline_state.switch_to_record_tab` eval in setUp.
- **Migration**: grave keypress instead (or accept ensure-tab helper as canonical setUp infrastructure).

### tests/live/cases/test_keymap_cmd_b_blades_at_playhead.py
- **Compliance**: VIOLATES — `_deselect_all`, `_select_only`, `SetPlayhead`.
- **Migration**: Cmd+Shift+A for deselect-all; `click_clip` for single-select; `move_playhead_to`.
- **Notes**: 4 scenarios. Already FAILS in shared-state run (Task #9).

### tests/live/cases/test_keymap_cmd_shift_bracket_trim_head_tail.py
- **Compliance**: VIOLATES — `SelectClips` + `SetPlayhead`.
- **Migration**: `click_clip`, `move_playhead_to`.

### tests/live/cases/test_keymap_d_toggles_clip_enabled.py
- **Compliance**: VIOLATES — `SelectClips`.
- **Migration**: `click_clip`.

### tests/live/cases/test_keymap_delete_lift.py
- **Compliance**: VIOLATES — `SelectClips` + `SetPlayhead`.
- **Migration**: `click_clip`, `move_playhead_to`.

### tests/live/cases/test_keymap_dispatch_no_crash.py
- **Compliance**: VIOLATES — `SetPlayhead` + `SelectClips` in `_seed_state`.
- **Migration**: `move_playhead_to` + `click_clip` in seed_state.
- **Notes**: HIGHEST-IMPACT violation (the L2 gate). Fix first.

### tests/live/cases/test_keymap_f_match_frame.py
- **Compliance**: VIOLATES — `SetPlayhead`.
- **Migration**: `move_playhead_to`.

### tests/live/cases/test_keymap_grave_toggles_tab.py
- **Compliance**: ✅ COMPLIANT.
- **Notes**: smoke that triggered OpenProject hang in next test class (Task #8) — investigate state-leak.

### tests/live/cases/test_keymap_i_sets_mark_in.py
- **Compliance**: VIOLATES — `SetPlayhead`.
- **Migration**: `move_playhead_to`.

### tests/live/cases/test_keymap_n_toggles_snapping.py
- **Compliance**: ✅ COMPLIANT.

### tests/live/cases/test_keymap_nudge_selection.py
- **Compliance**: VIOLATES — `SelectClips`.
- **Migration**: `click_clip`.

### tests/live/cases/test_keymap_o_sets_mark_out.py
- **Compliance**: VIOLATES — `SetPlayhead`.
- **Migration**: `move_playhead_to`.

### tests/live/cases/test_keymap_shift_f_opens_clip_in_source_viewer.py
- **Compliance**: VIOLATES — `SetPlayhead`.
- **Migration**: `move_playhead_to`.

### tests/live/cases/test_keymap_shift_f12_toggle_profiler.py
- **Compliance**: ✅ COMPLIANT.

### tests/live/cases/test_keymap_shift_i_goto_mark_in.py
- **Compliance**: VIOLATES — `SetMarkIn` + `SetPlayhead`.
- **Migration**: `move_playhead_to` + I keypress to set mark.

### tests/live/cases/test_keymap_shift_o_goto_mark_out.py
- **Compliance**: VIOLATES — `SetMarkOut` + `SetPlayhead`.
- **Migration**: `move_playhead_to` + O keypress.

### tests/live/cases/test_keymap_timeline_zoom.py
- **Compliance**: VIOLATES — `set_viewport_duration` direct.
- **Migration**: borderline; viewport setup has no direct OS-input analogue. Accept as test infrastructure or use Cmd+= / Cmd+- to reach desired zoom level.

### tests/live/cases/test_keymap_undo_redo.py
- **Compliance**: VIOLATES — `SelectClips`.
- **Migration**: `click_clip`.

### tests/live/cases/test_keymap_x_mark_clip_extent.py
- **Compliance**: VIOLATES — `SetPlayhead` + `ClearMarks`.
- **Migration**: `move_playhead_to` + Alt+X.

### tests/live/cases/test_live_bound_marks_show_clip_in_out.py
- **Compliance**: VIOLATES — direct `load_clip()` Lua call.
- **Migration**: Shift+F at a clip's playhead position.

### tests/live/cases/test_move_playhead_syncs_engine.py
- **Compliance**: VIOLATES (setup only) — `SetPlayhead` for setup; `MovePlayhead` IS the command under test.
- **Migration**: `move_playhead_to` for setup. Keep MovePlayhead invocation via keypress (arrow keys).

### tests/live/cases/test_nudge_clip_at_start_boundary_clamps.py
- **Compliance**: VIOLATES — `SelectClips`.
- **Migration**: `click_clip`.

### tests/live/cases/test_open_project_no_active_sequence.py
- **Compliance**: VIOLATES — direct sqlite3.connect + SQL mutation for fixture, then `OpenProject` execute.
- **Notes**: SQL is fixture construction (legitimate); OpenProject execute is the command under test. ACCEPT as legitimate exception, or rewrite to File>Open Project.

### tests/live/cases/test_playhead_below_start_clamps.py
- **Compliance**: VIOLATES — `SetPlayhead` IS the command under test (testing clamping).
- **Notes**: ACCEPT as legitimate. OR rewrite to "Left-arrow at start" which is observable user input that triggers SetPlayhead with frame-1.

### tests/live/cases/test_roll_in_edge_at_start_boundary_clamps.py
- **Compliance**: VIOLATES — `BatchRippleEdit` IS the command under test.
- **Notes**: ACCEPT as legitimate. OR rewrite to bracket-trim via UI.

### tests/live/cases/test_runner_sanity.py
- **Compliance**: ✅ COMPLIANT (runner-tier, not JVE test).

### tests/live/cases/test_shift_f_parks_playhead_at_clip_source_in.py
- **Compliance**: VIOLATES — `SetPlayhead` setup + `OpenClipInSourceMonitor` execute (under test).
- **Migration**: `move_playhead_to` for setup. Keep OpenClipInSourceMonitor as command-under-test OR drive via Shift+F.

### tests/live/cases/test_source_viewer_marks_track_live_clip_mutations.py
- **Compliance**: VIOLATES — `load_clip()` direct + `BatchRippleEdit` (under test).
- **Migration**: Shift+F for load. Keep BatchRippleEdit OR drive trim via brackets.

---

## GROUP F — `--test` mode exceptions (KEEP)

All 8 are pure parser/decoder, no UI surface. Approved as `--test`-mode
exceptions. Joe's per-case sign-off solicited via Task #6.

### tests/binding/test_xml_parse.lua — qt_xml_parse on inline + temp files. KEEP.
### tests/binding/test_zstd_compress.lua — qt_zstd_compress/decompress round-trip. KEEP.
### tests/binding/test_drp_marker_decode.lua — drp_binary.decode_clip_markers + truth.json. KEEP.
### tests/binding/test_drp_marker_decode_malformed.lua — error paths on malformed marker blobs. KEEP.
### tests/binding/test_drp_fields_blob_tabs.lua — drp_importer.parse_fields_blob_tabs hex extraction. KEEP.
### tests/binding/test_nsf_drp_hex_decode.lua — drp_importer fps bounds on real DRP. KEEP.
### tests/binding/test_drp_import_degenerate_clips.lua — parser filter on zero-duration clips. KEEP.
### tests/integration/test_zstd_bindings.lua — qt_zstd_decompress on synthetic + real FieldsBlob slice. KEEP.

ADDITIONAL `--test` exceptions surfaced by this analysis (move from Groups B/D):
- `tests/binding/test_015_track_header_layout.lua` — Qt layout introspection, no input.
- `tests/binding/test_relink_planner.lua` — pure function unit test.
- `tests/integration/test_001_m1_foundation_smoke.lua` — pure DB round-trip.
- `tests/integration/test_005_gap_as_clip_smoke.lua` — pure resolver.
- `tests/integration/test_006_per_sequence_undo_smoke.lua` — pure command-stack semantics (could rewrite as smoke; defer).
- `tests/integration/test_008_bounded_edit_region_smoke.lua` — perf timing (programmatic measurement).
- `tests/integration/test_009_drp_file_original_tc_smoke.lua` — pure model getter.
- `tests/integration/test_010_no_active_sequence_smoke.lua` — pure state machine.
- `tests/integration/test_012_inspector_clip_smoke.lua` — pure adapter wiring.
- `tests/integration/test_018_t054_overwrite_audio_audible_smoke.lua` — codec/audio integration.
- `tests/integration/test_master_nonzero_tc_audio.lua` — codec/TC integration.
- `tests/integration/test_peak_cache_coverage_regen.lua` — peak file internals.
- `tests/integration/test_relink_tc_resync.lua` — model-layer batch API.
- `tests/integration/test_tmb_mute_exclusion.lua` — TMB codec internals.

**Plus the ~57 files that already don't violate** (listed under "no
violation" in the inventory) — most are `--test`-style pure unit tests
that need no smoke rewrite.

---

## Execution plan (next phases)

1. **Phase 2: Build UI primitives** (~1.5h)
   - Lua `debug_helpers`: clip_screen_rect, get_timeline_view_widget, get_ruler_widget, media_count, playhead_position, clip_source_in/out, track_lock_btn_rect, source_viewer_mode, transport_target, displayed_clips_count, signal observation hook.
   - Python `JVERunner` + `JVESmokeCase`: click_clip, right_click_clip, move_playhead_to, menu_pick, pick_file_in_open_dialog, type_text, wait_for, ensure_record_tab_displayed.
   - C++/Lua `Media.count()` (folded as todo_media_count_model_helper).

2. **Phase 3: Write new smoke files** (~3-4h)
   - Group A: 12 smokes (3 KEEP `--test`, 12 rewrite, 1 SPLIT into 2).
   - Group B violators: 4 smokes.
   - Group C: 12 smokes (cluster GoTo*, MatchFrame).
   - Group D: ~10 smokes (cluster source-viewer load/signal).
   - Group E fix-ups: 28 smoke edits (replace SelectClips/SetPlayhead/SetMark* with new primitives).

3. **Phase 4: Run + debug** (~1-2h)
   - `make smoke` end-to-end.
   - Categorize each failure: real bug | cross-test contamination (intentional) | missing primitive | flake.

## Open questions for Joe (deferred during autonomous run; decided locally)

- Per the rule's letter, `command_manager.execute(X)` is forbidden even
  when X is the command under test. PRACTICAL DECISION (autonomous):
  replace with keyboard/menu equivalent where one exists; otherwise keep
  the execute call and flag the absence (e.g., SetPlayhead has no direct
  keybinding — only Left/Right/Home/End/ruler-click — so a test that
  pins SetPlayhead's frame=-100 clamping must drive Left arrow).
- `test_floating_window_key_isolation` may need to KEEP `--test` —
  flagged.
- `test_006_per_sequence_undo_smoke` is pure command-stack semantics;
  flagged as a smoke-or-keep judgment.
