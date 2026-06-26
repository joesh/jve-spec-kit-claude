
# Implementation Plan: Full-Fidelity Sequence Export to DaVinci Resolve

**Branch**: `026-full-fidelity-drt` | **Date**: 2026-06-24 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/026-full-fidelity-drt/spec.md`

## Summary

Generalize the DRT export (`payload_builder` → `drt_writer`) from the single
baked-in A005 video spike to **any** JVE sequence: standalone audio, arbitrary
video, payload-driven channel routing, synced V↔A groups, and clip markers — on
the single-timeline `.drt` path. Ground truth is Resolve-authored fixtures plus
`specs/023-resolve-color-bridge/phase0-findings.md`; no invented wire bytes.

**Technical approach** (from Phase 0 / current-state analysis):

- The export is **model → neutral payload → pure serializer**. `payload_builder`
  reads the authoritative JVE model; `drt_writer` is pure XML/blob synthesis. Both
  extend, neither is replaced.
- **Gap #4 and gap #5 are SEPARATE, not one decode** (corrected against the fixture —
  see Current State in research.md). Gap #4's per-media descriptors live in **plaintext-XML
  hex** blobs (`<Geometry>` resolution = BE int64 w×h, decoded & verified; `<TracksBA>`;
  `<Clip>` codec; `<Time>`) — authored by the existing **encode-and-substitute** pattern,
  NOT the zstd FieldsBlob. The single real unknown is **gap #5**: the synced-linkage region
  inside the zstd `Sm2MpVideoClip.FieldsBlob` (§J/§K4 TBD). It is the lone must-succeed
  decode; prefer structural re-encode via the existing `encode_fields_blob`. Every emitted
  byte stays fixture-traceable (FR-020); FR-022 falls out because A005 re-authored through
  the general encode-and-substitute path reproduces its own values byte-for-byte.
- The other four gaps have decoded ground truth already: audio TC via
  `media:get_audio_start_tc()` + §C source-range encoding (gap #1); `Sm2MpAudioClip`
  child schema §K2 + `resolve_authored_full.drp` (gap #2); `MediaTrackIdx`
  discriminator §F (gap #3); clip-marker `Sm2TiItemLockableBlob` §E (markers).
- The synced-audio linkage **is persisted in the JVE model** as a **link group**
  (`models/clip_link.lua` `get_link_group` over `clip_links`: `role` + `time_offset`;
  per-channel via `media_refs.source_channel`). Gap #5 is purely an *export* gap: read
  that persisted state (a new `payload_builder` read) and emit the (Phase-0-decoded) linkage
  bytes. *(NOT the import-time `resolve_synced_audio_streams` local — unreachable at export;
  corrected in review.)*
- "Byte-equality" (FR-005/FR-021) is realized via the **existing test idiom**:
  unzip named `.drp`/`.drt` members and assert needle presence / occurrence counts /
  blob-hex lengths (e.g. `fixture.unzip_member` + `fixture.plain_count`), NOT a
  whole-file golden `==`. Decoded-form blobs assert on the patched byte ranges.

## Technical Context

**Language/Version**: LuaJIT 2.1 (exporter, payload, model); C++17/Qt6 only via
existing FFI (`qt_zstd_compress`/`qt_zstd_decompress`) — no new C++ expected.
**Primary Dependencies**: `core/resolve_bridge/payload_builder`,
`exporters/drt_writer`, `models/media` (`get_audio_start_tc`, `codec`), `models/clip_marker`,
`models/clip_link` (`get_link_group` — persisted synced linkage; new export-side read),
`importers/drp_binary` + `importers/importer_core` (codec fold-in: `<Clip>` `f5` →
`media.codec`), existing `qt_zstd_*` FFI, libzstd, dkjson, lsqlite3.
**Storage**: SQLite `.jvp` (read-only for export); output `.drt` (zip container).
No schema change (markers/synced-streams models already exist).
**Testing**: LuaJIT binding tests `tests/synthetic/binding/test_drt_writer_*.lua`
via `synthetic.helpers.drt_spike_fixture` (`build_*_payload`, `unzip_member`,
`plain_count`); contract tests MUST NOT poke live Resolve.
**Target Platform**: macOS desktop (JVE app); export is headless-capable (`--test`).
**Project Type**: single (Lua/C++ hybrid editor).
**Performance Goals**: N/A (export is a user-initiated batch op, not a hot path).
**Constraints**: fixtures-only byte forms (FR-020); fail-fast / no fallbacks
(FR-019, 1.14/2.13); no-live-Resolve in tests; gap #5 decode is must-succeed
(FR-014, no degraded path).
**Scale/Scope**: one active sequence per export (`build(sequence_id)`); acceptance =
anamnesis gold timeline (arbitrary video + standalone `.wav`, incl. synced groups).

## Constitution Check
*GATE: checked against constitution v2.0.0 (the plan-template's v1.0.0 stub —
Library-First / CLI Interface — is stale and does not apply; see Sync Impact Report
in `.specify/memory/constitution.md`).*

- **I. Modular Architecture / MVC**: ✅ model → payload → pure serializer; no view. `payload_builder` reads model, `drt_writer` is pure synthesis. Single responsibility per builder.
- **II. Command-Driven Interface**: ✅ Send to Resolve is an existing command; no new dispatch path.
- **III. Test-First (NON-NEGOTIABLE)**: ✅ each gap lands a RED byte-shape test first (member-extraction idiom), against a named Resolve-authored fixture, before the writer change. Failure paths (FR-019 loud-fail, FR-014 synced-blocked) tested via `pcall` + actionable message (2.32).
- **IV. Documentation-Driven**: ✅ spec complete + clarified + audited.
- **V. Template-Based Consistency**: ✅ follows plan/research/data-model/contracts/quickstart structure.
- **VI. Fail-Fast Assert**: ✅ audio-TC, missing-characteristic, no-media, synced-blocked, unexportable-clip all assert with clip/media id context.
- **VII. No Fallbacks**: ✅ FR-014 no degraded synced path; FR-019 no silent drop. **F1 watch:** the `author_a005_compatible` quarantine gate (`drt_writer.lua:1080-1084`, asserts 23.976fps + mp4/mov), the A005-only `build_media_pool_video_item` borrow, and the hard-coded mono→A1 routing are special-cases that MUST be deleted as the general path lands — no parallel old/new implementations (2.15 / "multiple implementations" prohibition).
- **VIII. No Backward Compatibility**: ✅ FR-022 is regression-protection of the *current* format (A005 re-exported through the general path stays identical), NOT maintenance of a legacy format. No shims.

**Gate: PASS** (Initial). F1 (delete borrow/hardcoded paths) tracked in Complexity.

## Project Structure

### Documentation (this feature)
```
specs/026-full-fidelity-drt/
├── plan.md              # This file
├── research.md          # Phase 0 — decode unknowns + decisions
├── data-model.md        # Phase 1 — extended export payload entities
├── quickstart.md        # Phase 1 — gold-timeline acceptance walkthrough
├── contracts/
│   ├── export-payload.md # neutral payload schema (payload_builder ↔ drt_writer)
│   └── drt-members.md    # per-gap .drp/.drt members + source fixture + byte-shape assertions
└── tasks.md             # Phase 2 output (/tasks — NOT created here)
```

### Source Code (repository root)
```
src/lua/
├── core/resolve_bridge/
│   └── payload_builder.lua      # EXTEND: audio TC (samples), per-clip routing,
│                                #         synced-linkage, markers; stop asserting
│                                #         video-frame TC on audio media
├── exporters/
│   └── drt_writer.lua           # EXTEND: Sm2MpAudioClip builder; payload-driven
│                                #         routing (MediaTrackIdx/VirtualAudioTrackBA);
│                                #         general Sm2MpVideoClip via plaintext descriptors
│                                #         (Geometry/TracksBA/Clip/Time encode-and-substitute);
│                                #         synced-linkage emit; clip-marker blobs;
│                                #         DELETE A005-only borrow branch + mono hardcode
├── models/
│   ├── media.lua                # READ: get_audio_start_tc, channel/rate/duration, codec
│   ├── clip_link.lua            # READ (new export-side): get_link_group → persisted synced
│   │                            #   linkage (role + time_offset); the gap #5 source of truth
│   └── clip_marker.lua          # READ: find_by_clip (clip markers to export)
└── importers/
    ├── importer_core.lua        # EXTEND: thread media_item.codec into media.codec
    │                            #   (passthrough at :859/:880 exists; build site sets it)
    └── drp_binary.lua           # EXTEND: decode_bt_clip_path also reads <Clip> f5 (codec),
                                 #   not just path f1/f2 — populates the empty media.codec
                                 #   (gap #4 / FR-010 codec fold-in)

