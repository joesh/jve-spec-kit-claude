# Skeptical Code Review — branch 023-resolve-color-bridge (2026-06-07)

**Scope:** all 308 files / ~35k LOC on `023-resolve-color-bridge` vs `master`.
**Method:** 10-dimension parallel review + 6-dimension pass-2 gap probe, each finding adversarially verified. 68 findings survived skeptical verification (65 in the main pass + 3 from a re-verify of gap-0 / gap-4 verifiers that crashed mid-workflow; 11 of the 14 re-verified were refuted). No fixes proposed — direction only.

## Executive Summary

The branch is large and substantively correct on the architecturally hard pieces (MVC purity zero findings; LUT3D pull integration, supervisor protocol, identity ledger, schema rationale all hold up). The signal concentrates in four themes:

1. **Smoke pipeline still leaking `eval`-based programmatic state mutation** — 5 high-severity sites use `command_manager.execute(...)` / `model:save()` from Python to seed marks, selection, viewport, and tab state. Joe's own rule (`feedback_no_programmatic_tweaks_in_smokes.md`) tightened against this; the branch shipped new violations alongside the rule.
2. **Helper subprocess lifecycle has real bugs** — `wait_for_bind` shells out to `sleep` from the GUI thread; dead Connect-error branches comparing Qt CamelCase against the bindings' snake_case; stale-socket leak on crash; helper reuses one `ResolveHandle` across reconnects.
3. **`sync_edits_from_resolve` is a half-implemented V2** — `M.apply` asserts `user_choices == nil` and discards it; 8/11 CONFLICT_REASONS are dead; fingerprint upsert escapes the undo group; phase 0/B double-bucket failures.
4. **Tests-as-mocks regression and SQL-layer bootstrap** — 14 new spec-023 tests bypass project lifecycle via `database.init()` + raw INSERTs and one (`test_sync_grades_command.lua`) stubs the supervisor with a fake Command. Joe's no-mocks rule and tests-drive-via-user-primitives rule both lose ground here.

Counts: 20 high, 29 medium, 19 low (68 total). The 3 recovered findings are spliced into their severity sections below and tagged `(recovered)`.

## High (20)

### C++ / FFI

**SURFACE_SET_LUT3D folds file-open + .cube parse + GPU upload into one C++ entry point — violates spec 023 thin-FFI rule (2.18/1.10) when qt_lut3d_parse_string already exists**
`src/lua/qt_bindings/emp_bindings.cpp:1635-1663`

Evidence: `const char* path = luaL_checkstring(L, 2); emp::Lut3d lut; std::string err; if (!emp::load_cube_file(path, lut, err)) { return luaL_error(...); } if (gpu_surface) gpu_surface->setLut3D(lut);`

Why bad: Spec 023 architecture is explicit: 'C++ FFI is thin 1:1; supervision/protocol/correlation in Lua' and helper boundary section (2.18/1.10) requires policy in Lua. This binding folds three operations (file open, .cube parse, GPU upload) into one C++ entry point, with file I/O policy (path resolution, missing-file UX, error surface) decided in C++. lut3d_bindings.cpp already exposes a thin qt_lut3d_parse_string — Lua should slurp the file, parse via that, then call a thin SURFACE_UPLOAD_LUT3D taking a parsed handle. As-is the View has no way to handle 'LUT couldn't load' the way FR-015's badge requires without parsing the err string the C++ raises through luaL_error.

Direction: Split into thin verbs: Lua reads the file (io.open) and parses via the existing qt_lut3d_parse_string handle; the surface verb takes the handle (or raw cube bytes) and uploads only. Move the file-not-found / parse-failed UX decision to view_grade_pull.lua.

---

### Fail-fast / No-fallback

**Supervisor wait_for_bind blocks GUI thread with os.execute('sleep') + risks SIGCHLD race with QProcess::finished**
`src/lua/core/resolve_bridge/helper_supervisor.lua:139-156`

```
while elapsed < timeout_ms do
        if os.execute("test -S " .. socket_path) == 0 then
            return nil
        end
        ...
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute(string.format("sleep %f", BIND_READY_POLL_MS / 1000))
        elapsed = elapsed + BIND_READY_POLL_MS
    end
```

Why bad: Wait-for-bind on the GUI thread spawns a `/bin/sh` for every 25 ms poll AND blocks via `sleep` (system call returning) — that's both a fork-per-25ms churn and a GUI-thread block up to 5 s. Worse, `os.execute` consumes child SIGCHLD which can race the QProcess finished signal. The `PROCESS_EVENTS()` interleave does not save you because the `sleep` shellout blocks regardless. This is the architectural anti-pattern called out in MEMORY's malloc-in-hot-loop / good-result-over-fast-process rules; correct path is a single-shot Qt timer chain or `qt_local_socket_wait_for_connected` with retry.

Direction: Drive readiness via `qt_create_single_shot_timer`-driven retry of `qt_local_socket_connect`, or expose a single C++ `qt_wait_for_socket_path` that blocks on the kernel, not on fork+sleep. No `os.execute` in lifecycle code.

---

### Python helper

**version_string() bare except returns "unavailable" with no logging, masking API-drift bugs the author's own comment warns about**
`tools/resolve-helper/resolve_handle.py:101-102`

```
except Exception:
            return "unavailable"
```

Why bad: Rule 1.14 / 2.13: silent fallback. version_string() is called from verb_ping for every health response; any Resolve-API regression (renamed method, stale handle producing surprise exception) gets folded into the harmless-looking string "unavailable". Bare `except Exception:` with no logging means log readers cannot tell 'Resolve not running' from 'helper bug'. Also bare except (no exc capture, no log).

Direction: Narrow the except, log at warn with the exception, and return a discriminating value (or the same string only on the well-understood handle-stale shape — propagate everything else).

---

### DRT↔DRP round-trip

**DRT writer drops clip.enabled and clip.volume on round-trip — WasDisbanded/Flags/EffectFiltersBA hardcoded**
`src/lua/exporters/drt_writer.lua:450-453`

Evidence: `text_elem("WasDisbanded", "false"), … text_elem("Flags", "0"),`

Why bad: drp_importer.lua:1597-1598 derives enabled = WasDisbanded≠'true' AND (Flags%4)<2 (muted bit). Writer emits constants for every clip with no read of clip.enabled / clip.muted / clip.volume. A JVE→DRT→DRP round-trip silently turns muted clips into unmuted and disabled clips into enabled. EffectFiltersBA is also self-closed (line 455) so any clip volume ≠ 1.0 is lost too (importer reads volume_db at line 1568). Violates FR-018 round-trip parity intent and rule 2.13 (silent data loss).

Direction: Encode WasDisbanded from clip.enabled, set Flags bit 1 from clip.muted, and emit a real EffectFiltersBA blob from clip.volume_db (mirror decode_effect_filters_volume_db). Add a round-trip binding test that flips each bit and checks it survives.

---

**DRT writer drops clip.markers — emits only identity markers, breaking DRP→JVE→DRT round-trip**
`src/lua/exporters/drt_writer.lua:769-773`

```
for _, clip_id in ipairs(collect_clip_ids(payload.sequence)) do
    marker_elements[#marker_elements + 1] =
        build_identity_marker_element(clip_id, fresh_uuid(0x06))
```

Why bad: drp_importer.lua:2103 attaches decoded user markers as c.markers, and ClipMarker model persists them. Writer side iterates collect_clip_ids only and emits exactly one identity marker per clip — user-authored markers (color/name/note/duration) are silently dropped on DRT export. Round-trip from a JVE project that imported a marker-rich DRP back out to DRT loses every non-identity marker. Asymmetric encode vs decode.

Direction: Have build_project_xml iterate clip.markers and append non-identity entries to the same Sm2TiItemLockableBlob payload alongside the identity marker (encode_clip_markers already accepts an array). Round-trip test that imports a fixture with 3+ colored markers, exports DRT, re-imports and asserts marker count + fields.

---

### Helper subprocess lifecycle

