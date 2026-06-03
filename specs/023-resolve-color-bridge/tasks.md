# Tasks: JVE ⇄ DaVinci Resolve Color Roundtrip Bridge

**Input**: Design documents in `specs/023-resolve-color-bridge/` (plan.md, research.md, data-model.md, contracts/helper-protocol.md, quickstart.md)
**Branch**: `023-resolve-color-bridge` — **cut by T001 at the start of implementation** (`start-feature-branch.sh`); all prior work (spec/plan/tasks) was authored on master.

## Format: `[ID] [P?] Description`
- **[P]** = different file, no dependency on another unstarted task → may run in parallel.
- **🔬 SPIKE** = investigation against a real Resolve Studio; produces a findings note, **no production code**; ends at a STOP gate.
- **🟢 LIVE** = test requiring a real running Resolve Studio + human-launched runner (cannot pass in headless CI; record real output).
- Exact file paths are given. TDD is mandatory (constitution III): a test task and its "verify it FAILS" step precede the implementation that satisfies it.

## Conventions for every task here
- **No mocks that assert their own canned values** (`feedback_no_mocks_use_test_mode`). Pure-Lua model/encoder tests run in `tests/` via the LuaJIT harness; anything touching Qt/EMP/bindings runs via `jve --test`; Resolve behavior is asserted by 🟢 LIVE tests only.
- **Fail-fast, no fallbacks** (1.14/2.13): every error path asserts or returns a structured error; assert messages name the offending id/value.
- **Command-only mutation** (2.29/`todo_command_bypass_enforcement`): `clip_grade`/`resolve_bridge_link` writes happen inside a `command_event`.
- **Thin FFI, policy in Lua** (2.18/1.10): C++ bindings are one-to-one Qt mappings; supervision/protocol/correlation live in Lua.
- **Commit after each task** (scoped to that task's files; on the feature branch).

---

## Phase 0 — Connection spike 🔬 (STOP gate)

- [X] **T001** Cut the feature branch: run `.specify/scripts/bash/start-feature-branch.sh --json` from repo root. If it refuses on a dirty tree, commit only the 023 spec/plan/tasks docs first (never sibling work), then re-run. All later tasks run on `023-resolve-color-bridge`. **DONE** — branch `023-resolve-color-bridge` cut & checked out (the dirty file was only the cozempic guard runtime lock, now gitignored).
- [X] **T002** 🔬 SPIKE Prove a standalone process makes an *external* connection to a running Resolve Studio. Establish (a) does external-**Lua** connect, or is **Python** required; (b) does the handle survive a project/timeline switch in Resolve's UI, or is per-verb revalidation required (FR-009). Write `specs/023-resolve-color-bridge/phase0-findings.md` with the **actual** connection code + real `ping`-equivalent output. If a research.md §10 assumption is contradicted, STOP and report. **No helper code yet.** **DONE** — see `phase0-findings.md`. (a) **Python** (external LuaJIT segfaults in its own runtime loading `luaopen_dfscript`; no PUC Lua 5.1 present) — the spec's pre-declared fallback. Studio 20.3.2.9 confirmed (FR-010). (b) `scriptapp` re-acquire is cheap → per-verb revalidation is viable; the cached-handle-across-UI-switch durability test needs Joe driving the UI (folded into T042), non-blocking since FR-009 revalidates regardless.

> **STOP GATE 0 — REACHED, awaiting Joe's review.** Findings reported in `phase0-findings.md`: helper language = **Python** (decided); per-verb revalidation viable. Do not start Phase 1 until reviewed.

---

## Phase 1 — DRT authoring + identity spike (STOP gate)

*The DRT writer is pure Lua and testable offline against the existing decoder; the identity round-trip needs Resolve. Build + prove the writer first, then spike identity.*

### Tests first (offline, must FAIL before implementation)
- [X] **T003** [P] `tests/test_drt_writer_roundtrip.lua` — black-box round-trip per blob type: for non-trivial values (e.g. TC `01:00:04:12` @ 23.976, sub-frame `|hex`, LE-double frame rates, a MediaTimemap speed ramp) assert `drp_binary.decode(drt_binary.encode(x)) == x`. Derive expected values from timecode/format domain rules, never by tracing the encoder. Verify it FAILS (no encoder yet). **DONE** — covers BE32/BE64, LE double (NTSC fractional rates), sub-frame fraction, resolution, TLV int+double, BtVideoInfo Time, MediaTimemap (forward+reverse). Verified FAIL (require) → PASS after T006.
- [X] **T004** [P] `tests/test_drt_writer_file_roundtrip.lua` — author a `.drt` for a 3-clip sequence, then parse it with the real `src/lua/importers/drp_importer.lua::parse_drp_file` and assert clips read back with identical TC, duration, MediaRef, and the identity field. Verify it FAILS. **DONE** — 3-clip black-box round-trip (NTSC 23.976, distinct file_uuids, absolute-TC source_in including a 01:00:00:00 origin and a 02:00:00:00 origin, non-contiguous timeline placement). Runs via `jve --test` (needs `qt_xml_parse`). Verified FAIL → PASS after T007.

### Implementation (make T003/T004 pass)
- [X] **T005** `src/lua/qt_bindings/zstd_bindings.cpp` — add thin `qt_zstd_compress` mirroring existing `qt_zstd_decompress`; register it. Binding test via `jve --test` (`tests/binding/test_zstd_compress.lua`): compress→`qt_zstd_decompress` returns the original bytes. **DONE** — one-shot `ZSTD_compress` embeds content size so the existing decompress reads it back symmetrically; thin FFI (2.18), errors not aborts. Build green, binding test passes (binary/NUL, UTF-16BE UUIDs, incompressible, empty all round-trip). Actual path is `src/lua/qt_bindings/` (tasks listed `src/qt_bindings/`).
- [X] **T006** `src/lua/exporters/drt_binary.lua` — encoder mirror of `importers/drp_binary.lua` decoders (`write_be32/64`, `encode_hex_double`, `encode_le_double`, `encode_tlv_fields`, `encode_bt_video_time`, `encode_media_timemap`, `encode_fields_blob` via `qt_zstd_compress`). DRY: keep encode beside the matching decode; do not fork format constants. Makes T003 pass. **DONE** — pure-Lua IEEE-754 (no FFI, per drp_binary.lua:111 scale caveat); T003 green, luacheck clean. `encode_fields_blob` is complete but its zstd path is exercised once T005 lands the `qt_zstd_compress` binding (added to `.luacheckrc` read-globals here).
- [X] **T007** `src/lua/exporters/drt_writer.lua` — author the **minimal-viable** `.drt` (zip of project.xml + one SeqContainer + MediaRefs against `media.file_uuid` + per-clip identity field carrying `clip.id`; absolute TC per `feedback_timecode_is_truth`). Grow only as the identity spike shows Resolve rejects pieces. Makes T004 pass. **Must not probe media** (`feedback_importers_no_media_probe`). **DONE** — XML emission mirrors the importer's read shape (Sm2MpFolder→Sm2MpTimelineClip→Sm2Timeline→Sm2Sequence with FrameRate/Resolution LE-double hex; Sm2SequenceContainer→Sm2TiTrack→Items→Element→Sm2TiVideoClip with DbId attr); `<In> = source_in - media.start_tc_frame` inverts the importer's absolute-TC composition exactly; clip.id ↔ Sm2Ti*.DbId carries the round-trip identity; deterministic UUID minting (no Date.now/random) for stable archive output under workflow resume. T004 green via `jve --test`.

### Identity spike (needs Resolve)
- [X] **T008** 🔬 SPIKE For each candidate identity field (clip metadata / item name / marker), author a DRT carrying a known `clip.id`, import into Resolve, read it back via the API, and report which field round-trips **byte-clean** (FR-002). Append the result + the minimal DRT Resolve actually accepts to `phase0-findings.md` (identity section). Decide the join field. **DONE** — commits `181bbc72` (dissection), `7d7ab446` (kitchen-sink dissection), `48f015ba` (canonical-shape writer). Per `phase0-findings.md §K5`, Resolve accepts the canonical-shape DRT; **identity = clip marker carrying `clip.id`** (round-trip proven inbound spike T047). Residual marker-stamp/read wiring is T048/T049 (Phase 2i), tracked separately.

> **STOP GATE 1** — the join field is proven with real read-back; the minimal importable DRT is known. Everything downstream depends on this.

---

## Phase 2 — Schema, helper skeleton + protocol core (STOP gate)

### Schema + entity tests first (offline, must FAIL)
- [X] **T009** `src/lua/schema.sql` — bump V11→V12; add `clip_grade` and `resolve_bridge_link` (incl. `grade_fingerprint` + `edit_fingerprint`) tables exactly per `data-model.md` (FK `ON DELETE CASCADE` to `clips`; `fidelity` enum; CDL all-or-none; `stale` NOT NULL with **no SQL default** — the writer always sets it, per 2.13). Set `schema_version` 12. No migration. (FR-014, FR-013a, FR-025) **DONE** — both tables added (CHECK on `fidelity` IN ('primary','partial','unrepresentable'), CHECK on `stale` IN (0,1), no DEFAULT on `stale`); CDL all-or-none enforced at model boundary (T015); index on `resolve_bridge_link.resolve_item_id` for FR-011 reconcile lookup. Schema applies cleanly (`sqlite3 < schema.sql` green; `schema_version=12`); existing test_clip_link_model.lua still passes against V12.
- [X] **T010** [P] `tests/test_clip_grade_model.lua` — black-box: store the non-trivial CDL from data-model, reload identically; partial-CDL write asserts (pcall, actionable msg, 2.32); bad `fidelity` asserts; delete clip → grade row gone (cascade); item-missing → `stale=1`, values retained. **DONE** — commit `ac621ee9` (RED) → `fa9eff9c` (GREEN).
- [X] **T011** [P] `tests/test_identity_ledger.lua` — black-box: record a clip→item mapping, reload it; delete clip → link gone (cascade); fingerprint changes when grade changes. **DONE** — `ac621ee9` (RED) → `fa9eff9c` (GREEN).
- [X] **T012** [P] `tests/test_resolve_bridge_protocol.lua` — black-box envelope build/parse: round-trip a request/response, structured error parse, idempotency keys off `change_token` (not `id`). **DONE** — `ac621ee9` (RED) → `fa9eff9c` (GREEN).

### Contract tests first (one per verb; shape only; may use a regenerable recorded fixture)
- [X] **T013** [P] `tests/binding/test_helper_ping.lua` — assert `ping` result shape `{alive, resolve_connected, resolve_version, helper_version}`. **DONE** — commit `27e29fa6`. Lives in `tests/binding/` not `tests/contract/` (the live-helper boundary needs `jve --test`).
- [X] **T014** [P] `tests/binding/test_helper_import_timeline.lua` — bad_request + closed-set + client-side idempotency-gate paths; success-shape (`{mapping[], unrelinked[]}`) deferred until T029 lands real mapping+relink (avoiding live-Resolve modal). **DONE** — commit `27e29fa6`. See `todo_t014_extend_import_timeline_success_shape`.

### Models / Lua bridge (make T010–T012 pass)
- [X] **T015** [P] `src/lua/models/clip_grade.lua` — load/batch_load/fingerprint; write helpers assert CDL all-or-none + fidelity enum at the boundary; no `database.get_connection()` from commands. **DONE** — commit `fa9eff9c`.
- [X] **T016** [P] `src/lua/core/resolve_bridge/identity_ledger.lua` — `resolve_bridge_link` read/write only (FR-011). Reconcile NOT added here per 2.17. **DONE** — commit `fa9eff9c`.
- [X] **T017** [P] `src/lua/core/resolve_bridge/change_token.lua` — build `{project_id, sequence_id, mutation_generation}` (FR-008). **DONE** — commit `fa9eff9c`.
- [X] **T018** [P] `src/lua/core/resolve_bridge/protocol.lua` — envelope build/parse, closed error-code set, structured errors. **DONE** — commit `fa9eff9c`; later extended in `27e29fa6` (object-encoding tag for empty `args`) and 2026-06-01 audit (closed set includes `helper_unavailable`).

### Thin FFI (generic Qt; binding tests via `jve --test`)
- [X] **T019** [P] `src/lua/qt_bindings/process_bindings.cpp` — thin `qt_process_start/terminate/state` (one-to-one QProcess). **DONE** — commit `6339b9d1`. (Actual path is `src/lua/qt_bindings/`, not `src/qt_bindings/`.)
- [X] **T020** [P] `src/lua/qt_bindings/local_socket_bindings.cpp` — thin `qt_local_socket_connect/write` + `readyRead`. **DONE** — commit `6339b9d1`.

### Helper + client + supervisor + command
- [X] **T021** `tools/resolve-helper/helper.py` + `verbs.py` — Python helper (Phase-0 decision); verb dispatch with per-verb `handle_stale` revalidation (FR-009); `ping` + `import_timeline` (full mapping/relink/`unrelinked` payload is the T029 follow-on — currently returns `resolve_api_error:"not yet implemented"`; closed-set discipline holds). Idempotency ledger process-local (FR-005, FR-021). Makes T013/T014 pass. **DONE** — commit `6339b9d1`.
- [X] **T022** `src/lua/core/resolve_bridge/client.lua` — request/response over the socket with correlation ids; 2026-06-01 audit wired the FR-007 single-shot timeout timer per the docstring's promise. **DONE** — commit `ca7ab107` + audit cleanup.
- [X] **T023** `src/lua/core/resolve_bridge/helper_supervisor.lua` — lifecycle policy in Lua over T019 (start-on-first-use, structured connect-timeout error, no silent retry). **DONE** — commit `ca7ab107`.
- [X] **T024** `src/lua/core/commands/send_to_resolve.lua` — `SendToResolve` registered command authoring DRT (T007) → `import_timeline` → ledger upsert (T016). **DONE** — commit `ca7ab107`. Live success path (mapping rows) returns the helper's real mapping now that T029a/b have shipped (verb_read_identities + verb_read_grades wired against Resolve).
- [x] **T025a** 🟢 LIVE `tests/live/test_send_identity.lua` + `tests/live/live_fixture.lua` — verifies `read_identities` returns ≥1 keyed item with non-empty jve_guid against an operator-set-up live timeline (precondition: run SendToResolve before the test). RED until operator runs SendToResolve. Live identity-channel gate. T025b (end-to-end SendToResolve drive within one test) folded to `todo_t025b_send_to_resolve_end_to_end` — blocked on `delete_timeline` verb for teardown. Live fixture pattern (`skip_unless_live`, `expect_ok`, `expect_error`) shipped for reuse by T026/T033/T034/T037/T042/T050/T055.
- [ ] **T026** 🟢 LIVE `tests/live/test_idempotency.lua` — re-send `import_timeline` with the same `change_token`; Resolve item count unchanged, both responses identical (quickstart step 6).

> **STOP GATE 2** — identity join holds end-to-end through the helper; idempotency proven. Decide whether the change token needs a DRT content hash (spec Deferred).

---

## Phase 3 — Color model + grade read-back (STOP gate)

- [x] **T027** [P] `tests/binding/test_helper_read_grades.lua` — asserts `{grades: [{jve_guid, cdl?, lut?, fidelity}]}` shape: fidelity closed-set enum `{primary, partial, unrepresentable}` mandatory; `cdl` strictly gated on `fidelity == "primary"` with RGB-triple slope/offset/power + sat number (FR-015 honest downgrade, never approximated); `lut.ref` non-empty path when present; `bad_request` for malformed `item_ids`; empty `item_ids ⇒ 0 grades` distinct from omit. Currently RED — verb wired to `_unimplemented`. Drives T029.
- [x] **T028** [P] `tests/binding/test_helper_read_identities.lua` — asserts `{items: [{resolve_item_id, jve_guid}], unkeyed_count}` shape (per-item non-empty strings; non-negative integer count); bidirectional reconciliation per T047 (marker channel + content match — neither raw id equality); `bad_request` on extraneous args (contract is `args: none`). Currently RED — verb wired to `_unimplemented`. Drives T029.
- [x] **T029a** `tools/resolve-helper/verbs.py::verb_read_identities` — enumerate timeline items (video + audio tracks), recover `jve_guid` via marker `customData` channel (helper-protocol.md §read_identities convention), count unkeyed. Multi-marker stamp ambiguity → fail-fast `resolve_api_error` (rule 2.32). Makes T028 pass once Resolve is attached.
- [x] **T029b** `tools/resolve-helper/verbs.py::verb_read_grades` + `tools/resolve-helper/cdl_edl.py` — CDL extraction via the spec.md:30 path: `timeline.Export(path, EXPORT_EDL, EXPORT_CDL)` (Resolve has no `GetCDL`; only the EDL+CDL export surfaces per-item ASC_SOP/ASC_SAT). Fidelity from `item.GetNodeGraph().GetToolsInNode()` enumeration (`primary` when only bare-primary corrector + no LUT; `partial` when LUT present or CDL+other tools with LUT carrier; `unrepresentable` when non-CDL tools present with no LUT carrier — FR-015 honest downgrade, never approximated). LUT carrier via `TimelineItem.GetLUT()`. Items without a marker-stamped jve_guid are omitted (mirrors §read_identities). 48-test offline coverage in `tools/resolve-helper/test_cdl_edl.py` (CMX-3600 event header, ASC CDL S-2014-009-01 happy + failure paths, drop-frame TC math, fidelity classifier all-branches). The `t029_cdl_probe.py` exploration referenced previously was superseded by spec.md:30 itself — the bigger session lesson is in `feedback_spec_already_decided_dont_respike`. Makes T027 GREEN against live Resolve.
- [X] **T030** `tests/test_sync_grades_command.lua` — black-box undo round-trip. **DONE** — commit `c251fe24`.
- [X] **T031** `src/lua/core/commands/sync_grades_from_resolve.lua` — `SyncGradesFromResolve` (undoable; upsert `clip_grade`, update ledger fingerprint; before-state captured for undo). **DONE** — commit `c251fe24`.
- [x] **T032** renderer CDL stage (FR-016): EMP color stage `src/editor_media_platform/include/editor_media_platform/emp_cdl.h` + `src/editor_media_platform/src/emp_cdl.cpp` (`emp::apply_cdl_rgb` + `apply_cdl_bgra8_inplace`, ASC S-2014-009-01 math, BT.709 luma, negative-clamp before pow, no allocation); Metal shader mirror in `src/gpu_video_surface.mm` (shared `apply_cdl` MSL helper used by YUV/BGRA/PackedYUV fragment shaders, `CdlUniform` uploaded each draw via `setFragmentBytes` — zero-alloc); CPU mirror in `src/cpu_video_surface.cpp` (`apply_cdl_bgra8_inplace` called in `setFrameData`); `setGrade/clearGrade` API on both surface classes; `EMP.SURFACE_SET_GRADE` Lua binding in `src/lua/qt_bindings/emp_bindings.cpp`; test-only `qt_cdl_apply_pixel` binding in `src/lua/qt_bindings/cdl_bindings.cpp`. MVC pull layer: `src/lua/core/view_grade_pull.lua` (gates `fidelity == "primary"`; stale primary still applies per FR-013a) + SequenceMonitor `_on_show_frame` hook (`_apply_clip_grade` calls the pull every show-frame — no View-side cache; an earlier clip-id-keyed cache was removed because the key didn't change when the underlying row did, hiding SyncGradesFromResolve mutations; rationale captured in commit `a480c891` and re-stated in `view_grade_pull.lua:23-28`). LUT-after-CDL stage is deferred (partial-fidelity display not in V1 scope; spec.md FR-015 says non-primary grades show ungraded with the fidelity badge — T043 lights up the badge UX). Tests GREEN: `tests/test_view_grade_pull.lua` (11/11, pull rule), `tests/binding/test_cdl_apply_pixel.lua` (5/5 via `jve --test`, ASC reference math). Per Joe's 2026-06-02 placement decision, math lives in EMP (editor-general primitive, not JVE-specific).
- [ ] **T033** 🟢 LIVE `tests/live/test_primary_cdl_pixel.lua` — apply the known primary CDL in Resolve, sync, render the clip in JVE, **pixel-compare** to Resolve's render within a tolerance set here (quickstart step 2). Pins the CDL math convention (research.md §5.4).
- [ ] **T034** 🟢 LIVE `tests/live/test_fidelity_downgrade.lua` — apply a power-window/secondary in Resolve, sync, assert `fidelity` is `partial`/`unrepresentable` and JVE does not claim full reproduction (quickstart step 3).

> **STOP GATE 3** — grades store, display, undo; fidelity is honest; CDL math pixel-verified.

---

## Phase 4 — Re-conform identity ledger (STOP gate)

- [X] **T035** `tests/test_reconcile_bladed.lua` — black-box reconcile bladed-inherit. **DONE** — commit `fbb6ca43`.
- [X] **T036** `src/lua/core/resolve_bridge/identity_ledger.lua::reconcile` — algorithm per data-model §reconcile. **DONE** — commit `fbb6ca43`.
- [ ] **T037** 🟢 LIVE `tests/live/test_reconform.lua` — grade in Resolve, blade + re-edit in JVE, `SendToResolve` again; assert no grade scrambling and both blade halves carry the parent grade (quickstart step 5).

> **STOP GATE 4** — re-edits re-conform without scrambling grades.

---

## Phase 5 — REMOVED (render + relink carved out 2026-06-02)

The render-and-relink path (former T038/T039/T040a/T040b/T041) was carved out 2026-06-02 because it was a Claude-inferred extension of Joe's original /specify input ("send → grade → bring grade back"), not something Joe asked for. The historic decision in plan.md §Complexity Tracking ("Render-and-relink only was offered and Joe chose store+display") rejected render-only in favor of store+display; render-and-relink was then quietly added on top as a "later phase" without an explicit Q&A. Preserved at git tag `spec023-render-relink-deferred` for future revival.

---

## Phase 2i — Inbound identity + connect an imported project (STOP gate)

*Slots alongside Phase 1/2 in dependency order (it is identity infra); numbered T046+ to avoid renumbering. The inbound spike (T047) belongs with the Phase-1 identity spike T008.*

- [x] **T046** ~~`tests/test_inbound_id_adoption.lua` — `Sm2Ti DbId` adoption as `clip.id`~~ **SUPERSEDED by T047.** DbId only bridges file↔file, not live (proven by `inbound-findings.md §2`). Live-path identity is `clip marker → clip.id` (T048/T049 own that work). DbId-as-clip-id for file↔file re-conform is retained behavior; tested by importer round-trip (T004), not by a separate `id_adoption` test.
- [X] **T047** 🔬 SPIKE Does the DRP `Sm2Ti DbId` equal the live scripting API's `TimelineItem` unique id? **DONE — answer: NO (0/1003).** See `inbound-findings.md` §2. `GetUniqueId()` is an undocumented runtime instance handle ≠ persisted `Sm2Ti DbId`; the live id is absent from the DRP; media-pool ids diverge too. **No id bridges DRP ↔ live API.** ⇒ id-adoption does NOT enable live connect. Resolution: durable identity = **clip marker carrying `clip.id`** (round-trip proven); first-connect join = **content/position** (`name + record-TC + source-TC + media identity`). Reframes T048/T049 below.
- [x] **T048** ~~adopt `Sm2Ti DbId` as `clip.id`~~ **SUPERSEDED by T047** — replaced by helper-side marker stamp verb. `tools/resolve-helper/verbs.py::verb_stamp_identity_marker` (state-changing; FR-008 change_token required): looks up the timeline item by `GetUniqueId`, checks `_recover_jve_guid` for existing identity (idempotent on same customData; refuses on conflicting customData), calls `item.AddMarker(0, "Purple", "JVE clip identity", "", 1, customData)`. Result: `{stamped: bool}`. Contract test `tests/binding/test_helper_stamp_identity_marker.lua` GREEN against live helper (6/6 bad_request gates). Live happy-path stamp deferred to T050 (which exercises the full connect → stamp → re-sync flow).
- [x] **T049a** `src/lua/core/commands/connect_to_resolve_project.lua` — `ConnectToResolveProject`: reads `read_identities` (marker channel) + `read_timeline` (position channel) via the helper supervisor, runs the pure-data `M.match` matcher (marker priority over position; duplicate position-key on Resolve side → fail-fast; in-seq jve_guid only), persists matches via `identity_ledger.upsert`, surfaces `{matched, unmatched, ambiguous}` to `on_complete`. 25 unit-test scenarios pass (`tests/test_connect_to_resolve_project_match.lua`) covering pure marker / pure position / mixed / orphan / position-already-claimed / cross-sequence-id-ignored / failure-path asserts. Registered command (FR-023).
- [ ] **T049b** Augment position match with FR-011c content key (`name + media identity`). Blocked on read_timeline carrying `name` + `media_file_path` (helper-side enhancement). See `todo_t049b_content_match_media_identity`.
- [x] **T049c** ConnectToResolveProject `args.stamp_position_matches=true` fans out `stamp_identity_marker` (T048 verb) for every `pos_matched` pair. Skips marker-channel hits (already id-anchored). Per-pair result lands in `on_complete.result.{stamped, skipped, failures}`. Stamp failures don't cascade — every pair gets tried (rule 2.32). Sequence + change_token loaded upfront so missing mutation_generation fails before any roundtrip. Commit `f9c71900`.
- [ ] **T050** 🟢 LIVE `tests/live/test_connect_imported.lua` — import the graded DRP, open the same project live in Resolve, run `ConnectToResolveProject`; assert every clip with an adopted id links directly and unmatched count is reported. Then `SyncGradesFromResolve` and assert grades land on the right clips. (FR-011b/c — this is the "I imported a graded DRP, hook up the grade" flow.)

> **STOP GATE 2i** — an already-imported jvp connects to its live Resolve project by id (+ positional fallback) and pulls grades onto the correct clips.

## Phase 4e — Edit read-back (Resolve-side tweaks) (STOP gate)

- [x] **T051** [P] `tests/binding/test_helper_read_timeline.lua` — asserts `read_timeline` result shape `{items:[{resolve_item_id, track_type, track_index, record_start, record_duration, source_in, source_out, enabled}]}`; track identity is positional (closed-set `track_type ∈ {video,audio}` + 1-based integer `track_index`) — JVE-side translates via `Track.find_by_sequence`; per-item TC field shape (integer-frame video, `{frame, subframe}` audio); `bad_request` for malformed `item_ids`; empty `item_ids ⇒ 0 items` distinct from omit (⇒ all). RED until T052. Drives T052.
- [x] **T052** `tools/resolve-helper/verbs.py::verb_read_timeline` + `src/lua/core/commands/sync_edits_from_resolve.lua::M.translate_wire_response` — helper returns positional `(track_type, track_index)` per video item with record/source TC and enabled; JVE-side translates wire shape via `Track.find_at`. V1 video-only at the helper layer (audio items skipped, lands with T054). Missing JVE track produces a sentinel string that flows through classifier's existing `missing_target_track_in_jve` conflict path. T051 GREEN against live Resolve; 64 classifier tests + 74 apply tests green. Commit `a739d02b`.
- [X] **T053** `src/lua/core/resolve_bridge/edit_diff.lua` + `tests/test_edit_diff.lua` — classify per-clip Resolve-changed / JVE-changed-local / both-changed conflict. **DONE** — commit `77e9a616`.
- [X] **T054** Pass 1 `sync_edits.classify_all` bucketing (RED → fix using helper-protocol shape + ledger lookup). **DONE** — commits `b238ca43` (RED) → `c4cbf3b0` (GREEN).
- [X] **T054a** `src/lua/core/commands/sync_edits_from_resolve.lua::classify_all` + `tests/test_sync_edits_classify_all.lua` + `tests/test_resolve_bridge_link_schema.lua` — pure-data classifier: walk `read_timeline` response + ledger; bucket into `{to_apply, conflicts, skipped, unmatched}` per the data-model.md §SyncEditsFromResolve contract. V1 VIDEO ONLY (audio asserts; deferred to `todo_t054_audio_support`). Fail-fast invariants: cross-sequence assert; FK CASCADE asserted (regression test); closed-set reason validation at every emit. Identity-ledger reverse lookup + multi-row defensive assert + empty-string fingerprint rejection. Verify tests FAIL first. (FR-024/025, supports FR-011c)
- [x] **T054b-1** `src/lua/core/commands/sync_edits_from_resolve.lua::apply` (skeleton + Phase 0) + `tests/test_sync_edits_apply.lua` — apply() entry point, classify_all wrap, bootstrap-fp persist (both `skipped` and `to_apply` `bootstrapped=true` entries), V1 no-modal conflict surface (classifier-field passthrough), early-return on empty `to_apply`, `begin_undo_group`/`end_undo_group`, Phase 0 `MoveClipToTrack` dispatch with `phase0_failed` cascade, post-success fingerprint persist. `DISPATCH_VERBS` closed-set asserted at dispatch chokepoint. Non-Phase-0 `to_apply` entries assert (honest staging). Tests RED→GREEN. (FR-024/025)
- [x] **T054b-2** Phase A `ToggleClipEnabled` — per to_apply entry with `live.enabled ≠ current.enabled`, dispatched via explicit `clip_toggles` form (idempotent — sets exact `enabled_after`, not a blind flip). Phase 0 failure cascades A (`phaseA_status = skipped_phase0_failed`); Phase A failure is independent (does NOT cascade-skip B/C — geometrically inert). Per-clip `attempted_verbs` array now records dispatch order; result.applied / result.failed assembled in `finalize_per_clip` once dispatch finishes. `assert_phase0_only` replaced by `assert_no_unimplemented_phases` (rejects only geometric residuals on source_in/source_out/record_start/record_dur). Tests RED→GREEN.
- [x] **T054b-3** Phase B pure-trim convergence via `OverwriteTrimEdge` — dispatches left (`delta_frames = Δsource_in`) then right (`delta_frames = Δsource_out`) per to_apply entry, each only when nonzero. Reloads current state per clip so Phase 0's track move doesn't stale-shadow source/record. Algebraic decomposition gate (`assert_no_unimplemented_phases` relaxed): trim-decomposable iff Δrecord_start == Δsource_in AND Δrecord_dur == Δsource_out − Δsource_in; non-decomposable residuals still abort until Phase C/D land. Cascade: phase0_failed → skip B; phaseB_failed → push to skipped[] + cascade-skip C (left failure within a clip also skips its right). V1 uses `OverwriteTrimEdge` only — *not* RippleTrim — because Resolve gives absolute per-clip positions and ripple would shift other to_apply clips off their targets (see data-model.md §apply step 10 for rationale; blanket-reload caveat is V2 territory). Tests RED→GREEN. (FR-024/025)
- [x] **T054b-4** Phase C `Nudge` for residual record_start shift M = (live.record_start − cur.record_start) reloaded post-B; combined trim+move algebra L=Δsource_in, R=Δsource_out, M=Δrecord_start−L. Phase D partitions non-decomposable entries (Δrecord_dur ≠ Δsource_out−Δsource_in) into `apply.skipped[unknown_delta_shape]` BEFORE dispatch — no clip mutation, no fp persist. Replaces `assert_no_unimplemented_phases` with `surface_shape_failures` (partition, not abort). `unknown_delta_shape` re-categorized from CONFLICT_REASONS → SKIP_REASONS (apply-only emit, not classifier-emit). Phase C cascade: phase0_failed → skipped_phase0_failed; phaseB_failed → skipped_phaseB_failed. Closes T054b. Tests RED→GREEN (69 checks). (FR-024/025)
- [ ] **T055** 🟢 LIVE `tests/live/test_edit_readback.lua` — trim/move a clip in Resolve, run `SyncEditsFromResolve`; assert the matched JVE clip's record/source updates; separately, locally edit a JVE clip then pull and assert it surfaces as a conflict, not an overwrite (quickstart edit-pull steps). (FR-024/025)

> **STOP GATE 4e** — Resolve-side edit tweaks pull into JVE, conflict-aware, undoable.

---

## Phase 6 — Edge cases + polish

- [ ] **T042** [P] 🟢 LIVE `tests/live/test_edge_cases.lua` — free (non-Studio) Resolve ⇒ `not_studio` and nothing destructive; stale handle on project switch ⇒ `handle_stale`; locale fractional-rate read as integer ⇒ `locale_rate_corruption`, conform refused (FR-010/009/020; quickstart edge checks).
- [~] **T043** [P] Register `SendToResolve`/`SyncGradesFromResolve`/`SyncEditsFromResolve`/`ConnectToResolveProject` in the menu + keymap; tooltips on non-obvious controls (3.11). Inspector fidelity badge for non-primary clips (spec §5.5 — minimal; full inspector UI is a later spec). **PARTIAL** — menus.xml `Color` submenu lit up with all four commands; per-sequence grey-out wired in `core/menu_system.lua` (Send/SyncGrades/SyncEdits — `ConnectToResolveProject` is project-scope, always enabled when a project is open); `helper_supervisor.configure(<repo>/tools/resolve-helper/helper.py)` called from `ui/layout.lua` post-menu-init, with matching `helper_supervisor.shutdown()` in the `__jve_shutdown` hook so the Python helper is reaped on Qt's aboutToQuit. Auto-registry resolution confirmed for all four CamelCase names. **Outstanding:** keymap entries, tooltips, Inspector fidelity badge (spec §5.5). Bundled-app path for `tools/resolve-helper/` is dev-only today; production-bundle deploys must rsync the helper tree into `Contents/Resources/` for parity.
- [ ] **T044** [P] `tests/binding/test_test_mode_*` and luacheck: zero warnings; ensure `make -j4` is green (2.4) — capture to `/tmp/make.log`, grep for `warning:|error:|FAILED`.
- [ ] **T045** Run `quickstart.md` end-to-end against a real Resolve Studio; record observed results. Do not mark the feature done until every scenario passes as an observable fact (constitution 0.1, `feedback_always_run_smoke_test`).

---

## Dependencies

- **T001 → everything** (branch must exist).
- **STOP GATES are hard barriers**: do not start a phase until the prior gate is reported/reviewed (spec §0.6). Spikes (T002, T008) gate the code that assumes their findings.
- Phase 1: T003,T004 (fail) → T005 → T006 → T007 → T008.
- Phase 2: T009 → {T010,T011 [P]}; T009 → T015,T016; T012→T018; T018+T020→T022; T019→T023; {T007,T016,T021,T022}→T024→T025→T026. T021 needs T008's join field (helper language already decided: Python).
- Phase 3: T009→T015→T030→T031; T029 before T033/T034; T032 needs T015 (model) + T031 (data to display).
- Phase 4: T016→T036→T035→T037.
- Polish (T042–T045) after their feature phases; T045 is the final gate.

## Parallel execution examples

```
# Phase 1 offline tests (independent files), write together then verify all FAIL:
Task: "tests/test_drt_writer_roundtrip.lua"          # T003
Task: "tests/test_drt_writer_file_roundtrip.lua"     # T004

# Phase 2 entity + protocol tests (independent files):
Task: "tests/test_clip_grade_model.lua"              # T010
Task: "tests/test_identity_ledger.lua"               # T011
Task: "tests/test_resolve_bridge_protocol.lua"       # T012

# Phase 2 thin-FFI bindings (independent .cpp files):
Task: "src/qt_bindings/process_bindings.cpp"         # T019
Task: "src/qt_bindings/local_socket_bindings.cpp"    # T020
```

Note: 🟢 LIVE tasks (T025, T026, T033, T034, T037, T042, T045) cannot run in parallel headlessly — they need a single foregrounded Resolve Studio and a human-launched runner; serialize them.

## Requirement → task traceability
*Every spec FR maps to at least one task. (Implementation tasks listed; each is preceded by its test task per TDD.)*

| FR | Tasks | FR | Tasks |
|----|-------|----|-------|
| FR-001 author DRT | T007 | FR-013 read identities | T029 |
| FR-002 identity field | T007, T008 | FR-013a delete cascade / stale | T009, T015, T010 |
| FR-003 absolute TC | T007 | FR-014 store grade | T009, T015 |
| FR-004 importer round-trip validation | T004 | FR-015 fidelity honest | T029, T034 |
| FR-005 separate process | T021 | FR-016 display pull (MVC) | T032, T033 |
| FR-006 socket / JSON / structured errors | T018, T020, T022 | FR-017 undoable sync | T031 |
| FR-007 spawn + supervise | T023 | FR-018 queue render + poll | CARVED OUT (tag spec023-render-relink-deferred) |
| FR-008 idempotency on token | T017, T026 | FR-019 relink to render | CARVED OUT (tag spec023-render-relink-deferred) |
| FR-009 per-verb handle revalidation | T021, T042 | FR-020 locale-rate guard | T042 |
| FR-010 Studio required | T042 | FR-021 helper holds no model | T021 |
| FR-011 record mapping | T016, T024 | FR-022 test discipline | conventions + all test tasks |
| FR-011b inbound id adoption | T046, T048 | FR-023 commands invocable | T024, T031, T043, T049, T054b-1..4 |
| FR-011c connect imported (id + positional) | T047, T049, T050 | FR-024 pull Resolve edits | T052, T054a, T054b-1..4, T055 |
| FR-012 reconcile (bladed inherit) | T036, T037 | FR-025 edit conflict detection | T053, T054a, T054b-1..4, T055 |

## Validation checklist
- [x] Every contract verb has a contract test (T013/T014/T027/T028/T051) before its helper impl (T021/T029/T052).
- [x] Every spec FR (001–025, incl. 011b/c, 013a) maps to a task — see traceability matrix above.
- [x] Every entity has a model task (T015 clip_grade, T016 resolve_bridge_link) gated by schema T009.
- [x] Every quickstart scenario has a 🟢 LIVE test (steps 1–6 → T025,T033,T034,T031-undo,T037,T026; edges → T042; scenario 7 / render+relink carved out — see Phase 5 note).
- [x] Tests precede their implementation (TDD); spikes precede code that assumes them.
- [x] [P] tasks touch distinct files; no two [P] tasks edit the same file.
- [x] Resolve behavior is asserted only by live tests; no mock-asserts-mock.

## Coverage bounded (stated, not hidden)
- 🟢 LIVE + 🔬 SPIKE tasks require a real Resolve Studio + human runner; they are **not** auto-completable headlessly. An implementing agent must pause at these for Joe to run them, per the STOP gates.
- The fidelity-badge UI (T043) is intentionally minimal; the full inspector color UI is deferred to a later spec (spec §5.5).
