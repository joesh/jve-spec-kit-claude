# Contract: EMP TC Origin Override

## MediaFile::set_tc_origin_override

**Signature**: `void set_tc_origin_override(int64_t first_frame_tc, int64_t first_sample_tc)`

**Preconditions**:
- MediaFile is open (valid m_impl)
- No decode operation has been performed on this MediaFile instance
- `first_frame_tc >= 0`
- `first_sample_tc >= 0`

**Postconditions**:
- `m_info.first_frame_tc == first_frame_tc`
- `m_info.first_sample_tc == first_sample_tc`
- `m_decode_started` unchanged (still false)
- All subsequent calls to `info()` reflect the overridden values
- All subsequent decode operations use the overridden TC origin

**Failure mode**: Asserts (hard crash) if called after decode has started. Assert message includes function name and file path.

**Thread safety**: Not thread-safe. Must be called before the MediaFile is shared. TMB's `acquire_reader` is the only call site in practice; it calls the setter in Phase 2 (before the pool mutex is acquired in Phase 3), which is safe because the MediaFile is freshly opened and not yet installed into the shared reader pool.

## TimelineMediaBuffer::SetTcOverrides

**Signature**: `void SetTcOverrides(std::unordered_map<std::string, TcOverride> overrides)`

**Preconditions**:
- TMB is initialized
- No playback is active (should be called after SetTrackClips, before SetPlayhead)

**Postconditions**:
- `m_tc_overrides` is replaced with the provided map
- Subsequent `acquire_reader` calls check this map for each opened path
- If path found in map, setter is called on the new MediaFile before Reader::Create

**Lua binding**: `EMP.TMB_SET_TC_OVERRIDES(tmb, overrides_table)`

Where `overrides_table` format:
```lua
{
    ["/path/to/vfx_file.mov"] = { video = 1194321, audio = 21855360 },
    ["/path/to/another.mov"]  = { video = 90000,   audio = 172800000 },
}
```

## Relinker TC Matching (Lua)

### find_candidates_for_media — extended contract

**Existing behavior**: Compare candidate's probed `start_tc_value` against `media_info.media_start_tc_value`. Accept if offset ≤ 1.

**New behavior**: If offset > 1 AND `media_info.media_file_original_tc` is not nil, compute a second offset comparing candidate's probed TC against `media_file_original_tc`. Accept if second offset ≤ 1. The `tc_mismatch` flag is NOT set for a match on `file_original_tc` — the candidate is accepted as a clean match because the override setter handles the decode-side delta.

**Precondition**: `media_info.media_file_original_tc` is nil (no override) or a valid TC value in frames at `media_info.media_start_tc_rate`.

**Postcondition**: Candidate accepted without source_in remap. No entry in the `tc_mismatch` bucket.
