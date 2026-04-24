# T031 wrapper-shape audit

Enumerates fields read by callers of `Sequence:get_video_in_range` /
`Sequence:get_audio_in_range` so T031 can verify no field is silently
dropped by the wrapper rewrite. The wrappers become thin filters over
`Sequence:resolve_in_range` (per `contracts/resolver.md`, output shape
= `ResolvedEntry`).

## Canonical entry shape (post-T031) = `ResolvedEntry`

Per contracts/resolver.md §ResolvedEntry:

```
media_path, media_id, media_kind, source_in, source_out,
timeline_start, duration, track_role, channel_index, volume,
enabled, effects, provenance
```

## Caller survey

### `src/lua/core/playback/playback_engine.lua:509,511` — only runtime caller

Reads through `entry`:

| Read | Used by | ResolvedEntry field? |
|---|---|---|
| `entry.media_path` | `_build_tmb_clip`, `_active_media_paths` | ✔ `media_path` |
| `entry.clip.id` | TMB `clip_id`, `_clip_info_by_id` key | ✘ — `provenance[1]` carries outermost clip id |
| `entry.clip.timeline_start` | TMB `timeline_start` | ✔ `timeline_start` (resolver already in outer timebase — G-R7) |
| `entry.clip.duration` | TMB `duration`, speed ratio | ✔ `duration` |
| `entry.clip.source_in` | TMB `source_in`, speed ratio, `_clip_info_by_id` | ✔ `source_in` (file-native — CT-R1) |
| `entry.clip.source_out` | speed ratio, `_clip_info_by_id`, audio reverse check | ✔ `source_out` |
| `entry.clip.rate.fps_numerator/denominator` | TMB `rate_num/rate_den` | ✘ — not on ResolvedEntry; recoverable via `media_id → media` |
| `entry.clip.volume` | TMB `volume` | ✔ `volume` (composite per G-R4) |
| `entry.track.track_index` | TMB track routing | ✘ — not on ResolvedEntry |
| `entry.track.volume/muted/soloed/id` | `_build_audio_mix_params` | ✘ — per-track state, orthogonal to per-entry |
| `entry.source_time_us`, `entry.source_frame` | (not actually read by `_provide_clips`) | ✘ — dead field |
| `entry.media_fps_num/den` | `_compute_audio_speed_ratio` | ✘ — recoverable via `media_id → media` |

### `tests/binding/test_drp_anamnesis_full.lua:122-171`

Reads `entry.clip.enabled`, `entry.clip.id`, `entry.clip.timeline_start`.
`clip.enabled` is now on ResolvedEntry as `entry.enabled` (composite of
chain). Test must be updated if wrapper returns ResolvedEntry shape.

### `tests/integration/test_tmb_mute_exclusion.lua:204-222`

Reads nothing off entries — only counts them. Wrapper change is
transparent.

### `tests/test_resolve_wrapper_shape.lua`

Reads `media_path`, `media_kind`. Both are on ResolvedEntry. Pass.

### Other test mocks

`test_playback_engine*.lua`, `test_reverse_clip_playback.lua`,
`test_offline_frame_display.lua`, `test_zero_source_range_clip.lua`,
`test_playback_video_display.lua`, `test_playback_edit_invalidation.lua`,
`test_playback_controller_audio_guards.lua` — all mock
`get_video_in_range` / `get_audio_in_range`. They stub the sequence
object and don't hit the real wrapper. Wrapper rewrite doesn't touch
them; their assertions are against `_provide_clips` + downstream. They
will need parallel rewrites when T093 touches `_provide_clips`.

## Finding

**Column-for-column preservation is impossible** because the legacy
wrapper shape (`entry.clip`, `entry.track`, `entry.media_fps_*`,
`entry.source_time_us`) depends on `clips.media_id`, which was
dropped by T008 (schema V9). The legacy shape is therefore dead under
V9 regardless of T031.

**T031 decision**: wrappers emit `ResolvedEntry[]` filtered by
`media_kind`. Every field that callers legitimately need exists on
ResolvedEntry or is recoverable via `media_id → media`.

## Deferred to T093 (playback_engine rewrite)

These items are downstream of T031 and belong to T093:

1. `playback_engine:_provide_clips` — rewrite to read
   `provenance[1]` for TMB `clip_id`, look up `rate` via `media_id →
   media` for `rate_num/den`, and either (a) extend ResolvedEntry
   with `outer_track_id/index` or (b) round-trip `Track.load(clip.track_id)`.
2. `_compute_video_speed_ratio`, `_compute_audio_speed_ratio` — read
   `source_in`/`source_out`/`duration` directly off the entry (already
   there); `media_fps_num/den` via `media` lookup.
3. `_build_audio_mix_params` — per-track state comes from `Track`
   queries, not per-entry state. Decouple from entry reads.
4. `_extract_clip_ids` — use `provenance[1]` per entry.
5. Per-channel audio collapse — current TMB/mixer is per-track, has no
   per-channel disable surface. `clip_channel_override` data is
   DB-represented but **not** honored at playback until a separate
   design pass. T093's audio entry collapse: group per-(outermost clip,
   media_ref) and treat enabled = OR across channels.
6. `tests/binding/test_drp_anamnesis_full.lua` — update `entry.clip.*`
   reads to `entry.*` (or `entry.enabled`) per ResolvedEntry.

## Rule 2.18 FFI stability

No C++ FFI touched by T031. `TMB_ADD_CLIPS` clip-table shape is built by
`_build_tmb_clip`, not by the wrapper. T031 preserves the Lua→C++
boundary. T092b / T093 revisit FFI at rewrite time.
