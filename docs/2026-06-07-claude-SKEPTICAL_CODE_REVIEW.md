# Skeptical Code Review — 2026-06-07
_Branch: 023-resolve-color-bridge — dirty files only_

## Executive Summary
- **Two crash-on-first-use bugs ship on this branch**: `drt_writer.build_project_xml` is called missing its `state` argument (every non-empty DRT export will crash on identity-marker emission), and `Sequence.count_clips` references an undefined `db` global. Neither is exercised by tests — strong signal that test coverage of "shipping path" is thin.
- **Systemic silent-fallback regression across ~10 files** despite ENGINEERING 1.14/2.13 being repeatedly cited in the new comments. The same hands writing "Rule 2.13" in comments are simultaneously adding `or 0`, `pcall`-swallow, `if ok then`, `or '.'`, "force to 1", and "return repo_root_candidate". This is the dominant systemic finding on the branch.
- **A spike (`t008_author.lua`) was committed with a Lua syntax error** — it cannot have run, meaning any artifact claimed to come from it is unverified.
- **Heavy comment/spec-citation bloat across new Lua and C++**: per-block "Rule N.NN" tags (often misapplied), multi-paragraph spec essays in source, aspirational docstrings (`qt_process_start` doc lies, `client.lua` `in_flight` shape lies, `change_listeners` docstring stale). CLAUDE.md default is no comments; this branch went the other direction.
- **Helper protocol contract drift**: `not_studio` error code is emitted by `resolve_handle.py` but absent from `helper-protocol.md`'s closed set — callers cannot switch on it correctly.
- **DRY misses cluster around new tests and the resolve-bridge command pair** (duplicated `elem()` helper × 9 DRP tests, duplicated project/sequence/track scaffold × 6 tests, duplicated DRT roundtrip payload × 2 files, double-required `identity_ledger` under two aliases, duplicated opts-unpacking in DRP importer, triplicated Lua-callback-ref machinery across three C++ binding files, repeated `notify_*` boilerplate across 4 models).

## High Severity

### `build_project_xml` called without required `state` — every DRT export with ≥1 clip crashes
**File:** `src/lua/exporters/drt_writer.lua:753, 960-961`
**Evidence:** Definition is `local function build_project_xml(template, payload, dbids, state)`. Call site passes only 3 args. Inside, `fresh_uuid(0x06, state)` runs per clip and does `state.uuid_counter = state.uuid_counter + 1` → `attempt to index local 'state' (a nil value)`.
**Why it matters:** This silently un-implements the identity-marker carrier (FR-002) for every real export. No test catches it.
**Direction:** Pass `state` at the call site; add regression that exports a single-clip sequence and asserts `<BlobOwner>` contains the clip id.

### `Sequence.count_clips` references undefined `db`
**File:** `src/lua/models/sequence.lua:558-560`
**Evidence:** Function body uses `db.get_connection(...)` / `db.count(...)` but the file-level local is named `database` and no `db` is required inside the function. First call raises `attempt to index a nil value (global db)`.
**Direction:** Use the file-level `database` alias (or local-require like neighboring helpers).

### `t008_author.lua` spike has a Lua syntax error — has never run
**File:** `tools/resolve-helper/spikes/t008_author.lua:46-48`
**Evidence:** `path_utils.resolve_repo_root() .. "/",` (trailing comma terminates the table-field expression) followed by a line starting with `..`. `path_utils` is also never required.
**Why it matters:** Any claim that this spike produced a fixture or verified the round-trip is false. CLAUDE.md rule 0.1 / Warning #2.
**Direction:** Delete or fix and actually run.

### Systemic silent-fallback regressions across ~10 sites (the headline issue on this branch)
The same anti-pattern repeats in many forms. Treat as one finding; all sites should be revisited together.

