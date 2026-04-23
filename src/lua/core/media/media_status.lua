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
local offline_note = require("core.media.offline_note")
local peak_cache = require("core.media.peak_cache")
local Media = require("models.media")
local runtime_mode = require("core.runtime_mode")
local ffi = require("ffi")
ffi.cdef("int access(const char *pathname, int mode);")

local M = {}

-- Lazy require: database may not be initialized when media_status is first loaded (tests)
local _database = nil
local function get_database()
    if not _database then _database = require("core.database") end
    return _database
end

-- Guard for handlers where "DB must be open" is a production invariant.
-- Production: no connection is an upstream bug (project_changed handler
-- firing before set_path, etc.) → loud assert. Tests: pure-Lua logic
-- tests that don't stand up a DB reach these handlers via signal emits;
-- those return false and the caller skips the body.
local function db_available(caller)
    local connected = get_database().has_connection()
    runtime_mode.assert_production(connected,
        caller .. ": no DB connection in production — DB must be open "
        .. "by the time this path runs")
    return connected
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

-- Persistence: project_id for debounced DB writes
local current_project_id = nil
local persist_timer_active = false
local PERSIST_DEBOUNCE_MS = 500
local DB_SETTING_KEY = "media_error_cache"

-- qt_constants is a bound global in the editor; absent in headless Lua
-- tests. pcall insulates from "attempt to index global 'qt_constants'".
local function try_qt()
    local ok, qt = pcall(function() return qt_constants end)
    if ok then return qt end
    return nil
end

local function try_emp()
    local qt = try_qt()
    return qt and qt.EMP or nil
end

local function init_fs()
    if fs_available then return true end
    local qt = try_qt()
    if qt and qt.FS then
        FS = qt.FS
        fs_available = true
        -- Wire watcher callbacks the moment FS becomes available. This
        -- must happen BEFORE any FS.WATCH_FILE/DIR call, or events that
        -- arrive between first-watch and callback-registration go into
        -- the void (QFileSystemWatcher has no "missed events" replay).
        -- Keeping this inside init_fs() means every watch_path() caller
        -- — including the background-probe callback, which is the ONLY
        -- path that installs watches in production — wires callbacks
        -- as a precondition of adding its first path.
        FS.SET_FILE_CHANGED_CB(function(path) M._on_file_changed(path) end)
        FS.SET_DIR_CHANGED_CB(function(dir) M._on_dir_changed(dir) end)
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
-- @return table|nil: {offline, error_code, offline_note} or nil if not registered
function M.get(media_path)
    return status_cache[media_path]
end

--- Read per-media `offline_note` JSON for a path. Returns nil when the
--- media row carries no note (file truly unreachable, or last relink
--- succeeded). Pulled from the in-memory cache — the renderer calls
--- this per offline frame, so it MUST NOT touch the DB.
--- @param media_path string
--- @return string|nil raw note JSON
function M.get_offline_note(media_path)
    local entry = status_cache[media_path]
    return entry and entry.offline_note or nil
end

--- Populate the offline_note field of every cache entry from the media
--- table. Called on project open (once, before rendering starts). The
--- relinker writes new notes via media_changed — `reprobe_media_ids`
--- keeps the cache in sync after that.
function M.read_offline_notes_from_db()
    if not db_available("media_status.read_offline_notes_from_db") then return end
    local rows = Media.load_all_offline_notes()
    for _, row in ipairs(rows) do
        local entry = status_cache[row.file_path]
        if not entry then
            entry = { offline = false, error_code = nil }
            status_cache[row.file_path] = entry
        end
        entry.offline_note = row.offline_note
    end
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
    if not get_database().has_connection() then return end
    local map = build_persist_map()
    get_database().set_project_setting(current_project_id, DB_SETTING_KEY, map)
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
    if not db_available("media_status.load_persisted") then return end
    local map = get_database().get_project_setting(project_id, DB_SETTING_KEY)
    if map == nil then return end  -- first run: no persisted cache yet
    assert(type(map) == "table", string.format(
        "media_status.load_persisted: %s setting must be a table, got %s",
        DB_SETTING_KEY, type(map)))
    local error_count = 0
    local online_count = 0
    local cleared_count = 0

    for path, entry in pairs(map) do
        assert(type(entry) == "table", string.format(
            "media_status.load_persisted: entry for %s must be a table, got %s",
            path, type(entry)))
        assert(type(entry.offline) == "boolean", string.format(
            "media_status.load_persisted: entry.offline for %s must be boolean", path))
        -- Clear stale "Unsupported" codec errors. These may be from a previous
        -- build that lacked support (e.g. BRAW before SDK integration). The
        -- background probe will re-check and set the correct status. Only
        -- "Unsupported" is cleared — "FileNotFound" persists (file really missing).
        if entry.offline and entry.error_code == "Unsupported" then
            cleared_count = cleared_count + 1
        else
            status_cache[path] = {
                offline = entry.offline,
                error_code = entry.error_code,
            }
            if entry.offline then
                error_count = error_count + 1
            else
                online_count = online_count + 1
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
    if cached then
        clip.offline = cached.offline
        clip.error_code = cached.error_code
    end

    -- Per-clip shortfall: even when the file IS present (media_status
    -- says online), this specific clip may need frames that the file
    -- doesn't cover (partial-coverage relink). `offline` is the union
    -- of "file missing" and "content insufficient for this clip's
    -- range". The per-clip check depends on clip.source_in/out, which
    -- status_cache — keyed only on path — cannot know.
    if not clip.offline and clip.offline_note
        and clip.source_in and clip.source_out then
        local sf = offline_note.shortfall(
            offline_note.parse(clip.offline_note),
            clip.source_in, clip.source_out)
        if sf then
            clip.offline = true
            -- Distinct from FileNotFound / Unsupported so downstream
            -- code (offline-frame composer, label styling) can
            -- recognize "file there, content short" specifically.
            clip.error_code = clip.error_code or "InsufficientCoverage"
        end
    end
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

