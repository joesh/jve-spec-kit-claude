--- Disk-backed cache of EMP.MEDIA_PROBE_BATCH results, keyed on
--- (path, mtime, size). First-relink still pays the ~3s probe cost;
--- every subsequent relink on the same search dir hits the cache and
--- finishes in ~0s. The relink workflow is iterative — tweak rules,
--- re-run — so repeat hits are the common case.
---
--- The cache lives at ~/.jve/probe_cache.json. It is a single JSON
--- document: {version, entries={[path]={mtime, size, info}}}. Entries
--- are MediaFileInfo tables shaped identically to what
--- EMP.MEDIA_PROBE_BATCH returns, so caller code treats hits and misses
--- identically.
---
--- Staleness: a cached entry is used only when the file's current
--- mtime AND size match the cached values. Any change → miss →
--- re-probe → cache overwrite. Missing files (user deleted / renamed)
--- are treated as misses and left out of the fresh probe set too (the
--- matcher's per-path lookup still returns nil — same as before).
---
--- Errors: only successful probes are cached. EMP returning a Result
--- error (broken container, etc.) is not cached because transient
--- errors would otherwise persist across relinks. The caller sees the
--- same nil that EMP.MEDIA_PROBE_BATCH returned.
---
--- @file media_probe_cache.lua

local M = {}
local log = require("core.logger").for_area("media")

-- Cache file version. Bump when the MediaFileInfo Lua shape changes
-- (new fields, renamed fields, changed semantics) so stale caches get
-- rejected wholesale rather than silently returning wrong data.
--
-- v2 (2026-04-21): reject entries missing presence flags. c2b2b505
-- added has_duration / has_video_tc_origin / has_audio_tc_origin but
-- kept version=1, so pre-commit caches loaded and silently served
-- entries with `duration_us` but no `has_duration`. The relinker's
-- probe_result_from_emp_info gates duration_frames on has_duration,
-- so those stale hits produced cand_dur=0 and failed every
-- containment check downstream (TSO 2026-04-21 15:55:19 — 477 of 562
-- media appeared unrelinkable from cache hits). Bumping the version
-- forces the whole doc to reload, AND per-entry presence-flag
-- validation in classify_paths catches any future field-addition
-- where someone forgets to bump this version.
--
-- v3 (2026-04-24): EMP now derives first_sample_tc /
-- has_audio_tc_origin from first_frame_tc for video-with-audio files
-- (MOVs with tmcd atom, BRAW). Pre-v3 caches have has_audio_tc_origin
-- = false for these files — relink matching is unaffected, but TC
-- sync at relink time reads `info.has_audio_tc_origin` to decide
-- whether to emit start_tc_audio_samples in the metadata write. Stale
-- hits therefore silently CLEAR the audio_samples field the DRP
-- importer wrote from MediaStartTime, leaving peak_cache with no
-- authoritative audio tc_origin → waveforms vanish for every
-- Media-Managed trim.
--
-- v4 (2026-05-15): EMP now surfaces container-authoritative
-- video_frame_count and audio_sample_count when the demuxer reports
-- them (BRAW SDK). Pre-v4 cache entries lack these fields, and the
-- relinker would silently fall back to the lossy duration_us
-- round-trip — exactly the bug being fixed. Bump forces re-probe.
local CACHE_VERSION = 4

-- Fields that MUST be present on every cached info to consider the
-- entry fresh. The relinker's downstream logic gates behavior on
-- these — a missing field means "unknown" in Lua (nil/falsy), which
-- is indistinguishable from "probe said no", which breaks matching.
--
-- THIS LIST IS THE CONTRACT between the probe cache and the
-- relinker's `probe_result_from_emp_info` (core/media_relinker.lua,
-- near `if info.has_video_tc_origin`, `if info.has_audio_tc_origin`,
-- `if info.has_duration`). If you add a new presence-flag read over
-- there, add it here AND bump CACHE_VERSION above — otherwise stale
-- caches will silently serve entries missing the new flag.
local REQUIRED_INFO_FIELDS = {
    "has_duration",
    "has_video_tc_origin",
    "has_audio_tc_origin",
}

