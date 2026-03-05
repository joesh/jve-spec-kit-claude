--- Reactive media status registry
--
-- Maintains a {media_path → {offline, error_code}} cache.
-- Lazy evaluation: clips are probed (file existence + codec) only when displayed.
-- Watches file system for changes; re-probes and emits "media_status_changed".
--
-- For missing files: watches parent directory (QFileSystemWatcher can't watch
-- nonexistent paths). When parent dir changes, checks if pending files appeared.
--
-- @file media_status.lua
local Signals = require("core.signals")
local log = require("core.logger").for_area("media")
local ffi = require("ffi")
ffi.cdef("int access(const char *pathname, int mode);")

local M = {}

-- status_cache[media_path] = { offline = bool, error_code = string|nil }
local status_cache = {}

-- codec_probed[media_path] = true — paths that have had EMP codec check
local codec_probed = {}

-- Async codec probe queue: paths waiting for EMP check, drained via timer
local codec_queue = {}           -- {path = true}
local codec_drain_active = false -- true while timer chain is running

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

--- Check codec support via EMP container open (no reader/decoder creation).
-- Catches formats with no FFmpeg demuxer (e.g. BRAW without SDK).
-- Does NOT create a reader — reader creation grabs VT sessions, and rapid-fire
-- probing exhausts the pool, forcing TMB's playback readers to SW fallback.
-- For codecs that open but can't decode, TMB discovers the error at render time
-- and feeds back via update_from_tmb().
-- @param media_path string: path to an existing file
-- @return table|nil: {offline=true, error_code=string} if codec fails, nil if OK
local function probe_codec(media_path)
    local emp_ok, qt = pcall(function() return qt_constants end)
    if not (emp_ok and qt and qt.EMP and qt.EMP.MEDIA_FILE_OPEN) then
        return nil
    end

    local handle, err = qt.EMP.MEDIA_FILE_OPEN(media_path)
    if not handle then
        assert(err and err.code,
            string.format("media_status.probe_codec: EMP.MEDIA_FILE_OPEN returned nil handle "
                .. "with no error for %s", media_path))
        return { offline = true, error_code = err.code }
    end

    -- Container opened successfully — codec may still fail at decode time
    -- (TMB handles that via update_from_tmb)
    qt.EMP.MEDIA_FILE_CLOSE(handle)
    return nil
end

--- Drain one path from the codec probe queue.
-- Called by timer chain; processes 1 path then reschedules if more pending.
local function drain_one_codec_probe()
    codec_drain_active = false

    local path = next(codec_queue)
    if not path then return end

    codec_queue[path] = nil
    codec_probed[path] = true

    -- Only probe if still cached as online (status may have changed since queued)
    local cached = status_cache[path]
    if cached and not cached.offline then
        local codec_err = probe_codec(path)
        if codec_err then
            status_cache[path] = codec_err
            log.event("media_status codec probe: %s offline=%s error=%s",
                path, tostring(codec_err.offline), tostring(codec_err.error_code))
            Signals.emit("media_status_changed", path, codec_err)
        end
    else
        log.detail("media_status codec drain: skipping %s (already offline or unregistered)", path)
    end

    -- Chain: schedule next if more pending
    if next(codec_queue) then
        M._schedule_codec_drain()
    end
end

--- Start the timer-based codec probe drain (if not already running).
function M._schedule_codec_drain()
    if codec_drain_active then return end
    if not next(codec_queue) then return end
    if type(qt_create_single_shot_timer) ~= "function" then return end

    codec_drain_active = true
    qt_create_single_shot_timer(0, drain_one_codec_probe)
end

-- Exposed for testing (tests don't have qt_create_single_shot_timer)
M._drain_one_codec_probe = drain_one_codec_probe

--- Lazily ensure a clip has up-to-date media status.
-- Cache hit: two table lookups + two field writes (safe for per-frame use).
-- Cache miss: file existence probe + cache.
-- When check_codec is true, queues an async EMP codec probe (timer-based,
-- one path per tick so rendering stays responsive).
-- @param clip table: clip with .media_path or .file_path field
-- @param check_codec boolean: if true, queue codec check for existing files
function M.ensure_clip_status(clip, check_codec)
    assert(type(clip) == "table", "media_status.ensure_clip_status: clip must be a table")
    local path = clip.media_path or clip.file_path
    if not path or path == "" then return end

    local cached = status_cache[path]
    if not cached then
        -- First time seeing this path — file existence probe + cache + watch
        cached = M.register(path)
    end

    -- Queue async codec check for files that exist and haven't been probed
    if check_codec and not cached.offline and not codec_probed[path]
        and not codec_queue[path] then
        codec_queue[path] = true
        M._schedule_codec_drain()
    end

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
        log.event("media_status updated from TMB: %s offline=%s error=%s",
            media_path, tostring(offline), tostring(error_code))
        Signals.emit("media_status_changed", media_path, new_status)
    end
end

--- Clear all watches and cache. Called on project_changed.
function M.clear()
    if fs_available then
        FS.CLEAR_ALL()
    end
    status_cache = {}
    codec_probed = {}
    codec_queue = {}
    codec_drain_active = false
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

-- Register for project_changed signal to clear all state
Signals.connect("project_changed", function()
    M.clear()
end, 12)  -- priority 12: after playback_controller (10), before media_cache (20)

return M
