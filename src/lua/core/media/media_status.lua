--- Reactive media status registry
--
-- Maintains a {media_path → {offline, error_code}} cache.
-- Error state is persisted to project_settings so clips show correct offline/
-- codec status on first paint after restart — no probing cost.
--
-- Writers (authoritative — only these modify status_cache):
-- 1. load_persisted     — previous session's discoveries, loaded on project open
-- 2. Background probe   — C++ worker thread, file existence + codec check
-- 3. TMB (update_from_tmb) — runtime decode error discovery during playback
-- 4. FS watcher (reprobe_and_notify) — file appeared/disappeared
--
-- Reader (pure — never writes to cache):
-- ensure_clip_status    — stamps clip.offline/error_code from cache, called per render
--
-- Watches file system for changes; re-probes and emits "media_status_changed".
-- For missing files: watches parent directory (QFileSystemWatcher can't watch
-- nonexistent paths). When parent dir changes, checks if pending files appeared.
--
-- @file media_status.lua
local Signals = require("core.signals")
local log = require("core.logger").for_area("media")
local ffi = require("ffi")
ffi.cdef("int access(const char *pathname, int mode);")

local M = {}

-- Lazy require: database may not be initialized when media_status is first loaded (tests)
local _database = nil
local function get_database()
    if not _database then _database = require("core.database") end
    return _database
end

-- status_cache[media_path] = { offline = bool, error_code = string|nil }
local status_cache = {}

-- pending_paths[parent_dir] = { [media_path] = true, ... }
-- Tracks missing files by their parent directory for dir-change re-probe.
local pending_paths = {}

-- watched_dirs[dir_path] = true — dirs we've asked FS to watch
local watched_dirs = {}

-- watched_files[file_path] = true — files we've asked FS to watch
local watched_files = {}

-- Whether FS bindings are available (false in tests without Qt)
local fs_available = false
local FS = nil

-- TMB handle for ClearOffline (set by playback engine init)
local tmb_handle = nil

-- Persistence: project_id for debounced DB writes
local current_project_id = nil
local persist_timer_active = false
local PERSIST_DEBOUNCE_MS = 500
local DB_SETTING_KEY = "media_error_cache"

local function init_fs()
    if fs_available then return true end
    local ok, qt = pcall(function() return qt_constants end)
    if ok and qt and qt.FS then
        FS = qt.FS
        fs_available = true
        return true
    end
    return false
end

--- Probe a media file's status (file existence only).
-- Codec errors are discovered lazily by TMB at render time and fed back
-- via update_from_tmb(). This keeps probing fast (sub-ms per file).
-- @param media_path string: absolute path to media file
-- @return table: {offline=bool, error_code=string|nil}
local function probe(media_path)
    assert(media_path and media_path ~= "", "media_status.probe: media_path required")

    local f = io.open(media_path, "r")
    if not f then
        return { offline = true, error_code = "FileNotFound" }
    end
    f:close()

    return { offline = false, error_code = nil }
end

--- Extract parent directory from a path.
local function parent_dir(path)
    local dir = path:match("^(.+)/[^/]+$")
    return dir or "/"
end

--- Check if a path exists on the local filesystem (fast, no network blocking).
local function path_accessible(path)
    return ffi.C.access(path, 0) == 0
end

--- Start watching a media path for changes.
-- Tracking (pending_paths/watched_files) always happens; actual FS calls only when available.
local function watch_path(media_path, status)
    local has_fs = init_fs()

    if status.offline and status.error_code == "FileNotFound" then
        -- File doesn't exist — watch parent dir for it to appear
        local dir = parent_dir(media_path)
        if has_fs and not watched_dirs[dir] and path_accessible(dir) then
            local ok = FS.WATCH_DIR(dir)
            if not ok then
                log.warn("media_status: failed to watch dir %s", dir)
            end
            watched_dirs[dir] = true
        end
        if not pending_paths[dir] then
            pending_paths[dir] = {}
        end
        pending_paths[dir][media_path] = true
    else
        -- File exists (online or codec error) — watch the file itself
        if has_fs and not watched_files[media_path] then
            local ok = FS.WATCH_FILE(media_path)
            if not ok then
                log.warn("media_status: failed to watch file %s", media_path)
            end
        end
        watched_files[media_path] = true
    end
end