local function cache_path()
    return assert(os.getenv("HOME"), "HOME env var required") .. "/.jve/probe_cache.json"
end

--- Load the full cache document. The cache is a performance accelerator,
--- not required state — on any load error (file missing, parse failure,
--- version mismatch) we return an empty entries table and proceed as if
--- this were a fresh session. Every failure is logged so it's visible.
--- Schema assumption: if parsed.version matches, parsed.entries MUST be
--- a table; a missing/non-table entries field means schema corruption
--- and asserts.
local function load_cache()
    local path = cache_path()
    local f = io.open(path, "r")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    if not data or data == "" then return {} end

    local json = require("dkjson")
    local parsed, _, err = json.decode(data)
    if not parsed then
        log.warn("media_probe_cache: parse error on %s: %s — ignoring cache",
            path, tostring(err))
        return {}
    end
    if parsed.version ~= CACHE_VERSION then
        log.event("media_probe_cache: version mismatch (got %s, need %d) — ignoring",
            tostring(parsed.version), CACHE_VERSION)
        return {}
    end
    assert(type(parsed.entries) == "table", string.format(
        "media_probe_cache: version %d document missing entries table at %s",
        CACHE_VERSION, path))
    return parsed.entries
end

--- Atomically write the cache document. Writes to a temp file then
--- os.rename so a crash mid-write can't leave a half-written cache.
--- mkdir of the parent ~/.jve/ asserts on failure (rule 1.14 — a missing
--- prefs dir is unrecoverable for cache persistence). Downstream io.open
--- + os.rename still return false on transient I/O failure so callers can
--- log + continue (a failed save just means next probe_batch rebuilds).
--- @return boolean ok
local function save_cache(entries)
    local path = cache_path()
    local dir = path:match("(.+)/[^/]+$")
    local ok, err = qt_fs_mkdir_p(dir)
    assert(ok, "media_probe_cache: mkdir " .. dir .. " failed: " .. tostring(err))

    local json = require("dkjson")
    local data = json.encode({ version = CACHE_VERSION, entries = entries })
    local tmp = path .. ".tmp"
    local f, open_err = io.open(tmp, "w")
    if not f then
        log.warn("media_probe_cache: failed to open %s for write: %s",
            tmp, tostring(open_err))
        return false
    end
    local write_ok, write_err = f:write(data)
    f:close()
    if not write_ok then
        log.warn("media_probe_cache: failed to write %s: %s",
            tmp, tostring(write_err))
        os.remove(tmp)
        return false
    end
    local rename_ok, rename_err = os.rename(tmp, path)
    if not rename_ok then
        log.warn("media_probe_cache: failed to rename %s → %s: %s",
            tmp, path, tostring(rename_err))
        os.remove(tmp)
        return false
    end
    return true
end

--- Classify each input path into a hit (cache entry fresh vs current
--- file stat) or a miss (stale, absent, or file missing on disk).
--- Returns {results, miss_paths, miss_indices, hit_count, missing_count}.
--- Hits land directly in results[i] with the cached info; misses are
--- left unfilled for the caller to probe. Missing-file paths are also
--- counted as misses so the caller gets an EMP-failure result (nil)
--- for downstream behavior parity with the no-cache path.
---
--- Exposed as M._classify_paths so tests can exercise the pure
--- classification logic without touching disk or EMP. The underscore
--- prefix marks it as an implementation-internal entry point — callers
--- other than tests should go through M.probe_batch.
local function has_required_shape(info)
    if type(info) ~= "table" then return false end
    for _, field in ipairs(REQUIRED_INFO_FIELDS) do
        if info[field] == nil then return false end
    end
    return true
end