**Connect-error branches are dead — client.lua compares Qt CamelCase enum names but bindings emit snake_case; specific diagnostics never fire (generic fallback still surfaces the snake_case name, so it isn't literally "timed out", but the targeted guidance text is unreachable)**
`src/lua/core/resolve_bridge/client.lua:161-179`

```
if err == "ServerNotFoundError" then ... if err == "ConnectionRefusedError" then ... if err == "PeerClosedError" then ... — but local_socket_bindings.cpp:74-76 emits 'connection_refused' / 'peer_closed' / 'server_not_found' (lowercase snake_case)
```

Why bad: The whole point of last_socket_error capture (per the inline comment about a 1hr session lost to misleading 'timed out') is to surface the actual cause. Strings don't match → every branch falls through to the generic timeout message. Rule 2.32 / FR-007 'no silent failure of the actual cause' violated; the misleading-error trap that cost real session time is back. Also exactly the brittleness the pass-1 confirmed finding called out ('chain is brittle to QLocalSocket enum drift').

Direction: Single source of truth for the error name set, shared by binding + Lua. Either: change binding to emit Qt enum names verbatim ('ServerNotFoundError'…) — preferred, since names are stable in Qt API; OR change client.lua to match the snake_case strings. Add a unit/binding test that drives each failure mode (connect to nonexistent path → assert specific code) so this stays caught.

---

**wait_for_bind busy-polls via two os.execute shell-outs per 25ms tick (test -S + sleep), blocking the Qt event loop for ~400 forks over the 5s budget**
`src/lua/core/resolve_bridge/helper_supervisor.lua:135-148`

```
while elapsed < timeout_ms do if os.execute("test -S " .. socket_path) == 0 then return nil end ... os.execute(string.format("sleep %f", BIND_READY_POLL_MS / 1000)) elapsed = elapsed + BIND_READY_POLL_MS end
```

Why bad: Two distinct shell-out busy-polls inside a 5s blocking loop (200 forks each for `test -S`, 200 forks for `sleep`). Pass-1 flagged the bind-readiness shell-out (line 141/153); this is the same pattern still here. Forks block the Qt event loop → QLocalSocket signals (including the helper's own connected/readyRead) cannot deliver; the supervisor is observing socket existence via filesystem fork-shell, not via Qt. Architectural: the helper's socket-bound signal should come through QFileSystemWatcher or simply a connect-retry against `qt_local_socket_wait_for_connected` with proper error-cb branching (now that the misnamed-string bug above is fixed). Rule against shell-out busy-poll already established in pass-1.

Direction: Replace with: loop calling qt_local_socket_wait_for_connected with a small per-attempt timeout, branching on the (newly correctly-named) error code — `server_not_found` means retry, anything else is fatal. Use a Qt single-shot timer + QEventLoop::exec, not fork(sleep). Drops two fork-storms; lets Qt deliver signals during the wait.

---

### sync_edits classifier/apply

**Edit-fingerprint upsert in finalize_per_clip runs after end_undo_group — undo leaves ledger holding post-sync fingerprint, future classify buckets Resolve delta as jve_only and silently skips it**
`src/lua/core/commands/sync_edits_from_resolve.lua:949-956`

```
command_manager.begin_undo_group("Sync Edits from Resolve") … run_phase_0/A/B/C … command_manager.end_undo_group() … finalize_per_clip(per_clip, runnable, db, result) -- identity_ledger.upsert(entry.clip_id, { edit_fingerprint = fp }, db) at line 850
```

Why bad: Inner verbs run inside the undo group and revert on Cmd-Z, but identity_ledger.upsert(edit_fingerprint=...) runs OUTSIDE the group. After the user undoes the sync, clip geometry is back at the pre-sync state but the ledger still holds the post-sync fingerprint. The next classify_all sees stored_fp == live (post-sync) but current == pre-sync → classified.kind = "jve_only" → bucketed as only_jve_changed and silently skipped. The Resolve-side delta will never re-apply. Violates 1.14 (silent invariant break) and the persistence/undo contract the spec defines for fingerprints. Same issue applies to persist_bootstrap_fingerprints at line 936 which also runs before the undo group opens.

Direction: Persist edit_fingerprint mutations through a real command_manager command so they participate in the undo entry — or invert the contract and explicitly never persist fingerprint unless the undo group commits successfully and the user cannot Cmd-Z past it (e.g., write fingerprint inside each dispatched verb's commit path). Either way, ledger writes and clip-state mutations must move together under one undo barrier.

---

### Tasks.md vs diff

**LUT3D subsystem (parser + bindings + apply + surface-pull integration) shipped on branch with no governing task; tasks.md T032 explicitly defers LUT-after-CDL while spec.md FR-016 normatively requires "apply CDL, then LUT if present" — silent re-scope, and the C++-side .cube parser inherits no review gate**
`src/lua/qt_bindings/lut3d_bindings.cpp, src/editor_media_platform/src/emp_lut3d.cpp, src/editor_media_platform/include/editor_media_platform/emp_lut3d.h, tests/binding/test_lut3d_apply.lua, tests/integration/test_piece3_lut3d_surface_pull.lua`

```
tasks.md T032: 'LUT-after-CDL stage is deferred (partial-fidelity display not in V1 scope; spec.md FR-015 says non-primary grades show ungraded with the fidelity badge — T043 lights up the badge UX)'. But spec.md FR-016: 'JVE's viewer MUST display the stored primary grade (apply CDL, then LUT if present)'. A full LUT3D apply path, .cube parser, bindings, surface-pull integration test all landed in this diff with no T-NN authorising it.
```

Why bad: FR-016 is normative (MUST apply LUT if present) — T032's 'LUT deferred' note contradicts spec.md. A whole subsystem was added outside the tasks.md plan, which is the surface tasks.md is supposed to govern. Also entangles the known pass-1 finding that EMP.SURFACE_SET_LUT3D opens+parses .cube inside C++ (thin-FFI violation 2.18/1.10) — that violation has no task either, so there's no review gate that would have caught it.

Direction: Either (a) add T032b 'LUT-after-CDL pull + thin .cube parse in Lua' to tasks.md retroactively with explicit FR-016 traceability, AND fix the FFI thinness; or (b) revert the LUT3D subsystem until a task exists. Update T032 prose to stop claiming LUT is deferred when the code is present. Either way reconcile with FR-016.

---

### Schema / data model

**`db = db or database.get_connection()` in ClipGrade.load is a Rule 2.13 fallback — make `db` required like M.upsert**
`src/lua/models/clip_grade.lua:157`

```
db = db or database.get_connection()
assert(db, "ClipGrade.load: no active database connection")
```

Why bad: Rule 2.13 ('MANDATORY No Fallbacks or Default Values') and the bullet 'NEVER use `or 0`, `or default`, `or nil` — every one of those hides a real bug. Assert instead.' The justification comment says 'db is optional — views can omit it' but that's exactly the silent-coupling problem: callers who forget to pass a connection get an implicit ambient one, and the failure mode (wrong project DB after a project swap) is silent rather than loud. M.upsert correctly requires `db`; M.load splitting the contract is asymmetric and unsafe.

Direction: Make db required on both upsert and load (mirror upsert). Force every caller — views included — to thread the connection explicitly. Same applies to clip_marker.lua's database.get_connection() calls at save/find_by_clip/delete_for_clip (lines 60, 91, 107).

---

### Smoke architecture

**Smoke seeds bogus master mark_in/out/playhead via eval+model:save — banned programmatic mutation**
`tests/smoke/cases/test_match_frame.py:175-180`

```
self.eval(
    f"local s = require('models.sequence').load('{master_id}'); "
    f"s.mark_in = {bogus_in}; "
    f"s.mark_out = {bogus_out}; "
    f"s.playhead_position = {bogus_playhead}; "
    "assert(s:save())")
```

Why bad: Violates MEMORY rule 'NO programmatic state mutation in smokes — even for setup' (feedback_no_programmatic_tweaks_in_smokes.md). This is direct model-state write via eval to seed bogus values, bypassing the real UI pipeline. Joe explicitly tightened the rule: any model write requires real UI input or explicit approval.

Direction: Either drive the bogus seeding via the real UI surface that would mutate those marks (key presses on the source viewer), or ask Joe for an explicit exemption. Stop using eval for s:save().

---

**Teardown eval-mutates fullscreen UI state — fixture seeding via eval is banned even in finally**
`tests/smoke/cases/test_fullscreen_pause_on_app_deactivate.py:114`

```
finally:
    # Leave fullscreen off so the next test doesn't inherit a
    # borderless on-top window. ... 
    self.eval("require('ui.fullscreen_viewer').exit()")
```

Why bad: fullscreen_viewer.exit() is a user-visible state change. Teardown is still 'setup for the next test'; bypassing real input here means the next test runs on a path the user never takes. Violates the smoke-no-mutation rule.

Direction: Send the actual key that exits fullscreen (Esc / the bound shortcut).

---

**eval-driven set_selection({}) used as setup in test_match_frame smokes (lines 126-129, 166)**
`tests/smoke/cases/test_match_frame.py:166 and tests/smoke/cases/test_match_frame.py:126-129`

```
self.eval("require('ui.timeline.timeline_state').set_selection({})")
...
self.eval(
    "local rec_seq = require('core.playback.transport')"
    ".record_engine.loaded_sequence_id; "
    "require('ui.timeline.timeline_state').set_selection({})")
```

Why bad: set_selection({}) is a model-state write done as a 'belt-and-braces' clear before the gesture. MEMORY says even DeselectAll-style seeding via eval is banned; if a real DeselectAll is needed, press Cmd+Shift+A.

Direction: Replace with key('Cmd+Shift+A') (the canonical DeselectAll key per case.py docstring), or ask Joe.

---

**setUp uses eval to mutate tab state instead of calling ensure_record_tab() helper**
`tests/smoke/cases/test_keymap_timeline_zoom.py:34-39`

```
self.eval(
    "local ts = require('ui.timeline.timeline_state'); "
    "if ts.get_displayed_tab_kind() ~= 'record' then "
    "  local active = ts.get_active_sequence_id(); "
    "  if active then ts.switch_to_record_tab(active) end "
    "end")
```

Why bad: switch_to_record_tab is a state-mutating UI command. case.py:406 (`ensure_record_tab`) already implements the same idea correctly by pressing Grave — i.e., a known UI primitive exists. This is the literal pattern Joe banned: bypassing the real shortcut because it was convenient.

Direction: Call self.ensure_record_tab() (the existing real-input helper).

---

**eval-seeded viewport state is the same surface the zoom commands write — seed via real Cmd+=/Cmd+-/Shift+Z or get explicit acceptance**
`tests/smoke/cases/test_keymap_timeline_zoom.py:43-45 and tests/smoke/cases/test_go_to_edit_surfaces_playhead.py:58-61`

```
self.eval(
    "require('ui.timeline.timeline_state').set_viewport_duration("
    f"{SEED_VIEWPORT_DURATION})")
...
# Narrow the viewport — view-layer setup, not model mutation.
self.eval(
    "local ts = require('ui.timeline.timeline_state'); "
    f"ts.set_viewport_duration({duration}); "
    f"ts.set_viewport_start_time({start_frame})")
```

Why bad: set_viewport_duration / set_viewport_start_time are state writes the user would perform via Cmd+= / Cmd+- / Shift+Z / scrolling. The comment 'view-layer setup, not model mutation' is a self-justifying dodge — viewport IS state the test under exam reads back via the same getter (line 48-49 of zoom test). This is exactly the kind of 'I'll just seed it via eval' that the rule prohibits.

Direction: Either drive viewport seeding via the user-visible keys/scroll (real input through the runner), or get Joe's explicit per-case acceptance and annotate clearly.

---

### Coding style / naming

**`c.duration or 0` fallback in roll-partner search (added in d80895d8) — assert instead**
`src/lua/ui/timeline/timeline_panel.lua:3891`

Evidence: `and (c.sequence_start + (c.duration or 0)) == boundary_frame then`

Why bad: Rule 2.13 / 1.14 / MEMORY 'Architectural Correctness': clip without duration is broken state — masking with `or 0` lets a malformed clip silently change which partner the roll-edge picks, producing wrong-edge mutations instead of a loud assert. Exactly the `or 0` pattern flagged in CLAUDE.md WARNINGS §4.

Direction: Assert duration is a positive integer at clip load (model boundary already enforces this) and drop the fallback; if you reach a clip without duration in roll-edge, fail loud.

---

**Bind-readiness loop shells out to `sleep` instead of using `qt_create_single_shot_timer`**
`src/lua/core/resolve_bridge/helper_supervisor.lua:141,153`

Evidence: `if os.execute("test -S " .. socket_path) == 0 then … os.execute(string.format("sleep %f", BIND_READY_POLL_MS / 1000))`

Why bad: Forks a shell every 25ms for the file-existence probe AND another shell to sleep, blocking the Qt event loop in a tight `fork+exec` storm during startup. The file rationalises why polling is needed but not why both probe and sleep are shelled; LuaJIT has `lfs.attributes`/`io.open` and the codebase already uses `qt_create_single_shot_timer` for non-blocking waits. Also: unquoted `socket_path` interpolation into `test -S ` is one path-with-space away from a metachar surprise.

Direction: Either turn this into an async wait driven by `qt_create_single_shot_timer` (the established pattern) or, if a synchronous gate is required, use a direct stat (`lfs.attributes`) + nanosleep FFI — and quote the path.

---

### Test quality

**Spec 023 sync-grades/grade-model/ledger tests bypass project lifecycle via database.init() + SQL INSERTs with SQL-layer field names**
`tests/test_sync_grades_command.lua, tests/test_sync_grades_fidelity_none.lua, tests/test_sync_grades_wire_shape.lua, tests/test_sync_grades_ledger_attribution.lua, tests/test_sync_grades_lut_bake_path.lua, tests/test_view_grade_pull.lua, tests/test_clip_grade_model.lua, tests/test_identity_ledger.lua, tests/test_sync_edits_classify_all.lua, tests/integration/test_piece3_lut3d_surface_pull.lua`

```
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))
...
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, ...) VALUES (...)
    INSERT INTO sequences (...) VALUES (...)
    INSERT INTO tracks (...) VALUES (...)
    INSERT INTO clips (...) VALUES (...)
]], now, now, ...))
```

Why bad: MEMORY rule feedback_tests_drive_via_user_primitives: 'Tests drive via user-visible primitives (commands/UI), NEVER database.init() or raw schema bootstrap — bypassing the lifecycle hides bugs in the real user path AND leaks state real close/quit would clean up. Really good reason required.' These tests bypass project_open / sequence creation entirely, and use SQL-layer column names (sequence_start_frame, duration_frames) which Lua-side code names without _frame suffix — exactly the foot-gun feedback_clip_lua_field_names warns about. Bugs in the open/init lifecycle (e.g. signal wiring, in-memory cache invalidation) will never surface.

Direction: Route through a helpers/blank_project.lua-style primitive that calls the real OpenProject / NewSequence / Add Clip commands. If the surface area is genuinely model-only, the test should construct via models.Clip.create / Sequence.create — not raw INSERTs.

---

**sync_grades_command test stubs helper supervisor + fakes Command to exercise async-tail regression — violates no-mocks rule**
`tests/test_sync_grades_command.lua`

```
local fake_client = {}
function fake_client:request(verb, _, cb)
    assert(verb == "read_grades", ...)
    cb({ result = response }, nil, nil)
end
supervisor.ensure_client = function() return fake_client end

local fake_command = { parameters = { sequence_id = "s" } }
function fake_command:get_all_parameters() return self.parameters end
```

Why bad: Direct violation of 'NO mocks/stubs in tests' rule (MEMORY: feedback_no_mocks_use_test_mode + feedback_drive_jve_via_ui_only). The test replaces the live helper supervisor with a stub that synchronously invokes the callback, and stands in for the real Command object. The comment even admits 'No mocks: apply()/restore() take a literal grades list (the shape the helper would deliver)' immediately before introducing them. This is exactly the pattern banned.

Direction: Drive M.execute through real command_manager.execute_interactive in --test mode with the live helper supervisor stubbed only at the FFI boundary or, better, route through a smoke that talks to a recorded helper transcript.

---

### Spec drift (recovered)

**FR-011c content-match key drops clip name + record-TC — implemented as (file_uuid + source-TC overlap) only** *(recovered)*
`src/lua/core/resolve_bridge/identity_ledger.lua:179-189`

Evidence: `find_content_match` keys candidates by `file_uuid` + source-TC overlap; no `name` or `sequence_start` comparison anywhere in the module. spec.md:84 FR-011c specifies channel (b) = "(clip name + record-TC + source-TC + media identity)".

Why bad: Implementation drops two of the four fields FR-011c requires. Will false-positive on the same media duplicated and trimmed differently (very common after a copy+trim operation). Spec regression — implementation diverged from FR-011c without a spec amendment.

Direction: Extend the candidate key to include clip `name` + record-TC (`sequence_start`) per FR-011c. Either implement the four-field key or amend spec.md FR-011c with explicit rationale for dropping name/record-TC.

---

## Medium (29)

### Correctness

**identity_ledger.find_content_match silently binds to first overlapping candidate when multiple Resolve items share file_uuid + overlapping range**
`src/lua/core/resolve_bridge/identity_ledger.lua:179-189`

```
local function find_content_match(jve_clip, resolve_items)
    for _, rs in ipairs(resolve_items) do
        if rs.file_uuid == jve_clip.file_uuid
            and (rs.jve_guid == nil or rs.jve_guid == "")
            and ranges_overlap(jve_clip.source_in, jve_clip.source_out,
                rs.source_in, rs.source_out) then
            return rs
        end
    end
end
```

Why bad: Two Resolve items sharing the same file_uuid (legitimate: same source used twice) that both overlap the JVE clip's source range will silently bind the JVE clip to whichever scan order hits first. The contract documented above this function (FR-007 / FR-011 'never silently dropped') is broken in the ambiguous case. blade_inherit has a similar shape: range_contains uses `<=`, so an exact-bounds child is treated as 'inside' its parent and inherits — a fragment that happens to coincide with its parent's bounds gets the parent's resolve_item_id even when content_match would have been more accurate.

Direction: Collect ALL content overlaps; if >1 found, emit to unmatched with a distinct 'ambiguous_content_match' reason so the user resolves the tie. For blade_inherit, require strict containment (`<` instead of `<=` on at least one bound), or fold exact-bounds into direct match upstream.

---

### C++ / FFI

**LUT3D CPU/GPU mirror contract violated: CPU still trilinear, shader switched to tetrahedral (file headers still claim mirroring)**
`src/editor_media_platform/src/emp_lut3d.cpp:212-272`

```
CPU apply_lut3d_rgb: 8-corner trilinear lerp ('const float c00 = c000[ch] * (1 - tx) + c100[ch] * tx; ...'). Shader in gpu_video_surface.mm:1316-1345 picks tetrahedron based on sorted dr/dg/db ('if (dr >= dg) { if (dg >= db) { ... tet 000-100-110-111 ...').
```

Why bad: Files explicitly claim the CPU + GPU paths are 'shared regression target' / 'mirrored byte-for-byte semantically' (emp_lut3d.cpp:5-7, gpu_video_surface.mm:1305-1306 'Mirrored by the Metal fragment shader … any change here MUST also land'). They are no longer mirrored — pixel-precise CPU/GPU comparison will drift in diamond-region samples that exercise the trilinear-vs-tetrahedral diff. Test reference vectors derived to match one will disagree with the other.

Direction: Either upgrade CPU to tetrahedral so the mirror invariant holds, or rip out the 'mirrored byte-for-byte' claim and label CPU as 'reference trilinear; production renderer is tetrahedral'.

---

**qt_zstd_compress/decompress success return 1 value while header comment documents 2-value shape (frame, nil)**
`src/lua/qt_bindings/zstd_bindings.cpp:93-110`

```
Header comment: 'qt_zstd_compress(payload[, level]) → frame_string, err_string' and '(frame, nil) | (nil, err)'. Implementation success branch: `lua_pushlstring(L, out.data(), written); return 1;` — only one value pushed.
```

Why bad: Inconsistent arity across the success/error paths means Lua callers doing `local frame, err = qt_zstd_compress(x)` get err = nil from missing return, which works by accident; but pattern-matching callers that distinguish via select('#', ...) will see 1 vs 2 and either think success is malformed or assume the doc is wrong. Symmetric inverse qt_zstd_decompress shows the same asymmetry (success returns 1). Either fix the contract or push an explicit nil on success. Documenting one shape and shipping another is the 'aspirational documentation' anti-pattern.

Direction: Pick one: either push `nil` after the bytes on success (matches the doc and the (val, err) Lua idiom) or amend the comment to match the single-return reality. Same fix likely needed on qt_zstd_decompress for consistency.

---

### DRY / Duplication

**Closed error-code set duplicated as Python literals despite protocol.py existing precisely to centralize such constants**
`src/lua/core/resolve_bridge/protocol.lua:28-39 vs tools/resolve-helper/verbs.py (scattered: `_error(envelope_id, "bad_request", …)`, `_error(envelope_id, "resolve_api_error", …)`, `_error(envelope_id, "not_implemented", …)` at dozens of sites) and tools/resolve-helper/protocol.py:18 (only PROTOCOL_VERSION)`

```
Lua `KNOWN_ERROR_CODES` enumerates {not_studio, handle_stale, relink_failed, locale_rate_corruption, timeline_rate_mismatch, identity_field_missing, bad_request, resolve_api_error, helper_unavailable, not_implemented}. Python helper hard-codes each code at the call site (e.g. verbs.py line 277, 285, 1120, 1127, etc.) with no central constant. tools/resolve-helper/protocol.py:11-15 explicitly says 'Single source removes that footgun' for PROTOCOL_VERSION — but never made the same move for the error-code set.
```

Why bad: The Lua side will fail-assert on any helper code outside KNOWN_ERROR_CODES (protocol.lua:150) — so a typo in a Python error literal (e.g. `"not_implimented"`) silently produces a JVE-side assert at the boundary that says 'helper-protocol.md drift' rather than 'helper typo'. Exactly the divergence protocol.py was created to prevent for PROTOCOL_VERSION, applied inconsistently.

Direction: Lift the closed-set into tools/resolve-helper/protocol.py (mirror `KNOWN_ERROR_CODES`); have `_error()` in verbs.py assert membership before building the envelope. Keep the two enumerations side-by-side in code-review for drift.

---

**Pass/fail/check boilerplate duplicated across 12 spec-023 tests; belongs in test_env**
`tests/test_sync_grades_command.lua:25 (and tests/test_view_grade_pull.lua, tests/test_edit_diff.lua, tests/test_sync_grades_fidelity_none.lua, tests/test_sync_grades_ledger_attribution.lua, tests/test_sync_grades_lut_bake_path.lua, tests/test_sync_grades_wire_shape.lua, tests/test_sync_edits_apply.lua, tests/test_sync_edits_classify_all.lua, tests/test_resolve_bridge_link_schema.lua, tests/test_resolve_bridge_protocol.lua, tests/test_resolve_bridge_change_token.lua, tests/test_identity_reconcile.lua, tests/test_identity_ledger.lua, tests/test_clip_grade_model.lua)`

```
local pass = 0 / local fail = 0 / local function check(label, cond) / if cond then pass = pass + 1 / else fail = fail + 1; print("FAIL: " .. label) end — verbatim across at least 15 spec-023 test files
```

Why bad: Far beyond the third-copy threshold. Same five-line snippet is open-coded in every new test in the branch; test_env (require'd by all of them) already exists as the natural home. Each future test adds another copy. Also no consistent exit code surface — some assert at end, some don't.

Direction: Lift `pass/fail/check` (plus the trailing assert(fail==0, ...) + ✅ print) into test_env (e.g. test_env.checker()) and have every new black-box test pull it from there.

---

**item_ids validator body duplicated in _validate_item_ids and _validate_read_grades_args — extract shared helper**
`tools/resolve-helper/verbs.py:534-543 vs 1078-1086`

```
Lines 534-543: `if not isinstance(item_ids, list): return ("error", "item_ids must be a list of strings (got " f"{type(item_ids).__name__})") / for i, x in enumerate(item_ids): if not isinstance(x, str) or x == "": return ("error", f"item_ids[{i}] must be non-empty string …")`. Lines 1078-1086 in `_validate_read_grades_args` are line-for-line the same body, including the same error wording.
```

Why bad: Two copies today (read_timeline + read_grades); any future read_* verb that takes an item-id whitelist is the third copy. The verbs file is already 1269 lines; spec mentions T054 audio support and unwired verbs to come — third-copy risk is concrete, not hypothetical.

Direction: Extract `_validate_item_ids_list(value) -> ("ok", set|None) | ("error", msg)` and have both validators delegate. read_grades's `_validate_read_grades_args` then only owns the bake_lut_dir extra + the extras-set gate.

---

### DRT↔DRP round-trip

**Importer source_extent_frames uses timeline-frame units for AUDIO branch vs native-rate units for video — incoherent against source_in_native (pre-existing on master, not 023-introduced)**
`src/lua/importers/drp_importer.lua:1546-1551`

```
if track_type == "AUDIO" then
    source_extent_frames = math.floor(in_value) + duration_raw
else
    source_extent_frames = in_offset + source_duration
end
```

Why bad: Video uses in_offset/source_duration (already native-rate-converted, ceil/floor snapped). Audio uses raw in_value (sequence-frame integer) + duration_raw (timeline frames). Mixed-rate audio (e.g. 25fps sequence + 48kHz audio) produces source_extent_frames in TIMELINE FRAMES for audio but NATIVE FRAMES for video. The downstream media-row duration tracking comment claims this is file length but the unit is incoherent across modalities — caller can't trust the field.

Direction: Unify on native units (samples for audio, native frames for video). For audio: source_extent_frames = in_offset (native samples) + source_duration (native samples). The AUDIO branch's reasoning needs a comment explaining why the divergence is correct OR be eliminated.

---

**Round-trip clip.id symmetry not asserted across DRT-export → DRP-import**
`src/lua/exporters/drt_writer.lua:510 vs src/lua/importers/drp_importer.lua:1582-1583`

```
writer: return elem(tag, table.concat(parts), {DbId = clip.id})
importer: local clip_db_id = clip_elem.attrs and clip_elem.attrs.DbId
         if clip_db_id == "" then clip_db_id = nil end
```

Why bad: Writer always emits DbId=clip.id (asserted non-empty), but the importer's fallback path (`if clip_db_id == "" then clip_db_id = nil`) silently accepts an empty DbId attribute and lets Clip.create mint a fresh UUID. For a self-authored DRT this should be an assertion failure — empty DbId means writer corruption. Treating it as 'no identity' on import means a JVE-authored DRT with a broken DbId will round-trip with a new clip.id and the identity-marker linkage breaks.

Direction: Importer should assert DbId is present-and-nonempty whenever the file claims spec-023 identity-marker presence (the LocableBlobSet has marker entries). Or at minimum log.warn loudly and surface in the import report rather than silently re-minting.

---

### Helper subprocess lifecycle

**Helper accept() loop reuses a single ResolveHandle across client sessions with no boundary reset — a respawned JVE inherits the prior session's live Resolve project/timeline/selection state**
`tools/resolve-helper/helper.py:133-167`

Evidence: `while True: log.info("waiting for client on socket"); conn, _ = sock.accept(); ... with conn: ... while True: chunk = conn.recv(4096); if not chunk: break`

Why bad: listen(1) backlog=1 + serial accept means: if JVE crashes mid-request without closing the socket, the OS holds the connection until TCP-style FIN/RST. Meanwhile, a respawned JVE supervisor connects → accept returns it AFTER the prior session's recv() returns EOF (kernel-dependent timing). The new JVE's first request could be served by a helper whose Resolve handle state was mid-transaction for the prior session — the idempotency ledger is in-memory, so it's clean across the gap, but ResolveHandle process state isn't (any open project, current timeline pointer, undo stack — all live in DaVinci Resolve which the helper holds a scripting handle to). No 'new session' boundary signal.

Direction: On accept of a new connection after a prior disconnect, helper should reset any per-session Resolve state (close any open Resolve project it opened on behalf of the prior session, clear in-memory caches). Or: protocol-level hello/session_start verb the supervisor must send first, which lets helper differentiate 'fresh session' from 'replayed connection'. Document in helper-protocol.md.

---

**finished_cb leaks state.socket_path — helper crashes accumulate stale sockets under /tmp**
`src/lua/core/resolve_bridge/helper_supervisor.lua:174-185`

Evidence: `qt_process_set_finished_cb(proc, function(exit_code, exit_status) ... if state.client_handle then state.client_handle:close() state.client_handle = nil end state.process_handle = nil end)`

Why bad: On helper crash mid-session, finished_cb clears process_handle + client_handle but leaves state.socket_path populated. Next ensure_client → spawn_helper increments spawn_sequence and writes a NEW socket_path to state, but the OLD socket_path inode on /tmp is never unlinked (helper's own finally clause unlinks the path it bound, but only on graceful exit — on SIGKILL/segfault the file persists). Over a session of repeated crashes /tmp accumulates jve-resolve-bridge-N.sock garbage. Worse: if helper.py:54 `if os.path.exists(path): os.unlink(path)` ever races with a parallel session using mktemp collision (unlikely with os.tmpname but documented as the reason for spawn_sequence suffix), the wrong socket gets unlinked. _teardown unlinks correctly — but the finished_cb path bypasses _teardown.

Direction: finished_cb should call _teardown() (or its socket+process subset). Or: drop the inline cleanup in finished_cb entirely and let the next ensure_client → spawn_helper call _teardown before re-spawning. Either way the socket_path slot must be cleaned on crash, not just on graceful close.

---

**helper.py dispatch catch-all returns 'resolve_api_error' for any Python exception, conflating helper-side bugs (KeyError/TypeError/AttributeError) with real Resolve API failures and violating the closed-set contract's stated purpose of distinguishing the two**
`tools/resolve-helper/helper.py:155-164`

Evidence: `except Exception as exc: crash_id = _recover_envelope_id(decoded); log.exception("dispatch crashed (id=%r)", crash_id); response = make_error(crash_id, "resolve_api_error", f"helper crashed: {exc}")`

Why bad: Bare `except Exception` catches KeyboardInterrupt-adjacent things (no), SystemExit (no — but timeout-style), and importantly: every JVE-side bug surfacing through dispatch (KeyError on missing arg, TypeError on wrong type) gets bucketed as 'resolve_api_error' which the closed-set protocol marks as 'Resolve API failure'. Engineering rule 1.14 fail-fast: the JVE side should see distinct codes for 'helper-side bug' vs 'Resolve actually said no'. Both are now indistinguishable, and the JVE-side error UI suggests Resolve as the failure source — sending Joe down the wrong rabbit hole. Pass-1 already noted 'closed error-code set duplicated as Python string literals'; this is the matching policy bug.

Direction: Add 'helper_internal_error' to the closed set, use it for non-Resolve exceptions. Keep 'resolve_api_error' for the verbs that actually catch a Resolve API exception. Or: re-raise on dispatch crash and let the supervisor see process exit + 'crashed' status — fail-fast posture. Half-and-half (catch + mislabel) is the worst option.

---

### sync_edits classifier/apply

**Bootstrap fingerprints persist outside undo group and bypass command_manager — Cmd-Z after sync leaves ledger advanced**
`src/lua/core/commands/sync_edits_from_resolve.lua:484-503, 936-937`

```
persist_bootstrap_fingerprints(classified, db, result.fingerprints_persisted) runs before the undo group opens. Walks `skipped[]` and `to_apply[]` for entries the classifier marked `bootstrapped = true` and writes link.edit_fingerprint = stored_fp directly via identity_ledger.upsert.
```

Why bad: Bootstrap writes are unguarded by the undo group and outside any command_manager dispatch. If a later phase fails and the user Cmd-Z's, the bootstrap fingerprint stays. If the user cancels the entire sync attempt with Cmd-Z immediately, the ledger still moved. The comment justifies it as 'metadata catch-up', but a fingerprint IS state that gates the next sync's classification — silently persisting it without undo violates the per-sequence undo guarantees the rest of the system enforces. Also violates the rule that database mutation goes through command_manager.

Direction: Route bootstrap fingerprint persistence through a dedicated non-undoable command_manager verb (so SQL stays in the command layer and the operation is at least visible in the command history), OR fold it into the same undo group as the dispatched verbs so undo reverts both the geometry and the fingerprint catch-up together.

---

**M.apply hard-asserts user_choices == nil and discards the parameter — V2 conflict-resolution path is unimplemented (deliberate V1/V2 staging per docstring, but execute() accepts user_choices it cannot forward)**
`src/lua/core/commands/sync_edits_from_resolve.lua:913-919, 927`

```
assert(user_choices == nil, "sync_edits.apply: user_choices is V2 only; V1 MVP must pass nil ...") … local classified = M.classify_all(response, sequence_id, db, nil)  -- take_resolve_set hardcoded nil
```

Why bad: Spec 023 advertises conflict-aware pull (per FR-024/025); classify_all already accepts take_resolve_set as a Take-Resolve override knob. But M.apply hard-asserts user_choices==nil and discards the parameter, so there is no path to feed user-resolved conflicts into a Pass-2 dispatch. The Pass-1/Pass-2 split exists in name only — every diverged_both_sides flow drops to no_modal_v1_unhandled_conflict regardless of what UI is built on top. Violates Rule 2.16 (shortcut implementation: API shaped for two-pass but the second pass cannot consume the first's choices).

Direction: Either remove user_choices from the public signature until V2 (and remove take_resolve_set plumbing from classify_all so the dead branch isn't drifting) or wire user_choices through: translate user_choices into take_resolve_set, re-run classify_all with that set, then dispatch. Don't leave the half-built seam.

---

**Phase 0 and Phase B double-bucket failed clips into result.failed AND result.skipped (with phase0_failed/phaseB_failed reasons), while Phase A and Phase C emit only to result.failed — inconsistent and misuses skipped[] semantics**
`src/lua/core/commands/sync_edits_from_resolve.lua:731-742, 755-766, 621-625`

```
record_failure(state, "OverwriteTrimEdge", { edge = "left", delta_frames = L }, err, result) … table.insert(result.skipped, { clip_id = entry.clip_id, resolve_item_id = entry.resolve_item_id, reason = "phaseB_failed" })
```

Why bad: Phase 0 and Phase B emit to BOTH result.failed (via record_failure) and result.skipped (with phase0_failed / phaseB_failed) for the same clip on the same failure. Phase A and Phase C emit only to result.failed, not result.skipped. Downstream consumers and tests that iterate failed[] + skipped[] will count the clip twice, and the emission policy is inconsistent across phases for no apparent reason. The skipped[] bucket also contains entries that have nothing to do with "skipped" semantically — they were attempted and failed.

Direction: Pick one bucket per outcome and stick to it. Failures belong in result.failed; result.skipped should contain only entries that were never dispatched (not_needed, unknown_delta_shape, conflict-surfaced). Remove the table.insert into result.skipped from run_phase_0 and run_phase_b, and update reason taxonomies to match.

---

**walk_ledger_for_deleted emits minimal conflict entry; surface_conflicts_as_skipped propagates missing live/current/track_id/kind as nil because emit() enforces only `reason`, not shape**
`src/lua/core/commands/sync_edits_from_resolve.lua:405-410, 512-524`

```
walk_ledger_for_deleted emits { clip_id, resolve_item_id, reason = "deleted_in_resolve" } — no live/current/track_id/etc. … surface_conflicts_as_skipped then does table.insert(result.skipped, { clip_id = c.clip_id, ..., live = c.live, current = c.current, stored_fp = c.stored_fp, track_id = c.track_id, track_type = c.track_type, live_track_id = c.live_track_id })
```

Why bad: Two conflict-entry shapes coexist: classify_track_change/classify_edit_diff produce full entries with live/current/track_id; walk_ledger_for_deleted produces a minimal entry. surface_conflicts_as_skipped reads c.live etc unconditionally and inserts them as nil for deleted_in_resolve rows. Any consumer that asserts "skipped[i].current ~= nil" or formats the message will nil-deref or print 'nil'. Closed-set assert at emit() only checks reason, so the shape drift is silent. Violates Rule 2.13 (silent nil instead of explicit field) and 2.21 (closed-set declared, shape isn't enforced).

Direction: Either give deleted_in_resolve entries a full shape (live = nil-marker, current loaded from the doomed clip) or split the surfaced-skipped shape per reason and validate each. The emit() validator should assert the field shape per reason, not just reason membership.

---

**8 of 11 CONFLICT_REASONS declared but never emitted; classifier loads frame_rate/fps_mismatch_policy but never consults them**
`src/lua/core/commands/sync_edits_from_resolve.lua:37-49`

```
CONFLICT_REASONS = { diverged_both_sides=true, deleted_in_resolve=true, fps_mismatch_unsupported=true, subframe_unsupported=true, composite_undecomposable=true, mutual_composite=true, overwrite_absorb_inconsistent=true, slip_unsupported=true, roll_unsupported=true, multi_mapped_ambiguous=true, missing_target_track_in_jve=true } — only diverged_both_sides, deleted_in_resolve, and missing_target_track_in_jve have call sites.
```

Why bad: load_current_state reads clip.frame_rate and clip.fps_mismatch_policy into current but no classifier branch ever consults them. A Resolve-side edit on a clip whose frame_rate differs from sequence rate will misclassify as `resolve_only` and dispatch trims with the wrong delta_frames units. Same for subframe-precision live values arriving from Resolve. The closed-set declarations create the illusion of coverage. Violates Rule 2.16 (incomplete implementation hiding behind a closed set) and 1.14 (silent fall-through where an assert/conflict should fire). Speed/composite/slip/roll deltas from Resolve will be silently shape-failed as unknown_delta_shape with no domain-meaningful reason for the user.

Direction: Either narrow the closed set to what the code actually emits and assert the rest are unreachable (delete the declarations), or add explicit branches: fps check before classify_edit_diff (current.frame_rate ≠ sequence.frame_rate ⇒ fps_mismatch_unsupported), integer-frame check on live source_in/out/record_start/dur (subframe_unsupported), and a dedicated shape-discriminator on the Phase D residual to distinguish slip vs roll vs speed before lumping them all into unknown_delta_shape.

---

### Tasks.md vs diff

**T009 completion note still says schema_version=12 but schema.sql now writes 13 (bumped by later commit 8aeeede1 without updating T009's narrative)**
`src/lua/schema.sql:35, specs/023-resolve-color-bridge/tasks.md:53`

Evidence: `schema.sql: 'INSERT OR IGNORE INTO schema_version (version) VALUES (13);'. tasks.md T009: 'Set schema_version 12. … schema_version=12; existing test_clip_link_model.lua still passes against V12.'`

Why bad: Tasks.md still claims V12; reviewer reading the task can't tell whether (a) another spec legitimately bumped to V13 after T009 or (b) someone snuck a schema change into spec 023's tables. Per the memory rule 'spec already decided → don't re-spike', and given schema-bump-freely policy, the violation is documentary: T009's completion note is stale and the diff narrative is broken.

Direction: Either reword T009 to say 'schema_version bumped to N (was 11)' without pinning N, or add a one-line addendum noting V12→V13 happened in spec NNN and which delta belongs to 023. Don't leave version numbers in completion notes — they go stale.

---

**T035 path in tasks.md points at nonexistent test file; actual file is tests/test_identity_reconcile.lua**
`specs/023-resolve-color-bridge/tasks.md:102, tests/test_identity_reconcile.lua (actual)`

```
tasks.md T035: 'tests/test_reconcile_bladed.lua — black-box reconcile bladed-inherit. DONE — commit fbb6ca43.' Filesystem: no tests/test_reconcile_bladed.lua; tests/test_identity_reconcile.lua exists and covers reconcile with blade_inherit source tag.
```

Why bad: Tasks names the wrong path. A future agent searching for the reconcile-bladed test by the path in tasks.md finds nothing and may rewrite or re-add it. Test renames must round-trip into tasks.md.

Direction: Fix the path in T035 to tests/test_identity_reconcile.lua, or rename the test file back. Add a note for the rename rationale.

---

### Schema / data model

**`clip_grade.source` is unconstrained TEXT while sibling `fidelity` uses CHECK(IN ...); writer literal ('resolve') already disagrees with data-model.md's documented value ('resolve_readback')**
`src/lua/schema.sql:857`

Evidence: `source      TEXT NOT NULL,`

Why bad: Code at clip_grade.lua:70-71 asserts only `type(grade.source) == 'string' and grade.source ~= ''`. No documentation in schema or model identifies the valid values. Compare `fidelity` directly above which is CHECK(fidelity IN ('primary','partial','unrepresentable')). For a bridge contract column that's almost certainly an enum (likely 'resolve' / 'manual' / something), open-ended TEXT lets typos through silently and provides no docs to readers.

Direction: Add CHECK with the closed set, and mirror the assert in the model with a VALID_SOURCES table (same shape as VALID_FIDELITIES). If source genuinely is open-ended (e.g. carries a helper version string), document that in the schema comment.

---

**`clip_markers.frame` breaks schema's own coordinate-space-suffix convention; rename to `clip_offset_frame` (or `start_frame`) for join-site clarity**
`src/lua/schema.sql:413`

```
frame INTEGER NOT NULL,
duration INTEGER NOT NULL CHECK(duration >= 1),
```

Why bad: MEMORY rule 'Lua Clip field names DROP _frame/_frames suffix' is about Lua field-name surface; SQL columns at the model boundary still need to be unambiguous about WHICH frame coordinate. The schema comment says 'offset from the clip's start' but the column is bare `frame`. clips.source_in_frame, sequence_start_frame etc. all carry coordinate-space suffixes in this same schema. A `marker_frame` column called `frame` is the kind of naming that bites when read in a join later.

Direction: Rename to `clip_offset_frame` (or `start_frame` with an explicit 'relative to clip.sequence_start' comment) to disambiguate from sequence-frame and media-frame coordinates that clip records also carry.

---

**`resolve_bridge_link` FK column named `jve_clip_uuid` instead of `clip_id`, breaking the schema-wide convention used by sibling `clip_grade.clip_id` and propagating into identity_ledger.lua API**
`src/lua/schema.sql:870-875`

```
CREATE TABLE IF NOT EXISTS resolve_bridge_link (
    jve_clip_uuid     TEXT PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
    resolve_item_id   TEXT NOT NULL,
```

Why bad: The column is a FK to clips(id) — every other table in schema.sql refers to it as `clip_id` (e.g. clip_grade.clip_id line 845, clip_markers.clip_id line 418, clip_channel_override.clip_id). Naming it `jve_clip_uuid` here invents a new convention for one table. The identity_ledger.lua module then propagates this name throughout its public API (`link.resolve_item_id`, `jve_clip_uuid` parameters) making translation harder for callers. Both sides are identifiers; the asymmetric naming buys nothing.

Direction: Rename `jve_clip_uuid` → `clip_id` to match every other FK column in the schema. The 'this side is JVE, that side is Resolve' distinction is already captured by `resolve_item_id` and the table name.

---

**`clip_grade.source` lacks closed-set CHECK and `synced_at` lacks unit doc + non-negative CHECK, inconsistent with sibling `fidelity` enforcement**
`src/lua/schema.sql:855-861`

```
stale       INTEGER NOT NULL CHECK(stale IN (0, 1)),
synced_at   INTEGER NOT NULL
...
source      TEXT NOT NULL,
```

Why bad: `source` has no CHECK constraint or documented closed-set despite being semantically an enum (the model asserts only non-empty string at clip_grade.lua:70-71). Compare to `fidelity` directly above which DOES have a closed-set CHECK. `synced_at` is an INTEGER unix timestamp with no documentation of unit (seconds? ms?) and no CHECK >= 0 — the model asserts >=0 at line 75 but SQL allows negative values from any other writer. Inconsistent enforcement across two columns of the same table.

Direction: Either add a CHECK(source IN (...)) for the closed set, or document why source is open-ended. Add CHECK(synced_at >= 0) and pick a documented unit (the codebase elsewhere uses seconds — see synced_at usage).

---

### Smoke architecture

**Multi-line structural Lua assertions stitched into a Python string blob in smoke eval**
`tests/smoke/cases/test_imported_sequence_ripple.py:89-132`

```
report = self.eval(
    "local Track = require('models.track'); "
    "local Clip = require('models.clip'); "
    ...50+ lines of asserts...
    "return string.format('tracks=%d clips=%d', #tracks, #clips)")
```

Why bad: Tens of lines of structural assertions encoded as a Python f-string blob. Not debuggable (no line numbers map to source), not lintable (escapes luacheck), and the assertion messages get mashed into a single Lua error. This is precisely the kind of in-eval logic that --test mode was meant to avoid; the smoke is doing a --test-style invocation through the debug terminal.

Direction: Move the structural validator into a real Lua module (`tests/smoke/validators/imported_sequence.lua`) and call it as `require('tests.smoke.validators.imported_sequence').check(seq_id)` — same eval surface, real debuggable code.

---

**Open-dialog wait loop misses process-liveness check — crash reported as "did not respond"**
`tests/smoke/runner/jve_runner.py:594-599`

```
try:
    # If JVE is responsive, the modal sheet is closed.
    self.eval("return 1")
    return
except (JVERunnerError, JVEEvalError):
    continue
```

Why bad: Broad except eats both 'modal still up' and 'JVE crashed/socket died' as the same case. A crashed JVE will silently loop until the outer timeout, then report 'did not respond' rather than the actual crash reason.

Direction: Distinguish socket-dead from eval-timeout; if the socket dies, fail immediately with the crash log path.

---

**Smoke reaches transport.record_engine.loaded_sequence_id directly instead of debug_helpers.record_engine_sequence_id()**
`tests/smoke/cases/test_imported_sequence_ripple.py:44-49, test_match_frame.py:127-128`

```
self.eval_str(
    "local sid = require('core.playback.transport')"
    ".record_engine.loaded_sequence_id; ...")
```

Why bad: Reaching into `transport.record_engine.loaded_sequence_id` from Python smokes bakes private-field paths into smokes — pulls vs. pushes are fine, but smoke tests should query debug_helpers (the documented seam). Internal refactors will silently break tests in ways that look like product regressions.

Direction: Route through core.debug_helpers (where there's already a function for displayed/active sequence id). Add a helper if missing.

---

### Coding style / naming

**SendToResolve out_path_for_export shells out to mkdir and ignores exit status**
`src/lua/core/commands/send_to_resolve.lua:51`

Evidence: `os.execute(string.format("mkdir -p %q", dir))`

Why bad: Shells out for mkdir, ignores the exit status (silent failure if mkdir fails — rule 2.13/1.14). The export path is then `string.format`'d in even though `mkdir -p` may have done nothing. The %q quoting is Lua-string-literal style, not POSIX shell quoting; works for the home path today but is fragile.

Direction: Use a Qt FS binding (the codebase already exposes one elsewhere) or `lfs.mkdir` with recursive walk, and assert on failure.

---

**Wire response items named `row` in command-layer code violates "no DB terminology outside model/SQL layer"**
`src/lua/core/commands/sync_edits_from_resolve.lua:179-205, 269-295, 1391-1508; src/lua/core/commands/sync_grades_from_resolve.lua (assert_response_shape and apply loop); src/lua/core/commands/send_to_resolve.lua:1091-1098`

Evidence: `for i, row in ipairs(response.items) do … assert(type(row.resolve_item_id) == "string" … row.resolve_item_id, i)) … local function classify_track_change(row, current, clip_id, result)`

Why bad: MEMORY 'No DB terminology outside the model/SQL layer'. These are wire envelopes from the helper, not SQL rows — calling them `row` smuggles DB terminology into command code and obscures the wire/model boundary the file's own comments insist on (FR-021 cleanliness). Same violation in send_to_resolve where `mapping` items are called `row`.

Direction: Name by wire shape: `item`, `wire_item`, `helper_grade`, `mapping_entry`. Reserve `row` for code inside `clip_grade.lua` / `identity_ledger.lua` actually executing SQL.

---

### Test quality

**Smoke teardown uses eval() to exit fullscreen instead of Cmd+Shift+F keypress**
`tests/smoke/cases/test_fullscreen_pause_on_app_deactivate.py`

```
finally:
    # Leave fullscreen off so the next test doesn't inherit a
    # borderless on-top window. is_active() may already be false
    # if a prior assertion already exited; the call is idempotent.
    self.eval("require('ui.fullscreen_viewer').exit()")
```

Why bad: MEMORY feedback_no_programmatic_tweaks_in_smokes is absolute: 'eval-based command_manager.execute(...) is BANNED for fixture seeding, not just for the gesture under test. Read-only eval for state queries is fine; anything that writes model state needs real UI input or explicit Joe approval.' Calling fullscreen_viewer.exit() via eval writes state. Even cleanup must go through Cmd+Shift+F (the real keypress the user would use).

Direction: Use a real Cmd+Shift+F keypress (or no cleanup — let JVE relaunch) instead of eval. Or get explicit Joe approval for cleanup-only eval and document it.

---

### Wire drift (recovered)

**`row.lut` shape unvalidated at wire/model boundary while `row.cdl` is strictly asserted** *(recovered)*
`src/lua/core/commands/sync_grades_from_resolve.lua:89-115, 156-166`

Evidence: `assert_response_shape` validates `cdl` strictly (table type, per-triple numeric checks, fidelity-gated presence) using a closed-set `FIDELITIES` table, but never asserts anything about `row.lut`. Line 160 reads `row.lut and row.lut.ref` with no type check on `lut` and no check that `ref` is a non-empty string. The neighboring `cdl_wire_to_model` is explicitly documented as enforcing rule 1.14 at the wire/model boundary — `lut` gets none of that discipline.

Why bad: If `verbs.py` renames `ref`→`path`, switches `lut` to a bare path string, or adds required `kind`/`size` fields, JVE silently accepts (`lut_ref` becomes nil, or downstream crashes with "attempt to index a string value") instead of failing loudly at the boundary. Asymmetric wire/model contract.

Direction: Closed-shape validation for `lut` mirroring `cdl`: required `{ref, kind, size}`; `kind in {'cube'}`; `size in {17, 33, 64}`. Assert at apply boundary.

---

## Low (19)

### Correctness

**resolve_bridge_link lacks UNIQUE(resolve_item_id); lookup_clip_id error() fires on schema-permitted dup state**
`src/lua/core/resolve_bridge/identity_ledger.lua:121-135`

```
-- Multi-row defensive assert. One resolve_item_id should map to
-- at most one clip; multiple ledger rows means reconcile produced
-- a bad state ...
```

Why bad: Need to confirm schema.sql carries `UNIQUE(resolve_item_id)` on resolve_bridge_link — the comment claims this state is impossible, but the only thing in the diff that prevents it is `INSERT OR REPLACE` keyed on jve_clip_uuid, NOT on resolve_item_id. A pos_matched / marker_matched run that binds two different JVE clips to the same resolve_item_id will produce two ledger rows, and the next SyncEditsFromResolve crashes the user via error() with a stack trace they can't act on. ConnectToResolveProject's `already_claimed` set tries to prevent it within one Connect run, but does nothing about the second Connect after a Resolve item id was reused.

Direction: Add UNIQUE(resolve_item_id) to the resolve_bridge_link schema (regenerate per schema-bump-freely rule) OR convert the error() into a structured surface that ConnectToResolveProject can handle. As-is the invariant is asserted but not enforced.

---

**sync_grades_from_resolve apply boundary validates fidelity/cdl shape but not row.lut — silent nil if helper emits {lut:{}} or renamed field**
`src/lua/core/commands/sync_grades_from_resolve.lua:160`

Evidence: `lut_ref = row.lut and row.lut.ref,`

Why bad: If the helper ever emits `{lut: {}}` or `{lut: {path: ...}}` without a `ref` field, this evaluates to nil and the row silently has no LUT — the clip displays passthrough while the helper thought it baked one. The closed-set discipline applied to fidelity / cdl is missing here. Either assert the shape (`row.lut == nil` OR `row.lut.ref` is a non-empty string) or drop the whole lut accessor through a validator like cdl_wire_to_model.

Direction: Add lut shape assertion to assert_response_shape: when row.lut is non-nil, require row.lut.ref string; when fidelity is partial/unrepresentable, require row.lut.ref present (matches view_grade_pull's expectation).

---

### C++ / FFI

**DebugTerminal constructor silently overwrites singleton global g_terminal_instance instead of asserting the documented one-instance-per-process invariant**
`src/debug_terminal.cpp:15-16`

Evidence: `static DebugTerminal* g_terminal_instance = nullptr; … g_terminal_instance = this; (constructor) … if (g_terminal_instance == this) g_terminal_instance = nullptr; (destructor).`

Why bad: If two instances are ever constructed in the same process (test harness, future multi-socket support), the second silently steals the global pointer with no assert. Fail-fast policy (1.14): the constructor should assert g_terminal_instance == nullptr.

Direction: Add JVE_ASSERT(g_terminal_instance == nullptr) at construct; pin the singleton invariant rather than silently overwriting.

---

### Fail-fast / No-fallback

**QLocalSocket error enum is matched via string-equality chain with open fallthrough — no closed-set assertion at the FFI boundary**
`src/lua/core/resolve_bridge/client.lua:165-200`

```
if err == "ServerNotFoundError" then ... end
        if err == "ConnectionRefusedError" then ... end
        if err == "PeerClosedError" then ... end
        if err then return nil, string.format("client.connect: %s on %s (waited up to %dms)", err, socket_path, connect_timeout_ms) end
```

Why bad: Closed-set discipline (2.21) wants the error enum asserted against a known set at the FFI boundary, not a chain of string equality with an open generic fallthrough. The fallthrough branch effectively swallows new enum values into a half-structured message.

Direction: Define KNOWN_SOCKET_ERRORS in protocol.lua, assert membership at the FFI boundary, and route unknown values to fail-fast (crash on the supervisor side — the caller's contract is closed-set codes).

---

### Helper subprocess lifecycle

**helper_supervisor exposes configure/ensure_client/shutdown as module functions over a singleton `state`; should be methods on a supervisor instance to enable test isolation and multiple supervisors**
`src/lua/core/resolve_bridge/helper_supervisor.lua:69, 229, 284`

Evidence: `function M.configure(helper_script_path) ... function M.ensure_client() ... function M.shutdown()`

Why bad: All three operate on the singleton `state` table — there IS a dominant subject (the supervisor). Per MEMORY rule 'methods over standalone functions', these want to be methods on a supervisor object. Today the singleton is process-global, which also prevents two helpers (e.g. one for testing, one for prod) and makes test isolation harder (every test that touches the supervisor inherits state from the last run). The fake_supervisor in test_sync_grades_command.lua exists precisely because there's no clean way to instantiate a fresh supervisor.

Direction: Turn supervisor into a constructable object: local sup = HelperSupervisor.new(); sup:configure(path); sup:ensure_client(); sup:shutdown(). App-startup wires the singleton (one line in layout.lua). Tests construct their own. Drops the need for fake_supervisor / global state reset between tests, which the pass-1 confirmed-finding 'sync_grades_command uses fake supervisor + fake Command mock' indirectly points at.

---

**in-flight timeout timer is not cancelled when reply arrives — idle timers accumulate (acknowledged-intentional no-cancel design; resource smell, not a correctness bug)**
`src/lua/core/resolve_bridge/client.lua:233-240, 99-110, 243-252`

Evidence: `qt_create_single_shot_timer(effective_timeout_ms, function() local slot = in_flight[corr_id] if slot == nil then return end ... end) — and on reply: in_flight[parsed.id] = nil`

Why bad: Reply-path nils in_flight[id] but the qt_create_single_shot_timer keeps a strong Lua reference to the closure, the closure captures corr_id (cheap) and in_flight (the whole table — fine, but the closure stays alive). For a long-running read_grades with timeout_ms = 600000 (10min), every fast reply leaves a 10-minute timer ticking that no-ops. Under a heavy burst (sweep of 1000 read_grades in a session), 1000 idle timers accumulate, each pinning a small closure + corr_id string. Eventually GC reclaims them but only when the timer fires. Not a correctness bug; it's a memory/scheduler-pressure smell. Bigger concern: on client:close, the timer fires LATER, looks up in_flight[corr_id], finds nil (closed-set drained it), no-ops. OK. But the documentation comment on lines 24-27 says 'A reply that beats the timer wins the race by clearing in_flight; the timer callback no-ops on missing slot' — confirms the no-cancel was intentional. So this is a 'fine, but worth a cancel API'.

Direction: If qt_create_single_shot_timer can return a handle that supports cancel, store it in slot.timer_id (the field is already declared in the comment 'corr_id → { on_complete = fn, timer_id = ... }' line 55 but never set) and cancel on reply. If the FFI doesn't expose cancel, file a separate task to add it; meanwhile the comment field 'timer_id = ...' is misleading and should be removed.

---

**qt_process/qt_local_socket cache lua_State in file-scope global — risk of dereferencing State during Qt-queued-signal delivery after teardown, and violates thin-FFI per-slot state principle**
`src/lua/qt_bindings/process_bindings.cpp:50, 70 and src/lua/qt_bindings/local_socket_bindings.cpp:48, 93`

Evidence: `static lua_State* s_proc_L = nullptr; ... s_proc_L = L; (in create) — same pattern in socket bindings`

Why bad: s_proc_L is set on create() and on every set_*_cb call. If a test harness opens a new lua_State for isolation, OR if a Lua callback ever fires after the State is gc'd (e.g. QProcess::finished delivered post-shutdown), invoke_cb dereferences a dead State. The thin-FFI rule says bindings should be 1:1; threading state-per-slot would also let the State live with the slot's lifetime via the registry, not via a process-global.

Direction: Store lua_State* per ProcSlot/SockSlot at create-time; invoke_cb takes the slot's stored L. Same for socket. If multi-state isn't a target now, at minimum NULL the global in destroy of the last slot to fail loudly instead of silently.

---

### sync_edits classifier/apply

**load_current_state populates frame_rate / fps_mismatch_policy and SKIP_REASONS declares fps_mismatch_unsupported, but classifier never reads either — dead scaffolding for unimplemented fps handling**
`src/lua/core/commands/sync_edits_from_resolve.lua:204-219`

```
return { source_in = clip.source_in, source_out = clip.source_out, record_start = clip.sequence_start, record_dur = clip.duration, enabled = clip.enabled, track_id = clip.track_id, track_type = clip.track_type, owner_sequence_id = clip.owner_sequence_id, frame_rate = clip.frame_rate, fps_mismatch_policy = clip.fps_mismatch_policy, }
```

Why bad: Dead carriage. frame_rate and fps_mismatch_policy are loaded into the current state but no branch reads them. Combined with the never-emitted fps_mismatch_unsupported reason, this is the smoking gun that fps handling was scaffolded but never implemented. Violates 2.16.

Direction: Implement the fps gate (compare current.frame_rate against sequence rate or against the helper-reported timeline rate) and emit fps_mismatch_unsupported when they diverge, OR delete the dead fields and the dead closed-set entries.

---

### Tasks.md vs diff

**BT.709 CSC test-only binding (qt_compose_bt709_csc) + test_compose_bt709_csc.lua shipped on 023 with no T-NN owner; renderer YUV-stage work missing from tasks.md ledger**
`src/lua/qt_bindings/csc_bindings.cpp, tests/binding/test_compose_bt709_csc.lua`

```
Files in the diff list under cpp/tests_lua. No T-NN in tasks.md references csc, BT.709, or color-space conversion. The 023 spec carves color management to spec 024 (specs/024-jve-color-management/spec.md is in this diff).
```

Why bad: Either this is genuinely scope of 024 (and shouldn't be on this branch) or it's a sub-piece of T032/LUT3D work that escaped the task ledger. Given the recent commit 'tests: BT.709 CSC binding test + fullscreen pause/restore smoke', it's the latter. As with LUT3D, code shipped without the review gate of a task.

Direction: Either move CSC bindings to a 024 branch, or add the missing task (e.g. 'T032c: BT.709 CSC binding for view-side conversion') with FR mapping. The commit message hinted at LUT/CSC entanglement; clarify where the color pipeline boundary lives.

---

**Traceability matrix lists bare T029 for FR-013 though task was split into T029a/T029b**
`specs/023-resolve-color-bridge/tasks.md:88-89`

Evidence: `T029a/T029b marked [x] (lowercase, signalling done) but the traceability table still lists 'FR-013 read identities | T029' as a single bare T029. T029 was split mid-implementation.`

Why bad: Same documentation-drift class as T035 — the matrix doesn't track the split. A reviewer asking 'where does FR-013 actually live?' is led to a non-existent T029 entry.

Direction: Update the traceability matrix to show T029a (identities) and T029b (grades) separately, mapping to the right FRs (FR-013 → T029a; FR-014/015 → T029b).

---

**T043 [~] hides 3 untracked sub-items + unenforced bundled-app rsync precondition**
`specs/023-resolve-color-bridge/tasks.md:150`

```
T043 status [~] with 'Outstanding: keymap entries, tooltips, Inspector fidelity badge (spec §5.5). Bundled-app path for tools/resolve-helper/ is dev-only today; production-bundle deploys must rsync the helper tree into Contents/Resources/ for parity.'
```

Why bad: Three outstanding items (keymap, tooltips, fidelity badge) sit inside a single [~] checkbox with no sub-task IDs and no traceability into T045 (final gate). The bundled-app path note is a deploy-time bug waiting to bite (running JVE.app outside a dev tree → helper not found → bridge silently nonfunctional). 'Production-bundle deploys must rsync' is an external precondition with no enforcement.

Direction: Split T043 into T043a (menu+keymap), T043b (fidelity badge), T043c (bundle the helper into Contents/Resources/ with a CMake install rule so 'deploys must rsync' becomes 'CMake handles it').

---

**FR-011b traceability row points at superseded T046 and at T048-as-originally-titled, both of which no longer reflect actual coverage (T004 round-trip + T048 marker stamp)**
`specs/023-resolve-color-bridge/tasks.md:120-122`

```
T046 'SUPERSEDED by T047' marked [x]; T048 strikethrough 'adopt Sm2Ti DbId as clip.id' marked [x] but replaced with 'helper-side marker stamp verb'. The traceability matrix line 201 still lists 'FR-011b inbound id adoption | T046, T048' as though both contributed.
```

Why bad: Once a task is superseded, completing it with [x] hides the supersession from skim-readers and matrix consumers. The FR→task table claims T046 (a deleted task) covers FR-011b; the actual coverage is the marker stamp verb. A reviewer auditing FR-011b reads the matrix and chases a phantom.

Direction: Mark superseded tasks with a distinct sigil (e.g. [~] + 'SUPERSEDED — see T0XX') or remove the [x] tickmark, and rewrite the traceability matrix to point at the actual implementing task(s).

---

**delete_timeline verb + tests/binding/test_helper_delete_timeline.lua shipped with no governing task (only a parenthetical in T025a)**
`specs/023-resolve-color-bridge/contracts/helper-protocol.md:84, tests/binding/test_helper_delete_timeline.lua, tools/resolve-helper/verbs.py`

```
helper-protocol.md: '### delete_timeline (state-changing; idempotent; test-only)'. tasks.md mentions delete_timeline only once: 'T025b … blocked on delete_timeline verb for teardown'. No T-NN owns delete_timeline implementation or contract test, yet the binding test ships.
```

Why bad: Same pattern as the LUT3D finding but smaller in scope: contract surface added without the gate of a task that says 'this verb is in scope, contract test before impl'. Tasks.md is meant to be the place where 'is this in V1?' gets answered, and a test-only verb that exists to unblock T025b should be explicit (e.g. T025b-prereq) so 023 has an honest accounting of what shipped.

Direction: Add a small T0XX 'delete_timeline test-only verb + contract test' under Phase 2, gated on T021, with explicit 'test-only; not exposed to commands' annotation. Update the helper-protocol.md cross-link.

---

### Smoke architecture

**Smoke eval uses `or 0` fallback on Clip.duration — masks nil instead of asserting**
`tests/smoke/cases/test_roll_in_edge_at_start_boundary_clamps.py:57-65`

```
"     and (c.duration or 0) > 1 then "
"     and c.sequence_start + (c.duration or 0) == target.sequence_start then "
```

Why bad: Field names are correct (`duration`, `sequence_start` — no _frames suffix per MEMORY rule). But the `or 0` fallback on a clip field that MUST exist is a 2.13 violation: if duration is nil, the clip is malformed and the test should assert, not silently treat as 0.

Direction: Drop the `or 0`; assert that duration is a number at the top of the eval.

---

### Coding style / naming

**`ClipGrade.fingerprint(grade)` is a method on `grade` masquerading as a standalone**
`src/lua/models/clip_grade.lua:133`

Evidence: `function M.fingerprint(grade)`

Why bad: MEMORY 'Methods over standalone functions': `grade` is the dominant subject (function reads its fields and produces a digest of them). `M.upsert(clip_id, grade, db)` is the legitimate constructor-style standalone; `fingerprint` is not.

Direction: Either return a `Grade` instance from `ClipGrade.load` and expose `grade:fingerprint()`, or keep flat-table style but ensure the same direction in `edit_diff.fingerprint(state)` — and document the convention in the file header so the next module's first call site doesn't drift.

---

**`find_direct` body has redundant nil-check (table index already returns nil)**
`src/lua/core/resolve_bridge/identity_ledger.lua:180-184`

Evidence: `local function find_direct(jve_clip, by_jve_guid)\n    local hit = by_jve_guid[jve_clip.id]\n    if hit then return hit end\n    return nil\nend`

Why bad: Two-line wrapper around an index lookup; the `if hit then return hit end; return nil` pattern is equivalent to `return by_jve_guid[jve_clip.id]`. Adds visual noise without abstraction; rule 2.5 wants helpers that hide complexity, not ones that hide a table read.

Direction: Inline the lookup at the one callsite, or shrink to `return by_jve_guid[jve_clip.id]`.

---

**`rs` abbreviation for resolve_item in find_content_match and Pass 1 index build**
`src/lua/core/resolve_bridge/identity_ledger.lua:186-191,248-250`

```
for _, rs in ipairs(resolve_items) do if rs.file_uuid == jve_clip.file_uuid and (rs.jve_guid == nil or rs.jve_guid == "") and ranges_overlap(jve_clip.source_in, jve_clip.source_out, rs.source_in, rs.source_out) then return rs end
```

Why bad: Abbreviation hides intent; the sibling clip variable is the full `jve_clip`. Renames to `resolve_item` cost nothing and make the reconcile logic self-narrating.

Direction: Rename `rs` → `resolve_item` everywhere in reconcile.

---

**Redundant `or nil` tail on `stages and stages.cdl` / `stages and stages.lut_ref` (dead code, not strictly a 2.13 violation)**
`src/lua/ui/sequence_monitor.lua (in view-grade pull integration, diff line ~8036-8037)`

Evidence: `local cdl     = stages and stages.cdl     or nil\nlocal lut_ref = stages and stages.lut_ref or nil`

Why bad: `nil` is already what `stages and stages.cdl` evaluates to when `stages` is non-nil and field missing; the trailing `or nil` is dead code that reads like the banned `or default` fallback (rule 2.13) and trains future Claudes to add similar `or X` chains.

Direction: Drop the trailing `or nil`; write `local cdl = stages and stages.cdl` (and same for lut_ref).

---

### Tasks.md vs diff (recovered)

**tasks.md T009 and CLAUDE.md still record schema_version 12; schema.sql and data-model.md use V13 (V12 skipped per data-model preamble)** *(recovered)*
`specs/023-resolve-color-bridge/tasks.md:53 + CLAUDE.md:34 vs src/lua/schema.sql:35 + specs/023-resolve-color-bridge/data-model.md:1`

Evidence: `schema.sql` writes `PRAGMA user_version = 13` (lines 1, 35, 844). `data-model.md` line 1 says "V11 → V13" and explains V12 was skipped. `tasks.md` T009 (line 53) still says "bump V11→V12" and "Set schema_version 12" — marked DONE with stale text. `CLAUDE.md` line 34 still records "Schema V11 → V12" for feature 023.

Why bad: Two docs disagree with the shipped schema. Future reader checking `tasks.md` or `CLAUDE.md` sees V12; checking `schema.sql` or `data-model.md` sees V13. MEMORY: `feedback_specify_no_branch_switch.md` (reconcile tasks.md in same commit) applies; same goes for CLAUDE.md Active-Technologies block.

Direction: Update `tasks.md` T009 + `CLAUDE.md` Active-Technologies block to V13. Add a one-line note in `data-model.md` explaining why V12 was skipped (the commit message would be the natural reference).

---

## Per-Dimension Notes

**DRY / Duplication.** 3 confirmed duplications. All third-copy-rule violations: `pass/fail/check` test boilerplate (12 copies), `item_ids` validator (2 copies, third one queued), and the error-code closed set (Lua has it, Python doesn't — exactly the footgun `protocol.py` was created to prevent). No false alarms.

**MVC.** Zero findings. View-grade pull integration (`sequence_monitor` + `view_grade_pull`) is genuinely clean — views pull through `effective_clip_id_for_playhead`, `grades_changed` is the invalidation signal, no model state in views. Worth noting as a strong section.

**Fail-fast / No-fallback.** 2 confirmed. The high-sev one (`helper_supervisor` `wait_for_bind` shelling to `sleep` + SIGCHLD race with `QProcess::finished`) is both a fail-fast violation and a real reliability bug. The low-sev (QLocalSocket error string-equality chain with open fallthrough) hides protocol drift.

**Coding style / naming.** 8 confirmed. The high-sev `or 0` fallback in `timeline_panel:3891` and shell-out-to-`sleep` are textbook 2.13/1.14 violations. The `row` terminology bleed in command-layer code (`sync_edits_from_resolve`, `sync_grades_from_resolve`) is a fresh regression of Joe's no-DB-terminology rule.

**Test quality.** 3 confirmed, 2 high-severity. The structural issue is the same in both highs: spec-023 tests do `database.init()` + SQL `INSERT` for fixture setup, then exercise a code path. This is exactly the pattern flagged in `feedback_tests_drive_via_user_primitives.md` after the batch_binding hang.

**Smoke architecture.** 9 confirmed, 5 high-severity. This is the dimension with the most signal. Multiple new smokes (`test_match_frame.py`, `test_keymap_timeline_zoom.py`, `test_go_to_edit_surfaces_playhead.py`, `test_fullscreen_pause_on_app_deactivate.py`) seed state via `eval("command_manager.execute(...)")` for marks, selection, viewport, tab state. Rule tightened on 2026-05-XX; branch contains violations dated after.

**Python helper.** 3 confirmed, 1 high-severity (`version_string` bare-except returning `"unavailable"`). The helper.py dispatch catch-all (`resolve_api_error` for any Python exception) and the long-lived `ResolveHandle` across reconnects are real lifecycle issues.

**Schema / data model.** 5 confirmed. `resolve_bridge_link.jve_clip_uuid` should be `clip_id`; `clip_grade.source` lacks a closed-set CHECK; `clip_markers.frame` violates the coordinate-space-suffix convention. None are migration-blocking (Joe regenerates), but they'll calcify if not caught now.

**C++ / FFI.** 4 confirmed. The high-sev `SURFACE_SET_LUT3D` folds file-open + .cube parse + GPU upload into one C++ entry point — violates spec 023 §2.18/1.10 thin-FFI rule. CPU/GPU LUT3D mirror drift (CPU still trilinear, shader tetrahedral) tracked in MEMORY but the file headers still claim they mirror.

**Correctness (pure bug hunt).** 3 confirmed, all medium/low. `identity_ledger.find_content_match` silently binds the first overlapping candidate when multiple Resolve items share a `file_path` — needs assert-or-disambiguate.

**Tasks.md vs diff.** 8 findings — meaningful drift. LUT3D subsystem (~3 files, ~1500 LOC) shipped with no governing task. T009 says schema_version=12 but `schema.sql` writes 13. T035 path is wrong. `delete_timeline` verb + binding test shipped task-less. `BT.709 CSC` shipped task-less.

**DRT↔DRP round-trip.** 4 findings, 2 high. `drt_writer` drops `clip.enabled`, `clip.volume`, and `clip.markers` — round-tripping a JVE project through Resolve loses state silently. `clip.id` symmetry across export→import isn't asserted.

**sync_edits classifier/apply.** 7 findings, 1 high. `M.apply` discards `user_choices` and asserts it nil — V2 conflict-resolution is unimplemented but the surface advertises it. 8/11 declared CONFLICT_REASONS are never emitted; loaded but unused `frame_rate` / `fps_mismatch_policy`. Fingerprint upsert outside undo group → Cmd-Z leaves ledger advanced.

**Helper subprocess lifecycle.** 8 findings, 2 high. Dead Connect-error branches (string-equality on enum names that disagree). Busy-poll on socket bind blocking Qt event loop. Stale-socket leak. ResolveHandle re-use across sessions. `qt_process/qt_local_socket` cache `lua_State` in file-scope global — Qt-queued-signal-after-shutdown risk.

## Cross-Cutting Themes

**T1 — Concurrency boundary between Lua supervisor and Qt event loop is shaky.** Three of the highest-severity findings (supervisor `sleep` shell-out, dead Connect-error branches, accept-loop ResolveHandle reuse, file-scope `lua_State` cache in `qt_process/qt_local_socket`) all sit on this seam. The pattern is: Lua orchestration was written assuming synchronous QProcess/QLocalSocket semantics that don't actually hold under Qt event-loop dispatch. Worth a dedicated audit pass.

**T2 — Spec-023 left V2 surfaces declared but unimplemented; classifier and ledger pretend completeness.** `sync_edits.M.apply` asserts `user_choices==nil`; 8/11 conflict reasons are dead; `frame_rate`/`fps_mismatch_policy` loaded but unused. Either V2 is in scope (then implement) or it isn't (then delete declarations, don't leave half-doors). MEMORY.md `feedback_uncertain_comments_are_claude_tells.md` applies — half-implemented surfaces lie about their contract.

**T3 — Smoke seeding rule has tightened; branch has new violations.** Joe's `feedback_no_programmatic_tweaks_in_smokes.md` says even fixture setup must go through real OS input. Five new smoke tests violate this for marks/selection/viewport/tab/fullscreen state. Treat as a rule-enforcement sweep, not individual fixes.

**T4 — Tasks.md is out of sync with what shipped.** LUT3D subsystem, BT.709 CSC binding, `delete_timeline` verb, schema bump to V13 — all shipped without task entries or with stale entries. `feedback_specify_no_branch_switch.md` says reconcile tasks.md in the same commit. That didn't happen here, multiple times.

**T5 — DRT writer is the asymmetric side of round-trip.** Drops enabled/volume/markers/clip.id-symmetry. DRP importer reads them. The asymmetry is the regression risk for FR-018 (no back-compat) becoming "silent data loss on export".

## Open Questions for Joe

- `sync_edits` V2 conflict resolution — in scope for 023 or split? `M.apply(...,user_choices)` already shaped.
- LUT3D CPU/GPU drift (CPU trilinear, GPU tetrahedral) — deferred to 024 per MEMORY, but file headers still lie; fix headers now or wait for 024?
- Schema rename `jve_clip_uuid` → `clip_id` for `resolve_bridge_link` — yes/no? Pre-V13-lock window.
- Closed error-code set duplication — lift into `protocol.py` now or after 024 stabilizes wire?
- `BT.709 CSC` test-only binding + LUT3D subsystem — add T-NN entries to tasks.md retroactively or treat as 024 prerequisites?
- 14 spec-023 tests using `database.init()` — sweep-rewrite or grandfather?
- Helper `ResolveHandle` reuse across accept() iterations — intentional (Resolve session is per-process) or boundary-reset bug?
- `drt_writer` dropping `clip.enabled`/`volume`/`markers` — known gap awaiting 024, or regression?

## Claims

- All 65 findings below are from a 10-dimension review + 4-dimension pass-2 probe; each finding survived an independent adversarial verifier instructed to default-refute. Verifier transcripts at `~/.claude/projects/-Users-joe-Local-jve-spec-kit-claude/246d1baa-6bb5-451d-87e0-91551dc69ba4/subagents/workflows/wf_ec766862-f7d/`. — *workflow run output*
- 38 findings confirmed in pass 1, 27 in pass 2, +3 in a recovery re-verify of the 14 pass-2 findings whose verifiers crashed (11 of those 14 refuted as overstated). Recovered findings are tagged `(recovered)` in the body. — *workflow result JSON + recovery workflow `wf_1d8157f9-a20`*
- MVC dimension had zero confirmed findings. — *workflow result, dimSummaries.mvc.count=0*
- The branch contains 308 files / +35473 / -2281 lines. — `git diff master..HEAD --stat`
- Every finding's `file:line` citation, evidence quote, why-bad reasoning, and direction sketch is verbatim from the (verified) reviewer + verifier output — I did not re-derive any of them. — *content extracted from `agent-aba1e723f162b4a31.jsonl` write-report prompt*
- The 4 pass-2 verify dimensions whose verifiers were rate-limited (cpp, schema_model, helper_py partial, bugs) used pass-1 verifier results — those findings still survived adversarial verification in pass 1, just not a second round. — *failure log*
- Executive Summary themes (smoke leakage / helper lifecycle / sync_edits half-V2 / mock-tests regression) are my synthesis across confirmed-finding clusters, not from any single agent. — *inference*
- Per-dimension Notes paragraphs are my synthesis of confirmed-finding counts and patterns per dimension. — *inference*
- T1-T5 Cross-Cutting Themes are my synthesis from finding clusters; not surfaced by any single review agent. — *inference*
- Open Questions list is what I extracted as decision points the workflow couldn't resolve. — *inference*
- I have NOT independently re-verified the 65 findings by reading each cited `file:line` — I trusted the per-finding verifier. — *I haven't checked*
- No claim about workflow finding counts contradicting each other has been reconciled — first run reported 38+27, second resume reported 27+0, the 65 number comes from the larger (first-run) write-report prompt cache. Resume cache regression in pass-2 verification is a workflow runtime question, not a finding count question. — *workflow telemetry*