--- Unwatch a media path.
local function unwatch_path(media_path)
    if watched_files[media_path] then
        if fs_available then FS.UNWATCH_FILE(media_path) end
        watched_files[media_path] = nil
    end

    -- Remove from pending_paths
    local dir = parent_dir(media_path)
    if pending_paths[dir] then
        pending_paths[dir][media_path] = nil
        -- If no more pending paths in this dir, unwatch it
        if not next(pending_paths[dir]) then
            pending_paths[dir] = nil
            if watched_dirs[dir] then
                if fs_available then FS.UNWATCH_DIR(dir) end
                watched_dirs[dir] = nil
            end
        end
    end
end

--- Register a media path for status tracking.
-- Probes, caches, and sets up file watches.
-- @param media_path string
-- @return table: {offline=bool, error_code=string|nil}
function M.register(media_path)
    assert(media_path and media_path ~= "", "media_status.register: media_path required")

    local status = probe(media_path)
    status_cache[media_path] = status
    watch_path(media_path, status)
    return status
end

--- Unregister a media path — remove watches and cache.
function M.unregister(media_path)
    if not media_path then return end
    unwatch_path(media_path)
    status_cache[media_path] = nil
end

--- Get cached status for a media path.
-- @return table|nil: {offline, error_code} or nil if not registered
function M.get(media_path)
    return status_cache[media_path]
end

-- ============================================================
-- Persistence: save/load error state to project_settings
-- ============================================================

--- Build persist map — all cache entries are authoritative (only authoritative
-- sources write to status_cache: bg probe, TMB, FS watcher, load_persisted).
local function build_persist_map()
    local map = {}
    for path, status in pairs(status_cache) do
        map[path] = { offline = status.offline, error_code = status.error_code }
    end
    return map
end

-- Helper for logging (and tests)
function M._count_map(map)
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    return n
end

--- Flush dirty cache to DB immediately.
function M.persist_now()
    if not current_project_id then return end
    local map = build_persist_map()
    local ok, err = pcall(function()
        get_database().set_project_setting(current_project_id, DB_SETTING_KEY, map)
    end)
    if not ok then
        log.warn("media_status: persist failed: %s", tostring(err))
        return
    end
    log.detail("media_status: persisted %d entries", M._count_map(map))
end

--- Schedule a debounced persist (coalesces rapid status changes).
local function schedule_persist()
    if persist_timer_active then return end
    if type(qt_create_single_shot_timer) ~= "function" then return end
    persist_timer_active = true
    qt_create_single_shot_timer(PERSIST_DEBOUNCE_MS, function()
        persist_timer_active = false
        M.persist_now()
    end)
end

--- Load persisted error cache from DB into status_cache.
-- Called on project open (before any rendering).
function M.load_persisted(project_id)
    assert(project_id and project_id ~= "",
        "media_status.load_persisted: project_id required")
    current_project_id = project_id
    local ok, map = pcall(function()
        return get_database().get_project_setting(project_id, DB_SETTING_KEY)
    end)
    if not ok then return end  -- no DB connection (test mode)
    if type(map) ~= "table" then return end
    local error_count = 0
    local online_count = 0
    local cleared_count = 0

    for path, entry in pairs(map) do
        if type(entry) == "table" then
            -- Clear stale "Unsupported" codec errors. These may be from a previous
            -- build that lacked support (e.g. BRAW before SDK integration). The
            -- background probe will re-check and set the correct status. Only
            -- "Unsupported" is cleared — "FileNotFound" persists (file really missing).
            if entry.offline and entry.error_code == "Unsupported" then
                cleared_count = cleared_count + 1
            else
                status_cache[path] = {
                    offline = entry.offline or false,
                    error_code = entry.error_code,
                }
                if entry.offline then
                    error_count = error_count + 1
                else
                    online_count = online_count + 1
                end
            end
        end
    end
    if cleared_count > 0 then
        log.event("media_status: cleared %d stale 'Unsupported' entries (codec now available)", cleared_count)
    end
    log.event("media_status: loaded %d errors + %d online from DB", error_count, online_count)
end

--- Test hook: inject a cache entry directly (simulates load_persisted).
function M._set_cache(path, status)
    status_cache[path] = status
end