- `src/lua/core/command_helper.lua` ~1099 — `pcall(Clip.get_sequence_id, ...)`; if it fails, `seq_id` stays nil and sequence watchers never see deletes. **The extra `db` arg passed is silently ignored by the callee** — the comment lies about what the code does. Resolve owner_sequence_id from the pre-mutation snapshot instead.
- `src/lua/core/path_utils.lua` `resolve_repo_root` — magic 6-level walk, then `return repo_root_candidate` with no diagnostic.
- `src/lua/models/track.lua:319-326` — `Track:save` captures `ok = stmt:exec()` then ignores it; `notify_track` fires on failed saves; always returns `true`. (Spot-check the other models touched by FU-8 for the same pattern.)
- `src/lua/models/sequence.lua:195-198` — bare `print("DEBUG: ... fps_num is nil!")` on a NOT NULL column. Should `assert`.
- `src/lua/ui/timeline/timeline_panel.lua:163-173` — stray `print("DEBUG: missing sequence fps metadata!...")` + silent nil-return on a path annotated "rule 1.14: required state".
- `src/lua/ui/timeline/timeline_panel.lua:189-191` — `state.get_playhead_position() or 0` masks a model bug.
- `src/lua/ui/timeline/timeline_ruler.lua:75-78` and `view/timeline_view_renderer.lua:1020-1024,1222-1224` — silent early-return when viewport not hydrated; parallel skips in renderer and ruler.
- `src/lua/importers/drp_binary.lua:898-907` — `duration < 1 → duration = 1` with a comment saying "don't let them reach the model layer". Exactly the patch-over-broken-model anti-pattern.
- `src/lua/importers/drp_binary.lua:474` — `duration <= 0` loosened to `duration < 0`; comment cites rule 2.13 while violating it.
- `src/lua/inspectable/clip.lua:110-114` — silently returns nil for `synced_at <= 0` when `ClipGrade.upsert` already asserts `>= 0`. Read path hides write-side bugs.
- `src/lua/inspectable/sequence.lua:162` — comment literally says "Fallback for generic metadata fields".
- `tests/test_braw_authoritative_counts.lua:46` — `os.getenv('JVE_REPO_ROOT') or '.'`.
- `tools/resolve-helper/resolve_handle.py:38-53` — `ImportError` swallowed into `_terminal_error` so the helper accepts verbs forever and replies the same error per request. Should raise at bootstrap.

**Direction:** Audit every site. Either assert the invariant or surface the failure to the caller. No `or default`, no `if ok then`, no "force to N".

### Helper protocol: `not_studio` error code outside the closed set
**File:** `tools/resolve-helper/resolve_handle.py:73-79` vs `specs/023-resolve-color-bridge/contracts/helper-protocol.md`
**Evidence:** `_terminal_error = ("not_studio", ...)` but the contract's closed error-code set does not list it.
**Why it matters:** FR-010 closed-set semantics mean JVE-side dispatch is undefined for unknown codes.
**Direction:** Add `not_studio` to the contract or fold under `resolve_api_error` with a discriminating message. Pick one.

### Test verifies source code via regex instead of behavior
**File:** `tests/test_keyboard_tab_panel_containment.lua:20-37`
**Evidence:** `src:find('if key == KEY.Tab or key == KEY.Backtab then')`, `tab_branch:find('return true%s+end')`.
**Why it matters:** This is exactly the "test code, not behavior" pattern CLAUDE.md flags. The test had to be rewritten this branch precisely because it pins formatting. Worthless as a regression signal.
**Direction:** Replace with a black-box test that injects Tab via `keyboard_shortcuts.handle_key()` and asserts the panel does not escape.

## Medium Severity

### Inspectable / inspector reaches across abstractions (multiple sites)
- `src/lua/inspectable/clip.lua:105-117` — per-poll `ClipGrade.load()` SQL on three string fields; no cache despite `grades_changed` signal being wired (and see sequence_monitor below).
- `src/lua/ui/sequence_monitor.lua:986-1006` — per-frame `pull_for_clip` → `ClipGrade.load` on the 60Hz `show_frame` path. `_grades_changed_id` is already wired but unused for cache invalidation; the rationale comment undercuts itself ("defer until profile shows it").
- `src/lua/inspectable/sequence.lua:64-71` — `COLUMN_TO_MODEL_FIELD` adds a third schema dialect on top of two existing ones. Patches over the "four layers of schema drift" rather than fixing it; either return DB columns verbatim and rename at one boundary, or rename the columns.

