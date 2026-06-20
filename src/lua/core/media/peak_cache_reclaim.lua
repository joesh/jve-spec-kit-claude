--- Disk reclamation for the GLOBAL peak cache (~/Library/Caches/JVE/peaks).
---
--- The peak cache is project-independent: a peak file is keyed by the
--- source file's stable identity (<media_id>__ch<N>.peaks), not by project,
--- so it survives DRP re-import and .jvp re-open (see
--- database.get_peak_cache_dir). That removes the old per-project cleanup
--- (deleting <name>_<project_id>/ on close) — a shared cache has no
--- per-project directory to drop. Two reclamation duties replace it:
---
---   reclaim_lru        — keep the cache under a configured byte ceiling by
---                        evicting the least-recently-ACCESSED peak files.
---                        atime is the signal: querying a peak file's mmap'd
---                        bytes faults its pages and bumps atime, so a
---                        waveform shown recently on a timeline survives and
---                        one never displayed ages out.
---   migrate_legacy_layout — one-time sweep of the pre-global per-project
---                        cache directories left behind by the layout change.
---
--- @file peak_cache_reclaim.lua
local M = {}
local log = require("core.logger").for_area("media")
local fs_utils = require("core.fs_utils")

-- Default ceiling when the user has set no override. A single channel's
-- peaks are small (tens to hundreds of KB), but a large project has
-- thousands of channels (~300-500 MB) and several projects share the one
-- global cache. 4 GiB holds many large projects with headroom; the OS may
-- purge ~/Library/Caches under storage pressure regardless. Override via
-- ~/.jve/peak_cache.json {"max_cache_bytes": <N>}.
local DEFAULT_MAX_CACHE_BYTES = 4 * 1024 * 1024 * 1024
local PREF_FILENAME = "peak_cache.json"
-- Records that the one-time legacy-layout sweep has run. Lives in the cache
-- root; if the OS purges it the sweep simply re-runs harmlessly.
local LEGACY_MARKER = ".global_layout_v1"
local PEAK_SUFFIX = "%.peaks$"

local function prefs_path()
    local home = assert(os.getenv("HOME"), "peak_cache_reclaim: HOME not set")
    return home .. "/.jve/" .. PREF_FILENAME
end

--- Read the configured cache ceiling, in bytes. An absent pref file means
--- "no override" → default (a legitimate state, not an error). A present
--- doc with a malformed JSON body is surfaced (warn) and the default used.
--- A well-formed doc whose max_cache_bytes is the wrong type / non-positive
--- is a user config error → assert (no silent fallback to default).
--- @return number positive byte ceiling
function M.read_max_bytes()
    local path = prefs_path()
    local f = io.open(path, "r")
    if not f then return DEFAULT_MAX_CACHE_BYTES end
    local data = f:read("*a")
    f:close()
    if not data or data == "" then return DEFAULT_MAX_CACHE_BYTES end

    local parsed = require("dkjson").decode(data)
    if type(parsed) ~= "table" then
        log.warn("peak_cache_reclaim: malformed %s — using default cap", path)
        return DEFAULT_MAX_CACHE_BYTES
    end
    local v = parsed.max_cache_bytes
    if v == nil then return DEFAULT_MAX_CACHE_BYTES end
    assert(type(v) == "number" and v > 0, string.format(
        "peak_cache_reclaim: max_cache_bytes in %s must be a positive "
        .. "number (got %s)", path, tostring(v)))
    return v
end