--- Stamp a clip with its cached media status (pure reader — no probing).
-- Cache hit: stamps clip.offline + clip.error_code from cache.
-- Cache miss: no-op (clip keeps whatever state it had).
-- Writing to status_cache is done exclusively by authoritative sources:
-- background probe, TMB, FS watcher, load_persisted.
-- @param clip table: clip with .media_path or .file_path field
function M.ensure_clip_status(clip)
    assert(type(clip) == "table", "media_status.ensure_clip_status: clip must be a table")
    local path = clip.media_path or clip.file_path
    if not path or path == "" then return end

    local cached = status_cache[path]
    if not cached then return end

    clip.offline = cached.offline
    clip.error_code = cached.error_code
end

--- Update status from TMB error discovery.
-- Called by renderer when TMB reports offline/error_code for a media path.
-- Only updates if the status actually changed (avoids redundant signals).
-- @param media_path string
-- @param offline boolean
-- @param error_code string|nil
function M.update_from_tmb(media_path, offline, error_code)
    assert(media_path and media_path ~= "", "media_status.update_from_tmb: media_path required")
    assert(type(offline) == "boolean",
        string.format("media_status.update_from_tmb: offline must be boolean, got %s", type(offline)))

    local old = status_cache[media_path]
    local new_status = { offline = offline, error_code = error_code }

    -- Only emit if status actually changed
    local changed = not old
        or old.offline ~= new_status.offline
        or old.error_code ~= new_status.error_code

    if changed then
        status_cache[media_path] = new_status
        schedule_persist()
        log.event("media_status updated from TMB: %s offline=%s error=%s",
            media_path, tostring(offline), tostring(error_code))
        Signals.emit("media_status_changed", media_path, new_status)
    end
end

--- Set TMB handle for ClearOffline integration.
-- Called by playback engine init when TMB is created.
-- @param tmb userdata TMB handle (or nil to clear)
function M.set_tmb(tmb)
    tmb_handle = tmb
end

--- Clear all watches and cache. Called on project_changed.
function M.clear()
    -- Cancel any running background probe before clearing
    M.cancel_background_probe()
    -- Flush any pending error state before clearing
    M.persist_now()
    if fs_available then
        FS.CLEAR_ALL()
    end
    status_cache = {}
    persist_timer_active = false
    current_project_id = nil
    pending_paths = {}
    watched_dirs = {}
    watched_files = {}
end

--- Re-probe a media path and emit signal if status changed.
local function reprobe_and_notify(media_path)
    local old = status_cache[media_path]
    local new_status = probe(media_path)
    status_cache[media_path] = new_status

    -- Update watches if status category changed (missing ↔ exists)
    unwatch_path(media_path)
    watch_path(media_path, new_status)

    local changed = not old
        or old.offline ~= new_status.offline
        or old.error_code ~= new_status.error_code

    if changed then
        schedule_persist()
        -- File reappeared: purge TMB's offline blacklist so it retries the reader
        if old and old.offline and not new_status.offline and tmb_handle then
            local emp_ok, qt = pcall(function() return qt_constants end)
            if emp_ok and qt and qt.EMP and qt.EMP.TMB_CLEAR_OFFLINE then
                qt.EMP.TMB_CLEAR_OFFLINE(tmb_handle, media_path)
            end
        end
        log.event("media_status changed: %s offline=%s error=%s",
            media_path, tostring(new_status.offline), tostring(new_status.error_code))
        Signals.emit("media_status_changed", media_path, new_status)
    end
end

--- FS callback: a watched file changed (modified/deleted).
function M._on_file_changed(path)
    assert(path, "media_status._on_file_changed: path required")
    if status_cache[path] then
        reprobe_and_notify(path)
    end

    -- Invalidate peak cache for this media file (waveform regeneration).
    -- Guard: FS callback can fire after project close (no DB connection).
    local database = require("core.database")
    if not database.has_connection() then return end
    local Media = require("models.media")
    local media_id = Media.find_id_by_path(path)
    if media_id then
        local peak_cache = require("core.media.peak_cache")
        peak_cache.invalidate(media_id)
    else
        log.warn("media_status: file changed but no media record for %s — peak cache not invalidated", path)
    end
end

