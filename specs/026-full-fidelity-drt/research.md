# Phase 0 Research — Full-Fidelity DRT Export

Resolves the unknowns in the plan's Technical Context. Ground truth: Resolve-authored
fixtures in `tests/fixtures/resolve/` + `specs/023-resolve-color-bridge/phase0-findings.md`.
Each decision cites the fixture/section it derives from; no invented bytes (FR-020).

---

## Current State — how the export writer works today (read in full, cited)

Grounding for every decision below (brownfield gate). Read `drt_writer.lua` (1219 lines)
and `drt_binary.lua` (584 lines) end to end + decoded the gold fixture.

- **Entry point is a hard quarantine.** `drt_writer.author_a005_compatible`
  (`drt_writer.lua:1074`) asserts *every* media is ≈23.976fps **and** mp4/mov
  (`:1080-1084`). It cannot ingest the gold timeline at all. Generalizing = removing this
  gate (and likely renaming), not adding a parallel path — this is what F1 deletes.
- **Three authoring mechanisms exist:** (a) **structured encoders** `drt_binary.encode_*`
  (BtVideoInfo `<Time>` :786, `<Clip>` path/codec :815-835, markers :890, retime curves);
  (b) **encode-then-substitute a known reference hex** — seq Resolution/FrameRate/
  MediaExtents at `:966-999` (resolution via `%016x%016x` BE int64); (c) **verbatim borrow**
  of zstd blobs (`Sm2MpVideoClip.FieldsBlob`, per-clip `TI_*_FIELDS_BLOB`) + still-borrowed
  plaintext `<Geometry>`/`<TracksBA>`/`VirtualAudioTrackBA`.
- **Per-media video descriptors are plaintext-XML hex, not zstd.** Real gold
  `000_master clips/MpFolder.xml`: 495 `<Geometry>`, 495 `<Time>`, 932 `<TracksBA>` plaintext
  siblings vs 945 separate zstd `<FieldsBlob>`. `<Geometry>`/`Resolution` decoded = BE int64
  w×h (verified, 9 distinct real resolutions). `<Time>`/`<Clip>` already payload-driven;
  `<Geometry>`/`<TracksBA>` borrowed; `<Clip>` codec hard-coded at the call site though the
  encoder takes a `codec` param (`drt_binary.lua:455`).
- **`encode_fields_blob` (`drt_binary.lua:361`)** authors zstd blobs by payload-bytes-in →
  recompress-out (used for `<Clip>` and markers), NOT byte-offset patching — the precedent
  for any gap #5 work.