**Direction:** Cache CDL keyed by `clip_id`, invalidate on `grades_changed` + `_on_show_gap`. Lift grade fields into the existing `_property_cache`. Consolidate column/field naming at a single boundary.

### Double-required `identity_ledger` under two aliases + dead `wire_decode` require
**File:** `src/lua/core/commands/sync_grades_from_resolve.lua:24-30`, `sync_edits_from_resolve.lua:18-25`
**Evidence:** Both files do `local ledger = require(...)` AND `local identity_ledger = require(...)` for the same module; usage mixes the two. `sync_grades_from_resolve.lua:25` also has an unused `local wire = require('core.resolve_bridge.wire_decode')`.
**Direction:** Pick one alias (`identity_ledger`); drop the dead require.

### `mkdir -p` via raw `os.execute` instead of Qt FFI
**File:** `src/lua/core/commands/send_to_resolve.lua:42-57` (`out_path_for_export`)
**Evidence:** `os.execute(string.format("mkdir -p %s", q_dir))` — shell-out with hand-rolled quoting, return value discarded. The "Rule 2.32" comment is misapplied (2.32 is about tests).
**Why it matters:** Rules 1.10/2.18 — Lua talks to OS via Qt FFI, not shell. Failed mkdir is silently ignored.
**Direction:** Use a Qt filesystem binding (add one if absent) and assert on success.

### `project_open` pidlock has a real race + shells out for PID
**File:** `src/lua/core/project_open.lua`
**Evidence:** Pidlock is written *after* `db_module.set_path` succeeds; `another_jve_owns_project` returns false when the pidlock is missing — a peer JVE between `set_path` and pidlock-write is invisible, and a second instance launched in that window will delete the SHM and corrupt the peer's WAL. `our_pid` shells out (`/bin/ps -o ppid= -p $$`) for a value Qt already knows.
**Direction:** Write pidlock *before* `set_path` (remove on failure). Add `qt_application_pid()` / `qt_pid_alive()` one-line FFI; drop the `ps`/`kill -0` shell-outs.

### `command_manager.begin/end_undo_group` not exception-symmetric
**File:** `src/lua/core/commands/sync_edits_from_resolve.lua:944-949`
**Evidence:** Four phase runs between `begin_undo_group` and `end_undo_group`; any assert in `run_phase_*` leaves the group open and poisons subsequent commands.
**Direction:** Either wrap the phase dispatch in pcall-and-rethrow that ends the group before re-raising, or make `end_undo_group` safe to call on a poisoned group.

### `keyboard_shortcut_registry.handle_key_event` return semantic flipped
**File:** `src/lua/core/keyboard_shortcut_registry.lua:handle_key_event`
**Evidence:** Was `return true` (matched). Now `return result and result.success or false` (matched-and-succeeded). Callers in `keyboard_shortcuts.lua` use this to decide whether to consume the event — a command that returns `success=false` (no-op precondition) will now leak the key to native Qt.
**Direction:** Either keep the matched semantic and surface command failure separately, or audit every caller for the new semantic.

### Hard-coded single-clip `FieldsBlob` in `author_a005_compatible` masquerades as general
**File:** `src/lua/exporters/drt_writer.lua:352-358, 832-838`
**Evidence:** `SM2_MP_TIMELINE_CLIP_FIELDS_BLOB_SINGLE_CLIP` is borrowed verbatim from a one-clip reference DRP and substituted regardless of payload clip count. `compute_emit_order` walks all clips, suggesting the writer pretends to handle N.
**Direction:** Assert `#clips == 1` in `author_a005_compatible` (quarantined to A005 anyway), or synthesize the FieldsBlob from payload.