-- Sum the .peaks files in peaks_dir, returning ({entries}, total_bytes).
-- Subdirectories and non-.peaks files are ignored (the cache holds only
-- <id>.peaks, but be defensive — never touch a stray file).
local function collect_peak_files(peaks_dir)
    local files, total = {}, 0
    for _, e in ipairs(fs_utils.dir_scan(peaks_dir)) do
        if not e.is_dir and e.name:match(PEAK_SUFFIX) then
            files[#files + 1] = e
            total = total + e.size
        end
    end
    return files, total
end

--- Evict the least-recently-accessed peak files until the cache is at or
--- under max_bytes. in_use_keys is a set of job-key stems
--- (<media_id>__ch<N> or <media_id>) the running editor holds open or is
--- mid-generation on this session — never evicted, even if coldest.
--- @param peaks_dir string absolute peaks directory
--- @param max_bytes number positive byte ceiling
--- @param in_use_keys table set { [stem]=true } of protected keys
--- @return table { freed_bytes, kept_bytes, evicted = {filename,...} }
function M.reclaim_lru(peaks_dir, max_bytes, in_use_keys)
    assert(type(peaks_dir) == "string" and peaks_dir ~= "",
        "peak_cache_reclaim.reclaim_lru: peaks_dir required")
    assert(type(max_bytes) == "number" and max_bytes > 0,
        "peak_cache_reclaim.reclaim_lru: max_bytes must be a positive number")
    assert(type(in_use_keys) == "table",
        "peak_cache_reclaim.reclaim_lru: in_use_keys must be a table")

    local files, total = collect_peak_files(peaks_dir)
    if total <= max_bytes then
        return { freed_bytes = 0, kept_bytes = total, evicted = {} }
    end

    -- Coldest (smallest atime) first.
    table.sort(files, function(a, b) return a.atime < b.atime end)

    local freed, evicted = 0, {}
    for _, e in ipairs(files) do
        if total - freed <= max_bytes then break end
        local stem = e.name:gsub(PEAK_SUFFIX, "")
        if not in_use_keys[stem] then
            if os.remove(peaks_dir .. "/" .. e.name) then
                freed = freed + e.size
                evicted[#evicted + 1] = e.name
            else
                log.warn("peak_cache_reclaim: failed to remove %s/%s",
                    peaks_dir, e.name)
            end
        end
    end

    local kept = total - freed
    if kept > max_bytes then
        log.warn("peak_cache_reclaim: still %.1f MB over the %.1f MB cap after "
            .. "evicting %d file(s) — remaining peaks are all in use this session",
            (kept - max_bytes) / 1048576, max_bytes / 1048576, #evicted)
    end
    log.event("peak_cache_reclaim: freed %.1f MB (%d files), kept %.1f MB "
        .. "(cap %.1f MB)", freed / 1048576, #evicted, kept / 1048576,
        max_bytes / 1048576)
    return { freed_bytes = freed, kept_bytes = kept, evicted = evicted }
end

--- One-time sweep of the pre-global per-project cache directories
--- (~/Library/Caches/JVE/<name>_<project_id>/). The global layout keeps
--- only `peaks/` directly under the cache root, so any OTHER subdirectory
--- is a dead per-project cache and is removed. Idempotent: a marker file
--- records the sweep so it never re-scans.
--- @param cache_root string absolute ~/Library/Caches/JVE
--- @return table { removed = n } | { skipped = true }
function M.migrate_legacy_layout(cache_root)
    assert(type(cache_root) == "string" and cache_root ~= "",
        "peak_cache_reclaim.migrate_legacy_layout: cache_root required")
    local marker = cache_root .. "/" .. LEGACY_MARKER
    if fs_utils.file_exists(marker) then
        return { skipped = true }
    end

    local removed = 0
    for _, e in ipairs(fs_utils.dir_scan(cache_root)) do
        if e.is_dir and e.name ~= "peaks" then
            local path = cache_root .. "/" .. e.name
            -- Absolute /bin/rm — a Finder-launched .app has a stripped PATH.
            local rc = os.execute(string.format("/bin/rm -rf %q", path))
            if rc == 0 or rc == true then
                removed = removed + 1
                log.event("peak_cache_reclaim: swept legacy cache dir %s", e.name)
            else
                log.warn("peak_cache_reclaim: failed to remove legacy dir %s", path)
            end
        end
    end

    -- Record the sweep so it runs exactly once. Ensure the root exists first
    -- (a fresh install may have no cache directory yet).
    local ok, err = qt_fs_mkdir_p(cache_root)
    assert(ok, string.format(
        "peak_cache_reclaim: mkdir cache_root %s failed: %s",
        cache_root, tostring(err)))
    local mf = assert(io.open(marker, "w"), string.format(
        "peak_cache_reclaim: cannot write migration marker %s", marker))
    mf:write("global peak cache layout active; legacy per-project dirs swept\n")
    mf:close()
    return { removed = removed }
end

return M
