# Contract: DRP Import — File Original TC Extraction

## decode_bt_audio_duration — extended return

**Current signature**: `decode_bt_audio_duration(hex_str) → {duration_samples, sample_rate} | nil`

**New signature**: `decode_bt_audio_duration(hex_str) → {duration_samples, sample_rate, start_time_seconds} | nil`

**New field**: `start_time_seconds` (number) — the `StartTime` TLV field from the TracksBA blob, decoded as a BE double representing seconds since midnight. This is the file's real container TC origin.

**Failure mode**: `start_time_seconds` is nil when the `StartTime` field is absent from the TLV. The function still returns successfully with `duration_samples` and `sample_rate` (existing callers that only need duration are unaffected). Per FR-003, the caller checks `start_time_seconds`, and if nil, logs a loud error naming the master clip and skips that media row.

## Media metadata population — file_original_timecode

**Where**: In `parse_drp_file()` media creation loop, after `media_start_time` is converted to `start_tc_value`.

**Logic**:
```
file_tc_seconds = bt_audio_result.start_time_seconds
file_tc_video = floor(file_tc_seconds * native_rate + 0.5)
file_tc_audio = floor(file_tc_seconds * audio_sr + 0.5)

if file_tc_video ~= start_tc_value then
    metadata.file_original_timecode = file_tc_video
    metadata.file_original_timecode_audio = file_tc_audio
end
```

**Preconditions**:
- `bt_audio_result` is not nil (TracksBA decoded successfully; otherwise media row is skipped)
- `native_rate > 0` (video fps, always available from DRP project settings)
- `audio_sr > 0` (audio sample rate, from TracksBA.SampleRate)

**Postconditions**:
- If override exists: `metadata.file_original_timecode ~= metadata.start_tc_value`
- If no override: `metadata.file_original_timecode` is nil (not stored)
- `metadata.start_tc_value` is unchanged (still the override/displayed TC)

## Media model accessor — get_file_original_timecode

**New method on Media model**: `Media:get_file_original_timecode() → tc_value, tc_rate | nil, nil`

**Behavior**:
- Reads `file_original_timecode` and `start_tc_rate` from parsed metadata JSON
- Returns the values if `file_original_timecode` is not nil
- Returns `nil, nil` if absent (no override — camera footage)

**Consumer**: Relinker (for TC matching) and playback_engine (for TMB override map).
