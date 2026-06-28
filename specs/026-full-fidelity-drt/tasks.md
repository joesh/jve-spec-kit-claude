# Tasks: Full-Fidelity Sequence Export to DaVinci Resolve

**Input**: Design documents from `/specs/026-full-fidelity-drt/`
**Prerequisites**: plan.md, research.md (D1–D8 + Current State), data-model.md,
contracts/{export-payload.md, drt-members.md}, quickstart.md

## Scope reminder (from plan.md)
- Export is **model → neutral payload → pure serializer**: `payload_builder.build` reads
  the JVE model; `drt_writer` is pure XML/blob synthesis. Both EXTEND; neither is replaced.
- **`payload_builder.lua` and `drt_writer.lua` are each touched by every gap.** Edits to
  either file are therefore **strictly sequential** — they are NEVER marked `[P]` against
  each other. The only genuinely parallel core work is the import-side codec decode
  (`drp_binary.lua` / `importer_core.lua`) and the RED test files (each its own new file).
- Order (cheapest/dependency-first): **gap #1 → gap #3 → gap #2 → gap #4 (+codec fold-in)
  → markers → gap #5**. Gap #5 (synced linkage) is the lone must-succeed zstd-FieldsBlob
  decode and is LAST; gaps #1–4 + markers satisfy the **interim acceptance gate**
  independent of it.
- TDD (Constitution III): every gap lands a **RED byte-shape test first**, against a named
  Resolve-authored fixture, via the existing `synthetic.helpers.drt_spike_fixture` idiom
  (`unzip_member` + needle/`plain_count`/length) — **no live Resolve** (D8). Fail paths
  tested via `pcall` with an actionable message (2.32).
- Fail-fast asserts, no fallbacks (1.14 / 2.13). F1: delete each special-case
  (`author_a005_compatible` quarantine, A005 descriptor borrow, mono→A1 hardcode) as the
  general path that replaces it lands — no parallel old/new implementations (2.15).

## Format: `[ID] [P?] Description`
- **[P]**: different file, no dependency on an unfinished task → may run in parallel.
- Every task names exact file path(s) + the FR(s) and fixture/§ it derives from.

---

## Phase 3.0: Decode gate (Phase-0 spike — must-succeed)