### `setGrade` is push-based but comments claim pull-based (MVC violation)
**File:** `src/cpu_video_surface.cpp:60-65`
**Evidence:** Comment cites "Rule 3.0: Park mode must be pull-based" but body is `void setGrade(...) { m_cdl = ...; regrade(); }` — caller pushes; nothing re-asks the model.
**Direction:** Give the surface a `std::function<emp::CdlParams()>` it invokes at the top of `regrade()`, OR honestly document this as a push contract on the hot path. Don't comment-paper-over.

### DRY: shared test scaffolds duplicated across many tests
- DRP tests: identical `elem()` / `wrap_clips()` / `text()` XML helper duplicated in 9 files (`tests/test_drp_*.lua`). This branch widened the helper signature in all 9 simultaneously — clear signal of missed centralization.
- Six command tests (`test_insert_command.lua`, `test_overwrite.lua`, `test_add_clips_to_sequence.lua`, `test_trim_head_tail.lua`, `test_relink_clips_integration.lua`, `test_move_to_bin.lua`) repeat the same Project + Sequence + Track scaffolding paragraph introduced by the SQL-isolation refactor.
- DRT roundtrip payload (`FR_23976`, `TC_1H_AT_23976`, identical UUIDs) duplicated across `tests/integration/test_drt_writer_file_roundtrip.lua` and `test_drt_round_trip_validator.lua`.
- Two near-identical UUID-dedup tests (`test_drp_uuid_dedup.lua` + `test_drp_uuid_dedup_full.lua`) — the `_full` variant's success print even says `test_drp_uuid_dedup.lua passed`.
- DRP importer: `opts.*` 4-line unpack duplicated in `parse_sequence` and `parse_resolve_tracks`.

**Direction:** Move `elem()`/`wrap_clips()` into `tests/drp_test_helpers.lua`; add `test_env.scaffold_project{...}` and the 3-clip DRT payload to a shared helper. Factor a single `assert_uuid_dedup(fixture, opts)`. Pass `opts` through unchanged in the DRP importer.

### Notification boilerplate duplicated across models
**File:** `src/lua/models/{clip,sequence,track,media}.lua`
**Evidence:** Each `save`/`delete` inlines `require("core.watchers").notify_*(...)` with an identical "FU-8" comment.
**Direction:** Fold into a single `persist_and_notify(entity, kind)` helper or have `core.watchers` expose one `notify(kind, id, opts)` so future API changes touch one symbol.

### `ClipGrade` 16 hand-bound positional parameters
**File:** `src/lua/models/clip_grade.lua:101-117`
**Evidence:** `stmt:bind_value(2..16, ...)` plus a for-loop binding nil for indices 2..11 in the else branch.
**Why it matters:** Off-by-one between INSERT column order and bind order silently corrupts grades.
**Direction:** Drive both the column list and the binds from `CDL_CHANNELS` + a small constant for trailing columns.

### Test mutates production module constants to drive a failure path
**File:** `tests/integration/test_drt_round_trip_validator.lua:165-196`
**Evidence:** `canon.FRAME = 99 ... canon.FRAME = orig`. Encodes that the validator reads `canon.FRAME`; also leaks state if the assertion in between throws.
**Direction:** Drive drift through the writer (produce a .drt with a different marker frame/duration and feed it to the validator). Test bytes, not Lua tables.

### `qt_process_start` doc-comment is aspirational
**File:** `src/lua/qt_bindings/process_bindings.cpp:268-289`
**Evidence:** Header says `→ ok, err`. Body never returns `err`. QProcess::start is void; FailedToStart only arrives async via `errorOccurred`.
**Direction:** Update the doc to reflect async-error reality (failures arrive via `error_cb`) or remove the line.