--- Re-probe a media path. Emits media_status_changed ONLY when the
--- offline/error status actually flipped — `media_content_changed` is
--- a separate signal emitted from _on_file_changed for in-place
--- rewrites where the status stays online but bytes moved.
---
--- Separating the two lets consumers subscribe to what they actually
--- care about: views (offline icons, clip.offline flags) listen to
--- status_changed; path-keyed caches (decoder pools, peak cache,
--- preview thumbnails) listen to content_changed.
local function reprobe_and_notify(media_path)
    local old = status_cache[media_path]
    local new_status = probe(media_path)
    status_cache[media_path] = new_status

    -- Update watches if status category changed (missing ↔ exists)
    unwatch_path(media_path)
    watch_path(media_path, new_status)

    local status_changed = not old
        or old.offline ~= new_status.offline
        or old.error_code ~= new_status.error_code

    if status_changed then
        schedule_persist()
        log.event("media_status changed: %s offline=%s error=%s",
            media_path, tostring(new_status.offline), tostring(new_status.error_code))
        -- Downstream wiring (TMB_CLEAR_OFFLINE, TMB_INVALIDATE_PATH,
        -- view refresh) lives in the subscribers — PlaybackEngine and
        -- SequenceMonitor — keyed off this signal. media_status itself
        -- owns the cache + signal; nothing else.
        Signals.emit("media_status_changed", media_path, new_status)
    end
    return status_changed
end

--- FS callback: a watched file changed (modified/deleted).
function M._on_file_changed(path)
    assert(path, "media_status._on_file_changed: path required")
    if status_cache[path] then
        local status_changed = reprobe_and_notify(path)
        -- In-place byte rewrite of a file that stayed online: status
        -- didn't flip, but the bytes did. Fire media_content_changed
        -- so path-keyed caches (decoders, peaks, previews) invalidate.
        if not status_changed then
            log.event("media_content_changed: %s", path)
            Signals.emit("media_content_changed", path)
        end
    end

    -- Invalidate peak cache for this media file (waveform regeneration).
    -- Guard: FS callback can fire after project close (no DB connection).
    if not get_database().has_connection() then return end
    local media_id = Media.find_id_by_path(path)
    if media_id then
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

--- Initialize FS integration eagerly. Safe to call multiple times.
-- Called from app startup (layout.lua) so callbacks are live even if
-- the first watch isn't installed until later. init_fs() is idempotent
-- and also runs lazily from watch_path() as a safety net.
function M.init_watcher()
    init_fs()
end

-- ============================================================
-- Background codec probe: worker thread probes all project media
-- ============================================================

--- Start a background codec probe for all media in the project.
-- Probes active sequence media first, then remaining project media.
-- Results arrive in batches on the main thread; views are signalled to repaint.
-- @param active_sequence_id string|nil: sequence to prioritize (its media probed first)
function M.start_background_probe(active_sequence_id)
    local emp = try_emp()
    if not emp or not emp.CODEC_PROBE_START then
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

    emp.CODEC_PROBE_START(all_paths, function(results, is_final)
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
            schedule_persist()
        end

        if is_final then
            log.event("media_status: bg probe complete")
            M.persist_now()
        end
    end)
end

--- Cancel any running background codec probe.
function M.cancel_background_probe()
    local emp = try_emp()
    if emp and emp.CODEC_PROBE_CANCEL then
        emp.CODEC_PROBE_CANCEL()
    end
end

--- Re-probe current paths of changed media records so the cache is
-- authoritative by the time views call ensure_clip_status.
-- @param media_ids table: set {media_id = true, ...}
function M.reprobe_media_ids(media_ids)
    assert(type(media_ids) == "table", string.format(
        "media_status.reprobe_media_ids: media_ids must be a table, got %s",
        type(media_ids)))
    if not db_available("media_status.reprobe_media_ids") then return end
    for media_id in pairs(media_ids) do
        assert(type(media_id) == "string" and media_id ~= "", string.format(
            "media_status.reprobe_media_ids: invalid media_id key %s",
            tostring(media_id)))
        local media = Media.load(media_id)
        assert(media, string.format(
            "media_status.reprobe_media_ids: media %s not found "
            .. "(media_changed emitted a stale or unknown id)", media_id))
        local path = media:get_file_path()
        assert(path and path ~= "", string.format(
            "media_status.reprobe_media_ids: media %s has empty file_path",
            media_id))
        reprobe_and_notify(path)
        -- Refresh the cached relink diagnostic alongside file status so
        -- the next offline frame composes with the updated note.
        local entry = status_cache[path]
        if entry then entry.offline_note = media.offline_note end
    end
end

-- Priority 30: prime cache before view refresh handlers (default 100).
Signals.connect("media_changed", M.reprobe_media_ids, 30)

-- Register for project_changed signal: flush old, clear, load new, start bg probe
Signals.connect("project_changed", function(project_id)
    M.clear()  -- cancels bg probe, flushes pending writes, clears cache
    if project_id and project_id ~= "" then
        M.load_persisted(project_id)
        M.read_offline_notes_from_db()
        -- Start background codec probe (prioritize active sequence)
        local ok, active_seq = pcall(function()
            return get_database().get_project_setting(project_id, "last_open_sequence_id")
        end)
        M.start_background_probe(ok and active_seq or nil)
    end
end, 12)  -- priority 12: after playback_controller (10), before media_cache (20)

return M
