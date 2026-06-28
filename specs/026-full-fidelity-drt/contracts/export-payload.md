# Contract — Export Payload (payload_builder ↔ drt_writer)

The internal contract between the **producer** (`payload_builder.build`) and the
**consumer** (`drt_writer`). This is the seam 026 widens. Shape detail is in
`../data-model.md`; this file states the per-side obligations and assert points so the
two modules can be built/tested independently (TDD).

## Producer obligations — `payload_builder.build(db, project_id, sequence_id)`
1. **P1 (FR-001/002, CORRECTED per research D10):** For each media item, emit the TC origin from
   the carrying stream. Video → `start_tc_frame` (`get_start_tc`, frames at native fps). Audio →
   from `get_audio_start_tc()` `{samples, rate}`, but the **timeline clip is frame-domain**: emit
   `native_rate` = seq fps and `start_tc_frame` = samples ÷ rate × seq_fps (so `<MediaFrameRate>` =
   seq fps, `<MediaStartTime>` = seconds). MUST NOT call `get_start_tc()` on audio media. Raw
   sample-domain values feed the gap-#2 `Sm2MpAudioClip` `TracksBA` only — NOT the timeline `<In>`.
   - *Assert:* a media item missing BOTH a video and audio TC origin → assert with
     `media.id` (genuinely-missing required characteristic, not a recoverable case).
2. **P2 (FR-010):** Video media items carry their own `width/height/frame_rate/codec/
   embedded_audio`. Audio media items carry `sample_rate/channel_layout/duration_samples`.
   - *`codec`* is sourced from `media.codec`, which the DRP importer must populate from the
     `<Clip>` blob's `f5` (it currently reads only path); a genuinely-unknown codec asserts
     (FR-019), never a hard-coded four-CC.
3. **P3 (FR-007/008/009):** Every audio clip carries a `routing` descriptor
   (`kind`, `media_track_idx`, `source_channel`, `virtual_audio_track`). `source_channel`
   resolves through the **`clips.master_audio_track_id` pin** (the pinned master AUDIO
   track's `media_refs.source_channel`), set at import by decoding the per-clip
   `VirtualAudioTrackBA`/`ChannelsBA` (research D11). `media_track_idx` derives: synced → 2,
   pinned single channel → `source_channel`, composite/whole-file → 0.
4. **P4 (FR-013/014):** A video clip with synced audio carries `synced_linkage`
   (`audio_media_id`, `sample_offsets`, `virtual_track_index`) read from the **persisted
   link group** — `clip_link.get_link_group(clip_id)` (`clip_links`: `role` +
   `time_offset`) + `media_refs.source_channel` — NOT the import-time
   `resolve_synced_audio_streams` (unreachable at export). New read for `payload_builder`.
5. **P5 (FR-015):** Each clip carries `markers[]` from `clip_marker.find_by_clip`.
6. **P6 (FR-003):** `source_in/out` are whole frames for video clips, sample-accurate
   fractional for audio clips.
7. **Identity:** unchanged dedup by source-clip identity (two clips / one file = two items).

## Consumer obligations — `drt_writer`
1. **C1 (FR-004/006):** An audio media item → `Sm2MpAudioClip` via
   `build_media_pool_audio_item` (shape from `resolve_authored_full.drp`, §K2). A
   non-handled audio type → loud fail naming the file (FR-019).
2. **C2 (FR-010/011/012):** A video media item → `Sm2MpVideoClip` whose file-specific
   fields are encode-and-substituted into the **plaintext-XML hex** descriptor blobs
   (`<Geometry>` resolution = BE int64 w×h via the seq-resolution `%016x%016x` form;
   `<TracksBA>` embedded audio; `<Clip>` path + codec-from-`media.codec` (not hard-coded
   `avc1`/`AAC`); `<Time>` rate/dur) — NOT the zstd
   `<FieldsBlob>` (research D1). Fixed-form bytes match the fixture. No verbatim borrow of
   another file's descriptors.
3. **C3 (FR-007/008/009):** Per-clip `VirtualAudioTrackBA` + `MediaTrackIdx` come from the
   clip's `routing` (replaces the mono→A1 constant).
4. **C4 (FR-013/014):** A clip's `synced_linkage` → the D1-decoded linkage region of the
   video item's FieldsBlob, **synthesized** from the descriptor. If D1 has not decoded the
   region → loud fail (no fallback, FR-014).
5. **C5 (FR-015/016):** Each `markers[]` entry → an `Sm2TiItemLockableBlob` (byte form
   from `markers_16color_edge.drp`, §E).
6. **C6 (FR-019):** Any clip/track/media that cannot be faithfully authored → loud,
   actionable failure naming it. Never skip, substitute, or default.
7. **C7 (FR-020):** Every emitted byte traces to a fixture; no new wire form.
8. **C8 (FR-022):** Re-exporting A005 through these general paths is byte-identical to the
   current output (the A005-only borrow branch + mono hardcode are deleted, not bypassed).

## Failure-path tests (2.32 — via `pcall`, assert message actionable)
- audio media with neither TC origin → producer asserts with id.
- synced clip while D1 linkage region undecoded → consumer loud-fails (no fake sync).
- unhandled audio type / unexportable clip → consumer loud-fails naming the file/clip.
- video media missing a required descriptor field → asserts (not borrowed/defaulted).