- **`payload_builder.lua:150`** asserts a video-frame TC origin → crashes on audio media
  (the reported gap #1 bug). `build(db, project_id, sequence_id)` at `:172`.

Every D-decision below derives from this section or is tagged `[unverified — spike resolves]`.

---

## D1 — Gap #4 (plaintext descriptors) and gap #5 (zstd linkage) are SEPARATE; only #5 is undecoded

**Decision.** Author arbitrary-video descriptors (gap #4) by **encode-and-substitute
into the plaintext-XML hex blobs** the writer already authors that way — NOT by touching
the zstd `Sm2MpVideoClip.FieldsBlob`. The synced-linkage decode (gap #5) is a separate,
genuinely-undecoded effort confined to the zstd FieldsBlob. The two do not share a decode.

**Ground truth (decoded from the fixtures this session, via `drp_binary.decode_tlv_fields`).**
In a real Resolve `.drp` (`anamnesis-gold-timeline.drp`, `000_master clips/MpFolder.xml`)
each `Sm2MpVideoClip` carries its per-media descriptors as **plaintext-XML hex sibling
elements** — 495 `<Geometry>`, 495 `<Time>`, 932 `<TracksBA>` — distinct from the 945 zstd
`<FieldsBlob>` elements. The descriptors are NOT in the zstd blob:
- **`<Time>`** (duration/rate/timecode) — already payload-driven via
  `drt_binary.encode_bt_video_time` (`drt_writer.lua:786`).
- **`<Clip>`** (path/codec) — already payload-driven for path via `encode_bt_clip_blob`
  (`drt_writer.lua:815-835`); `codec` is already a parameter (`drt_binary.lua:455`; schema
  `f5=codec` documented at `:421` as the inverse of `decode_bt_clip_path`), merely hard-coded
  `"avc1"/"AAC"` at the call site (`drt_writer.lua:819/827`). **Codec fold-in (FR-010):** the
  model's `media.codec` column exists but is empty for imported media — the DRP importer's
  `decode_bt_clip_path` reads only path `f1/f2`, not `f5`. Closing the codec gap extends that
  decode to read `f5` → `media.codec` (the `importer_core.lua:859/880` passthrough already
  threads it), then the writer drives `codec` from the payload. No new wire form (FR-020): the
  four-CC is an existing decoded `<Clip>` field, round-tripped DRP→model→DRT.
- **`<Geometry>`** — a TLV blob (`[BE32 ver=1][BE32 count=4]` + UTF-16BE fields `UniqueId`,
  `Resolution`, `FrameSize`, `DbType="BtGeometry"`). The `Resolution` field's 16-byte
  payload is **width × height as two big-endian int64s** — *decoded and verified* against
  the 9 distinct real resolutions in the gold (480×360 … 8192×4320), all clean. This is the
  exact `string.format("%016x%016x", w, h)` form the writer ALREADY uses for the sequence
  resolution (`drt_writer.lua:975`). (`drt_binary.encode_resolution` — two LE doubles — is
  the WRONG encoder for this field; the seq-resolution path is the precedent.)
- **`<TracksBA>`** (embedded-audio descriptors) — same plaintext-TLV class (visible fields
  `StartTime/SampleRate/NumChannels/CodecName/ChannelLayout/BitDepth`); per-field authoring
  is mechanical via `encode_tlv_fields`.

So gap #4 = locate-and-substitute the per-media payload bytes inside the borrowed plaintext
Geometry/TracksBA blobs (resolution proven; codec via the existing param), carrying the TLV
frame as template residue and minting per-clip `UniqueId`. No zstd decode, no FR-020
violation (every byte traces to a decoded fixture field).

**Gap #5 — the lone undecoded item.** The synced V↔A linkage ("WAV X is virtual track N of
this video") lives in the zstd `Sm2MpVideoClip.FieldsBlob` (§J line 285, §K4 line 480 — TBD).
This is the one **must-succeed, no-fallback** decode (FR-014): until the linkage region is
mapped, a synced clip causes a loud failure (never faked). For it, prefer structural
re-encode via the existing `encode_fields_blob` (which already authors the `<Clip>` and
marker zstd blobs by payload-bytes-in, recompress-out); fall to in-place patch of the
decompressed template only for fixed-width fields amid still-opaque regions.

**Alternatives rejected.**
- *Route gap #4 through a zstd-FieldsBlob decode (earlier framing).* Refuted by the fixture:
  resolution/embedded-audio are plaintext-XML TLV siblings, not in the zstd blob. A
  FieldsBlob decode for gap #4 is unnecessary work and a second authoring mechanism (2.15).
- *Use `encode_resolution` (LE doubles) for the Geometry resolution.* Decode proves the field
  is BE int64, not LE double — wrong encoder.
- *Synthesize the gap #5 blob from a spec.* No public format spec; would invent bytes (FR-020).

**Status entering Phase 1:** gap #4's descriptor format is **decoded now** (no spike needed
for resolution; TracksBA per-field is mechanical). Gap #5's FieldsBlob linkage region is the
single Phase-0 spike and its own gate (see plan Phase 2).

---

## D2 — Audio-only timecode origin from the audio stream (gap #1)

**Decision.** For audio-only media, read the TC origin from
`media:get_audio_start_tc()` → `(start_tc_audio_samples, start_tc_audio_rate)` in
**samples**, not `media:get_start_tc()` (video frames, returns `nil` for audio-only).
`payload_builder.media_to_payload` MUST branch on media kind and MUST NOT assert a
video-frame TC for audio media.

**Rationale.** `media.lua:101-127` — `get_start_tc` is V-only post-2026-05-16
normalization; `get_audio_start_tc` is the sole audio TC source. The current assert
(`payload_builder.lua:150`) is the reported crash.

**Alternatives rejected.** Synthesize a video-frame TC for audio (invents a frame grid
audio doesn't have; shifts content). Default to 0 (fallback — 2.13 violation; wrong for
BWF / cinema TC).

---

## D3 — Source range: video whole-frame, audio sample-accurate fractional (gap #1, §C)

**Decision.** Per the spec clarification + §C `<In>` encoding (`<int_frames>|<hex_LE_double>`):
**video** clip in/out export as whole frames (JVE's honest precision); **audio** clip
in/out export at sample-accurate fractional precision (audio is sample-positioned).
Neither shifts content.

**Rationale.** §C (line 163) decoded. JVE `source_in_frame` is integer; Resolve stores a
sub-frame double. For audio, the fractional part is the sub-sample offset and is
authoritative; for video, JVE has no sub-frame data, so whole-frame is honest (Resolve's
rate quantization applies on import).

**Alternatives rejected.** Force whole-frame for audio (loses sample accuracy, shifts
audio). Fabricate sub-frame video precision (invents data JVE doesn't have).

---

## D4 — Standalone audio media-pool item from §K2 + fixture (gap #2)

**Decision.** Add `build_media_pool_audio_item` authoring an `Sm2MpAudioClip` whose
child order + fixed bytes derive from `resolve_authored_full.drp` (the real
Sm2MpAudioClip) per §K2's observed schema; file-specific fields (path, sample rate,
channel layout, duration-in-samples, audio TC) come from the audio media. At minimum
`.wav` is accepted (FR-006); a non-handled audio type fails loud (FR-019), not silently.

**Rationale.** §K2 (line 371) documents the child order; `resolve_authored_full.drp` is
the only real Sm2MpAudioClip fixture. Today only `build_media_pool_video_item` exists and
it asserts `.mp4/.mov` (`drt_writer.lua:739`, fn at `:733`).

**Alternatives rejected.** Route audio through the video-item builder (wrong root
element; Resolve drops it). Skip standalone audio (FR-019 violation — the original crash).

### D4a — Full byte map (first-hand, `resolve_authored_full.drp` test_click_48k_stereo.wav)

`Sm2MpAudioClip` (DbId = source-clip identity) child order (§K2):
`FieldsBlob, Name, MpFolder, UniqueMediaPoolItemId, 6×Mark{In,Out}{,Video,Audio} empties,
CurPlayheadPosition, PinsBA/, VirtualAudioTracksBA, EmbeddedAudioVec>Element>BtAudioInfo{
FieldsBlob/, Clip, TracksBA, MediaMetadata/}`.

**Borrow-and-substitute strategy** (mirrors `build_media_pool_video_item`): commit the
test_click `<Element>` block as `drt_canonical/full_reference_mp_audio_clip.xml`; substitute:

| Field | Substitution | Mechanism |
|-------|--------------|-----------|
| `Sm2MpAudioClip@DbId` | → `media.file_uuid` (timeline `<MediaRef>` resolves) | plain_gsub |
| `<MpFolder>` back-ref | → minted `mp_folder` DbId | plain_gsub |
| `<UniqueMediaPoolItemId>` | → fresh UUID | plain_gsub |
| `<Name>` | → `basename(file_path)` | plain_gsub |
| `BtAudioInfo@DbId` | → fresh UUID (cross-archive safety) | plain_gsub |
| `BtAudioInfo>Clip` | → path via `enc.encode_bt_clip_blob{directory,filename,date,codec="Linear PCM"}` | re-encode |
| `BtAudioInfo>TracksBA` | → SampleRate/NumChannels/Duration substituted | targeted value replace |

**TracksBA value encodings (confirmed byte-equal to fixture):** plaintext Fusion-fields
blob, 31-byte header, field_count @ offset 28 (mirror `decode_bt_audio_duration:509`). Each
field = `<UTF-16BE name><be16 0><be16 type><value>`. Substitute by anchoring on
`utf16be(name)+type` and replacing the fixed-width value:
  All TLV ints encode as **`aux*256 + val`** (decode_tlv_fields:387/397), NOT a plain BE int:
- `SampleRate` type `0003`: 4-byte BE aux + 1-byte val (5 B). 48000→`000000bb80`.
- `NumChannels` type `0002`: 4-byte BE aux + 1-byte val (5 B). 2→`0000000002`.
- `Duration` type `0004`: **8-byte BE aux + 1-byte val (9 B)**. 144000 = aux 562 + val 128 →
  `000000000000023280` (NOT a 16-hex BE64 — that off-by-2 was the first encoder bug).
- Left borrowed (not file-derived for the interim): `BitDepth` (`0003`, =1), `CodecName`
  (`000a`="Linear PCM"), `UniqueId` (mint if cross-archive collision matters), `StartTime`
  (`0006` double = audio TC origin; 0 in fixture — wire to `get_audio_start_tc` if non-zero).
- `VirtualAudioTracksBA` (412 B, plaintext Fusion): a per-virtual-track list; the fixture's
  stereo wav carries TWO ChannelsBA descriptors (the same VATBA mono/stereo grammar as D11,
  one per master virtual track). For the interim borrow verbatim (stereo); a mono wav would
  need a single-descriptor form — synthesize via the D11 grammar if a mono standalone arises.
- Outer `FieldsBlob` (zstd, marker 0x81) + `BtAudioInfo>Clip` are zstd; the Clip path is
  re-encoded via `encode_bt_clip_blob` (already emits the zstd frame — same as video item).
  Outer FieldsBlob borrowed verbatim (clip-level metadata; no path/rate inside that matters).

### D4b — Clip-blob tail is the file mtime, NOT opaque residue (LANDED 2026-06-27)

The `Clip` blob protobuf tail was previously a frozen constant (`BT_CLIP_TAIL`) — believed
"per-file residue that can't be derived." Decoded first-hand, it is fully derivable:
- **f13 varint = source-file mtime in µs** (the same instant the f3 date string encodes;
  verified: audio fixture f13 = 1775764733195782 µs = "Thu Apr  9 12:58:53 2026" local).
- **f15 varint = media-type**: 4 = video, 2 = audio.
- **f16 varint = 100** (constant in every fixture).
- **f18 varint = media-type**: 16384 = video, 32768 = audio.

Implemented (option (b) — persist mtime in the model, exporter reads it; NOT a filesystem
probe): schema **V18→V19** adds `media.file_mtime_us`; the DRP importer reads it from each
pool item's Clip blob (`drp_binary.decode_bt_clip_mtime`, field 13) and round-trips it;
`encode_bt_clip_blob` takes `mtime_us` + derives f13/f15/f18 (media-type from the existing
video-shape discriminant) and the f3 date (`os.date` local, space-padded `%e`). Verified
**byte-equal to the fixture's decompressed Clip payload** for the test_click audio item.
This also fixed the video item's stale 2024 date / 2016 mtime (both now derive from the real
file). f16=100 and the f18 enum are kind-keyed from 2 fixtures — revisit if a fixture varies.

**Producer (T016) — LANDED:** `payload_builder.media_to_payload` emits, on an audio-only
media item, `kind="audio"` + `sample_rate` + `num_channels` + `duration_samples` (the
TracksBA inputs) + `file_mtime_us`. Dedup by source-clip identity (D4 — two clips/one file =
one item). **NOT yet emitted:** the sample-domain `audio_start_tc` for the TracksBA
`StartTime` — T016 reads `get_audio_start_tc()` only to derive the scalar `start_tc_frame`
(timeline-clip `<In>`); wiring the sample origin into the TracksBA is T017 (until then
`StartTime` stays the borrowed 0 — fine for the zero-origin fixtures).

**RED test (T003):** `test_drt_audio_media_pool_item.lua` — author a payload with a
standalone wav; assert exactly one `Sm2MpAudioClip`, child order, file-specific fields =
media's (path/rate/channels/dur), fixed bytes = fixture, `.wav` accepted, bad type
loud-fails via pcall.

---

## D5 — Payload-driven routing via MediaTrackIdx discriminator (gap #3, §F)

**Decision.** Replace the hard-coded `VIRTUAL_AUDIO_TRACK_BA_MONO_A1` +
`MediaTrackIdx = 0` (`drt_writer.lua:606-607`) with values **derived** from persisted
state — there is no stored `clip.routing` field. The three §F relationships are
discriminated from the media relationship: **embedded** channel of a video file (audio is a
video master's stream, `MediaRef=video master`, idx 0), **linked** channel of a synced WAV
(audio-role of a `ln` link group, idx per §F), **standalone** WAV (own audio master).
Channel selection is `clip.source_channel` / `media_refs.source_channel`; mono-vs-stereo is
`media.audio_channels`; synced-vs-not is `clip_link.is_linked`. Each form is matched against
the §F fixtures.

**Rationale.** §F (line 189) decoded `MediaTrackIdx` as the discriminator. 1.5 (no
hardcoded lists) requires routing be data-driven — and the inputs are all persisted and
reachable at export (`clips`, `media_refs`, `media`, `clip_links`).

**Alternatives rejected.** Keep mono→A1 (the gap #3 bug; mis-routes stereo/synced).

---

## D6 — Synced linkage read from existing JVE model, emit via D1 region (gap #5)

**Decision.** The synced-audio linkage is **persisted as a link group**:
`models/clip_link.lua` `get_link_group(clip_id)` over the `clip_links` table returns
the group's clips with `role` (video/audio), `time_offset` (V↔A alignment) and `enabled`;
per-channel file selection is `media_refs.source_channel`; sub-sample is
`clips.source_in_subframe`. `payload_builder` reads this **persisted** state into the
synced-linkage descriptor (it does not read link groups today — a new read); `drt_writer`
emits it into the gap-#5-decoded FieldsBlob region. The writer **synthesizes** the linkage
from the decoded structure (not verbatim-borrow a fixture's group — FR-014).

**Rationale.** Gap #5 is an *export* gap only; the data is persisted and reachable.
**Correction (review pass):** the earlier draft cited
`importer_core.resolve_synced_audio_streams` / `master_builder.add_synced_audio_streams` —
those are **import-time intermediates, unreachable at export** (verified: the only
occurrences are a local `n()` builder in `importer_core.lua`; `payload_builder`/exporter do
not read them). The export-time source is the persisted link-group model. Verbatim-borrow
would reproduce one fixture's group, not arbitrary ones.

**Alternatives rejected.** Re-derive sync from scratch at export (duplicates the importer's
work; risks divergence). Emit a fixture's sync verbatim (only reproduces that one group).

---

## D7 — Clip markers via Sm2TiItemLockableBlob (markers, §E)

**Decision.** Export user clip markers from `clip_marker.find_by_clip(clip_id)` as
`Sm2TiItemLockableBlob` entries in project.xml, byte form derived from
`markers_16color_edge.drp` per §E. (Identity markers already emit this way —
`drt_writer.build_identity_marker_element:889` — so the carrier exists; this adds the
user-marker payload: name/note/keyword/color.) Sequence markers are **out of scope**
(no JVE model — spec Out of Scope).

**Rationale.** §E (line 179): clip markers live in project.xml `Sm2TiItemLockableBlob/
FieldsBlob` (110-byte ASCII), not on `Sm2TiVideoClip.MarkersBA`. `clip_markers` table +
`clip_marker.lua` already store them. §E header layout is partially TBD → a small Phase-0
decode (offsets for NAME/NOTE/KEYWORD/color) against the fixture.

**Alternatives rejected.** Emit markers on the timeline clip's `MarkersBA` (§E proved
Resolve ignores that). Invent the blob header (FR-020 violation).

---

## D8 — Byte-equality via member-extraction idiom, not whole-file `==`

**Decision.** FR-005/FR-021 "byte-for-byte where the format is fixed" is realized with the
existing test idiom: unzip named `.drp`/`.drt` members and assert needle presence /
occurrence counts / blob-hex lengths (`fixture.unzip_member` + `fixture.plain_count`, e.g.
`test_drt_writer_media_pool_population.lua`, `test_drt_writer_media_extents.lua` asserts
`#extents_hex == 32`). Decoded-form blobs assert on the patched byte ranges; file-specific
fields assert *derivation from media*, fixed-form fields assert *match to fixture*.

**Rationale.** No existing test does whole-file golden `==`; container ordering/timestamps
make that brittle. Member-extraction is the established, stable oracle and correctly
distinguishes file-specific (derived) from fixed (matched) fields (FR-012).

**Alternatives rejected.** Whole-file `==` (brittle to zip metadata; conflates derived and
fixed fields). Live-Resolve import as the gate (forbidden by the contract rule; FR-021
makes it an optional spot-check only).

---

## D9 — Gap #5 synced-linkage region byte map (T001 decode gate)

**Status: decode gate SATISFIED for the proven region; one residual asymmetry flagged for
the T025 round-trip.** Verified first-hand (own LuaJIT decode of `SYNCED_HEX`,
`test_drp_fields_blob_decode.lua:50`; zstd-CLI stub; offsets 1-indexed in the 2670-byte
decompressed payload). The import decoder (`drp_binary.scan_media_refs` /
`extract_media_refs` / `extract_media_ref_sample_offsets`, `drp_binary.lua:909-963`) is the
ground truth — gap #5 was NOT an undecoded unknown; the linkage round-trips on import today.

**Container.** The `Sm2MpVideoClip.FieldsBlob` decompresses to a Fusion "Fields" container.
Each field is framed (CONFIRMED against bytes):

```
[00 00]            2B pad
[LE16 name_len]    name byte length (UTF-16LE, so = 2×char count)
[name]             field name, UTF-16LE
[00 00]            2B separator
[LE16 type]        type tag
[value]            type-dependent value (note: blob VALUES are big-endian — Fusion quirk)
```

**Verified type tags / value forms (this fixture):**
- `SampleOffset` — type `0x0004`, value = **BE64 signed** samples. Fixture value
  `00 00 00 00 00 0e de 3f` = 974399. Present once per external-WAV channel; absent for
  camera-embedded scratch refs. (name@286,710,1134,1558,1982)
- `MediaRef` — type `0x000a`, value = `[BE32 len=72]` + 72-byte UTF-16BE dashed UUID (a
  BtAudioInfo DbId). 7 occurrences: 5× external WAV `580b74c0-…-c02df71eccc2`,
  2× embedded `5c14f5ac-…-ae1f9691`.
- `ChannelIdx` — type `0x0002`, value = `[BE32 channel]` + trailing `00`. Values **4,3,2,1**
  (name@428,852,1276,1700) — on-wire order is **reverse** channel index.
- Sibling per-channel fields in the ~424B block stride: `BitDepth` (0x0003), `CodecName`
  (0x000a, "Linear…"), `ChannelVecBA` (0x000c), `Origin` (0x0003), `MediaExtents` (0x000c).

**RESIDUAL — must resolve at T025, do NOT assume:** there are **5 external-WAV MediaRefs
but only 4 `ChannelIdx` fields** (4,3,2,1). The 5th WAV ref (MR@2023, with SampleOffset
@1982 but **no** trailing ChannelIdx) and the 2 embedded refs (MR@2369+) follow a different
sub-layout. So the MediaRef ↔ ChannelIdx ↔ virtual-track relationship is **NOT** a clean
1:1 — the 5th ref is likely a clip-level/primary reference distinct from the 4 per-channel
records. `[UNVERIFIED]` which virtual track each maps to. This is settled empirically by the
T025 byte-equality round-trip test against this fixture, not by assumption (FR-014: a synced
clip while the region is not faithfully reproducible → loud fail, no fake sync).

**Encoder reuse (for T025).** `drt_binary.encode_fields_blob` (`drt_binary.lua:361`) does the
outer zstd wrapper only — reusable as-is. The TLV encoders (`encode_tlv_fields`/`encode_field`,
≈`:189-215`) emit UTF-16**BE** names / BE32 lengths — the **TLV** container, NOT this Fusion
Fields framing (UTF-16LE names, `[2B pad][LE16 len]`). T025 needs Fields-framing emitters
(SampleOffset/MediaRef/ChannelIdx) + a **signed** BE64 (existing `write_be64` asserts `n>=0`;
SampleOffset is signed per `drp_binary.lua:890`). Per the plan, T025 prefers in-place patch of
fixed-width fields in the borrowed opaque region over full synthesis where the residual layout
is unverified.

## D10 — Gap #1 CORRECTION: audio timeline clips are FRAME-domain, not sample-domain

**Status: spec premise corrected (first-hand fixture decode).** The spec/tasks framed gap #1 as
"In/MediaStartTime math must work in audio SAMPLE units for audio media." **That is wrong for the
timeline clip.** Verified by dissecting `resolve_authored_full.drp` →
`SeqContainer/48e1a26b-…​.xml`:

- A standalone `test_click_48k_stereo.wav` `Sm2TiAudioClip` carries
  `<MediaFrameRate>872211b5dcf93740…` = **23.976 fps** (the conformed/sequence fps), **NOT 48000**.
  Audio and video clips share the IDENTICAL `<In>` encoding (`71|<LE-double subframe>` = frame +
  fraction) and `<MediaStartTime>0`. The 48000 sample rate + sample-count durations appear ONLY in
  the media-pool `Sm2MpAudioClip`'s `TracksBA` (gap #2: SampleRate=0xBB80, Duration=144000 samples).
- Reconciled with phase0-findings:149/273/460 — `<MediaStartTime>` is **seconds**
  (`start_tc_frame / native_rate`), which is unit-agnostic (samples/sr AND frames/fps both → sec).
  But `<MediaFrameRate>` = `native_rate` must be the **fps**, which forces the frame domain.

**Corrected gap #1 design (producer-only; writer math is already generic & correct):**
- `payload_builder.media_to_payload` must not crash on audio (the `:149` `get_start_tc()` assert).
  Branch on media kind (`width>0` ⇒ video; else audio-only).
- For an **audio** media item, emit FRAME-domain values so the writer's existing
  `in_offset = source_in − start_tc_frame` and `media_start_seconds = start_tc_frame / native_rate`
  produce the fixture bytes:
  - `native_rate` = the **conformed (sequence) fps** (→ `<MediaFrameRate>` = seq fps). NOT sample_rate.
  - `start_tc_frame` = audio TC origin in frames = `get_audio_start_tc()` samples ÷ sample_rate ×
    seq_fps (→ `<MediaStartTime>` correct seconds; 0 for a tc=0 WAV).
  - clip `source_in/out` = model samples converted to **frames** at seq_fps (the sub-frame fraction
    in `<In>` preserves sample accuracy). JVE model still stores audio source_in in SAMPLES
    (KEY INVARIANT) — the conversion is at the payload boundary only.
- The sample domain (sample_rate, sample-count duration, StartTime) is confined to the gap-#2
  `Sm2MpAudioClip` `TracksBA`. **No sample-unit math in the writer's timeline-clip path.**

**Impact:** T013 ("audio In/MediaStartTime in sample units") is REPLACED by "producer converts audio
TC/source_in samples→frames at seq fps; writer unchanged." T002 asserts audio `<MediaFrameRate>` =
seq fps and frame-domain `<In>`. data-model P-rows + contracts P1/C1 corrected (research-pass).

**RESIDUAL / open for Joe (decisive vs inferred):** DECISIVE evidence = standalone-WAV
`<MediaFrameRate>` = 23.976 fps (not 48000), verified by decode. INFERRED = the exact non-zero
standalone-audio `<In>` form, because every standalone-WAV clip in the fixtures has `In=empty`
(source_in=0); the only non-zero `In` (`71|hex`) is on a video-file's audio/video clip. So
"audio In = frames at seq fps" is the design that fits ALL observed evidence but the standalone
non-zero case is confirmed only by the T002 round-trip + a live-Resolve spot-check, not a fixture.
**spec.md FR-002/003 were rewritten to the D10 frame-domain reality** (commit 730ea689):
FR-002 = "frame-domain at seq fps, NOT raw sample units"; FR-003 = audio sub-frame remainder via
the `<frames>|<hex LE-double>` `<In>` form, MUST NOT silently round. **T013a (2026-06-27)
implements that encoder** in `drt_writer.build_in_element`, byte-grounded against the only
fixture-attested non-zero pipe form (`retime-test.drt` `<In>447|00f05d74d145e73f</In>` = frame
447 + 0.72727… — a video-file clip's audio/video clip; standalone-WAV clips in the fixtures all
have `In=empty`). The importer's `parse_resolve_tracks` already decodes the same `NN|hex` form,
so the round-trip is symmetric. The non-zero *standalone-WAV* case is still confirmed only by the
round-trip + a live-Resolve spot-check, not its own fixture — but the byte form is identical
regardless of whether the clip is embedded-A/V or standalone, so there is no separate byte risk.

---

## D11 — Gap #3 audio routing: VirtualAudioTrackBA + MediaTrackIdx byte map

**Status: decoded first-hand** from `resolve_authored_full.drp` + `anamnesis-gold-timeline.drp`
SeqContainer XML, cross-referenced with phase0 §F (lines 189–198). §F names only the
discriminating offsets; the full hex below is from the fixtures (authoritative).

The `VirtualAudioTrackBA` is a Fusion Fields blob: `ChannelsBA` (the channel/routing descriptor)
+ `AudioType`. The **mono ch1 embedded** form is today's hardcoded `VIRTUAL_AUDIO_TRACK_BA_MONO_A1`
(drt_writer.lua:302–305). Field offsets (0-based, within the 84-byte mono blob):
- **b40** (LE u32 block size): `0x0c`=12 (mono/1-track), `0x10`=16 (stereo/2-track).
- **b49** routing type: `0x00`=embedded/standalone, `0x20`=linked/synced.
- **b52** (LE u32) 1-based channel index = `source_channel + 1`.
- **b82–83** AudioType value: mono=`0001`, stereo=`0000`.

Distinct fixture forms (verbatim hex):
| Kind | MediaTrackIdx | VirtualAudioTrackBA hex |
|------|---------------|-------------------------|
| mono ch1 embedded/standalone | `source_channel` (=0) | `00000001000000020000001400430068...004200410000000c000000000c0000000200000001`**`00`**`0040`**`01000000`**`00000012004100750064...0054007900700065000000020000`**`0001`** |
| mono ch2 standalone | `source_channel` (=1) | …same as ch1 but b52 word = `02000000` (`...010000400200000000000012...0001`) |
| stereo both-ch embedded | `0` | block b40=`10`; bytes44–59 = `02000000 02000040 01000040 02000000`; AudioType=`0000` |
| stereo ch1-only | `0` | stereo form but b56 word = `01000000` |
| linked/synced ch1 | `2` (slot) | mono form but b49=`0x20`: `...0200000001`**`20`**`0040 01000000 ...0001` |

**Derivation from JVE model (T014 routing descriptor):**
- `source_channel` = `clip.source_channel` (= `media_ref.source_channel`, **0-based**;
  `models/media_ref.lua:94-101`, `models/clip.lua:149`). NULL on video clips.
- `audio_channels` = `media.audio_channels` (1=mono,2=stereo; `models/media.lua:525/568`).
- synced ⇔ `clip_link.is_linked(clip_id)` AND its `get_link_group` has a `role="video"` member
  (`models/clip_link.lua:60`/`:10`; roles enforced `:139`).
- **MediaTrackIdx** = `source_channel` (0-based) for embedded/standalone; **= 2 for the first
  linked track** (the virtual-track SLOT — NOT derivable from JVE model; lives in the
  `Sm2MpVideoClip.FieldsBlob`, §J/D9). Multi-linked-track slot generalization is gap #5 (T025).
- **VATBA b52 channel index** = `source_channel + 1` (0-based → Resolve 1-based).

**Import persistence (T014a/b) — the channel selection is a pin, not a stored field:**
the DRP importer decodes `VirtualAudioTrackBA` on the way in (`drp_binary.decode_audio_channel_select`)
and pins the timeline clip to a per-channel master AUDIO track via `clips.master_audio_track_id`
(`Sequence.find_master_audio_track_for_channel`). `clip.source_channel` is then read back through
that pin by `Clip.load`'s pin-aware JOIN — so the "= media_ref.source_channel" identity above is
realized through the pin, not a separate stored column on the timeline clip.
The decoder works on the **TLV-extracted `ChannelsBA` payload** (the 12-byte mono block), using
payload-relative offsets — `payload:byte(9)` = routing type (`0x00` embedded/standalone → channel;
`0x20` synced → no pin, deferred to gap #5), `payload:byte(12)` = 1-based channel — NOT the
whole-84-byte-blob offsets (b49/b52) tabulated above. Payloads ≠ 12 bytes (stereo/pair) → no pin
(composite). All offsets verified GREEN against the fixtures.

**Scope split:** mono/stereo (embedded + standalone) are fully derivable now → interim gate
(T028, non-synced). The synced form (b49=0x20, MediaTrackIdx=2) is emitted from is_linked but its
slot number ties to gap #5; the 9-channel forms (Forms B/C/D in anamnesis) are OUT OF SCOPE for
gap #3 (`0x40`→`0x80` multi-track flag undecoded — do not invent; loud-fail per FR-019).

---

## Open gate carried into implementation

- **Gap #5 / D1 FieldsBlob linkage-region decode**: decode gate satisfied (D9). The residual
  MediaRef↔track asymmetry is resolved by the T025 round-trip, not before. Gaps #1, #2, #3 and
  the markers work proceed against decoded fixtures and satisfy the **interim acceptance gate**
  (non-synced gold subset, FR-021) independent of gap #5.