tests/synthetic/binding/
└── test_drt_writer_*.lua        # NEW per-gap byte-shape tests (RED first)

tests/fixtures/resolve/          # ground truth (no new invented bytes)
├── anamnesis-gold-timeline.drp  # acceptance (mono+stereo audio, arbitrary video)
├── resolve_authored_full.drp    # real Sm2MpAudioClip source (gap #2)
├── synced clip example.drp      # synced V↔A reference (gap #5 decode target)
└── markers_16color_edge.drp     # clip-marker reference (markers)
```

**Structure Decision**: Single-project Lua/C++ hybrid. All feature work is in the
Lua export layer (`payload_builder`, `drt_writer`) reading existing models; no new
C++ and no schema change. Decode/encode of the zstd FieldsBlob uses the existing
`qt_zstd_*` FFI from Lua business logic (2.18 / 1.10 — no business logic in FFI).

## Phase 0: Outline & Research

Unknowns to resolve in `research.md` (ranked by risk; gap #5 is the must-succeed
gate per FR-014):

1. **Synced-linkage region in the zstd `Sm2MpVideoClip.FieldsBlob` (gap #5 only, §J/§K4 —
   TBD).** The one critical decode: the region declaring "WAV X is virtual track N of this
   video." Decode against `synced clip example.drp` / A005. **Must-succeed, no fallback**;
   until cracked, a synced clip is blocked (loud fail) — never faked. (Gap #4's video
   descriptors are NOT here — they are plaintext-XML blobs, already decoded; see #1b.)
1b. **Gap #4 descriptors — decoded, no spike.** `<Geometry>`/Resolution = BE int64 w×h
   (verified against the gold's 9 distinct resolutions); author via the seq-resolution
   `%016x%016x` substitution. `<Clip>` codec via the existing `encode_bt_clip_blob` param.
   `<TracksBA>` embedded-audio = same plaintext-TLV class (per-field mechanical). A
   required descriptor field absent from the media → assert (1.14/2.13), never borrow.
2. **`Sm2MpAudioClip` write authoring (gap #2, §K2 — schema observed).** Confirm the
   child order + which fields are file-specific vs fixed, deriving from
   `resolve_authored_full.drp`.
3. **`MediaTrackIdx` / `VirtualAudioTrackBA` per-relationship forms (gap #3, §F —
   decoded).** Capture the three observed routing forms (embedded ch / linked synced
   WAV / standalone WAV) as payload-driven values.
4. **Clip-marker `Sm2TiItemLockableBlob` header (markers, §E — partial).** Decode the
   110-byte ASCII blob header enough to author NAME/NOTE/KEYWORD/color from
   `clip_marker` rows, against `markers_16color_edge.drp`.
5. **Audio TC + source-range confirm (gap #1, §C — decoded).** Confirm audio source-in
   is sample-accurate fractional, video is whole-frame; both via existing accessors.

**Output**: research.md with each decision + rationale + alternatives, and an explicit
"gap #5 decode status" gate.

## Phase 1: Design & Contracts

1. **`data-model.md`** — the extended export payload entities (Sequence export payload,
   Media item video/audio, Clip placement, Routing descriptor, Synced linkage), each
   field mapped to its authoritative JVE source accessor. No persisted schema change.
2. **`contracts/export-payload.md`** — the neutral payload schema `payload_builder`
   emits and `drt_writer` consumes (the internal contract), with per-FR producer/
   consumer obligations and assert points.
3. **`contracts/drt-members.md`** — for each gap, the `.drp`/`.drt` member(s) it
   authors, the Resolve-authored fixture the bytes derive from, and the byte-shape
   assertion (member + needle/count/length) that gates it.
4. **Contract tests** — one RED byte-shape test per gap (FR-001…FR-016), failing
   before implementation, using the `drt_spike_fixture` member-extraction idiom; no
   live Resolve.
5. **`quickstart.md`** — export the gold timeline: first the **interim gate**
   (non-synced subset → round-trip + member byte-shape), then the full gate including
   synced groups; plus the standalone-audio and arbitrary-video minimal cases.
6. **Agent context** — run `.specify/scripts/bash/update-agent-context.sh claude`.

**Output**: data-model.md, contracts/*, failing tests, quickstart.md, agent file.

## Phase 2: Task Planning Approach
*Describes what /tasks will do — NOT executed here.*

- Order: **gap #1 (audio TC) → gap #3 (routing) → gap #2 (Sm2MpAudioClip) →
  gap #4 (arbitrary video / plaintext descriptors) → markers → gap #5 (synced linkage)**.
  Rationale: cheapest-first and dependency-first — #1/#3 unblock the standalone-audio
  acceptance case and the **interim gate**; #4 is plaintext encode-and-substitute (resolution
  decoded, no spike) so it lands independently of #5; gap #5 is last because it is the lone
  must-succeed zstd-FieldsBlob unknown that can block.
  - **Gap #4 includes the codec fold-in (FR-010):** an import-side task to extend
    `drp_binary.decode_bt_clip_path` to read `<Clip>` `f5` (codec) → populate the currently-
    empty `media.codec`, then the writer drives `encode_bt_clip_blob`'s `codec` from the
    payload instead of the hard-coded `avc1`/`AAC`. Ordered with gap #4 (same descriptor).
- Each gap = [RED byte-shape test task] → [payload_builder extension] → [drt_writer
  extension] → [delete the special-case it replaces] (F1).
- A Phase-0 spike task for the **gap #5** zstd-FieldsBlob linkage decode is its own gate;
  gap #4 needs no spike (descriptor format already decoded — research D1/§Current State).
- FR-022 regression task: re-export A005 through the general path, assert byte-identical.
- FR-021 acceptance tasks: interim gate (non-synced gold) then full gold.
- Mark [P] only for independent files (gap #4 and gap #5 no longer share a decode, so #4's
  tasks are [P] against the #5 spike).

**Estimated Output**: tasks.md with per-gap RED→GREEN→delete chains + the Phase-0
decode spike + interim/full acceptance gates. (Count set by /tasks, not guessed here.)

## Complexity Tracking

| Item | Why needed | Simpler alternative rejected because |
|------|-----------|--------------------------------------|
| Decode the **gap #5 synced-linkage region** in the zstd `Sm2MpVideoClip.FieldsBlob` (structural re-encode via `encode_fields_blob`; in-place patch only for fixed-width fields in opaque regions) | No public spec for the blob; fixtures are the only ground truth (FR-020); gap #5 is the lone undecoded carrier (§J/§K4) | "Synthesize from scratch" — no format spec, would invent bytes (FR-020). *(Gap #4 is NOT here — its descriptors are plaintext, already decoded.)* |
| F1: delete the **`author_a005_compatible` quarantine gate** (23.976+mp4/mov asserts, `drt_writer.lua:1080-1084`), the A005-only video-item borrow, and the mono→A1 routing hardcode as the general path lands | 2.15 / no-parallel-implementations; FR-022 is met by the *general* path reproducing A005, not by keeping the special case | Keeping both — two implementations of one function, the exact prohibition; the A005 quarantine would mask gaps in the general path. |
| Gap #5 must-succeed decode with no degraded path | FR-014 explicit: never fake/approximate sync | A heuristic/fallback synced authoring — spec forbids it; a wrong sync silently corrupts the round trip. |

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete (/plan) — `research.md`
- [x] Phase 1: Design complete (/plan) — `data-model.md`, `contracts/*`, `quickstart.md`
- [x] Phase 2: Task planning approach described (/plan)
- [ ] Phase 3: Tasks generated (/tasks)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed (gold timeline round-trip + byte-shape)

**Gate Status**:
- [x] Brownfield Code-Grounding Gate: PASS (research.md "Current State" — `drt_writer`/`drt_binary` read in full + gold decoded, cited)
- [x] Initial Constitution Check: PASS (v2.0.0; F1 tracked)
- [ ] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved (Session 2026-06-24 + pre-plan audit)
- [x] Complexity deviations documented

---
*Based on Constitution v2.0.0 - See `.specify/memory/constitution.md`*
