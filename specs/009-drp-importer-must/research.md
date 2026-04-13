# Research: File Original TC for Override-Aware Relink & Decode

**Feature**: 009-drp-importer-must | **Date**: 2026-04-11

## R1: BtAudioInfo.TracksBA.StartTime Extraction

**Decision**: Extract `StartTime` from the existing `decode_bt_audio_duration()` TLV decoder — it already parses all fields via `decode_tlv_fields()` including StartTime (decoded as a double; the TLV decoder handles multiple double encodings — BE double type 0x0006 and LE blob type 0x000c). Currently only `Duration` and `SampleRate` are returned; adding `StartTime` is a one-line change to the return table.

**Rationale**: The TLV decoder already handles the field correctly; no new blob parsing logic needed.

**Alternatives considered**: (1) Separate `decode_bt_audio_start_time()` function — rejected, redundant TLV walk. (2) Use `BtVideoInfo.Time.Timecode` as file_original_timecode — rejected, that's the OVERRIDE TC (what Resolve shows after Set Timecode), not the file's container TC. TracksBA.StartTime always reflects the file's real container because it comes from the audio track header, which Resolve's Set Timecode feature doesn't modify.

## R2: Persistence of file_original_timecode

**Decision**: Store in the existing `media.metadata` JSON blob as two new keys: `file_original_timecode` (video frames at `start_tc_rate`) and `file_original_timecode_audio` (audio samples at `start_tc_audio_rate`). No schema version bump. No new column.

**Rationale**: (1) Consistent with how `start_tc_value` and `start_tc_audio_samples` are already stored. (2) No schema migration needed — old projects just lack the key (absent = no override = today's behavior). (3) The metadata JSON is already read/written everywhere media TC is accessed.

**Alternatives considered**: (1) New `file_original_timecode` column on media table — rejected, requires schema version bump and migration for a field that's only populated for override clips. (2) Separate `file_original_timecodes` table — rejected, over-engineering for a single optional field.

## R3: EMP Override Mechanism

**Decision**: One new method on `MediaFile`: `void set_tc_origin_override(int64_t first_frame_tc, int64_t first_sample_tc)`. Mutates `m_info.first_frame_tc` and `m_info.first_sample_tc` directly. Asserts if any decode has already occurred (tracked by a new `bool m_decode_started` flag set on first decode call). All downstream code reading `info()` sees the overridden values — no other changes needed in the decode paths.

**Rationale**: The `info()` method returns `const MediaFileInfo&` referencing `m_info`. Mutating `m_info` before any decode means all existing video decode paths (`file_frame = source_frame - info.first_frame_tc`) and audio decode paths (`file_pos = source_in - file_info.first_sample_tc`) automatically use the correct origin. Zero changes to decode algorithms.

**Alternatives considered**: (1) Override parameter on `MediaFile::Open()` — rejected, user explicitly wants one additive setter, not a constructor change. (2) Virtual "TC provider" abstraction — rejected, over-engineering. (3) Per-backend override in BRAW/FFmpeg paths — rejected, the override is codec-agnostic at the `MediaFileInfo` layer.

## R4: Threading Override Through TMB

**Decision**: New TMB method `SetTcOverrides(std::unordered_map<std::string, TcOverride> overrides)` where `TcOverride = {int64_t first_frame_tc, int64_t first_sample_tc}`. Lua binding: `EMP.TMB_SET_TC_OVERRIDES(tmb, overrides_table)`. TMB stores the map. In `acquire_reader()`, after `MediaFile::Open(path)` succeeds, TMB checks the map and calls `media_file->set_tc_origin_override(...)` before `Reader::Create()`.

**Rationale**: The override is per-media-path (all clips sharing a path share the same override). A path→override map is O(1) lookup per open, keeps `ClipInfo` unchanged, and doesn't bloat the per-clip Lua tables. Called once after `TMB_SET_TRACK_CLIPS`, before first `SetPlayhead`.

**Alternatives considered**: (1) Per-clip `tc_origin_override` in `ClipInfo` — rejected, redundant (N clips × same override per path). (2) Lua calling setter on individual MediaFile handles — rejected, TMB opens MediaFiles internally; Lua has no handle to them.

## R5: Peak Generator — No Change Needed

**Decision**: No change. Peak generator reads sequential audio samples from file start to end; it does not use `first_frame_tc` or `first_sample_tc` for seek positioning. Override is irrelevant for waveform generation.

**Rationale**: Confirmed by grep — `emp_peak_generator.cpp` has zero references to `first_frame_tc`, `first_sample_tc`, `source_in`, or `file_pos`.

## R6: Relinker TC Matching

**Decision**: In `find_candidates_for_media()`, when `match_timecode` is enabled, compare the candidate's probed TC against BOTH `media_start_tc_value` (existing, = override when present) and `media_file_original_tc` (new field, = file container TC). Accept on either match. No source_in remap on either match.

**Rationale**: The relinker currently computes `offset = compute_tc_offset(stored, probed)` and rejects candidates with `abs(offset) > 1`. Adding a second comparison with `file_original_tc` as the stored value gives a second chance. If the candidate matches on file_original_tc, the offset between stored (override) TC and probed TC will be large, but that's expected — the file is correct, just in a different TC space. The setter at decode time handles the difference.

**Alternatives considered**: (1) Remap source_in by `(override - file_tc)` on relink — rejected per user clarification; source_in stays in override space, EMP setter handles the decode-side delta.

## R7: Lua `Media:extract_tc_from_file` Guard

**Decision**: No code change needed. The `_ensure_tc_extracted()` path at `media.lua:190` already short-circuits when `meta.start_tc_value ~= nil`. DRP-imported override clips always have `start_tc_value` populated from the DRP's `BtVideoInfo.Time.Timecode`, so `_ensure_tc_extracted` never overwrites it with a probed value. The forced `extract_tc_from_file()` path is only used by non-DRP imports (drop-file) where no override exists, so writing probed TC into `start_tc_value` is correct.

**Rationale**: Confirmed by code reading — the existing guard protects override clips by construction. Adding an explicit "skip if override present" guard would be defensive but redundant.

## R8: Callsite Inventory (TMB internal opens)

All `MediaFile::Open` calls inside EMP that need the override:

| Site | File | Line | Uses | Override Needed? |
|------|------|------|------|-----------------|
| `acquire_reader` | emp_timeline_media_buffer.cpp | 1903 | Video + audio decode | **Yes** — primary playback path |
| Probe decode | emp_timeline_media_buffer.cpp | 2153 | Source viewer park (video) | **Yes** — parked frame display |
| TMB open path 1 | emp_timeline_media_buffer.cpp | 1728 | Internal path | **Yes** — delegate to same pool |
| Peak generator | emp_peak_generator.cpp | 188 | Sequential audio read | No — never uses TC for seek |
| Lua MEDIA_FILE_OPEN | emp_bindings.cpp | 108 | TC extraction / probe | No — reads TC, doesn't decode |

All three "Yes" sites go through `acquire_reader` or the same reader pool. A single map lookup in the pool acquisition path covers all three.
