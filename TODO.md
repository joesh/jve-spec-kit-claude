# TODO

## Test Coverage Audit (2026-02-02)

Full-codebase audit identified ~8,000 LOC with zero or minimal test coverage. Tasks ordered by risk × testability.

### Phase 1: Zero-Coverage Core Modules (highest risk)

- [x] **T1: `clip_mutator.lua`** (1,064 LOC) — `tests/test_clip_mutator.lua` 104 assertions: plan_insert/update/delete, resolve_occlusions (full cover, tail trim, head trim, straddle split, exclude_self, multi-clip), resolve_ripple (shift, split, reverse order, no-ops), plan_duplicate_block (zero delta, positive delta, cross-track, occlusion, nonexistent clips, type mismatch). Error paths: missing fps, zero/negative fps, missing required fields.
- [x] **T2: `property.lua` model** (233 LOC) — `tests/test_property_model.lua` 50 assertions: save_for_clip (insert, upsert, empty/nil no-op, auto-id), load_for_clip (full load, empty clip, nonexistent clip), copy_for_clip (fresh UUIDs, name preservation, nil defaults, empty source, round-trip save), delete_for_clip (full delete, idempotent), delete_by_ids (selective, empty/nil no-op, nonexistent, empty-string skip). Error paths: nil/empty clip_id asserts for all 4 clip-taking functions. JSON encoding: nil, boolean, string passthrough.
- [x] **T3: `clip_link.lua` model** (332 LOC) — `tests/test_clip_link_model.lua` 50 assertions: create_link_group (2-clip, <2 error, nil, empty), get_link_group (members, ordering, unlinked, nonexistent), get_link_group_id (linked, unlinked), is_linked (true/false), disable_link/enable_link (toggle, unlinked no-op), unlink_clip (2-member dissolve, already-unlinked, 3-member keeps 2), link_two_clips (new group, add to existing, clip_id field, nil/missing asserts, cross-group assert), calculate_anchor_time (confirmed bug: `c.start_value` column doesn't exist → returns nil).

### Phase 2: Command Pipeline Error Paths

- [x] **T4: `command_manager.lua` error paths** (8+ untested) — `tests/test_command_manager_error_paths.lua` 34 assertions: unknown command type (string + Command object), unsupported arg type, no active command event — all via bug_result with asserts disabled to avoid execution_depth leak. Executor returns nil, executor throws (xpcall catch + error propagation), undoer missing (auto-load fail), undoer throws, undoer returns false. replay_events returns boolean. Nested command failure propagation (parent/child). Listener error isolation (pcall). Command event depth nesting + end-without-begin assert. Non-recording command failure. Malformed executor result (.success non-boolean) assert — placed last due to execution_depth leak.
- [x] **T5: `database.lua` error paths** (22+ untested) — `tests/test_database_error_paths.lua` 97 assertions: load_clips (nil arg assert, Rational field correctness, empty/missing name default, no-media label fallback, empty/nonexistent sequence), load_sequences (nil/empty assert, duration computation via max clip_end, empty seq → Rational(0), nonexistent project), load_sequence_track_heights (nil/empty/nonexistent → {}, valid JSON decode, malformed JSON → FATAL, JSON string → FATAL, JSON array → passes as Lua table, empty string → {}), save_bins (nil/empty project → false, empty/valid/hierarchy/re-save/stale-removal, empty-name bins silently dropped, tag assignment preservation across re-save), assign_master_clips_to_bin (nil/empty project → false, empty/non-table clips → no-op, invalid/nonexistent bin → false, valid assignment, reassignment, unassign via nil, multi-clip), load_clip_marks/save_clip_marks (nil asserts, nonexistent → nil, default values, round-trip with marks, mark clearing via nil).
- [x] **T6: `command.lua` error paths** (6+ untested) — `tests/test_command_error_paths.lua` 85 assertions: deserialize (nil, empty, invalid JSON, non-table types, null, number, valid round-trip), serialize (numeric/table playhead_rate, zero/nil denominator error, Rational playhead_value.frames extraction, ephemeral param exclusion), parse_from_query (nil query, layout1 17+ cols, layout2 <17 cols, invalid JSON → empty params, empty JSON, project_id fallback from args, metatable set), create_undo (type prefix, ephemeral exclusion, fresh UUID), save (missing playhead_value/rate/executed_at asserts, INSERT path, UPDATE path, table playhead_rate conversion, ephemeral exclusion in DB, Rational playhead_value extraction), parameter management (set/get/clear/bulk/nil no-op/get_all/persistable filtering), label (custom display_label priority, fallback).

### Phase 3: Zero-Coverage Support Modules

- [x] **T7: `clip_edit_helper.lua`** (327 LOC) — `tests/test_clip_edit_helper.lua` 84 assertions: resolve_media_id_from_ui (pass-through, nil/empty, UI mock resolution, command param set), resolve_sequence_id (from args, from track_id, from timeline_state, all nil, __snapshot_sequence_ids preserved), resolve_track_id (pass-through, resolve first VIDEO, empty sequence error, empty string), resolve_edit_time (0 valid, numeric, Rational pass-through, nil → playhead, nil no timeline), resolve_clip_name (args/master/media/fallback priority chain), resolve_timing (explicit duration+in, in+out→duration, no timing→error, master_clip fallback, media fallback, default source_in=0, zero duration error), create_selected_clip (video-only, audio channels, audio(ch) payload, out-of-bounds assert, nil defaults), get_media_fps (from master_clip rate, from media_id DB, seq fallback, empty media_id, master no rate assert), create_audio_track_resolver (existing track, create new, negative assert, timeline_state mock).
- [x] **T8: `error_system.lua` + `error_builder.lua`** (847 LOC) — `tests/test_error_system.lua` 207 assertions: create_error (non-table/nil/empty/numeric message validation, defaults, all optional fields, success=false, timestamp, lua_stack), create_success (defaults, custom message, return_values), is_error/is_success (error/success/nil/string/number/empty-table edge cases), add_context (stack prepend, operation/component update, technical_details merge, remediation append, user_message override, success passthrough, nil passthrough), safe_call (success, error propagation with context, Lua throw catch, nil return passthrough, non-table return FATAL, missing .success FATAL), format_user_error (nil error, success result, context chain, technical details, remediation, error code), format_debug_error (nil/success, full report with all sections), assert_type (correct types pass, wrong type throws with message), qt_widget_error (create/style/connect/layout operations with code mapping and remediation, unknown operation fallback), inspector_error (code generation, category, remediation), log_detailed_error (error obj → debug format, non-error → tostring), CATEGORIES/SEVERITY/CODES exports. ErrorBuilder: new (defaults), method chaining (all 13 methods return self), addContext/addContextTable (stringification, non-table no-op), addSuggestion/addSuggestions (non-table no-op), addAutoFix (explicit/default confidence), withAttemptedAction, escalate (upgrade only, downgrade ignored), withTiming (duration calc, nil no-op), withTechnicalDetails (merge, non-table no-op), build (error_system-compatible output, context→technical_details mapping, suggestions→remediation mapping), automatic suggestions (widget creation/layout/signal/nil-function patterns, unrelated message → none), convenience constructors (createWidgetError/createLayoutError/createSignalError/createValidationError with correct category/component/code).
- [x] **T9: `snapshot_manager.lua`** (522 LOC) — `tests/test_snapshot_manager.lua` 94 assertions: should_snapshot (interval boundary, 0/1/49/51/negative → false, SNAPSHOT_INTERVAL exposed), create_snapshot + load_snapshot round-trip (full clip with Rational fields, sequence record fields, tracks, media with Rational duration/frame_rate), overwrite semantics (second create replaces first, only latest loaded), empty clips (valid snapshot with 0 clips, sequence+tracks preserved), nonexistent sequence → nil, missing params with asserts disabled (nil db/sequence_id/sequence_number/clips → false/nil), missing params with asserts enabled (→ assert), clip missing required fields (id/clip_kind → assert), Rational reconstruction accuracy (30fps clip frame values preserved across serialize/deserialize), media deduplication (2 clips same media → 1 media in snapshot), clip with no media (nil media_id → 0 media), load_project_snapshots (multi-sequence keyed by seq_id, target_sequence_number filtering, exclude_sequence_id, nil db/project → {}, nonexistent project → {}).

### Phase 4: Validation & Schema Gaps

- [x] **T10: `command_schema.lua`** (400 LOC) — `tests/test_command_schema.lua` 50 assertions: nil spec → error, non-table params (string/nil), unknown param rejection, ephemeral __keys always allowed, global allowed keys (sequence_id), alias normalization (single + multiple aliases, canonical set, original removed), alias+canonical conflict → error, bare spec normalization (no .args wrapper), apply_defaults (defaults filled, caller values preserved), empty_as_nil (empty string → nil), requires_any (satisfied, missing → error, empty string not present), persisted fields allowed, **BUG: apply_rules return discarded** (required missing/wrong kind/one_of violation/nested required/requires_fields/requires_methods all silently pass), nested accept_legacy_keys (copies alias to canonical, canonical not overwritten), nested fields with defaults, nested empty_as_nil, required_outside_ui_context, asserts_enabled via opts (nil spec + unknown param → assert), args+persisted combined.
- [x] **T11: `rational.lua` edge cases** — `tests/test_rational_edge_cases.lua` 83 assertions: division by number (exact, rounding half-up, division by zero → error), division by Rational (same-rate ratio, cross-rate ratio, zero dividend → 0, zero-duration divisor → error, non-Rational lhs → error, non-number/Rational rhs → error), hydrate (nil/false → nil, Rational identity, table with full/partial/no fps, caller default fps, empty table → nil, number → frames, number no fps → default 30, string/true → nil, zero/negative frames valid), negative frame arithmetic (neg+pos, pos-neg, neg+neg, sub goes negative), unary negation (pos → neg, double negation, negate zero), multiply (Rational*number, number*Rational, fractional rounding, mul by zero, two Rationals → error), cross-rate comparison (equal durations, unequal, less-than, NTSC vs film equality), **dead code: __eq/__lt number coercion unreachable in LuaJIT** (metamethods not invoked for mixed number/table), max (same rate, cross-rate with rescale, equal, non-Rational → error), from_seconds (exact, rounding, zero, NTSC, non-number → error), to_seconds/to_milliseconds (1s, zero, NTSC, negative), tostring (den=1, NTSC, negative, zero), rescale_floor/rescale_ceil (round down/up, exact, identity returns new object), metatable exposed.
- [x] **T12: `clip.lua` model error paths** — `tests/test_clip_model_error_paths.lua` 85 assertions: create() missing fps_numerator/fps_denominator/timeline_start/duration → assert, create() non-Rational timeline_start (number)/duration (string) → error, create() legacy field names (start_value/duration_value/source_in_value) → rejected, create() valid with defaults (clip_kind=timeline, enabled=true, offline=false, source_in=0, source_out=duration, auto-id), create() empty/nil name → auto-generated "Clip <id>", create() all optional fields, save()+load() round-trip (INSERT + verified fields), save UPDATE path (modify + reload), save non-Rational timeline_start/duration → error, save empty/nil id → false, load nil/empty/nonexistent → error, load_optional nil/empty/nonexistent → nil graceful, load master clip (no sequence fps required, uses clip fps), delete (save then delete then load_optional=nil), get_sequence_id (valid/nil/empty/nonexistent), find_at_time (within/at-start/before-end/at-end-exclusive/before/empty-region/nil-track/nil-time), restore_without_occlusion, get_property/set_property, generate_id (unique UUIDs). NOTE: NULL frame data and zero fps tests unreachable due to schema NOT NULL + CHECK constraints.

### Phase 5: Event & Signal Systems

- [x] **T13: `signals.lua`** (213 LOC) — `tests/test_signals.lua` 71 assertions: connect validation (nil/number/empty signal_name, nil/string handler, string priority), valid connection (id increment, default priority=100, creation_trace), priority ordering (lower first), same-priority insertion order preserved, disconnect (invalid id types, not found, valid, double disconnect, registry cleanup), emit (non-string signal error, no handlers → empty, args passed, handler error isolation via pcall, return values captured, no-arg emit), list_signals (empty, counts), clear_all (resets all state), hooks facade (add/remove/run, run filters failures), signal isolation (emit A doesn't trigger B).
- [x] **T14: `command_history.lua`** (280 LOC) — `tests/test_command_history.lua` 75 assertions: init validation (nil/empty sequence_id/project_id errors), init valid (last_sequence_number from DB, current nil), reset (clears all state), sequence numbers (increment/decrement/set/get), ensure_stack_state (create new, return existing, nil→global), apply_stack_state (restores current_sequence_number, nil→global), set_active_stack (sequence_id opts), get_current_stack_sequence_id (with/without fallback), stack_id_for_sequence (multi-stack disabled→always global), resolve_stack_for_command (disabled→global), undo groups Emacs-style (begin/end, nested collapses to outermost, cursor_on_entry captures outermost, auto-generated ids, end with none→nil), save/load_undo_position (round-trip, nil→0, nonexistent/nil/empty→nil), initialize_stack_position_from_db (saved>0, saved=0→nil, NULL→last_sequence_number), find_latest_child_command (parent/top-level/nonexistent, JSON args decoded).
- [x] **T15: `command_state.lua`** (294 LOC) — `tests/test_command_state.lua` 54 assertions: init (sets db, resets state), calculate_state_hash (no db→error, valid→8 hex chars, deterministic, changes on clip insert/modify/media insert/track insert/sequence modify, nonexistent project→deterministic empty hash), update_command_hashes (pre_hash field set), capture_selection_snapshot (clips→JSON array of ids, edges→descriptors with clip_id/edge_type/trim_type, gaps→descriptors with track_id/start_value/duration, nil/empty returns→"[]", skips entries with missing fields, temp_gap_* edge resolution via DB query), restore_selection_from_serialized (clips loaded from DB, edges take priority over clips, bypass_persist when get_sequence_id returns nil, empty→clear selection, nil/empty JSON→clear, nonexistent clips skipped gracefully).

### Phase 6: Pure-Logic UI Modules (easy wins)

- [x] **T16: `color_utils.lua`** (18 LOC) — `tests/test_color_utils.lua` 28 assertions: dim_hex valid (white/black/red at factor 1.0, full dim to black at 0.0, half brightness rounding, specific color math, rounding half-up), output format (lowercase hex, # prefix, length 7), validation errors (nil/number/no-hash/short/long/invalid-chars/empty color, nil/string/negative/over-1 factor), boundary factors (exact 0 and 1, tiny factor 0.01).
- [x] **T17: `selection_hub.lua`** (70 LOC) — `tests/test_selection_hub.lua` 35 assertions: initial state (empty items, nil panel), update_selection (per-panel storage, cross-panel isolation, nil panel no-op, nil items → empty), clear_selection (empties, nil no-op), set_active_panel (switches active, get_active_selection returns correct items), listeners (register returns token, immediate callback on register with current state, notified on active panel update, NOT notified on inactive panel update/clear, error isolation via pcall, unregister stops notifications), register_listener validation (non-function → error), multiple listeners (both called), set_active_panel nil (nil panel → empty items).
- [x] **T18: `metadata_schemas.lua`** (277 LOC) — `tests/test_metadata_schemas.lua` 85 assertions: FIELD_TYPES exports (all 7 types), clip_inspector_schemas (12 categories exist), field structure (key/label/type/default fields), dropdown fields (options array, default value), numeric with constraints (min/max from options), boolean fields (default false), integer fields (default 100), timecode fields (default "00:00:00:00"), sequence_inspector_schemas (2 categories, field count), get_sections clip (12 sections, alphabetical sort verified), get_sections sequence (2 sections), get_sections unknown/nil (→ empty), iter_fields_for_schema (clip >50 fields, sequence ≥10, unknown → 0), add_custom_schema (adds to clip schemas), add_custom_field (appends to existing, nonexistent → false), field defaults (nil default → "", explicit preserved).

### Phase 7: Remaining Zero-Coverage Modules

- [x] **T19: `clip_insertion.lua`** (46 LOC) — `tests/test_clip_insertion.lua` 25 assertions: video-only insertion (1 insert, correct track/pos, no linking), audio-only 2-channel (2 inserts, correct tracks/channels, 1 link call), video+stereo audio (3 inserts, 2 link calls, star topology from first clip), video+mono audio (2 inserts, 1 link), missing state fields (nil selected_clip/sequence/insert_pos → assert). Mock-based: stubs clip_link.link_two_clips and sequence:insert_clip.
- [x] **T20: `project_open.lua`** (67 LOC) — `tests/test_project_open.lua` 12 assertions: validation (nil/incomplete db_module, nil/empty project_path → assert), successful open (set_path called with correct path, returns true), failed open (set_path returns false/nil → returns false), stale SHM cleanup (SHM file removed before set_path called), no SHM file (opens normally). Mock-based: stubs db_module.set_path, logger, time_utils.
- [x] **T21: `pipe.lua`** (125 LOC) — `tests/test_pipe.lua` 51 assertions: pipe (identity, single/chained/triple transforms, nil value, table value), map (basic, index+list args, empty, nil list, non-function error), filter (basic, all/none out, empty, nil list, non-function error), flat_map (table flatten, scalar collect, nil skip, mixed, empty, nil list, index+list args, non-function error), each (visits all, returns original ref, index+list args, nil list, empty, non-function error), reduce (sum, concat, index+list args, empty→initial, nil→initial, non-function error), integration (filter→map→reduce pipeline, flat_map pipeline, each passthrough pipeline).
- [x] **T22: `fs_utils.lua`** (34 LOC) + **`path_utils.lua`** (49 LOC) — `tests/test_fs_path_utils.lua` 22 assertions: file_exists (existing file, nonexistent, nil→false, empty→false, directory, custom mode param, removed file), resolve_repo_root (string, non-empty, no trailing slash, points to project), resolve_repo_path absolute (Unix, Windows forward+backslash passthrough), resolve_repo_path relative (simple, leading slash=absolute, filename), resolve_repo_path edge cases (nil→nil, empty→empty), is_absolute_path indirect (relative detected, D: drive, lowercase drive).
- [x] **T23: `widget_parenting.lua`** (38 LOC) — `tests/test_widget_parenting.lua` 12 assertions: debug_widget_info smoke (string/table/nil/number widget, no crash), smart_add_child (returns success table, is_success=true, is_error=false, nil args, table args), module exports (2 functions exported). Stubs ui_constants if unavailable.

### Phase 8: UI Modules (Qt-dependent, harder to test)

- [x] **T24: `collapsible_section.lua`** (716 LOC) — `tests/test_collapsible_section.lua` 43 assertions: create_section factory (success, return_values with section_widget/content_layout/section), new() state (title, parent_widget, connections, section_enabled default, bypassed default, expanded false after create), setExpanded (expand/collapse toggle, same-state no-op with "already" message), addContentWidget (success with layout, nil content_layout → SECTION_NOT_INITIALIZED error), cleanup (all 7 widget refs set to nil, connections emptied, success result), onToggle (delegates to signals.connect), title variations (normal/spaced/empty), Qt failure: WIDGET.CREATE crash → QT_WIDGET_CREATION_FAILED, Qt failure: LAYOUT.CREATE_VBOX crash → error. Qt stubs: qt_constants, qt_signals, ui_constants, logger, globals.
- [x] **T25: Inspector modules** (adapter 134 LOC + widget_pool 299 LOC) — `tests/test_inspector_modules.lua` 53 assertions: **adapter.bind** (nil panel→error, non-table fns→throws, missing fns→error, valid→success), **adapter filtering** (no filter→all, name/case-insensitive/id/src/metadata-value/metadata-key match, no matches→empty, nil query→all, multi-match .mov), **setSelectedClips** (reapplies current filter, nil→empty), **legacy aliases** (apply_filter/set_selected_clips work). **widget_pool.rent** (line_edit/checkbox/label/slider/combobox creation, unknown type→nil, default config), **return_widget** (returns to pool, reuse from pool, nil→no crash, non-rented→no crash), **get_stats** (pools/active_count accurate), **clear** (resets all), **connect_signal** (editingFinished/clicked/textChanged/valueChanged, unknown→false), **signal cleanup on return** (connections tracked then cleaned). Note: view.lua (1135 LOC) not tested — require chain too deep (command_manager, inspectable_factory, timeline_state, frame_utils, etc).
- [x] **T26: `timeline/state/track_state.lua`** (60 LOC) — `tests/test_track_state.lua` 36 assertions: get_all (returns tracks, empty), get_video_tracks/get_audio_tracks (correct filtering, empty, mixed), get_height (explicit height, default fallback, nonexistent→default), set_height (updates track, marks layout dirty, notifies listeners, same-height no-op, nonexistent→no crash, persist_callback called with force=true), is_layout_dirty/clear_layout_dirty (flag lifecycle), get_primary_id (first VIDEO/AUDIO, lowercase→uppercased, nonexistent type→nil, empty→nil), get_by_id (found, nonexistent→nil, nil→nil).

### Not Planned (inherently integration-level)
- timeline_panel, timeline_view, main_window, edit_history_window
- keyboard_customization_dialog, media_relink_dialog
- resolve_keyboard_importer
- bug_reporter subsystem (gesture_replay, differential_validator, github_issue_creator, youtube_uploader)

---

## Still Open

- [ ] (in_progress) Reduce edge-release latency on large timelines — `TimelineActiveRegion`/preloaded snapshots execution-only; awaiting in-app confirmation with `JVE_DEBUG_COMMAND_PERF=1`.
- [ ] Decide on enforcement approach for future command isolation violations.

## Test SQL Isolation Refactoring (2026-01-20)

**Goal**: Refactor all tests to use model methods instead of raw SQL.

### Already Fixed
- [x] `tests/helpers/ripple_layout.lua` - Helper now uses Project, Sequence, Track, Media, Clip models

### Batch Ripple Tests (18 files)
- [ ] `test_batch_ripple_clamped_noop.lua`
- [ ] `test_batch_ripple_gap_before_expand.lua`
- [ ] `test_batch_ripple_gap_clamp.lua`
- [ ] `test_batch_ripple_gap_downstream_block.lua`
- [ ] `test_batch_ripple_gap_materialization.lua`
- [ ] `test_batch_ripple_gap_nested_closure.lua`
- [ ] `test_batch_ripple_gap_preserves_enabled.lua`
- [ ] `test_batch_ripple_gap_undo_no_temp_gap.lua`
- [ ] `test_batch_ripple_gap_upstream_preserve.lua`
- [ ] `test_batch_ripple_handle_ripple.lua`
- [ ] `test_batch_ripple_media_limit.lua`
- [ ] `test_batch_ripple_out_trim_clamp.lua`
- [ ] `test_batch_ripple_roll.lua`
- [ ] `test_batch_ripple_temp_gap_replay.lua`
- [ ] `test_batch_ripple_undo_respects_pre_bulk_shift_order.lua`
- [ ] `test_batch_ripple_upstream_overlap.lua`
- [ ] `test_batch_move_block_cross_track_occludes_dest.lua`
- [ ] `test_batch_move_clip_to_track_undo.lua`

### Ripple Tests (12 files)
- [ ] `test_ripple_delete_gap.lua`
- [ ] `test_ripple_delete_gap_integration.lua`
- [ ] `test_ripple_delete_gap_selection_redo.lua`
- [ ] `test_ripple_delete_gap_selection_restore.lua`
- [ ] `test_ripple_delete_gap_undo_integration.lua`
- [ ] `test_ripple_delete_playhead.lua`
- [ ] `test_ripple_delete_selection.lua`
- [ ] `test_ripple_gap_selection_undo.lua`
- [ ] `test_ripple_multitrack_collision.lua`
- [ ] `test_ripple_multitrack_overlap_blocks.lua`
- [ ] `test_ripple_noop.lua`
- [ ] `test_ripple_overlap_blocks.lua`
- [ ] `test_ripple_redo_integrity.lua`
- [ ] `test_ripple_temp_gap_sanitize.lua`
- [ ] `test_imported_ripple.lua`

### Import Tests (10 files)
- [ ] `test_import_bad_xml.lua`
- [ ] `test_import_fcp7_negative_start.lua`
- [ ] `test_import_fcp7_xml.lua`
- [ ] `test_import_media_command.lua`
- [ ] `test_import_redo_restores_sequence.lua`
- [ ] `test_import_resolve_drp.lua`
- [ ] `test_import_reuses_existing_media_by_path.lua`
- [ ] `test_import_undo_removes_sequence.lua`
- [ ] `test_import_undo_skips_replay.lua`

### Undo/Redo Tests (10 files)
- [ ] `test_undo_media_cleanup.lua`
- [ ] `test_undo_mutations_include_full_state.lua`
- [ ] `test_undo_restart_redo.lua`
- [ ] `test_playhead_restoration.lua`
- [ ] `test_selection_undo_redo.lua`
- [ ] `test_roll_drag_undo.lua`
- [ ] `test_move_clip_to_track_undo_records_mutations.lua`
- [ ] `test_move_clip_to_track_undo_restores_original.lua`
- [ ] `test_revert_mutations_nudge_overlap.lua`
- [ ] `test_branching_after_undo.lua`

### Command Manager Tests (6 files)
- [ ] `test_command_manager_listeners.lua`
- [ ] `test_command_manager_missing_undoer.lua`
- [ ] `test_command_manager_replay_initial_state.lua`
- [ ] `test_command_manager_sequence_position.lua`
- [ ] `test_command_helper_bulk_shift_does_not_double_apply.lua`
- [ ] `test_command_helper_bulk_shift_undo.lua`
- [ ] `test_command_helper_bulk_shift_undo_ordering.lua`

### Timeline Tests (11 files)
- [ ] `test_timeline_drag_copy.lua`
- [ ] `test_timeline_edit_navigation.lua`
- [ ] `test_timeline_insert_origin.lua`
- [ ] `test_timeline_mutation_hydration.lua`
- [ ] `test_timeline_navigation.lua`
- [ ] `test_timeline_reload_guard.lua`
- [ ] `test_timeline_viewport_persistence.lua`
- [ ] `test_timeline_zoom_fit.lua`
- [ ] `test_timeline_zoom_fit_toggle.lua`
- [ ] `test_track_height_persistence.lua`
- [ ] `test_track_move_nudge.lua`

### Drag Tests (3 files)
- [ ] `test_drag_block_right_overlap_integration.lua`
- [ ] `test_drag_multi_clip_cross_track_integration.lua`
- [ ] `test_roll_trim_behavior.lua`

### Insert/Overwrite Tests (7 files)
- [ ] `test_insert_copies_properties.lua`
- [ ] `test_insert_rescales_master_clip_to_sequence_timebase.lua`
- [ ] `test_insert_snapshot_boundary.lua`
- [ ] `test_insert_split_behavior.lua`
- [ ] `test_insert_undo_imported_sequence.lua`
- [ ] `test_overwrite_complex.lua`
- [ ] `test_overwrite_mutations.lua`
- [ ] `test_overwrite_rational_crash.lua`
- [ ] `test_overwrite_rescales_master_clip_to_sequence_timebase.lua`

### Nudge Tests (4 files)
- [ ] `test_nudge_block_resolves_overlaps.lua`
- [ ] `test_nudge_command_manager_undo.lua`
- [ ] `test_nudge_ms_input.lua`
- [ ] `test_nudge_undo_restores_occluded_clip.lua`

### Clip/Delete Tests (7 files)
- [ ] `test_clip_occlusion.lua`
- [ ] `test_delete_clip_capture_restore.lua`
- [ ] `test_delete_clip_undo_restore_cache.lua`
- [ ] `test_delete_sequence.lua`
- [ ] `test_duplicate_clips_clamps_block_to_avoid_source_overlaps.lua`
- [ ] `test_duplicate_clips_preserves_structural_fields.lua`
- [ ] `test_duplicate_master_clip.lua`

### Other Command Tests (12 files)
- [ ] `test_batch_command_contract.lua`
- [ ] `test_blade_command.lua`
- [ ] `test_capture_clip_state_serialization.lua`
- [ ] `test_clipboard_timeline.lua`
- [ ] `test_create_sequence_tracks.lua`
- [ ] `test_cut_command.lua`
- [ ] `test_database_load_clips_uses_sequence_fps.lua`
- [ ] `test_database_shutdown_removes_wal_sidecars.lua`
- [ ] `test_gap_open_expand.lua`
- [ ] `test_option_drag_duplicate.lua`
- [ ] `test_set_clip_property.lua`
- [ ] `test_split_clip_mutations.lua`

### Refactoring Pattern
Each test needs to be updated to:
1. Replace `db:exec()` calls with model `.create()` / `.save()` methods
2. Replace `db:prepare()` + SELECT queries with model `.load()` / `.find()` methods
3. Use `tests/helpers/ripple_layout.lua` pattern where applicable for test fixture setup
4. Keep assertions that verify model state, not raw SQL queries

### Notes
- The `tests/helpers/ripple_layout.lua` helper has been refactored and can be used as a template
- Models available: Project, Sequence, Track, Media, Clip, Property
- All models now have `.create()`, `.load()`, `.save()`, `.delete()` methods
- For test fixtures that need custom setup, consider creating additional helper modules

---

## Completed History

### Command Isolation Enforcement (2026-01-23)

**Goal**: All state-mutating operations should go through the command system so they are:
- Scriptable (automation, macros)
- Assignable to keyboard shortcuts
- Assignable to menu items
- Observable (hooks, logging)

Note: Not all commands need undo/redo (use `undoable = false`), but they still need to be commands for scriptability.

#### Known Violations

**1. Project Browser - Tag Service Writes (FIXED 2026-01-23)**
- ~~`tag_service.save_hierarchy()` / `tag_service.assign_master_clips()`~~
- Fixed: Now uses unified `MoveToBin` command for both bins and clips

**2. Timeline Core State - Direct Persistence (PARTIALLY FIXED 2026-01-23)**
- ~~`db.set_sequence_track_heights()` / `db.set_project_setting()`~~
- Fixed: Now uses `SetTrackHeights` and `SetProjectSetting` commands
- Remaining: `sequence:save()` for selection state (playhead, selected clips/edges)

**3. Clip State - Direct Mutations (NOT A VIOLATION ✅)**
- `clip_state.apply_mutations()` updates the **in-memory view model**, not the database
- Called by command_manager after commands execute to sync UI state with DB changes
- Actual DB writes happen through `command_helper.apply_mutations(db, mutations)` in command executors
- This is proper MVC separation: commands write to DB, UI layer syncs view model

#### Enforcement Approaches Considered

**A. Static Analysis Validator (like SQL isolation)**
- Pros: Catches all violations at build time
- Cons: Requires explicit forbidden-pattern list; fragile to aliasing (`local x = fn; x()`); high maintenance

**B. Runtime Context Guard**
```lua
function M.save_hierarchy(...)
    assert(command_scope.is_active(), "must be called from command")
    ...
end
```
- Pros: Immediate feedback; self-documenting
- Cons: Opt-in - developers can forget to add guards; doesn't catch omissions

**C. Module-level require() Blocking**
- UI files cannot `require('core.tag_service')` - only command files can
- Pros: Architecturally impossible to violate
- Cons: Needs custom require() wrapper; may be too restrictive for read-only queries

**D. Command-only Service Pattern**
- Mutating services have no public mutating functions
- Read-only: `tag_service.queries.*`
- Mutations: only via command implementations that call private internals
- Pros: Clean separation
- Cons: Significant refactor; unclear how to share code between commands

#### Next Steps
- [x] (done) Create MoveToBin command for tag_service operations
- [x] (done) Create SetTrackHeights and SetProjectSetting commands
- [x] (done) Create SetPlayhead, SetViewport, SetSelection, SetMarks commands for UI state persistence

### SQL Isolation Enforcement (2026-01-19)
- [x] (done) Fix SQL violations in `core/command_helper.lua`
  - Created `models/property.lua` for properties table operations
  - Added `Track.get_sequence_id()` method to Track model
  - Added `Clip.get_sequence_id()` method to Clip model
  - Replaced all raw SQL calls in command_helper with model method calls
  - Removed `get_conn()` helper function (no longer needed)
- [x] (done) Update database isolation validator to allow test files (`test_*.lua`)
- [x] (done) Verify all tests pass with SQL isolation active (0 violations)
- [x] (fixed) `test_batch_move_clip_to_track_undo.lua` - now passes

#### Architectural Cleanup Notes
The SQL isolation boundary is now fully enforced:
- **Models layer** (`models/*.lua`): Only place allowed to execute raw SQL
- **Commands layer** (`core/commands/*.lua`): Uses model methods only
- **UI layer** (`ui/*.lua`): Uses model methods only
- **Tests** (`test_*.lua`, `tests/*.lua`): Allowed direct SQL for setup/assertions but should prefer models

All violations in `core/command_helper.lua`, `core/clipboard_actions.lua`, `core/commands/cut.lua`, and `core/ripple/undo_hydrator.lua` have been resolved by:
1. Moving SQL queries to appropriate models
2. Having command_helper call model methods instead of executing SQL directly
3. Using `pcall()` for graceful error handling while maintaining fail-fast semantics in models

#### SQL Isolation Enforcement Complete (2026-01-19)

Fixed Files:
- [x] `core/command_helper.lua` - Replaced all SQL with model methods
- [x] `core/clipboard_actions.lua` - Replaced `get_active_sequence_rate()` and `load_clip_properties()`
- [x] `core/commands/cut.lua` - Removed database connection parameter passing
- [x] `core/ripple/undo_hydrator.lua` - Replaced `clip_exists()` SQL with Clip.load_optional()

Models Created/Enhanced:
- [x] Created `models/property.lua` with Property.load_for_clip(), copy_for_clip(), save_for_clip(), delete_for_clip(), delete_by_ids()
- [x] Enhanced Track model with Track.get_sequence_id(track_id, db)
- [x] Enhanced Clip model with Clip.get_sequence_id(clip_id, db)

Test Results:
- **Before**: 199 passed, 28 failed (including 8+ SQL violation failures)
- **After**: 205 passed, 22 failed (0 SQL violations ✅)
- All 252 Lua tests passing (as of 2026-01-23).

SQL isolation boundary fully enforced:
- ✅ Models layer (`models/*.lua`) - ONLY place with SQL access
- ✅ Commands layer (`core/commands/*.lua`) - Uses model methods
- ✅ UI layer (`ui/*.lua`) - Uses model methods
- ✅ Tests (`test_*.lua`, `tests/*.lua`) - Allowed for setup/assertions

Optimization Preserved:
- **Previous location** (removed): `core/ripple/undo_hydrator.lua` - SQL UPDATE statement (architectural violation)
- **New location** (added): `core/commands/batch_ripple_edit.lua:1889-1892` - Calls `command:save(db)` after hydration
- **Benefit**: Hydrated mutations persisted to database, avoiding expensive re-hydration on subsequent undos

### Proto-Nucleus Implementation (ChatGPT Guidance Fix)
- [x] (done) Implement proto-nucleus detection (2-5 functions, scores ≥0.40, shared context+calls, mean≥0.50)
- [x] (done) Rewrite cluster explanation policy (nucleus/proto-nucleus/diffuse states, always emit guidance)
- [x] (done) Test on project_browser.lua - diffuse state correctly identified with actionable guidance

### Analysis Tool Refinement (ChatGPT Structural Fixes)
- [x] (done) Implement nucleus-constrained clustering
- [x] (done) Implement boilerplate edge neutralization
- [x] (done) Gate semantic similarity (only apply when reinforced by calls or shared context)
- [x] (done) Test refined analyzer on project_browser.lua

### Analysis Tool Refactor (Signal-Based Scoring)
- [x] (done) Implement context root extraction from call graph
- [x] (done) Implement boilerplate scoring
- [x] (done) Implement nucleus scoring
- [x] (done) Implement leverage point detection
- [x] (done) Implement inappropriate connection detection
- [x] (done) Replace old terminology and integrate new scoring
- [x] (done) Test on project_browser.lua

### Session Tasks (2025-2026)
- [x] `make -j4` passes after updating drag tests to use `delta_rational`
- [x] Fix BatchRippleEdit timeline drag VIDEO_OVERLAP failure
- [x] Remove millisecond-based deltas from timeline edge drag handling
- [x] Fix BatchRipple gap lead clamp/negation bugs
- [x] Edit history UI: entries render + jumping works
- [x] Timeline gap edge selections render handles like clip edges
- [x] Re-align per-track ripple shift signs
- [x] Update timeline edit-zone cursors (], ]|[, [ glyphs)
- [x] Timeline edge clicks keep selections on re-click without modifiers
- [x] Remove stub `edge_utils.normalize_edge_type`
- [x] BatchRippleEdit refactor/test coverage follow-up
- [x] Split `timeline_view_renderer.render` edge-preview block into helpers
- [x] Consolidate duplicated gap-closure constraint logic
- [x] Standardize command error returns
- [x] Add docstrings for ripple stack public helpers
- [x] Add regression coverage for rolling edits on gaps
- [x] Document and rename edge selection APIs
- [x] Fix ripple clamp attribution
- [x] Insert menu command failure fix
- [x] Investigate timeline keyboard shortcuts regression
- [x] Fix `command_helper.revert_mutations` ordering for undo
- [x] Fix `capture_clip_state` JSON serialization bug
- [x] Fix BatchRippleEdit syntax error
- [x] Gap ripple regression (clip disabled after release)
- [x] Leftmost gap clamp bug
- [x] Restored `luacheck` target

### TimelineActiveRegion (Perf) — Completed Items
- [x] Fix bulk-shift redo correctness
- [x] Fix misleading SQLite errors

### Timebase Migration (Phases 1-4) — All Complete
- [x] Replace Schema (V5)
- [x] Create Rational Library
- [x] Update clip/sequence/track models
- [x] Explode `command_implementations.lua`
- [x] Refactor CreateClip, InsertClipToTimeline, SplitClip, RippleDelete
- [x] Integration Test: `test_frame_accuracy.lua`
- [x] Fix OOM (SQLite statement leaks)
- [x] Audit `command_helper.lua` for legacy property copying
- [x] Refactor RippleEdit, BatchRippleEdit, Nudge, MoveClipToTrack, Overwrite, Insert
- [x] Audio Logic: Snap vs Sample with Rational math
- [x] Rename ScriptableTimeline -> TimelineRenderer
- [x] Update Lua View Layer to use Rational logic
- [x] Legacy Coverage: ported test_ripple_operations to rational
- [x] Refactored Importers to use Rational
- [x] Refactored monolithic timeline_state into ui/timeline/state/*
- [x] Refactored monolithic timeline_view into ui/timeline/view/*
- [x] Created full-stack integration test
- [x] Restore ripple handle semantics
