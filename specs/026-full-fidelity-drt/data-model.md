# Phase 1 Data Model — Export Payload (extended)

The neutral **sequence export payload** that `payload_builder.build(sequence_id)` emits
and `drt_writer` consumes. No persisted-schema change — every field is sourced from an
existing JVE model accessor (cited). This documents the *extensions* gaps #1–#5 + markers
require over today's video-only payload.

Legend: **NEW** = added by 026; (existing) = already emitted.

---

## Sequence export payload (root)
| Field | Source | Notes |
|-------|--------|-------|
| `project = {name, fps}` | (existing) | unchanged |
| `media_refs[]` | (existing, extended) | deduped per source-clip identity; now includes audio items |
| `sequence = {name, fps, width, height, tracks[]}` | (existing) | unchanged |

Validation: ≥1 media_ref (no-media fails early, FR-019/edge); each track typed
`video`|`audio`.

---

## Media item — video
| Field | Source (`models/media.lua`) | FR |
|-------|------------------------------|----|
| `file_uuid`, `name`, `file_path`, `native_rate`, `duration_frames` | (existing) | — |
| `start_tc_frame` | `get_start_tc()` (video frames) | FR-001 |
| **`width`, `height`** | `media.width`, `media.height` (NEW in payload) | FR-010 |
| **`frame_rate = {num, den}`** | `media.frame_rate` (NEW) | FR-010 |
| **`codec`** | `media.codec` (NEW) — populated by DRP importer from `<Clip>` `f5` (see Rule) | FR-010 |
| **`embedded_audio = {channels, sample_rate}`** | `media.audio_channels`, `media.audio_sample_rate` (NEW) | FR-010 |

Rule (FR-010/012): every file-specific field comes from *this* media; the writer encode-
and-substitutes it into the plaintext-XML descriptor blobs — `<Geometry>` resolution as BE
int64 w×h (`%016x%016x`), `<TracksBA>`, `<Clip>` codec (driven by `media.codec`, replacing
the hard-coded `avc1`/`AAC`), `<Time>` — NOT the zstd FieldsBlob (research D1). `media.codec`
is empty for imported media until the DRP importer's `<Clip>` decode is extended to read `f5`
(research D1, codec fold-in). A required field absent from the model → assert (edge case),
never a borrowed/default value (1.14/2.13).

---

## Media item — audio (NEW entity)
| Field | Source | FR |
|-------|--------|----|
| `file_uuid`, `name`, `file_path` | (existing accessors) | FR-004 |
| **`audio_start_tc = {samples, rate}`** | `get_audio_start_tc()` | FR-001/002 |
| **`sample_rate`** | `media.audio_sample_rate` | FR-002 |
| **`channel_layout`** | `media.audio_channels` | FR-007/009 |
| **`duration_samples`** | `media.duration` (audio-only = samples) | FR-002 |
| `track_type = "audio"` | (existing) | — |

Rule: has **no** video characteristics; `media_to_payload` MUST NOT call `get_start_tc()`
for audio media (research D2). Drives `Sm2MpAudioClip` (research D4). The sample-domain fields
(`sample_rate`, `duration_samples`, `audio_start_tc`) feed the `Sm2MpAudioClip` `TracksBA` only.
**The TIMELINE clip is frame-domain** — `media_to_payload` derives `native_rate` = **seq fps** and
`start_tc_frame` = `audio_start_tc.samples ÷ sample_rate × seq_fps`, so `<MediaFrameRate>` = seq fps
and `<MediaStartTime>` = correct seconds (research D10, supersedes any "sample-unit In" reading).

---

## Clip placement
| Field | Source | FR |
|-------|--------|----|
| `id`, `media_uuid`, `source_media_id`, `sequence_start`, `duration`, `enabled`, `name` | (existing) | — |
| `source_in`, `source_out` | (existing) — video: whole frames; **audio: model samples → FRAMES at seq fps for the timeline `<In>`; sub-frame fraction preserves sample accuracy (research D10, NOT raw sample units)** | FR-003 |
| **`routing`** (→ Routing descriptor) | (NEW) | FR-007/008/009 |
| **`synced_linkage`** (→ Synced linkage, video clips with synced audio) | (NEW) | FR-013/014 |
| **`markers[]`** (→ Clip marker) | `clip_marker.find_by_clip(id)` (NEW) | FR-015 |