### `parse_resolve_markers` regex over raw XML duplicates a parser
**File:** `src/lua/importers/drp_importer.lua:1969-2000`
**Evidence:** Scans raw XML with `gmatch("<Sm2TiItemLockableBlob.-</Sm2TiItemLockableBlob>")` because `find_all_elements` doesn't recurse into `LockableBlobMap`. Two text representations for the same data.
**Direction:** Fix `find_all_elements`/`qt_xml_parse` to recurse into `LockableBlobMap`, or document why raw-string is structurally safe forever (hex-only content).

### `version_string()` re-bootstraps Resolve handle inconsistently with `acquire()`
**File:** `tools/resolve-helper/resolve_handle.py:96-111`
**Evidence:** `acquire()` returns `("error", code, msg)` on `resolve is None`; `version_string` raises. Two shapes for the same failure mode.
**Direction:** Have `version_string` call `acquire()` and pull `GetVersionString()` off the handle.

### Hardcoded macOS Resolve paths in helper as silent defaults
**File:** `tools/resolve-helper/resolve_handle.py:21-28`
**Evidence:** `DEFAULT_SCRIPT_API`/`DEFAULT_SCRIPT_LIB` point at macOS-only paths. Non-mac hosts get a confusing ImportError instead of "env not configured".
**Direction:** Require the env vars (assert on missing) or have the supervisor own platform-specific resolution.

### Unknown EDL lines silently ignored in CDL parser
**File:** `tools/resolve-helper/cdl_edl.py:378-379`
**Evidence:** Any `*ASC_*` block not matching a known handler is treated as a comment. If Resolve adds `*ASC_SOP_HDR`, the parser misreads the file as fully primary.
**Direction:** Warn (or error) on unknown `*ASC_*` lines.

### Tooltip binding registered under `WIDGET` but accepts `QAction`
**File:** `src/lua/qt_bindings/misc_bindings.cpp:518-534`
**Evidence:** Registered as `qt_constants.WIDGET.SET_TOOLTIP`; body branches on `qobject_cast<QAction*>`.
**Direction:** Either restrict to `QWidget` + add `ACTION.SET_TOOLTIP`, or rename to `OBJECT.SET_TOOLTIP`. Match the contract.

### Inspector watcher re-entrancy / uninstall ordering is fragile
**File:** `src/lua/ui/inspector/change_listeners.lua:51-71, 108-128`
**Evidence:** `on_project_changed` calls `update_watches` *before* clearing `active_inspectables`; `uninstall` calls `update_watches` but doesn't empty the list — the "passing empty selection effectively unwatches everything" comment is wishful.
**Direction:** Have `uninstall` iterate `_watcher_tokens` directly. Clear inspectables first in `on_project_changed`.

### Layout reaches across modules for shutdown
**File:** `src/lua/ui/layout.lua:799-806`
**Evidence:** Inline `require("core.project_open").release_current_pidlock()` in a layout shutdown hook. `layout.lua` is accreting shutdown side effects (`media_status`, `helper_supervisor`, `project_open`).
**Direction:** Centralize shutdown ordering in `core.shutdown`; modules that created the resource own its release.

### `synced_at` typed as raw INTEGER in metadata schema → user sees epoch
**File:** `src/lua/ui/metadata_schemas.lua:148-150`
**Direction:** Add a formatter or store/display a localized timestamp string. Confirm spec intent.

## Low Severity / Nits

### `command_manager.execute_with_recording_ceremony` still mixes levels (extraction incomplete)
`src/lua/core/command_manager.lua` — Continue the extraction: `route_stack`, `open_or_join_transaction`, `capture_pre_state`, `dispatch_and_normalize`, `finalize`. Top-level body should be ~10 lines.

### `client.lua` `in_flight` slot comment lies about `timer_id`
`src/lua/core/resolve_bridge/client.lua:56` vs `:181` — comment documents `timer_id` field; construction omits it. Either store the handle or fix the comment.

### `payload_builder.lua` leaks the `author_a005_compatible` name
`src/lua/core/resolve_bridge/payload_builder.lua:88` — Caller shouldn't know about A005 quarantine. Rename to `drt_writer.author` or wrap.