local function classify_paths(paths, entries, stats)
    local results = {}
    local miss_paths, miss_indices = {}, {}
    local hit_count, missing_count = 0, 0
    for i, path in ipairs(paths) do
        local s = stats[path]
        if not s then
            missing_count = missing_count + 1
            miss_paths[#miss_paths + 1] = path
            miss_indices[#miss_indices + 1] = i
        else
            local cached = entries[path]
            if cached and cached.mtime == s.mtime and cached.size == s.size
                and has_required_shape(cached.info) then
                results[i] = cached.info
                hit_count = hit_count + 1
            else
                miss_paths[#miss_paths + 1] = path
                miss_indices[#miss_indices + 1] = i
            end
        end
    end
    return {
        results = results,
        miss_paths = miss_paths,
        miss_indices = miss_indices,
        hit_count = hit_count,
        missing_count = missing_count,
    }
end

--- Probe the miss set via EMP and write fresh results into `results`
--- at the original indices. Successful probes are also written back
--- into `entries` keyed by (mtime, size) so a subsequent probe_batch
--- call can hit cache. Probe errors are NOT cached — transient failures
--- shouldn't persist; a missing-file result shouldn't poison the cache.
local function probe_misses(miss_paths, miss_indices, stats, entries, results)
    if #miss_paths == 0 then return end
    local fresh = qt_constants.EMP.MEDIA_PROBE_BATCH(miss_paths, 0)
    for mi = 1, #miss_paths do
        local info = fresh[mi]
        local idx = miss_indices[mi]
        results[idx] = info
        if info then
            local s = stats[miss_paths[mi]]
            if s then
                entries[miss_paths[mi]] = {
                    mtime = s.mtime, size = s.size, info = info,
                }
            end
        end
    end
end

--- Probe a batch of paths, hitting the disk cache where entries are
--- still fresh and delegating to EMP.MEDIA_PROBE_BATCH for misses.
--- Returns an array shaped identically to EMP.MEDIA_PROBE_BATCH
--- (results[i] = info table or nil), so this function is a drop-in
--- replacement for that call.
---
--- Side effect: rewrites the on-disk cache when new successful probes
--- were collected.
--- @param paths table array of absolute paths
--- @return table array of info tables (nil for probe errors)
function M.probe_batch(paths)
    assert(type(paths) == "table", "probe_batch: paths array required")
    if #paths == 0 then return {} end

    assert(_G.qt_file_stat_batch,
        "media_probe_cache: qt_file_stat_batch binding required")
    assert(_G.qt_constants and _G.qt_constants.EMP
        and _G.qt_constants.EMP.MEDIA_PROBE_BATCH,
        "media_probe_cache: EMP.MEDIA_PROBE_BATCH binding required")

    local t_load = qt_monotonic_s()
    local entries = load_cache()
    local t_stat = qt_monotonic_s()
    local stats = qt_file_stat_batch(paths)
    local t_stat_end = qt_monotonic_s()

    local c = classify_paths(paths, entries, stats)

    local t_probe_start = qt_monotonic_s()
    probe_misses(c.miss_paths, c.miss_indices, stats, entries, c.results)
    local t_probe_end = qt_monotonic_s()

    -- Only rewrite the cache file when a new successful probe landed.
    -- #miss_paths alone isn't the signal — missing files count as
    -- misses but don't produce cache entries.
    local save_ok = true
    if #c.miss_paths > c.missing_count then
        save_ok = save_cache(entries)
    end
    local t_end = qt_monotonic_s()

    -- A save failure is not fatal — the next invocation just rebuilds
    -- the missing entries — but it IS observably wrong (the user's
    -- iterative workflow won't get the cache speedup). Surface via
    -- event-level log so it's visible in default logs.
    if not save_ok then
        log.event("media_probe_cache: save failed; next run will re-probe")
    end

    log.event("media_probe_cache: %d paths, %d hit, %d miss (%d missing-file) "
        .. "load=%.2fs stat=%.2fs probe=%.2fs save=%.2fs",
        #paths, c.hit_count, #c.miss_paths - c.missing_count, c.missing_count,
        t_stat - t_load, t_stat_end - t_stat, t_probe_end - t_probe_start,
        t_end - t_probe_end)

    return c.results
end

-- Test hook — see classify_paths docstring.
M._classify_paths = classify_paths

return M