---

## Routing descriptor (NEW entity)
| Field | Source (**derived** from persisted state — no stored "routing" field) | FR |
|-------|------------------------------------------------------------------------|----|
| `kind` = `mono`\|`stereo`\|`synced` | `clip_link.is_linked` → synced; else the channel-selection pin `clips.master_audio_track_id` (non-null → mono, single channel) vs `media.audio_channels == 2` composite (→ stereo); else mono | FR-007 |
| `media_track_idx` | §F discriminator, derived: synced → **2**; pinned single channel (`master_audio_track_id` non-null) → **`source_channel`** (the pinned master AUDIO track's `media_refs.source_channel`); composite/whole-file → **0** | FR-008/009 |
| `source_channel` | resolved from the pin: `clips.master_audio_track_id` → that master AUDIO track's `media_refs.source_channel` (0-based file channel). Null when no channel pin (composite). | FR-008 |
| `virtual_audio_track` | §F `VirtualAudioTrackBA` form for the relationship | FR-009 |

Rule: channel selection is the **`clips.master_audio_track_id` pin** — a timeline audio
clip pins to a per-channel master AUDIO track, and `source_channel` is read back through
that track's `MediaRef` (`Sequence.find_master_audio_track_for_channel` resolves it during
import; `Clip.load`'s pin-aware JOIN resolves it at load). The DRP importer decodes the
per-clip `VirtualAudioTrackBA` (`ChannelsBA`, research D11) to set the pin: embedded/
standalone mono block (byte 9 == 0x00) → 1-based channel at byte 12 → `source_channel`;
synced (byte 9 == 0x20) → no pin (deferred to gap #5 linkage); stereo/pair block → no pin
(composite). Routing is then **derived** at export from the pin + `media.audio_channels` +
link-group membership (`models/clip_link.lua`) — there is no stored `clip.routing` field.
Replaces today's hard-coded mono→A1 (research D5). A routing kind with no fixture-matched
form → loud fail (FR-019), not a silent mono fallback.

---

## Synced linkage (NEW entity — video clip carrying synced audio)
| Field | Source (**persisted** model, read at export) | FR |
|-------|-----------------------------------------------|----|
| `audio_media_id` | the audio-role clip(s) of the video clip's **link group** — `clip_link.get_link_group(clip_id)` (`clip_links`: `role`, `time_offset`, `enabled`) → that clip's `media_id` | FR-013 |
| `sample_offsets[]` | per-channel file selection via `media_refs.source_channel`; V↔A alignment via the link group's `time_offset` + clip `source_in_subframe` | FR-013/014 |
| `virtual_track_index` | which virtual track of the video item (gap #5-decoded region, T001) | FR-013/014 |

Rule: the linkage is **persisted as a link group** (`models/clip_link.lua` over the
`clip_links` table) — NOT the import-time `resolve_synced_audio_streams` local (that
intermediate is unreachable at export). `payload_builder` does not read link groups today
(new read); it calls `clip_link.get_link_group` and emits the structure; the writer emits
it into the gap-#5-decoded `Sm2MpVideoClip.FieldsBlob` region. Until T001 cracks that
region, a clip with `synced_linkage` → loud fail (FR-014, no fallback). The writer
**synthesizes** linkage from this structure, never verbatim-borrows a fixture's group.

---

## Clip marker (NEW in payload — model exists)
| Field | Source (`models/clip_marker.lua`) | FR |
|-------|------------------------------------|----|
| `frame`, `duration`, `color`, `name`, `note`, `custom_data` | `find_by_clip` rows | FR-015 |

Rule: emitted as `Sm2TiItemLockableBlob` (research D7), byte form from
`markers_16color_edge.drp` (§E). Sequence markers excluded (no model — spec Out of Scope).

---

## Identity invariant (carried, not changed)
Two source clips over one physical file remain **distinct items by source-clip identity**
(master `import_uuid`/`id`), for audio and arbitrary-video items, not just A005 (spec edge
case). `media_refs` dedup key is unchanged (`clip_row.media_uuid`).