### `bridge_completion.lua` signal vs on_complete ordering is undocumented
`src/lua/core/commands/bridge_completion.lua:147-149` — a throwing signal subscriber silently skips `on_complete`. Pick a contract and document/test it.

### `identity_ledger.find_direct` vestigial 3-line if/return
`src/lua/core/resolve_bridge/identity_ledger.lua:197-201` — collapses to one return.

### `author_a005_compatible` validates media before asserting payload shape; bare `-- ...` stub remains
`src/lua/exporters/drt_writer.lua:903-1003`. Two stacked doc-comment blocks read like a rebase artifact.

### `build_media_timemap_ba` magic constant `1/24000` only valid at 23.976
`src/lua/exporters/drt_writer.lua:259-289` — accepts `media_native_rate` then asserts it equals one value. Either hard-bind or accept `(numerator,denominator)`.

### Triplicated Lua-callback-ref / single-state machinery across C++ bindings
`process_bindings.cpp` + `local_socket_bindings.cpp` + `fs_watcher_bindings.cpp` — same `s_*_L` static state, `invoke_cb`, ref management. Lift into a shared `jve_lua_callback.h`.

### `require_slot` returns past `luaL_error` longjmp
`src/lua/qt_bindings/process_bindings.cpp:260-266` — mark the error path `[[noreturn]]` and add `JVE_ASSERT(slot)` after the call so make scan stays clean.

### `Destroy` blocks main thread up to 1s on kill with no diagnostic
`src/lua/qt_bindings/process_bindings.cpp:386-408` — log when `waitForFinished` returns false.

### `helper_fixture.lua` log_level mismatch
`tests/binding/helper_fixture.lua:35` — `DEBUG` contradicts the module's own docstring and `_helper_transport.lua`'s banner (`WARNING`). Pick one.

### `drt_spike_fixture.out_path` returns `.drp` for `.drt` output
`tests/helpers/drt_spike_fixture.lua:36-41` — rename to `.drt`.

### Stub conditionally executes real Cancel command
`tests/test_keyboard_focus_routing.lua:152-156` — hybrid stub. Either use the real `command_manager` or keep the stub pure.

### `tests/test_env.lua` strip-stub trio is sprawling
Three overlapping helpers (`attach_strip_to_state_mock`, `make_strip_stub`, `install_displayed_tab_stub`) ~130 lines. Migrate legacy callers and delete `attach_strip_to_state_mock`. Mid-file orphan docstring at 428-432 should anchor to `make_strip_stub`.