--- FS callback: a watched directory changed (file added/removed).
function M._on_dir_changed(dir)
    assert(dir, "media_status._on_dir_changed: dir required")
    local paths = pending_paths[dir]
    if not paths then return end

    -- Snapshot keys: reprobe_and_notify calls unwatch_path/watch_path which
    -- modifies pending_paths[dir] — can't iterate and mutate simultaneously.
    local snapshot = {}
    for media_path in pairs(paths) do
        snapshot[#snapshot + 1] = media_path
    end
    for _, media_path in ipairs(snapshot) do
        reprobe_and_notify(media_path)
    end
end

--- Initialize FS callbacks. Call once during app startup.
function M.init_watcher()
    if not init_fs() then return end

    FS.SET_FILE_CHANGED_CB(function(path)
        M._on_file_changed(path)
    end)

    FS.SET_DIR_CHANGED_CB(function(dir)
        M._on_dir_changed(dir)
    end)
end

-- ============================================================
-- Background codec probe: worker thread probes all project media
-- ============================================================

--- Start a background codec probe for all media in the project.
-- Probes active sequence media first, then remaining project media.
-- Results arrive in batches on the main thread; views are signalled to repaint.
-- @param active_sequence_id string|nil: sequence to prioritize (its media probed first)
function M.start_background_probe(active_sequence_id)
    local qt_ok, qt = pcall(function() return qt_constants end)
    if not qt_ok or not qt or not qt.EMP or not qt.EMP.CODEC_PROBE_START then
        log.event("media_status: background probe skipped (no EMP)")
        return
    end

    local db = get_database()

    -- Collect media paths: active sequence first, then the rest.
    -- Always re-probe ALL paths — persisted cache is a first-paint hint,
    -- not authoritative. Files may have moved/deleted between sessions.
    local active_paths = {}
    local active_set = {}
    if active_sequence_id and active_sequence_id ~= "" then
        local clips = db.load_clips(active_sequence_id)
        for _, clip in ipairs(clips) do
            local p = clip.media_path or clip.file_path
            if p and p ~= "" and not active_set[p] then
                active_set[p] = true
                active_paths[#active_paths + 1] = p
            end
        end
    end

    local all_media = db.load_media()
    local rest_paths = {}
    local rest_set = {}
    for _, m in ipairs(all_media) do
        local p = m.file_path
        if p and p ~= "" and not active_set[p] and not rest_set[p] then
            rest_set[p] = true
            rest_paths[#rest_paths + 1] = p
        end
    end

    -- Concatenate: active sequence paths first, then the rest
    local all_paths = {}
    for _, p in ipairs(active_paths) do all_paths[#all_paths + 1] = p end
    for _, p in ipairs(rest_paths) do all_paths[#all_paths + 1] = p end

    if #all_paths == 0 then
        log.event("media_status: background probe skipped (no media paths)")
        return
    end

    log.event("media_status: bg probe starting (%d to scan, %d active-seq)",
        #all_paths, #active_paths)

    qt.EMP.CODEC_PROBE_START(all_paths, function(results, is_final)
        -- Main thread callback: update cache, register watches, signal changes
        local changed_count = 0
        for path, result in pairs(results) do
            local old = status_cache[path]
            local new_status = {
                offline = result.offline,
                error_code = result.error_code,
            }

            watch_path(path, new_status)

            local same = old
                and old.offline == new_status.offline
                and old.error_code == new_status.error_code
            status_cache[path] = new_status
            if not same then
                changed_count = changed_count + 1
                Signals.emit("media_status_changed", path, new_status)
            end
        end

        if changed_count > 0 then
            log.event("media_status: probe batch — %d changed", changed_count)
        end
        schedule_persist()

        if is_final then
            log.event("media_status: bg probe complete")
            M.persist_now()
        end
    end)
end

--- Cancel any running background codec probe.
function M.cancel_background_probe()
    local qt_ok, qt = pcall(function() return qt_constants end)
    if qt_ok and qt and qt.EMP and qt.EMP.CODEC_PROBE_CANCEL then
        qt.EMP.CODEC_PROBE_CANCEL()
    end
end

-- Register for project_changed signal: flush old, clear, load new, start bg probe
Signals.connect("project_changed", function(project_id)
    M.clear()  -- cancels bg probe, flushes pending writes, clears cache
    if project_id and project_id ~= "" then
        M.load_persisted(project_id)
        -- Start background codec probe (prioritize active sequence)
        local ok, active_seq = pcall(function()
            return get_database().get_project_setting(project_id, "last_open_sequence_id")
        end)
        M.start_background_probe(ok and active_seq or nil)
    end
end, 12)  -- priority 12: after playback_controller (10), before media_cache (20)

return M
