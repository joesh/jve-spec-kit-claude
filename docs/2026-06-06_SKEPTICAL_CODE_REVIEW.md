# Code Review — branch `023-resolve-color-bridge`

_Date: 2026-06-06. Multi-agent skeptical review (8 reviewers + adversarial verifiers + synthesis, 18 agents total). 83/92 raw findings survived verification._

## EXECUTIVE SUMMARY

This branch lands the Resolve color bridge: Lua client + supervisor, Python helper, DRT writer, schema V12, plus DRP-importer marker work. Five systemic issues dominate:

1. **Silent-failure / fallback pattern is widespread** despite CLAUDE.md 1.14/2.13 being explicit. Helper-side (`version_string → "unavailable"`, bare-except dispatch, `or {}` on marker fetch, sticky ImportError). JVE-side (`or ""` on custom_data, `db = db or get_connection()`, `media_uuid` truthy-skip drops clips from export, `pull_for_clip(nil)→nil` *test-canonized*, EMP `content_hash` collapses 3 errors into nil).
2. **DRT writer is a spike masquerading as the canonical exporter**: 5 borrowed FieldsBlob hex blobs (one with a dangling 1235499f DbId), magic-number constants the author admits aren't decoded (`CurrentSelectorIdx = 1083179008`, `epsilon = 1/24000`), and a hard 23.976 native_rate assert that gates all real media. ABSOLUTE PROHIBITION "Patching over a broken model".
3. **Same-PR DRY contradiction**: this PR adds `database.select_rows` with a docstring saying "new readers should use it" — then ships 4 new readers that hand-roll the boilerplate it was created to eliminate. Plus 25× Resolve-API try/except boilerplate in Python, 2 copies of wire-track decoding, 3 copies of in-flight drain, 2 copies of ledger-walk-for-sequence.
4. **C++ binding twins**: `process_bindings.cpp` and `local_socket_bindings.cpp` are mechanical copy-paste of identical Slot/registry/callback machinery (~200 lines each). `CdlParams` declared in C++ header AND Metal shader source, guarded only by static_asserts that don't catch semantic drift.
5. **Lifecycle / fail-fast holes around long-lived state**: project-switch releases pidlock *before* opening the new project (can leave zero locks); helper `serve()` continues on bare-Exception dispatch crashes; `qt_process_pid` returns 0 silently when not running.

---

## Engineering-rules violations

### HIGH

- **src/lua/core/resolve_bridge/helper_supervisor.lua:147** — `wait_for_bind` shells out `sleep` per poll
  Forks `/bin/sh` + `sleep` up to 200× per 5s spawn on the Qt main thread. The supervisor is supposed to be Qt-event-driven; this is the LuaJIT-lacks-usleep workaround in disguise.
  Fix: add `qt_thread_msleep` FFI or restructure spawn as async timer chain.

- **src/lua/core/resolve_bridge/payload_builder.lua:181** — Clip with no media silently skipped from `media_refs`
  `if media_uuid and not media_seen[media_uuid] then` — clip is already emitted into the track's clips list at L68-80, so DRT ships a clip referencing nothing. Rule 1.14/2.13.
  Fix: `assert(media_uuid, "payload_builder: clip <id> has no media link")`.

- **src/lua/importers/drp_importer.lua:1577-1586** — Missing Sm2Ti DbId silently coerced to nil, fresh UUID minted
  Comment explicitly says "Real Resolve exports carry one on every timeline clip" (invariant), but code defends against `""` and lets `Clip.create` mint. Markers attached via `BlobOwner` map then orphan.
  Fix: assert; fix synthetic fixtures.

- **src/lua/importers/drp_binary.lua:890-897 / clip_marker.lua:46 / drt_binary.lua:368** — Three different duration rules
  Decoder accepts anything tonumber-able and floors, model asserts `>= 1`, exporter asserts `>= 0`. Resolve marker with duration 0 decodes fine then crashes ClipMarker.new mid-import.
  Fix: one rule (`>= 1`) enforced at the decoder with marker-identifying context.