### `test_schema_migration_015.lua` no longer pins a version
Renames itself implicitly as `SCHEMA_VERSION` moves. Either pin to V10 (it's a migration test) or rename to a sync_mode/patches invariant test.

### Synthetic `DbId` placeholders in DRP tests
`'v1'`, `'test-video-id'`, `'v-' .. clip_name` — trivial values that won't catch length/encoding bugs in identity flow. Use realistic 18-hex DbIds from real fixtures.

### Inconsistent step numbering across e2e test
`tests/binding/test_e2e_retime_relink.lua` — `[6/6]` then `[7/7]` then `[8/8]`. Pick one denominator or drop the fraction.

### Comment/spec-citation bloat (CLAUDE.md default is no comments)
Spread across `drt_writer.lua`, `send_to_resolve.lua`, `bridge_completion.lua`, `sync_grades_from_resolve.lua`, `cpu_video_surface.{cpp,h}`, `cdl_edl.py`, `clip_grade.lua`, `clip_marker.lua`. Per-block "Rule N.NN" tags are often misapplied (e.g. "Rule 2.32" used in `send_to_resolve.lua:52` for shell quoting; 2.32 is about regression tests). `change_listeners.lua` top docstring still describes a `content_changed` handler that was removed. `database.lua` `select_rows` carries a multi-line history comment. `cpu_video_surface.{cpp,h}` cites `T032 / FR-016` which decay once 023 ships. `layout.lua:416-426` has an 8-line aspirational bundle-deploy plan. Move rationale to spec/commit messages; keep one-line non-obvious-decision notes.

### `VIRTUAL_AUDIO_TRACK_BA_MONO_A1` carries "until #14 lands" marker with no tracker
`src/lua/exporters/drt_writer.lua:294-296`.

### Test-only helpers inflate `timeline_panel.lua` by ~300 lines
Three TEST-ONLY clip-geometry helpers appended at lines 3683-3979 also duplicate clip→widget resolution three times. Extract a private `_resolve_clip_widget_geometry(clip_id)` and move helpers to `ui.timeline.timeline_panel_test_helpers`.

### Mixed tab/space indent + trailing whitespace in new `command_helper.lua` block, and `inspectable/sequence.lua:134` assert message lost "be" ("must integer frames")
Clean-build / actionable-assert hygiene.

### `resolve_handle.py` unused `self._log`, inconsistent indentation on a few returns
`tools/resolve-helper/resolve_handle.py:33, 84-85, 109` — run black/ruff.

### `helper-protocol.md` `read_timeline` row is one mega-paragraph
Break into sub-bullets (Discriminator / Partial source / Track identity / `timeline_integer_rate` / Caller obligations).

### Pinned hex constants in DRT shape tests are unnamed
`tests/binding/test_drt_writer_ti_video_clip_shape.lua`, `test_drt_writer_media_pool_population.lua` — acceptable given byte-equality requirement and inline provenance comments, but extracting to `tests/helpers/resolve_pinned_bytes.lua` would improve diffability.

## Areas That Looked Clean
- `identity_ledger.reconcile` and the phase-pipeline state machine in `sync_edits_from_resolve` (core dispatch).
- `client.lua` malformed-line / unknown-id handling (appropriately fail-loud).
- `clip_marker.lua` validation invariants (color whitelist, all-required-fields).
- DRP `drp_binary.lua` protobuf walk helpers (`read_pb_tag`, `read_pb_len_slice`, `expect_tag`) and the three-state `unwrap_marker_blob`.
- `selection_binding.lua` diff (trivial require + call).
- `qt_bindings.cpp` wiring (mechanical three `register_*` calls + tooltip entry).
- `_helper_transport.lua`, `drt_spike_fixture.lua`, and the dedicated DRT writer shape/extents/media-pool tests (good provenance pinning).
- `menus.xml`, `keymaps/default.jvekeys`, `github_issue_creator.lua` repo-name fix.
- Smoke runner `keymap_exempt.py` and `tests/unit/test_timeline_media_buffer.cpp` (mechanical updates only).

## Open Questions for Joe
- DRP marker `duration < 1`: is this a protobuf-decode bug, a model invariant (`duration >= 1`), or real data? The current "force to 1" hides whichever it is.
- BtAudioInfo `duration <= 0` → `< 0` loosening: do any real DRPs contain 0-sample audio refs, or should this revert to the original `<= 0 return nil`?
- `keyboard_shortcut_registry.handle_key_event` new return semantic: was the flip from "matched" to "matched-and-succeeded" intentional for every caller, or only for the Escape/Cancel path?
- `not_studio` helper error: should it be a contract-level code, or fold under `resolve_api_error`?
- `setGrade` MVC: is push-based on the hot path the intended contract, or should the surface own the pull? (The comment claims pull but the code is push.)
- `synced_at` metadata field: how should it render to the user — localized timestamp string, or is showing the epoch integer intentional?
- `test_schema_migration_015.lua`: is this still meant to be a V10-specific migration regression, or a current-schema invariant test?
- DRT writer single-clip `FieldsBlob`: is `author_a005_compatible` permanently quarantined to single-clip A005 (assert it), or is multi-clip on the near-term roadmap (synthesize the blob)?
- DRP `LockableBlobMap` parsing: is the hex-only content guarantee permanent, or should `find_all_elements` learn to recurse?
