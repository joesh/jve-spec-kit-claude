# Contract: Peak Cache (Lua + C++)

## Module: `peak_cache.lua` (Lua) + peak file reader (C++)

Manages loading, caching, and querying of peak data for waveform rendering.

## Lua Interface: `peak_cache.lua`

```lua
local peak_cache = require("core.media.peak_cache")

-- Initialize cache (call once at startup)
peak_cache.init(project_cache_dir)

-- Request peaks for a media file. Triggers background generation if needed.
-- Returns immediately.
peak_cache.ensure_peaks(media_id, media_path, source_mtime)

-- Get peak data for visible region of a clip.
-- Returns array of {min, max} pairs (one per pixel column), or nil if not ready.
-- source_start/end are in source audio samples.
peak_cache.get_visible_peaks(media_id, source_start_sample, source_end_sample, pixel_width)

-- Check if peaks are ready (complete or partially available).
-- Returns: "complete", "generating", "none"
peak_cache.get_status(media_id)

-- Get generation progress (0.0 to 1.0), or nil if not generating.
peak_cache.get_progress(media_id)

-- Invalidate peaks for a media file (relink, mtime change).
-- Deletes peak file and triggers regeneration.
peak_cache.invalidate(media_id)

-- Cleanup orphaned peak files. Called on project close.
-- active_media_ids: set of media_ids still referenced by project + undo stack.
peak_cache.cleanup_orphans(active_media_ids)

-- Release all cached data (project close).
peak_cache.clear()
```

## C++ Binding: Peak File Reader

```
EMP.PEAK_LOAD(file_path) → peak_handle | nil, err
EMP.PEAK_QUERY(peak_handle, source_start_sample, source_end_sample, pixel_width) → lightuserdata (float array), count
EMP.PEAK_HEADER(peak_handle) → {version, source_mtime, sample_rate, channels, base_spp, num_levels, bins_per_level}
EMP.PEAK_RELEASE(peak_handle) → nil
```

## Behavior Contract

- `get_visible_peaks` MUST return nil (not empty) when peaks unavailable — caller skips waveform drawing
- `get_visible_peaks` MUST select appropriate mipmap level automatically based on samples-per-pixel ratio
- Peak files MUST be mmap'd, not read into heap — avoids allocation pressure
- `ensure_peaks` MUST be idempotent — safe to call on every render frame
- `invalidate` MUST delete the peak file from disk and remove from in-memory cache
- `cleanup_orphans` MUST NOT delete peaks for media_ids in the active_media_ids set
- Cache MUST handle concurrent access: Lua calls from main thread, peak gen writes from background thread