- **src/lua/qt_bindings/emp_bindings.cpp** (`lua_emp_media_content_hash`) — Stat failure, empty file, hash==0 all collapse to nil
  Three distinct conditions return the same "no fingerprint available" sentinel. Caller can't distinguish missing file from hash collision.
  Fix: `(nil, err)` tuples; assert on hash==0 (it's a ComputeContentHash bug).

- **tools/resolve-helper/resolve_handle.py:96-102** — `version_string()` catches bare Exception, returns `"unavailable"`
  Direct rule 2.13. Shipped in every ping; masks Resolve-API drift as a plausible version string.

- **tools/resolve-helper/verbs.py:465** — `markers = item.GetMarkers() or {}`
  The exact `or {}` pattern in ABSOLUTE PROHIBITIONS. Docstring above even cites a rule against silent first-wins while doing this.

- **tools/resolve-helper/helper.py:152-167** — Dispatch loop catches bare Exception, synthesizes envelope, *keeps serving*
  Verb crash poisons subsequent state. Comment claims "rule 2.32 - no silent failure" while being silent at the process level. Should re-raise so supervisor respawns.

- **tools/resolve-helper/resolve_handle.py:46-53** — ImportError parked as sticky `_terminal_error`
  Environment misconfig should fail at process start, not turn every verb into resolve_api_error forever.

- **tests/test_view_grade_pull.lua:124-128** — Test canonizes silent-nil fallback for nil/empty clip_id
  Pins the fallback in production. Gap-frame caller should not invoke `pull_for_clip` at all; the wrong layer is being asked to swallow the case.
  Fix: replace with `expect_assert`; move "gap → no grade" rule to render path.

- **src/lua/core/project_open.lua:124-157** — Pidlock released *before* `set_path` succeeds
  If `set_path` fails after `release_current_pidlock()`, no lock is held; sibling JVE that opens prior project sees no pidlock, may rm live SHM.
  Fix: release prior pidlock only after new `set_path` + `write_pidlock` both succeed.

### MEDIUM

- **src/lua/core/resolve_bridge/client.lua:100-102** — Unknown correlation id is logged + dropped silently; the malformed-line branch correctly fail-all-and-closes. Asymmetric helper-desync handling.
- **src/lua/core/resolve_bridge/identity_ledger.lua:22, 121** — `if stmt:exec() and stmt:next() then` collapses driver error into "no row"; module's own upsert at L95 shows the correct `assert(ok, ...)` pattern.
- **src/lua/core/commands/bridge_completion.lua:142-149** — `Signals.emit` runs *before* counter bump and `on_complete`; throwing subscriber starves both. Counter is the contract marker per the file's own docstring.
- **src/lua/exporters/drt_writer.lua:114-136** — `fresh_uuid` is hand-rolled with arithmetic that can collide; no test asserts per-export distinctness across the 21+ seed slots.
- **src/lua/exporters/drt_writer.lua:964-988** — 5× shell-out (mktemp / mkdir / zip) with `cd && zip` and stderr discarded; use a Qt zip binding.
- **src/lua/core/commands/send_to_resolve.lua:48-52** — `os.execute("mkdir -p %q")` with Lua quoting (not shell quoting) and return code ignored.
- **src/lua/qt_bindings/process_bindings.cpp:211-216** — `qt_process_pid` returns 0 silently when not running; should be `(nil, "not_running")`.
- **src/lua/importers/drp_binary.lua:899** — `custom_data or ""` after a comment explicitly invoking 2.13; identity round-trip silently breaks.
- **src/lua/models/clip_grade.lua:144-150** — `db = db or database.get_connection()` while `upsert()` in the same module requires `db`. Pick one.
- **tools/resolve-helper/verbs.py:656-657** — Audio items silently dropped from `read_timeline` with no caller-visible counter; JVE-side deletion detection will false-positive.

### LOW

- **src/lua/core/project_open.lua:59-62** — `rc == 0 or rc == true` accepts two return contracts; we're LuaJIT-only; unknown exit codes silently report "dead".
- **src/lua/core/project_open.lua:85-90** — `release_current_pidlock` log-warns and clears state on `os.remove` failure; next session inherits phantom alive-pid.
- **src/lua/core/commands/bridge_completion.lua:140** — `tostring(message or "")` directly under a docstring that bans `or` fallbacks.
- **src/lua/models/clip_grade.lua:153-156** — `if not stmt:exec() or not stmt:next() then return nil` conflates query failure with no-row.
- **src/lua/qt_bindings/process_bindings.cpp:138-160** — `qt_process_start` always returns `ok=true`; QProcess::start is async/void; docstring claims `ok, err`.
- **src/lua/qt_bindings/process_bindings.cpp:171-180** — `QProcess::state()` switch has no default; returns 1 with empty stack if a future enum value appears.
- **src/lua/qt_bindings/local_socket_bindings.cpp:174-180** — `read_all` empty-byte-array indistinguishable from disconnect.
- **src/lua/importers/drp_importer.lua:1963** — Comment cites rule 2.32 (which is "New Codepaths Require Tests") to justify surfacing errors; wrong citation, appears in 3 places.
- **src/lua/exporters/drt_writer.lua:309-331** — `build_media_timemap_ba` admits the short form silently broke Resolve and the long form "unblocks the spike" without decoding; no round-trip test.
- **src/lua/exporters/drt_writer.lua:25** — Module-level `_uuid_counter` makes writer non-reentrant.

---

## Architectural concerns

### HIGH

- **src/lua/exporters/drt_writer.lua:386-394, 352-367, 333-336, 286-289** — Five FieldsBlob hex constants borrowed verbatim
  TI_VIDEO_CLIP_FIELDS_BLOB embeds a hard-coded reference to a long-gone audio clip's DbId (`1235499f-...`); every export ships that dangling pointer. Tracked in TODOs but still in M.author. "Patching over a broken model" prohibition.
  Fix: synthesize from payload via existing drt_binary encoders; at minimum sweep the dangling UUID per-export.

- **src/lua/exporters/drt_writer.lua:283-330, 605-672, 100-103, 870-879** — Writer wired to A005-specific media
  `build_media_timemap_ba` asserts `math.abs(media_native_rate - 24000/1001) < 1e-6`. Other asserts gate on `.mp4/.mov`, duration. `M.author` advertises generality the implementation doesn't provide.
  Fix: rename to `M.author_a005_compatible` and gate at entry, or decode the format properly.

- **src/lua/exporters/drt_writer.lua:308-330, 489-493** — Magic-number patches with admitted-not-decoded meaning
  `CurrentSelectorIdx = 1083179008` (= `0x40914000` float ≈ 4.539) and a 41-byte MediaTimemapBA blob with "format is otherwise opaque — full decode is deferred". ABSOLUTE PROHIBITION "Lazy implementations that skip understanding".
  Fix: decode; until decoded, hold writer behind experimental flag.

- **src/lua/core/commands/connect_to_resolve_project.lua:209-226** — `match_by_marker` silently last-write-wins on duplicate `jve_guid` markers
  Position-collision branch right above (L197) asserts loudly. Inconsistent fail-fast policy for the same class of "two Resolve items claim one JVE identity" event.

- **src/cpu_video_surface.cpp:42-56** — CDL baked into `m_image` in place; no ungraded source preserved
  `setGrade` skips `update()` and relies on next `setFrame` push. In park mode there is no push, so grade changes leave stale pixels. CLAUDE.md MVC rule: park mode MUST be pull-based. GPU path is correct; CPU path codifies the anti-pattern.
  Fix: keep `m_imageSource`; `setGrade` calls private `regrade()` + `update()`.

### MEDIUM

- **src/lua/core/resolve_bridge/client.lua:34-39** — `mint_correlation_id` = `jve-<os.time()>-<counter-from-1>`; parallel JVE sessions started same second produce identical ids. Add pid (supervisor pid-protects the socket path for exactly this reason).
- **src/lua/core/commands/connect_to_resolve_project.lua:332-350, 367-399** — Two hand-rolled async-chain pyramids (`read_identities`→`read_timeline` nested; `stamp_each` manual recursive `step()`). Lift `request_chain.serial` / `request_chain.each`.
- **src/lua/importers/drp_importer.lua:2089-2106** — `project.xml` re-read off disk and string-grepped for marker blobs even though it's already parsed at L1996. Comment blames `find_all_elements` not traversing into `LockableBlobMap` — fix that, don't bypass.
- **src/lua/importers/drp_importer.lua:2087-2106 + src/lua/importers/importer_core.lua:907-920** — Marker attachment uses ad-hoc `clip_id` distinct from model column `id`; split across two files with no asserts tying them.
- **src/lua/qt_bindings/process_bindings.cpp + local_socket_bindings.cpp + fs_watcher_bindings.cpp** — Per-file `static lua_State* s_*_L` captured-on-last-call; callbacks silently no-op if last assignment was unexpected. Capture once at `registerQtBindings`, assert on fire.
- **src/gpu_video_surface.mm:114-124 + emp_cdl.h:28-37** — `CdlUniform` (MSL) is a hand-typed parallel declaration of `emp::CdlParams`; guarded only by 5 static_asserts that miss semantic drift (rename, bitfield).
- **src/editor_media_platform/src/emp_cdl.cpp:29-50 + gpu_video_surface.mm:130-141** — CDL math (SOP/pow/luma/sat) implemented twice with header comment saying "any change here MUST also land in the shader source"; no GPU/CPU conformance test.
- **src/lua/schema.sql:863-877 + clip_grade.lua:21-58** — CDL all-or-none invariant enforced only in Lua; schema comment claims "SQL can't express that cleanly" which is false (`(slope_r IS NULL) = (slope_g IS NULL) AND ...`).
- **src/lua/core/project_open.lua:36-49** — `our_pid()` shells out `ps -o ppid= -p $$` per pidlock op; one-line `qt_get_pid()` FFI fixes it.
- **tools/resolve-helper/verbs.py:733-800 vs 249-271** — `verb_stamp_identity_marker` reimplements `_stamp_marker_safe`'s check-then-add algorithm with different envelopes.

### LOW

- **src/lua/core/commands/sync_grades_from_resolve.lua:42-49** — Raw `DELETE FROM clip_grade WHERE clip_id = ?` SQL when ClipGrade model owns its table everywhere else. Add `ClipGrade.delete`.
- **src/lua/schema.sql:884-890** — `resolve_bridge_link.resolve_item_id` has index but not UNIQUE despite documented bidirectional invariant.
- **tools/resolve-helper/helper.py:53-58** — `bind_socket` blindly `unlink`s any existing socket file with no `connect()` probe.
- **src/lua/importers/drp_binary.lua:822-827** — `MARKER_COLOR_VALUES` shared bidirectional map lives in importer module; exporter takes cross-module dep. Lift to `models/resolve_marker_color.lua`.

---

## DRY hotspots

### HIGH

- **src/lua/models/clip_grade.lua:131-138 / clip_marker.lua:104-133 / sequence.lua:543-559 / media.lua:567-577** — Same PR adds `database.select_rows` with docstring saying "new readers should use it"; same PR ships 4 new readers that hand-roll prepare/bind/exec/next/finalize. Self-contradiction.
- **src/lua/core/commands/sync_grades_from_resolve.lua:87-128 vs sync_edits_from_resolve.lua:387-413** — Two near-identical "walk ledger-for-sequence, partition against seen-set, emit per missing row" with same SELECT shape. Lift to `identity_ledger.iter_links_for_sequence`.
- **src/lua/core/commands/connect_to_resolve_project.lua:89, 178-207 vs sync_edits_from_resolve.lua:76, 105-167** — Wire-track-type maps are inverses defined twice; same `kind ∈ {media, non_media}` assert + non_media skip+log duplicated. Lift to `core/resolve_bridge/wire_decode.lua`.
- **src/lua/exporters/drt_writer.lua:65-86, 940-949** — `DBID_SLOTS` pins `{ref, seed}` per slot; `M.author()` redeclares the entire seed→hex mapping a second time as a local `seeds = {...}` and iterates it.
- **src/lua/qt_bindings/process_bindings.cpp vs local_socket_bindings.cpp** — Identical Slot/registry/`invoke_cb`/`set_callback_slot`/destroy machinery, ~200 lines each. Templated `CallbackSlot<QtT, EnumT>` or shared `lua_cb_slot.h`.
- **tools/resolve-helper/verbs.py:200-1083** — `try: X(); except Exception as exc: raise RuntimeError(f"X raised: {exc}")` repeated ~25× across all Resolve API calls. `_api(label, fn, *args)` helper would collapse ~150 lines.

### MEDIUM

- **src/lua/models/sequence.lua + media.lua + project.lua + track.lua + clip.lua** — `SELECT COUNT(*)` re-implemented in every model with the same 9-line ritual; this PR adds two more without lifting (`Sequence.count_clips`, `Media.count`). `database.count(conn, sql, params)` helper.
- **src/lua/core/resolve_bridge/client.lua:70-75, 126-133, 226-230** — Three copies of "drain in_flight with structured error". `fail_all_in_flight` exists but disconnected_cb and `close()` don't call it.
- **src/lua/importers/drp_binary.lua:980-1015** — `unwrap_marker_blob` peeks byte-9 == 0x81 then calls `decode_fields_blob_bytes` which redoes the same check. Encode wire format once via typed error return.
- **tools/resolve-helper/verbs.py:837-862 vs 195-220, 223-239** — `verb_delete_timeline` walks `GetTimelineByIndex 1..N` with its own try/except instead of factoring `_find_timeline_by_uid` used by the other two sites.
- **tools/resolve-helper/ledger.py:77-83 vs verbs.py:688-702** — `change_token` validation duplicated; ledger version doesn't reject `bool` (would silently corrupt cache key with `'True'`), verbs version does.

### LOW

- **src/lua/core/resolve_bridge/protocol.lua:108-117, 119-131** — `build_response_ok`/`build_response_error` share envelope prelude verbatim.
- **src/lua/exporters/drt_writer.lua:153-179** — `open_tag`/`self_close` share attribute-rendering loop, differ only in trailing `>` vs `/>`.
- **src/lua/exporters/drt_writer.lua:735-751, 1012-1039** — `collect_clip_ids` and `compute_emit_order` walk the same `tracks→clips` structure with duplicate validation asserts.
- **src/lua/exporters/drt_writer.lua:140-148** — `xml_text` 3-gsub + `xml_attr` extra gsub; one table-driven gsub handles both.
- **src/lua/core/commands/connect_to_resolve_project.lua:78-83** — Reinvented `table_len` in a command file.

---

## Style (rule 2.5 — functions read like algorithms)

### MEDIUM

- **src/lua/core/commands/sync_edits_from_resolve.lua:702-775** — `run_phase_b` is 75 lines mixing reload, algebra, two near-identical 25-line edge-dispatch blocks (left/right parameterized only on edge string and L/R delta), error recording, status promotion. Extract `dispatch_edge_trim(edge, ...)`.
- **src/lua/exporters/drt_writer.lua:396-511** — `build_clip_element` is 115 lines: 11 asserts, 40-element XML parts table, video/audio branch that inlines thumbnail UUID mint and 4-element nested block. Split per Joe's 2.5 rule.
- **tools/resolve-helper/verbs.py:138-192** — `_validate_clip_positions` is 55 lines of `if not isinstance ... return error` walls with bool-vs-int gymnastics repeated. Extract `_validate_position_entry`, `_assert_no_duplicate_positions`.
- **tools/resolve-helper/verbs.py:545-620** — `_read_video_item` 75 lines mixing API extraction, bool/int gymnastics, partial-source-TC detection, two-branch shaping. Extract `_classify_source_kind`, `_assert_record_frame`.
- **tools/resolve-helper/verbs.py:1027-1112** — `verb_read_grades` 85-line god function. Extract `_grade_row(item, cdl_by_rec_in)`.

### LOW

- **src/lua/core/resolve_bridge/identity_ledger.lua:173-177** — `find_direct(jve_clip, by_jve_guid)` body is `return by_jve_guid[jve_clip.id]` wrapped pointlessly.
- **src/lua/core/commands/sync_edits_from_resolve.lua:595-824** — Phases 0/A/B/C share outer for-loop + cascade-skip skeleton (each phase repeats the `if state.phaseX_status == "ran_failed" then ... skipped_...`). Data-driven phase list would unify; medium-low because per-phase divergence is real.
- **src/lua/core/commands/sync_grades_from_resolve.lua:319-340** — Hand-built `M.register` wraps `OP.make_register` to install the undoer separately; the next undoable bridge command will copy this 22-line wrapper. Extend `OP.make_register(execute_fn, spec, undoer_fn?)`.
- **src/lua/exporters/drt_writer.lua:309-331** — `build_media_timemap_ba` comment-only acknowledgement of the format breakage; no round-trip test pins it.
- **src/lua/importers/drp_importer.lua:2089-2106** — Bare `do ... end` inside `parse_drp_file` inlines file I/O + slurp + triple-nested loop; extract `attach_clip_markers`.

---

## Test quality

### HIGH

- **tests/test_view_grade_pull.lua:124-128** — Test pins silent-nil fallback. See engineering-rules section above.

### MEDIUM

- **tests/test_sync_grades_command.lua:210-263** — Monkey-patches `supervisor.ensure_client` with a `fake_client` whose `request` asserts verb shape and synchronously delivers a hand-built envelope; success criterion is `type(fake_command.parameters.captured) == "table"`. Tests wiring, not behavior. Delete; use real helper via `helper_fixture` if integration coverage is wanted.
- **tests/test_sync_edits_apply.lua:185-571** — Scenarios 3-6 each restate every prior-converged clip with comment "Carry already-converged clips through to suppress deleted_in_resolve noise". rs-c_boot repeated 5×. Test surface exposes a real production-side coupling: `classify_all` conflates "live universe" with "deltas of interest". Either split fixtures or fix the seam.
- **tests/test_resolve_bridge_protocol.lua:90-95** — "Unknown error code surfaced" only checks `is_known_error_code('vibes_off') == false`; never tests `parse_response` with an unknown-code envelope. Silent-pass-through parser would satisfy this test.

### LOW

- **tests/test_edit_diff.lua:32-39** — `clip(opts)` helper uses `opts.source_in or 100` etc.; `source_in = 0` boundary test silently rewritten to 100. The `enabled` field correctly uses `== nil and ... or ...` showing the author knew the distinction.
- **tests/synthetic/binding/helper_fixture.lua:9 vs 35** — Docstring claims `log_level = WARNING`; code passes `DEBUG`.
- **tests/test_drt_writer_emit_order.lua:24-37** — Hand-built `seq` table pins encoder input contract but cannot catch upstream drift; add model-driven companion.
- **tests/synthetic/binding/_helper_transport.lua:85-89** — Socket-bind poll uses `os.execute("test -S " .. sock_path)` (unquoted) and `os.execute("sleep 0.05")` (fork per tick). Copy-pasted bad pattern from supervisor.

---

## NOW:

1. **Stop silent failures** — fix the helper trio (`version_string` fallback, bare-except `serve` loop, sticky ImportError) and the JVE-side trio (`payload_builder` clip-without-media skip, `drp_importer` missing-DbId coercion, EMP `content_hash` collapse). These are the highest-confidence engineering-rule violations and the cheapest to fix.
2. **Honor the same-PR `select_rows` contract** — port `ClipGrade.load`, `ClipMarker.find_by_clip`, `Sequence.count_clips`, `Media.count` onto the helper this PR introduces. Add `database.count` while you're there. Eliminates the worst self-contradiction in the diff.
3. **Quarantine the DRT writer** — rename `M.author` → `M.author_a005_compatible` and gate at the entry point; or commit to decoding `CurrentSelectorIdx` / MediaTimemapBA epsilon and sweeping the dangling 1235499f DbId. Until then, no caller should route arbitrary media through it.