- [X] **T001** Decode the **gap #5 synced-linkage region** in the zstd
  `Sm2MpVideoClip.FieldsBlob` against `tests/fixtures/resolve/synced clip example.drp` and
  the A005 fixture (phase0 §J line 285 / §K4 line 480). Produce a decoded byte map: which
  audio media ↔ which virtual track ↔ per-channel `SampleOffset`. Decode with the existing
  `qt_zstd_decompress` + `drp_binary` FieldsBlob reader (`src/lua/importers/drp_binary.lua`
  ≈ `:747+`). **Must-succeed, no fallback (FR-014)** — until this is mapped, gap #5 stays
  blocked (T009/T025 depend on it). Record the offsets in `research.md` (new "D9 — gap #5
  linkage region" subsection). *(Gaps #1–4 + markers do NOT depend on T001.)*

---

## Phase 3.1: RED byte-shape tests (write FIRST; MUST FAIL before any Phase-3.2 impl)

All are NEW separate files → `[P]` among themselves (T009 excepted — needs T001's decode).

- [X] **T002** [P] RED test gap #1 (audio TC + source range, FR-001/002/003) in
  `tests/synthetic/binding/test_drt_audio_tc_source_range.lua`. **CORRECTED per research D10:**
  audio timeline clips are FRAME-domain (not sample-domain). Assert a standalone-audio
  `Sm2TiAudioClip`: `<MediaFrameRate>` = the **sequence fps** (e.g. 23.976, NOT 48000),
  `<In>` = `source_in − start_tc_frame` in **frames** at seq fps (sub-frame fraction preserves
  sample accuracy), `<MediaStartTime>` = correct seconds (frames/fps); video `<In>` = whole
  frame. Fixture `resolve_authored_full.drp` (standalone WAV `Sm2TiAudioClip`) — the §C audio
  clips there carry MediaFrameRate=seq-fps, MediaStartTime=0. No content shift.
- [ ] **T003** [P] RED test gap #2 (`Sm2MpAudioClip`, FR-004/005/006) in
  `tests/synthetic/binding/test_drt_audio_media_pool_item.lua`. Assert: exactly one
  `Sm2MpAudioClip` per standalone audio media; child order matches; file-specific fields =
  media's (path/rate/channels/dur); fixed bytes = fixture; `.wav` accepted; bad type
  loud-fails via `pcall`. Fixture `resolve_authored_full.drp` §K2.
- [X] **T004** [P] RED test gap #3 (routing, FR-007/008/009) in
  `tests/synthetic/binding/test_drt_audio_routing.lua`. Producer-isolated: every audio clip
  carries a `routing` descriptor; `MediaTrackIdx` varies (not constant 0); standalone WAV
  reads file channel 2 → `source_channel == 1`, `media_track_idx == source_channel`. → GREEN
  after T014. (Writer byte-shape for `VirtualAudioTrackBA` mono/stereo/synced is asserted at
  T015, not here — the writer cannot emit a standalone-audio pool item until gap #2.)
- [ ] **T005** [P] RED test gap #4 video descriptors (FR-010/011/012) in
  `tests/synthetic/binding/test_drt_video_descriptors.lua`. Assert a non-A005 video item
  carries its own resolution (`<Geometry>` Resolution = `%016x%016x` BE int64 w×h),
  embedded-audio (`<TracksBA>`), and path — encode-and-substituted into the **plaintext**
  blobs, NOT the zstd FieldsBlob; fixed bytes unchanged. Fixture gold
  `000_master clips/MpFolder.xml` (decoded D1).
- [ ] **T006** [P] RED test gap #4 codec authoring (FR-010) in
  `tests/synthetic/binding/test_drt_video_codec.lua`. Assert the writer emits the `<Clip>`
  `f5` four-CC from `media.codec` (drive a non-`avc1` value through and see it in the blob),
  NOT the hard-coded `avc1`/`AAC`. `encode_bt_clip_blob` `codec` param (`drt_binary.lua:455`).
- [ ] **T007** [P] RED test codec import decode in
  `tests/synthetic/lua/test_drp_clip_codec_decode.lua`. Assert
  `drp_binary.decode_bt_clip_path` (extended) returns the `<Clip>` `f5` codec alongside the
  path, on a real gold clip blob (`f5=codec` documented at `drt_binary.lua:421`). Without
  this, `media.codec` stays empty (verified empty for all 945 gold media).
- [ ] **T008** [P] RED test markers (FR-015/016) in
  `tests/synthetic/binding/test_drt_clip_markers.lua`. Assert one `Sm2TiItemLockableBlob`
  per clip marker carrying NAME/NOTE/KEYWORD/color at §E offsets; 16-color enum honored;
  sequence markers absent. Fixture `markers_16color_edge.drp` §E.
- [ ] **T009** RED test gap #5 synced linkage (FR-013/014) in
  `tests/synthetic/binding/test_drt_synced_linkage.lua`. Assert a synced WAV appears as
  virtual track N of the video item; which-audio↔which-video↔which-track round-trips;
  **synthesized** not verbatim; undecoded → loud fail. **Depends T001** (cannot assert bytes
  not yet decoded). Fixture `synced clip example.drp` / A005 §J/§K4.
- [ ] **T010** [P] Characterization/regression test FR-022 in
  `tests/synthetic/binding/test_drt_a005_regression.lua`. Pin the **current** A005 `.drt`
  per-member bytes now, so the general-path refactor is proven byte-identical (goes/stays
  GREEN through Phase 3.2–3.3). Current output is the oracle.

---

## Phase 3.2: Core implementation (ordered; shared-file edits SEQUENTIAL)

### Gap #1 — audio TC origin + source range (FR-001/002/003) — **REVISED per research D10**
> Audio timeline clips are FRAME-domain at the conformed (sequence) fps, NOT sample-domain.
> The writer's generic frame math is already correct; gap #1 is producer-only — supply
> frame-domain values for audio so `<MediaFrameRate>`=seq fps and `<MediaStartTime>`=correct
> seconds. Sample units stay in the gap-#2 `Sm2MpAudioClip` `TracksBA`.
- [X] **T011** `src/lua/core/resolve_bridge/payload_builder.lua` (≈`:140-150`,
  `media_to_payload`): branch on media kind — video → `media:get_start_tc()` (frames, native fps);
  audio-only (`width` falsy / 0) → derive FRAME-domain: `native_rate` = **sequence fps**;
  `start_tc_frame` = `get_audio_start_tc()` samples ÷ sample_rate × seq_fps. **Delete** the
  unconditional `get_start_tc()` assert that crashes audio (`:150`). Assert a media item missing
  BOTH a video TC and an audio TC origin, naming `media.id` (D2). Pass seq fps into
  `media_to_payload` (new arg) since audio media has no inherent fps. → GREEN T002 (TC half).
- [X] **T012** `payload_builder.lua` (after T011): clip `source_in/out` — video: whole frames;
  audio: model samples converted to **frames** at seq fps (sub-frame fraction preserves sample
  accuracy in `<In>`). JVE model keeps audio source_in in SAMPLES; convert at the payload
  boundary only (D10). → GREEN T002 (range half).
- [X] **T013** `src/lua/exporters/drt_writer.lua`: **NO CHANGE confirmed** — the generic
  `in_offset = source_in − start_tc_frame` (`:509`) + `media_start_seconds = start_tc_frame /
  native_rate` (`:530`) + `MediaFrameRate = native_rate` (`:573`) already produce the fixture
  bytes once T011/T012 feed frame-domain audio values. Verify against the RED test; only touch the
  writer if a genuine audio-specific divergence shows up (D10 expects none). → confirms GREEN T002.
- [X] **T013a** `drt_writer.build_in_element` (FR-003): emit the sub-frame `<In>` form
  `<frames>|<hex LE-double fraction>` when a clip's `in_offset` is non-integer (an audio
  source-in off the frame boundary). Was a loud integer-only assert (deliberate D10
  trip-wire); now emits the fractional form — whole frame as decimal, fractional part as a
  16-hex LE IEEE-754 double, joined by `|`. Byte-grounded against `retime-test.drt`
  (`<In>447|00f05d74d145e73f</In>`, phase0-findings §C); the importer's `parse_resolve_tracks`
  already decodes this same form, so the round-trip is symmetric. Test:
  `tests/synthetic/binding/test_drt_subframe_audio_in.lua`. RESOLVED
  [[todo_026_subframe_audio_in_encoding]].

### Gap #3 — payload-driven routing (FR-007/008/009)
> **Import-side prerequisite discovered during impl (not in original task list).** Routing
> derivation keys on which file channel a clip reads, persisted as the clip's pin to a master
> AUDIO track (`clips.master_audio_track_id` → that track's `media_refs.source_channel`). But
> DRP import populated this for ZERO clips: the per-clip channel selection lives in the clip's
> `VirtualAudioTrackBA`, which the importer never decoded (anamnesis-gold: 1691 audio clips, 0
> pinned). So gap #3 first decodes VATBA → pins the channel (T014a–c), THEN derives routing
> (T014). This is the architecturally-correct realization of Joe's "fix importer to decode
> VATBA" — a timeline audio clip resolves to the stream `(media_id, source_channel)` it
> actually plays, per the stream-first-class canon. Backward-compatible: nil pin = composite,
> unchanged. (Decoding-side RED: `test_drp_import_audio_channel_select.lua`.)
- [X] **T014a** `src/lua/importers/drp_binary.lua`: `decode_audio_channel_select(hex)` — decode
  the clip `VirtualAudioTrackBA` `ChannelsBA` payload (research D11). Mono block (12B) → byte 12
  = 1-based file channel → 0-based `source_channel`; byte 9 routing type gates: `0x00`
  embedded/standalone returns the channel, `0x20` linked/synced → nil (gap #5 owns the slot, and
  a synced master holds camera+sync tracks at overlapping channel numbers). Stereo block (16B) /
  absent → nil (composite). Reuses the shared `decode_tlv_fields` walker (`raw_payloads`).
- [X] **T014b** `drp_importer.lua` `parse_resolve_tracks` (+ `importer_core.lua`): extract the
  clip's `VirtualAudioTrackBA` → `clip.source_channel`; in `importer_core` pin
  `master_audio_track_id` via new `Sequence.find_master_audio_track_for_channel(master_id, ch)`
  (`models/sequence/queries.lua`) — the master AUDIO track carrying that channel. nil ch ⇒
  unpinned (composite), as before.
- [X] **T014c** `models/clip.lua` `Clip.load`: make the `source_channel` JOIN honor
  `master_audio_track_id` (pinned ⇒ that channel's ref) using the SAME `EXISTS(track_type) AND
  (master_audio_track_id IS NULL OR mr.track_id = …)` form already in the timeline clip-load
  paths (`core/database.lua` build_clip_from_query_row). Unifies export/playback/waveform
  channel resolution — no competing formulation.
- [X] **T014** `payload_builder.lua` (after T012): emit a per-clip **routing descriptor**
  (`kind` mono|stereo|synced, `media_track_idx`, `source_channel`) **derived** from persisted
  state — the pin `clip.master_audio_track_id` + resolved `source_channel` (which channel) +
  `media.audio_channels` (mono/stereo) + `clip_link.is_linked` (synced); there is NO stored
  `clip.routing` field (D5). synced ⇒ `media_track_idx = 2` (gap #5 owns the linkage); pinned ⇒
  mono, `media_track_idx = source_channel`; composite ⇒ stereo (2ch) / mono, `media_track_idx
  = 0`. → GREEN T004.
- [X] **T015** DONE 2026-06-26. New `drt_binary.encode_virtual_audio_track_ba(routing)`
  synthesizes the VATBA blob (ChannelsBA TLV payload: block size 8+4·nch, per-channel
  `[routing][00]40[ch]` descriptors; AudioType TLV int mono=1/stereo=0) — byte-equal to all
  in-scope fixture forms (mono ch-N, stereo composite) verified against
  resolve_authored_full.drp + anamnesis-gold-timeline.drp. `drt_writer.lua` audio branch now
  drives `VirtualAudioTrackBA` + `MediaTrackIdx` from `clip.routing`; **F1 hardcode
  `VIRTUAL_AUDIO_TRACK_BA_MONO_A1` + `MediaTrackIdx="0"` DELETED**. Synced → loud-fail (gap #5
  owns the virtual-track slot, FR-014). Byte-shape RED→GREEN test
  `tests/synthetic/binding/test_drt_writer_vatba.lua` (mono ch2 ≠ hardcode = the RED; stereo;
  synced loud-fail via pcall). Adversarial review: tightened `payload_builder.build_audio_routing`
  to loud-fail an unpinned >2-channel composite (was silently mis-routed to mono — no Adaptive
  form in the JVE model; FR-019). Shared `drt_spike_fixture.build_a005_payload` audio clip now
  carries the embedded mono-ch1 routing the producer always emits.

### Gap #2 — standalone-audio media-pool item (FR-004/005/006)
**FOUNDATION LANDED 2026-06-27** (full dissection research D4a; reference XML
`drt_canonical/full_reference_mp_audio_clip.xml`; `drt_binary.substitute_audio_tracks_ba`
byte-equal to fixture w/ `test_drt_audio_tracks_ba.lua`). Builder/dispatch/producer + T003 remain.
- [X] **T016** DONE 2026-06-27. `payload_builder.media_to_payload` emits the media `kind`
  discriminant + audio-pool fields (`sample_rate`, `num_channels`, `duration_samples`) for
  audio-only media. `drt_writer.build_mp_folder_xml` now dispatches by `kind` (asserts kind
  present); `kind="audio"` currently **loud-fails** naming gap #2/T017 (honest "not yet
  implemented" at the right layer — no longer routes a .wav through the video builder's
  .mp4/.mov reject). Dedup by source-clip identity is the existing media_refs identity (D4).
- [ ] **T017** `drt_writer.lua` (after T016): add `build_media_pool_audio_item` →
  `Sm2MpAudioClip` from the reference XML (identity gsub + `substitute_audio_tracks_ba` for
  rate/channels/duration + `encode_bt_clip_blob` for the path); replace the dispatch's
  audio loud-fail with it; accept `.wav`; **loud-fail** unhandled audio type naming the file
  (FR-019).
  → GREEN T003. **Clip-blob tail RESOLVED 2026-06-27** (was flagged as opaque residue): it
  is the file mtime (f13 µs) + media-type markers (f15/f18). Implemented option (b) — schema
  V19 `media.file_mtime_us`, importer reads it from the Clip blob, `encode_bt_clip_blob`
  re-emits it; byte-equal to the fixture audio Clip payload. Also fixed the video item's
  stale date/mtime. See research D4b. T017 reuses `encode_bt_clip_blob` for the audio path.

### Gap #4 — arbitrary video descriptors + codec fold-in (FR-010/011/012)
- [ ] **T018** [P] `src/lua/importers/drp_binary.lua`: extend `decode_bt_clip_path`
  (`:242`) to also read `<Clip>` `f5` (codec) after path `f1/f2` — return `(path, dir,
  codec)`. Independent of payload/writer files → **[P]**. (`f5=codec` per `drt_binary.lua:421`.)
  → GREEN T007.
- [ ] **T019** `src/lua/importers/importer_core.lua` (after T018): set `media_item.codec`
  from T018's decode at the DRP media-build site (the `:859/:880` passthrough into
  `media.codec` already exists). Populates the currently-empty column. Watch ripple:
  `Media.classify_is_still` consumes `media.codec` (sharpens, doesn't break).
- [ ] **T020** `payload_builder.lua` (after T016): video media item carries its own
  `width/height/frame_rate/codec/embedded_audio` from `media` (FR-010); a required
  descriptor field absent → assert (1.14/2.13), never borrow.
- [ ] **T021** `drt_writer.lua` (after T017, `build_media_pool_video_item` `:733`):
  synthesize per-media descriptors — `<Geometry>` Resolution via `%016x%016x` BE int64 w×h
  (the seq-resolution form at `:976`), `<TracksBA>` embedded audio, `<Clip>` path + codec
  **from `media.codec`** (not `"avc1"/"AAC"` at `:819/827`). **F1 — delete** the `.mp4/.mov`
  assert (`:739`) and the A005-descriptor borrow. → GREEN T005 + T006.

### Markers (FR-015/016)
- [ ] **T022** `payload_builder.lua` (after T020): emit `markers[]` per clip from
  `clip_marker.find_by_clip(id)` (D7). Sequence markers excluded (no model).
- [ ] **T023** `drt_writer.lua` (after T021): emit user clip markers as
  `Sm2TiItemLockableBlob` (NAME/NOTE/KEYWORD/color), extending the existing
  `build_identity_marker_element` (`:889`) carrier; byte form from `markers_16color_edge.drp`
  §E. → GREEN T008.

### Gap #5 — synced V↔A linkage (FR-013/014) — gated on T001
- [ ] **T024** `payload_builder.lua` (after T022): emit `synced_linkage`
  (`audio_media_id`, `sample_offsets`, `virtual_track_index`) read from the **persisted
  link group** — `clip_link.get_link_group(clip_id)` (`clip_links`: `role` +
  `time_offset`) + `media_refs.source_channel` + clip `source_in_subframe` (D6). New
  export-side read of `models/clip_link.lua`. **NOT** `resolve_synced_audio_streams`
  (import-time local, unreachable at export). Read-only; no re-derivation.
- [ ] **T025** `drt_writer.lua` (after T023; **depends T001**): emit the linkage into the
  T001-decoded `Sm2MpVideoClip.FieldsBlob` region — **synthesize** via the existing
  `encode_fields_blob` (`drt_binary.lua:361`), in-place patch only for fixed-width fields in
  opaque regions. A `synced_linkage` clip while the region is undecoded → **loud fail**
  (FR-014, no fake sync). → GREEN T009.

---

## Phase 3.3: F1 cleanup + acceptance gates

- [ ] **T026** `drt_writer.lua`: **F1 — delete** the `author_a005_compatible` quarantine gate
  (`:1074`, asserts 23.976fps + mp4/mov at `:1081-1084`) and route the single general path
  as the entry point (rename if the A005-specific name no longer fits). No parallel old/new
  implementations (2.15). Depends on T013/T015/T017/T021/T023 (general paths landed).
- [ ] **T027** FR-022 regression: re-export A005 through the general path; T010 stays
  byte-identical per member. If any member diverges, the general path is wrong — fix the
  writer, not the test.
- [ ] **T028** **Interim acceptance gate** (FR-021 interim, quickstart Steps 1–4): the
  **non-synced** subset of the anamnesis gold timeline round-trips through JVE
  self-validation + per-member byte-shape for video/audio/range/routing/codec/markers on
  every non-synced clip. Independent of gap #5 (T024/T025). Run headless via `--test`
  (absolute script path).
- [ ] **T029** **Full acceptance gate** (FR-021 full, quickstart Step 5; **depends T025**):
  full gold incl. synced groups round-trips + synced linkage byte-shape. This is the headline
  definition of done. Live-Resolve import = optional manual spot-check only (not the gate).

---

## Phase 3.4: Polish

- [ ] **T030** [P] Failure-path coverage (2.32, via `pcall`, actionable messages):
  audio media missing both TC origins; synced clip while linkage undecoded; unhandled audio
  type; unknown codec; no-media sequence. One test file
  `tests/synthetic/binding/test_drt_export_failure_paths.lua`.
- [ ] **T031** [P] Run `make -j4` (authority gate) — C++/luacheck/full Lua + binding +
  integration suites green; then `.specify/scripts/bash/update-agent-context.sh claude`.

---

## Dependencies

- **T001 (gap #5 decode)** gates **T009** and **T025** only. Everything else is independent of it.
- **RED before GREEN**: T002→(T011,T012,T013); T003→T017; T004→T015; T005→T021; T006→T021;
  T007→T018; T008→T023; T009→T025; T010→T027.
- **Shared-file chains (strict order, same file):**
  - `payload_builder.lua`: **T011 → T012 → T014 → T016 → T020 → T022 → T024**
  - `drt_writer.lua`: **T013 → T015 → T017 → T021 → T023 → T025 → T026**
- **Import-side codec:** T018 (`drp_binary.lua`, [P]) → T019 (`importer_core.lua`).
- T026 (F1 quarantine delete) after all general paths land (T013/T015/T017/T021/T023).
- T028 (interim) after gaps #1–4 + markers + T026/T027; **not** after T024/T025.
- T029 (full) after T025.

## Parallel execution (the genuinely-independent work)

```
# RED test phase — all new files, write together, watch them fail:
Task: T002 test_drt_audio_tc_source_range.lua
Task: T003 test_drt_audio_media_pool_item.lua
Task: T004 test_drt_audio_routing.lua
Task: T005 test_drt_video_descriptors.lua
Task: T006 test_drt_video_codec.lua
Task: T007 test_drp_clip_codec_decode.lua
Task: T008 test_drt_clip_markers.lua
Task: T010 test_drt_a005_regression.lua
# (T009 waits on T001's decode.)

# Import-side codec decode runs parallel to the payload/writer chains:
Task: T018 drp_binary.decode_bt_clip_path reads <Clip> f5
```

> ⚠️ Do **NOT** parallelize any two `payload_builder.lua` tasks, nor any two
> `drt_writer.lua` tasks — they edit one file each and will conflict. The plan's "[P] only
> for independent files" reduces, in practice, to the RED tests + the import-side codec.

## Notes
- Verify each RED test fails before implementing its GREEN task.
- Commit after each task (explicit file list; attribution model+version+effort).
- Iterate with one targeted test (`cd tests && luajit test_harness.lua <file>` for Lua-only,
  or `--test` for binding/integration); **gate every change class with `make -j4`**.
- Bump nothing in schema — `media.codec` column already exists; no `.jvp` migration.

## Validation checklist
- [x] Every contract obligation has a task — export-payload P1–P7 → T011–T024;
  C1–C8 → T013–T027; drt-members rows #1–#5/markers/regression/acceptance → T002–T029.
- [x] Every data-model entity realized — video/audio media item, routing descriptor,
  synced linkage, clip marker, codec field → T016/T017/T020/T021/T014/T015/T024/T025/T022/T023.
- [x] All RED tests precede their implementation (Constitution III).
- [x] `[P]` only on truly independent files (RED tests, T018) — shared-file chains serialized.
- [x] Each task names exact file path(s) + FR + fixture/§.
- [x] Gap #5 (must-succeed decode) isolated as its own gate; interim gate independent of it.
