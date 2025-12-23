--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~1666 LOC
-- Volatility: unknown
--
-- @file database.lua
-- Original intent (unreviewed):
-- Database module for Lua
-- Provides simple interface to SQLite database
local M = {}
local sqlite3 = require("core.sqlite3")
local json = require("dkjson")
local Rational = require("core.rational")
local logger = require("core.logger")
local path_utils = require("core.path_utils")

local BIN_NAMESPACE = "bin"

local function load_main_schema(db_conn)
    if not db_conn then
        error("FATAL: No database connection provided to load main schema")
    end

    local schema_path = "src/lua/schema.sql"

    local absolute_schema_path = path_utils.resolve_repo_root() .. "/" .. schema_path

    local file = io.open(absolute_schema_path, "r")
    if not file then
        error(string.format("FATAL: Missing main schema file '%s'", absolute_schema_path))
    end
    local sql = file:read("*a")
    file:close()

    local ok, err = db_conn:exec(sql)
    if not ok then
        error(string.format("FATAL: Failed to apply main schema %s: %s", absolute_schema_path, tostring(err)))
    end
end

-- Database connection
local db_connection = nil
local db_path = nil
local tag_tables_supported = nil

local function safe_remove(path)
    if not path or path == "" then
        return
    end
    local ok, err = os.remove(path)
    if ok == nil and err and not err:match("No such file") then
        logger.warn("database", string.format("Failed to remove %s: %s", tostring(path), tostring(err)))
    end
end

local function cleanup_wal_sidecars(base_path)
    if not base_path or base_path == "" then
        return
    end
    safe_remove(base_path .. "-wal")
    safe_remove(base_path .. "-shm")
end

local function file_exists(path)
    if not path or path == "" then
        return false
    end
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

function M.list_wal_sidecars(project_path)
    if not project_path or project_path == "" then
        error("FATAL: database.list_wal_sidecars requires a project path")
    end
    return {
        wal = file_exists(project_path .. "-wal") and (project_path .. "-wal") or nil,
        shm = file_exists(project_path .. "-shm") and (project_path .. "-shm") or nil,
    }
end

function M.move_aside_wal_sidecars(project_path, suffix)
    if not project_path or project_path == "" then
        error("FATAL: database.move_aside_wal_sidecars requires a project path")
    end
    if not suffix or suffix == "" then
        error("FATAL: database.move_aside_wal_sidecars requires a suffix")
    end

    local sidecars = M.list_wal_sidecars(project_path)
    local moves = {}

    local function move_one(source_path)
        if not source_path then
            return
        end
        local target_path = source_path .. "." .. suffix
        if file_exists(target_path) then
            error("FATAL: Refusing to overwrite existing file: " .. tostring(target_path))
        end
        local ok, err = os.rename(source_path, target_path)
        if not ok then
            error(string.format("FATAL: Failed to move %s → %s (%s)", tostring(source_path), tostring(target_path), tostring(err)))
        end
        table.insert(moves, { from = source_path, to = target_path })
    end

    move_one(sidecars.wal)
    move_one(sidecars.shm)

    return moves
end

local function checkpoint_and_disable_wal(opts)
    if not db_connection then
        return true
    end

    opts = opts or {}

    local ok, err = db_connection:exec("PRAGMA wal_checkpoint(TRUNCATE);")
    if ok == false then
        if opts.best_effort then
            logger.warn("database", "wal_checkpoint failed during shutdown (best_effort): " .. tostring(err))
            return true
        end
        return false, "wal_checkpoint failed: " .. tostring(err)
    end

    ok, err = db_connection:exec("PRAGMA journal_mode = DELETE;")
    if ok == false then
        if opts.best_effort then
            logger.warn("database", "journal_mode=DELETE failed during shutdown (best_effort): " .. tostring(err))
            return true
        end
        return false, "journal_mode=DELETE failed: " .. tostring(err)
    end
    return true
end

local function has_com_apple_macl_label(path)
    if not path or path == "" then
        return false
    end
    if not jit or jit.os ~= "OSX" then
        return false
    end
    if not io or not io.popen then
        return false
    end
    local handle = io.popen(string.format("/usr/bin/xattr -p com.apple.macl %q 2>/dev/null", path))
    if not handle then
        return false
    end
    local output = handle:read("*a")
    handle:close()
    return output and output ~= ""
end

local function detect_tag_table_support()
    if not db_connection then
        return false
    end
    local stmt = db_connection:prepare([[SELECT name FROM sqlite_master WHERE type='table' AND name='tags']])
    if not stmt then
        return false
    end
    local has_tags = stmt:exec() and stmt:next()
    stmt:finalize()
    if not has_tags then
        return false
    end

    stmt = db_connection:prepare([[SELECT name FROM sqlite_master WHERE type='table' AND name='tag_assignments']])
    if not stmt then
        return false
    end
    local has_assignments = stmt:exec() and stmt:next()
    stmt:finalize()
    return has_assignments
end

local function tag_tables_available()
    if tag_tables_supported == nil then
        tag_tables_supported = detect_tag_table_support()
    elseif tag_tables_supported == false then
        tag_tables_supported = detect_tag_table_support()
    end
    return tag_tables_supported
end

local function require_tag_tables()
    if not tag_tables_available() then
        error("FATAL: Tag tables missing (tag_namespaces/tags/tag_assignments). Run schema migrations to create them.")
    end
end

local function ensure_sequence_track_layouts_table()
    if not db_connection then
        return
    end

    local ok, err = db_connection:exec([[
        CREATE TABLE IF NOT EXISTS sequence_track_layouts (
            sequence_id TEXT PRIMARY KEY,
            track_heights_json TEXT NOT NULL,
            updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
        )
    ]])

    if ok == false then
        logger.warn("database", "Failed to ensure sequence_track_layouts table: " .. tostring(err or "unknown error"))
    end
end

local function trim_text(value)
    if type(value) ~= "string" then
        return ""
    end
    local stripped = value:match("^%s*(.-)%s*$")
    if not stripped then
        return ""
    end
    return stripped
end

local function ensure_tag_namespace(namespace_id, display_name)
    if not db_connection then
        return false
    end
    local stmt = db_connection:prepare("INSERT OR IGNORE INTO tag_namespaces(id, display_name) VALUES(?, ?)")
    if not stmt then
        return false
    end
    stmt:bind_value(1, namespace_id)
    stmt:bind_value(2, display_name or namespace_id)
    local ok = stmt:exec()
    stmt:finalize()
    return ok ~= false
end

local function extract_filename(path)
    if not path or path == "" then
        return nil
    end
    return path:match("([^/\\]+)$")
end

local function build_clip_from_query_row(query, requested_sequence_id)
    if not query then
        return nil
    end

    local clip_id = query:value(0)
    local raw_project_id = query:value(1)
    local sequence_project_id = query:value(2)
    local clip_project_id = raw_project_id or sequence_project_id
    if not clip_project_id then
        error(string.format(
            "FATAL: load_clips: clip %s missing project_id (sequence %s)",
            tostring(clip_id),
            tostring(requested_sequence_id)
        ))
    end

    local track_sequence_id = query:value(18)
    local owner_sequence_id = query:value(9) or track_sequence_id
    if not owner_sequence_id then
        error(string.format(
            "FATAL: load_clips: clip %s missing owner_sequence_id",
            tostring(clip_id)
        ))
    end

    local media_name = query:value(19)
    local media_path = query:value(20)
    local media_id = query:value(6)
    if media_id and media_id ~= "" then
        local has_name = media_name and media_name ~= ""
        local has_path = media_path and media_path ~= ""
        if not has_name and not has_path then
            error(string.format(
                "FATAL: load_clips: media metadata missing for clip %s (media_id=%s)",
                tostring(clip_id),
                tostring(media_id)
            ))
        end
    end
    
    local clip_fps_num = query:value(16)
    local clip_fps_den = query:value(17)

    -- load_clips/load_clip_entry SELECT appends sequence fps metadata.
    local sequence_fps_num = query:value(23)
    local sequence_fps_den = query:value(24)
    if not sequence_fps_num or not sequence_fps_den then
        error(string.format(
            "FATAL: load_clips: missing sequence fps for clip %s (sequence %s)",
            tostring(clip_id),
            tostring(requested_sequence_id)
        ))
    end

    if not clip_fps_num or not clip_fps_den then
        -- Clip fps is currently persisted on the clip row; treat missing as fatal
        -- because source_in/source_out require a timebase.
        error(string.format(
            "FATAL: load_clips: missing clip fps for clip %s (sequence %s)",
            tostring(clip_id),
            tostring(requested_sequence_id)
        ))
    end

	    local clip = {
	        id = clip_id,
	        project_id = clip_project_id,
	        clip_kind = query:value(3),
	        name = query:value(4),
	        track_id = query:value(5),
	        media_id = media_id,
	        created_at = query:value(21),
	        modified_at = query:value(22),
	        source_sequence_id = query:value(7),
	        parent_clip_id = query:value(8),
	        owner_sequence_id = owner_sequence_id,
	        track_sequence_id = track_sequence_id,
        
                        -- Rational Properties
        
                        -- Timeline positions are in the owning sequence timebase.
                        timeline_start = Rational.new(query:value(10) or 0, sequence_fps_num, sequence_fps_den),

                        duration = Rational.new(query:value(11) or 0, sequence_fps_num, sequence_fps_den),

                        -- Source bounds are in the clip timebase (media/source rate).
                        source_in = Rational.new(query:value(12) or 0, clip_fps_num, clip_fps_den),

                        source_out = Rational.new(query:value(13) or 0, clip_fps_num, clip_fps_den),
        
                        
        
                        rate = {
                            fps_numerator = clip_fps_num,
                            fps_denominator = clip_fps_den
                        },
        
                        
        
                        enabled = query:value(14) == 1,
        
                        offline = query:value(15) == 1,
        
                        media_name = media_name,
        
                        media_path = media_path
        
                    }
        
                    if not clip.name or clip.name == "" then
        clip.name = "Clip " .. (clip_id and clip_id:sub(1, 8) or "")
    end

    local label = media_name
    if not label or label == "" then
        label = extract_filename(media_path)
    end
    if not label or label == "" then
        label = clip_id and ("Clip " .. clip_id:sub(1, 8)) or ""
    end

    local display_label = clip.name
    if (not display_label or display_label == "") and media_name and media_name ~= "" then
        display_label = media_name
    end
    if (not display_label or display_label == "") and label and label ~= "" then
        display_label = label
    end
    clip.label = display_label

    return clip
end

local function resolve_namespace(opts)
    opts = opts or {}
    local namespace_id = opts.namespace_id or BIN_NAMESPACE
    local display_name = opts.display_name
    if not display_name or display_name == "" then
        if namespace_id == BIN_NAMESPACE then
            display_name = "Bins"
        else
            display_name = namespace_id
        end
    end
    return namespace_id, display_name
end

local function begin_write_transaction()
    if not db_connection then
        return nil, "No database connection"
    end
    local ok, err = db_connection:exec("BEGIN IMMEDIATE;")
    if ok == false then
        local message = tostring(err or "")
        if message:find("within a transaction", 1, true) then
            return false, nil
        end
        return nil, message
    end
    return true, nil
end

local function rollback_transaction(started)
    if started then
        db_connection:exec("ROLLBACK;")
    end
end

local function commit_transaction(started, context)
    if not started then
        return true
    end
    local ok, err = db_connection:exec("COMMIT;")
    if ok == false then
        logger.warn("database", string.format("%s: failed to commit: %s", tostring(context or "database"), tostring(err)))
        db_connection:exec("ROLLBACK;")
        return false
    end
    return true
end

-- Initialize database at given path (legacy helper for tests/tools)
function M.init(path)
    if not path or path == "" then
        error("FATAL: database.init() requires a file path")
    end
    return M.set_path(path)
end

-- Set database path and open connection
function M.set_path(path)
    if db_connection and db_connection.close then
        db_connection:close()
        db_connection = nil
    end
    tag_tables_supported = nil

    db_path = path
    logger.debug("database", "Database path set to: " .. tostring(path))

    -- Open database connection
    local db, err = sqlite3.open(path)
    if not db then
        local extra = ""
        if err and err:match("disk I/O error") then
            if has_com_apple_macl_label(path) then
                extra = " macOS applied the com.apple.macl label to this file. Add JVEEditor (and helper scripts) to Full Disk Access under System Settings → Privacy & Security or move the project file outside protected folders such as ~/Documents."
            else
                extra = " Ensure the path is writable and not locked by another application."
            end
        end
        logger.error("database", "Failed to open database: " .. tostring(err or "unknown error") .. extra)
        return false
    end

    db_connection = db

    -- Apply main application schema
    load_main_schema(db_connection)

    -- Configure busy timeout so we wait for locks instead of failing immediately
    if db_connection.busy_timeout then
        db_connection:busy_timeout(5000)  -- 5 seconds
    else
        -- Fallback for drivers without helper
        db_connection:exec("PRAGMA busy_timeout = 5000;")
    end

    -- Enable WAL to reduce writer contention when multiple tools touch the DB
    db_connection:exec("PRAGMA journal_mode = WAL;")

    ensure_sequence_track_layouts_table()
    tag_tables_available()

    logger.debug("database", "Database connection opened successfully")
    return db_connection
end

-- Get database path
function M.get_path()
    return db_path
end

-- Get database connection (for use by command_manager, models, etc.)
function M.get_connection()
    return db_connection
end

function M.shutdown(opts)
    if not db_connection then
        return true
    end

    opts = opts or {}

    -- Best-effort cleanup: if a transaction is left open, attempt to roll it back
    -- so we can checkpoint/close cleanly.
    pcall(function()
        db_connection:exec("ROLLBACK;")
    end)

    local ok, err = checkpoint_and_disable_wal(opts)
    if not ok then
        return false, err
    end

    local close_ok, close_err = pcall(function()
        if db_connection and db_connection.close then
            db_connection:close()
        end
    end)
    db_connection = nil
    tag_tables_supported = nil

    if not close_ok then
        return false, "failed to close database: " .. tostring(close_err)
    end

    cleanup_wal_sidecars(db_path)
    return true
end

-- Ensure a media row exists for the given media_id.
-- If missing, attempt to rebuild it from the original ImportMedia command.
function M.ensure_media_record(media_id)
    if not media_id or media_id == "" or not db_connection then
        return false
    end

    local check_stmt = db_connection:prepare("SELECT 1 FROM media WHERE id = ?")
    if check_stmt then
        check_stmt:bind_value(1, media_id)
        if check_stmt:exec() and check_stmt:next() then
            check_stmt:finalize()
            return true
        end
        check_stmt:finalize()
    end

    local cmd_stmt = db_connection:prepare("SELECT command_args FROM commands WHERE command_type = 'ImportMedia'")
    if not cmd_stmt then
        return false
    end

    local restored = false
    if cmd_stmt:exec() then
        while cmd_stmt:next() do
            local args_json = cmd_stmt:value(0)
            local ok, args = pcall(json.decode, args_json or "{}")
            if ok and args and args.media_id == media_id then
                local file_path = args.file_path or args.path
                local project_id = args.project_id
                if not project_id or project_id == "" then
                    logger.warn("database", "ensure_media_record: ImportMedia args missing project_id for media " .. tostring(media_id))
                elseif file_path and file_path ~= "" then
                    local MediaReader = require('media.media_reader')
                    local new_id, _, import_err = MediaReader.import_media(file_path, db_connection, project_id, media_id)
                    if new_id == media_id then
                        restored = true
                        break
                    else
                        if import_err then
                            logger.warn("database", "ensure_media_record: failed to reimport media: " .. tostring(import_err))
                        end
                    end
                end
            end
        end
    end

    cmd_stmt:finalize()
    return restored
end

-- Get current project ID
function M.get_current_project_id()
    if not db_connection then
        error("FATAL: No database connection - cannot get current project")
    end

    -- Fail fast: "current project" is only meaningful if there is exactly one project,
    -- or if an explicit active-project authority exists.
    local stmt = db_connection:prepare([[
        SELECT id
        FROM projects
        ORDER BY id ASC
    ]])
    if not stmt then
        error("FATAL: Failed to prepare project query")
    end

    if not stmt:exec() then
        stmt:finalize()
        error("FATAL: Failed to execute project query")
    end

    local ids = {}
    while stmt:next() do
        local id = stmt:value(0)
        if id and id ~= "" then
            table.insert(ids, id)
        end
    end
    stmt:finalize()

    if #ids == 0 then
        error("FATAL: No projects exist in database")
    end

    if #ids > 1 then
        error("FATAL: Multiple projects exist; active project selection is required (count=" .. tostring(#ids) .. ")")
    end

    return ids[1]
end

-- Load all tracks for a sequence
function M.load_tracks(sequence_id)
    if not sequence_id then
        error("FATAL: load_tracks() requires sequence_id parameter")
    end

    logger.debug("database", "Loading tracks for sequence: " .. tostring(sequence_id))

    if not db_connection then
        error("FATAL: No database connection - cannot load tracks")
    end

    local query = db_connection:prepare([[
        SELECT id, name, track_type, track_index, enabled
        FROM tracks
        WHERE sequence_id = ?
        ORDER BY track_type DESC, track_index ASC
    ]])

    if not query then
        local err = db_connection.errmsg and db_connection:errmsg() or "unknown error"
        error("FATAL: Failed to prepare track query: " .. tostring(err))
    end

    query:bind_value(1, sequence_id)

    local tracks = {}
    if query:exec() then
        while query:next() do
            table.insert(tracks, {
                id = query:value(0),
                name = query:value(1),
                track_type = query:value(2),  -- Keep as "VIDEO" or "AUDIO"
                track_index = query:value(3),
                enabled = query:value(4) == 1
            })
        end
    end

    logger.debug("database", string.format("Loaded %d tracks from database", #tracks))
    return tracks
end

-- Load all clips for a sequence
function M.load_clips(sequence_id)
    if not sequence_id then
        error("FATAL: load_clips() requires sequence_id parameter")
    end

    if not db_connection then
        error("FATAL: No database connection - cannot load clips")
    end

	    local query = db_connection:prepare([[
	        SELECT c.id, c.project_id, s.project_id, c.clip_kind, c.name, c.track_id, c.media_id,
	               c.source_sequence_id, c.parent_clip_id, c.owner_sequence_id,
	               c.timeline_start_frame, c.duration_frames,
	               c.source_in_frame, c.source_out_frame,
	               c.enabled, c.offline, c.fps_numerator, c.fps_denominator, t.sequence_id,
	               m.name, m.file_path,
	               c.created_at, c.modified_at,
	               s.fps_numerator, s.fps_denominator
	        FROM clips c
	        JOIN tracks t ON c.track_id = t.id
	        JOIN sequences s ON t.sequence_id = s.id
	        LEFT JOIN media m ON c.media_id = m.id
	        WHERE t.sequence_id = ?
        ORDER BY c.timeline_start_frame ASC
    ]])

    if not query then
        local err_func = db_connection.last_error
        local err = nil
        if err_func then
            err = err_func(db_connection)
        end
        error("FATAL: Failed to prepare clip query: " .. tostring(err or "unknown error"))
    end

    query:bind_value(1, sequence_id)

    local clips = {}
    if query:exec() then
        while query:next() do
            local clip = build_clip_from_query_row(query, sequence_id)
            if clip then
                table.insert(clips, clip)
            end
        end
    end

    return clips
end

function M.load_clip_entry(clip_id)
    if not clip_id or clip_id == "" then
        return nil
    end

    if not db_connection then
        error("FATAL: No database connection - cannot load clip entry")
    end

	    local query = db_connection:prepare([[
	        SELECT c.id, c.project_id, s.project_id, c.clip_kind, c.name, c.track_id, c.media_id,
	               c.source_sequence_id, c.parent_clip_id, c.owner_sequence_id,
	               c.timeline_start_frame, c.duration_frames, c.source_in_frame, c.source_out_frame,
	               c.enabled, c.offline, c.fps_numerator, c.fps_denominator,
	               t.sequence_id, m.name, m.file_path,
	               c.created_at, c.modified_at,
	               s.fps_numerator, s.fps_denominator
	        FROM clips c
	        JOIN tracks t ON c.track_id = t.id
	        JOIN sequences s ON t.sequence_id = s.id
	        LEFT JOIN media m ON c.media_id = m.id
	        WHERE c.id = ?
        LIMIT 1
    ]])

    if not query then
        error("FATAL: Failed to prepare clip entry query")
    end

    query:bind_value(1, clip_id)

    local clip = nil
    if query:exec() and query:next() then
        clip = build_clip_from_query_row(query, query:value(18))
    end

    query:finalize()
    return clip
end

function M.load_clip_properties(clip_id)
    if not clip_id or clip_id == "" then
        return {}
    end

    if not db_connection then
        error("FATAL: load_clip_properties: No database connection")
    end

    local properties = {}
    local query = db_connection:prepare([[
        SELECT property_name, property_value
        FROM properties
        WHERE clip_id = ?
    ]])

    if not query then
        return properties
    end

    query:bind_value(1, clip_id)

    if query:exec() then
        while query:next() do
            local name = query:value(0)
            local raw_value = query:value(1)
            local decoded_value = nil

            if raw_value and raw_value ~= "" then
                local ok, decoded = pcall(json.decode, raw_value)
                if ok and type(decoded) == "table" then
                    if decoded.value ~= nil then
                        decoded_value = decoded.value
                    else
                        decoded_value = decoded
                    end
                else
                    decoded_value = raw_value
                end
            end

            properties[name] = decoded_value
        end
    end

    query:finalize()
    return properties
end

-- REMOVED: save_clip() - Stub implementation violated event sourcing
-- Use command system instead: Command.create("AddClip", ...)

-- Update clip position - PRESERVED (has real SQL implementation)
function M.update_clip_position(clip_id, start_value, duration_value)
    if not clip_id then
        error("FATAL: update_clip_position() requires clip_id parameter")
    end
    if not start_value then
        error("FATAL: update_clip_position() requires start_time parameter")
    end
    if not duration_value then
        error("FATAL: update_clip_position() requires duration parameter")
    end

    if not db_connection then
        error("FATAL: No database connection - cannot update clip position")
    end

    local query = db_connection:prepare([[
        UPDATE clips
        SET start_value = ?, duration_value = ?, modified_at = strftime('%s','now')
        WHERE id = ?
    ]])

    if not query then
        error("FATAL: Failed to prepare UPDATE query for clip position")
    end

    query:bind_value(1, start_value)
    query:bind_value(2, duration_value)
    query:bind_value(3, clip_id)

    local success = query:exec()
    if not success then
        error(string.format("FATAL: Failed to update clip position for clip %s", clip_id))
    end

    return true
end

-- REMOVED: update_clip_property() - Stub that returned false success
-- Use command system instead: Command.create("SetClipProperty", ...)

-- REMOVED: delete_clip() - Stub that returned false success
-- Use command system instead: Command.create("DeleteClip", ...)

-- Load all media with tag associations
function M.load_media()
    if not db_connection then
        error("FATAL: No database connection - cannot load media")
    end

    local query = db_connection:prepare([[
        SELECT id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
               width, height, audio_channels, codec, created_at, modified_at, metadata
        FROM media
        ORDER BY created_at DESC
    ]])

    if not query then
        error("FATAL: Failed to prepare media query")
    end

    local media_items = {}
    if query:exec() then
        while query:next() do
            local num = query:value(5)
            local den = query:value(6)
            if not num or not den then
                error("FATAL: media row missing fps_numerator/fps_denominator (corrupt database)", 2)
            end
            
            table.insert(media_items, {
                id = query:value(0),
                project_id = query:value(1),
                name = query:value(2),
                file_name = query:value(2),
                file_path = query:value(3),
                duration = Rational.new(query:value(4), num, den),
                frame_rate = { fps_numerator = num, fps_denominator = den },
                width = query:value(7),
                height = query:value(8),
                audio_channels = query:value(9),
                codec = query:value(10),
                created_at = query:value(11),
                modified_at = query:value(12),
                metadata = query:value(13),
                tags = {}
            })
        end
    end

    logger.debug("database", string.format("Loaded %d media items from database", #media_items))
    return media_items
end

function M.load_master_clips(project_id)
    if not project_id or project_id == "" then
        error("FATAL: load_master_clips requires project_id", 2)
    end

    if not db_connection then
        error("FATAL: No database connection - cannot load master clips")
    end

    local query = db_connection:prepare([[
        SELECT
            c.id,
            c.name,
            c.project_id,
            c.media_id,
            c.source_sequence_id,
            c.timeline_start_frame,
            c.duration_frames,
            c.source_in_frame,
            c.source_out_frame,
            c.fps_numerator,
            c.fps_denominator,
            c.enabled,
            c.offline,
            c.created_at,
            c.modified_at,
            m.project_id,
            m.name,
            m.file_path,
            m.duration_frames,
            m.fps_numerator,
            m.fps_denominator,
            m.width,
            m.height,
            m.audio_channels,
            m.codec,
            m.metadata,
            m.created_at,
            m.modified_at,
            s.project_id,
            s.fps_numerator,
            s.fps_denominator,
            s.width,
            s.height,
            s.audio_rate
        FROM clips c
        LEFT JOIN media m ON c.media_id = m.id
        LEFT JOIN sequences s ON c.source_sequence_id = s.id
        WHERE c.clip_kind = 'master'
          AND (
                (c.project_id IS NOT NULL AND c.project_id = ?)
                OR (c.project_id IS NULL AND (s.project_id = ? OR s.project_id IS NULL))
            )
        ORDER BY c.name
    ]])

    if not query then
        error("FATAL: Failed to prepare master clip query")
    end

    query:bind_value(1, project_id)
    query:bind_value(2, project_id)

	    local clips = {}
	    if query:exec() then
	        while query:next() do
	            local clip_id = query:value(0)
	            local clip_name = query:value(1)
	            local clip_project_id = query:value(2)
	            local media_id = query:value(3)
	            local source_sequence_id = query:value(4)
	            
	            local start_frame = query:value(5)
	            local duration_frames = query:value(6)
	            local source_in_frame = query:value(7)
	            local source_out_frame = query:value(8)
	            if start_frame == nil or duration_frames == nil or source_in_frame == nil or source_out_frame == nil then
	                error(string.format(
	                    "FATAL: load_master_clips: master clip %s missing timeline/source frame data",
	                    tostring(clip_id)
	                ))
	            end
	            
	            local clip_fps_num = query:value(9)
	            local clip_fps_den = query:value(10)
	            if not clip_fps_num or not clip_fps_den then
	                error(string.format(
	                    "FATAL: load_master_clips: master clip %s missing fps",
	                    tostring(clip_id)
	                ))
	            end
	            
	            local enabled = query:value(11) == 1
	            local offline = query:value(12) == 1
	            local created_at = query:value(13)
	            local modified_at = query:value(14)

	            local media_project_id = query:value(15)
	            local media_name = query:value(16)
	            local media_path = query:value(17)
	            local media_duration_frames = query:value(18)
	            local media_fps_num = query:value(19)
	            local media_fps_den = query:value(20)
	            if media_id and media_id ~= "" then
	                if not media_duration_frames or not media_fps_num or not media_fps_den then
	                    error(string.format(
	                        "FATAL: load_master_clips: master clip %s missing media fps/duration (media_id=%s)",
	                        tostring(clip_id),
	                        tostring(media_id)
	                    ))
	                end
	            end
	            local media_width = query:value(21)
	            local media_height = query:value(22)
	            local media_channels = query:value(23)
	            local media_codec = query:value(24)
            local media_metadata = query:value(25)
	            local media_created_at = query:value(26)
	            local media_modified_at = query:value(27)

	            local sequence_project_id = query:value(28)
	            local sequence_fps_num = query:value(29)
	            local sequence_fps_den = query:value(30)
	            if source_sequence_id and (not sequence_fps_num or not sequence_fps_den) then
	                error(string.format(
	                    "FATAL: load_master_clips: master clip %s missing source sequence fps (source_sequence_id=%s)",
	                    tostring(clip_id),
	                    tostring(source_sequence_id)
	                ))
	            end
	            local sequence_width = query:value(31)
	            local sequence_height = query:value(32)
	            local sequence_audio_rate = query:value(33)

	            local media_info = {
	                id = media_id,
	                project_id = media_project_id,
	                name = media_name,
	                file_name = media_name,
	                file_path = media_path,
	                duration = Rational.new(media_duration_frames, media_fps_num, media_fps_den),
	                frame_rate = { fps_numerator = media_fps_num, fps_denominator = media_fps_den },
	                width = media_width,
	                height = media_height,
	                audio_channels = media_channels,
	                codec = media_codec,
                metadata = media_metadata,
                created_at = media_created_at,
                modified_at = media_modified_at,
            }

	            local sequence_info = nil
	            if source_sequence_id then
	                sequence_info = {
	                    id = source_sequence_id,
	                    project_id = sequence_project_id,
	                    frame_rate = { fps_numerator = sequence_fps_num, fps_denominator = sequence_fps_den },
	                    width = sequence_width,
	                    height = sequence_height,
	                    audio_sample_rate = sequence_audio_rate
	                }
	            end

            local clip_entry = {
                clip_id = clip_id,
                project_id = clip_project_id or media_project_id or sequence_project_id,
                name = clip_name or (media_name or clip_id),
                media_id = media_id,
                source_sequence_id = source_sequence_id,
                
	                timeline_start = Rational.new(start_frame, clip_fps_num, clip_fps_den),
	                duration = Rational.new(duration_frames, clip_fps_num, clip_fps_den),
                source_in = Rational.new(source_in_frame, clip_fps_num, clip_fps_den),
                source_out = Rational.new(source_out_frame, clip_fps_num, clip_fps_den),
                
                rate = { fps_numerator = clip_fps_num, fps_denominator = clip_fps_den },
                
                enabled = enabled,
                offline = offline,
                created_at = created_at,
                modified_at = modified_at,
                media = media_info,
                sequence = sequence_info,
            }

            -- Convenience fields for consumers
            clip_entry.file_path = media_path
            clip_entry.width = media_width or sequence_width
            clip_entry.height = media_height or sequence_height
            clip_entry.codec = media_codec

            table.insert(clips, clip_entry)
        end
    end

    query:finalize()

    logger.debug("database", string.format("Loaded %d master clips from database", #clips))
    return clips
end

function M.load_sequences(project_id)
    if not project_id or project_id == "" then
        error("FATAL: load_sequences requires project_id", 2)
    end
    if not db_connection then
        error("FATAL: load_sequences: No database connection")
    end

    local sequences = {}
    local query = db_connection:prepare([[
        SELECT id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
               playhead_frame, view_start_frame, view_duration_frames
        FROM sequences
        WHERE project_id = ?
        ORDER BY name
    ]])
    if not query then
        error("FATAL: load_sequences: Failed to prepare query: " .. tostring(db_connection:last_error() or "unknown"))
    end

    query:bind_value(1, project_id)
    if query:exec() then
        while query:next() do
            local fps_num = query:value(3)
            local fps_den = query:value(4)
            table.insert(sequences, {
                id = query:value(0),
                name = query:value(1),
                kind = query:value(2),
                frame_rate = { fps_numerator = fps_num, fps_denominator = fps_den },
                audio_sample_rate = query:value(5), -- Maps to audio_rate
                width = query:value(6),
                height = query:value(7),
                playhead_value = query:value(8),
                viewport_start_value = query:value(9),
                viewport_duration_frames_value = query:value(10),
            })
        end
    end
    query:finalize()

    -- Compute duration for each sequence (max clip end)
    for _, sequence in ipairs(sequences) do
        local clips = M.load_clips(sequence.id)
        -- Initialize max_end as Rational 0
        local max_end = Rational.new(0, sequence.frame_rate.fps_numerator, sequence.frame_rate.fps_denominator)
        for _, clip in ipairs(clips) do
            if clip.timeline_start and clip.duration then
                local clip_end = clip.timeline_start + clip.duration
                if clip_end > max_end then
                    max_end = clip_end
                end
            end
        end
        sequence.duration = max_end
    end

    return sequences
end

function M.load_sequence_record(sequence_id)
    if not sequence_id or sequence_id == "" then
        return nil
    end

    if not db_connection then
        error("FATAL: load_sequence_record: No database connection")
    end

    local query = db_connection:prepare([[
        SELECT id, project_id, name, kind, fps_numerator, fps_denominator, width, height,
               playhead_frame,
               view_start_frame, view_duration_frames,
               mark_in_frame, mark_out_frame,
               selected_clip_ids, selected_edge_infos, audio_rate
        FROM sequences
        WHERE id = ?
    ]])

    if not query then
        error("FATAL: load_sequence_record: Failed to prepare query: " .. tostring(db_connection:last_error() or "unknown"))
    end

    query:bind_value(1, sequence_id)

    local sequence = nil
    if query:exec() and query:next() then
        local fps_num = tonumber(query:value(4))
        local fps_den = tonumber(query:value(5))
        if not fps_num or fps_num <= 0 or not fps_den or fps_den <= 0 then
            query:finalize()
            error(string.format("FATAL: sequence %s missing valid fps_numerator/fps_denominator", tostring(sequence_id)))
        end
        
        sequence = {
            id = query:value(0),
            project_id = query:value(1),
            name = query:value(2),
            kind = query:value(3),
            frame_rate = { fps_numerator = fps_num, fps_denominator = fps_den },
            width = tonumber(query:value(6)),
            height = tonumber(query:value(7)),
            playhead_value = tonumber(query:value(8)),
            viewport_start_value = tonumber(query:value(9)),
            viewport_duration_frames_value = tonumber(query:value(10)),
            mark_in_value = tonumber(query:value(11)),
            mark_out_value = tonumber(query:value(12)),
            selected_clip_ids = query:value(13),
            selected_edge_infos = query:value(14),
            audio_sample_rate = tonumber(query:value(15))
        }

        if not sequence.width or not sequence.height then
            query:finalize()
            error(string.format("FATAL: sequence %s missing width/height", tostring(sequence_id)))
        end

        if not sequence.playhead_value or not sequence.viewport_start_value or not sequence.viewport_duration_frames_value then
            query:finalize()
            error(string.format("FATAL: sequence %s missing view/playhead fields", tostring(sequence_id)))
        end

        if not sequence.audio_sample_rate or sequence.audio_sample_rate <= 0 then
            query:finalize()
            error(string.format(
                "FATAL: sequence %s missing valid audio_sample_rate", tostring(sequence_id)
            ))
        end
    end

    query:finalize()
    return sequence
end

function M.load_sequence_track_heights(sequence_id)
    if not sequence_id or sequence_id == "" then
        return {}
    end

    if not db_connection then
        error("FATAL: load_sequence_track_heights: No database connection")
    end

    ensure_sequence_track_layouts_table()

    local stmt = db_connection:prepare([[
        SELECT track_heights_json
        FROM sequence_track_layouts
        WHERE sequence_id = ?
    ]])

    if not stmt then
        error("FATAL: load_sequence_track_heights: Failed to prepare query")
    end

    stmt:bind_value(1, sequence_id)

    local payload = {}
    if stmt:exec() and stmt:next() then
        local raw = stmt:value(0)
        if raw and raw ~= "" then
            local ok, decoded = pcall(json.decode, raw)
            if not ok then
                stmt:finalize()
                error("FATAL: load_sequence_track_heights: invalid JSON in database")
            end
            if type(decoded) ~= "table" then
                stmt:finalize()
                error("FATAL: load_sequence_track_heights: expected JSON object in database")
            end
            payload = decoded
        end
    end

    stmt:finalize()
    return payload
end

function M.set_sequence_track_heights(sequence_id, track_heights)
    if not sequence_id or sequence_id == "" then
        return false
    end

    if not db_connection then
        error("FATAL: set_sequence_track_heights: No database connection")
    end

    ensure_sequence_track_layouts_table()

    if type(track_heights) ~= "table" then
        error("FATAL: set_sequence_track_heights: track_heights must be a table")
    end

    local encoded, encode_err = json.encode(track_heights)
    if not encoded then
        error("FATAL: set_sequence_track_heights: Failed to encode JSON: " .. tostring(encode_err))
    end

    local stmt = db_connection:prepare([[
        INSERT INTO sequence_track_layouts (sequence_id, track_heights_json, updated_at)
        VALUES (?, ?, strftime('%s','now'))
        ON CONFLICT(sequence_id) DO UPDATE SET
            track_heights_json = excluded.track_heights_json,
            updated_at = excluded.updated_at
    ]])

    if not stmt then
        error("FATAL: set_sequence_track_heights: Failed to prepare upsert statement")
    end

    stmt:bind_value(1, sequence_id)
    stmt:bind_value(2, encoded)

    local ok = stmt:exec()
    stmt:finalize()
    return ok ~= false
end

local function decode_settings_json(raw)
    if not raw or raw == "" then
        return {}
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok then
        error("FATAL: Invalid project settings JSON in database")
    end
    if type(decoded) ~= "table" then
        error("FATAL: Project settings JSON must be an object")
    end
    return decoded
end

local function ensure_project_record(project_id)
    if not project_id or project_id == "" or not db_connection then
        return false
    end

    local stmt = db_connection:prepare("SELECT 1 FROM projects WHERE id = ?")
    if stmt then
        stmt:bind_value(1, project_id)
        local exists = stmt:exec() and stmt:next()
        stmt:finalize()
        if exists then
            return true
        end
    end

    local Project = require("models.project")
    local project = Project.create_with_id(project_id, "Untitled Project")
    if not project then
        error("FATAL: ensure_project_record: Failed to create project object")
    end
    if not project:save(db_connection) then
        error("FATAL: ensure_project_record: Failed to save project " .. tostring(project_id))
    end
    return true
end

function M.get_project_settings(project_id)
    if not project_id or project_id == "" then
        error("FATAL: get_project_settings requires project_id", 2)
    end
    if not db_connection then
        error("FATAL: get_project_settings: No database connection")
    end

    local stmt = db_connection:prepare("SELECT settings FROM projects WHERE id = ?")
    if not stmt then
        error("FATAL: get_project_settings: Failed to prepare query")
    end

    stmt:bind_value(1, project_id)
    local settings_json = nil
    if stmt:exec() and stmt:next() then
        settings_json = stmt:value(0)
    end
    stmt:finalize()

    if not settings_json then
        error("FATAL: get_project_settings: missing settings row for project " .. tostring(project_id))
    end
    return decode_settings_json(settings_json)
end

function M.get_project_setting(project_id, key)
    if not key or key == "" then
        return nil
    end
    local settings = M.get_project_settings(project_id)
    return settings[key]
end

function M.set_project_setting(project_id, key, value)
    if not key or key == "" then
        return false
    end

    if not project_id or project_id == "" then
        error("FATAL: set_project_setting requires project_id", 2)
    end
    if not db_connection then
        error("FATAL: set_project_setting: No database connection")
    end

    ensure_project_record(project_id)
    local settings = M.get_project_settings(project_id)
    if value == nil then
        settings[key] = nil
    else
        settings[key] = value
    end

    local encoded, encode_err = json.encode(settings)
    if not encoded then
        error("FATAL: set_project_setting: Failed to encode settings JSON: " .. tostring(encode_err))
    end

    local stmt = db_connection:prepare([[
        UPDATE projects
        SET settings = ?, modified_at = strftime('%s', 'now')
        WHERE id = ?
    ]])

    if not stmt then
        error("FATAL: set_project_setting: Failed to prepare update statement")
    end

    stmt:bind_value(1, encoded)
    stmt:bind_value(2, project_id)
    local ok = stmt:exec()
    if not ok then
        error("FATAL: set_project_setting: Update failed for project " .. tostring(project_id))
    end
    stmt:finalize()
    return ok
end

-- Load all tags for a specific namespace (or all namespaces if nil)
function M.load_media_tags(namespace)
    local media_items = M.load_media()
    local tags = {}

    for _, media in ipairs(media_items) do
        if media.tags then
            for _, tag in ipairs(media.tags) do
                if not namespace or tag.namespace == namespace then
                    -- Build unique tag list
                    local key = tag.namespace .. ":" .. (tag.tag_path or "root")
                    if not tags[key] then
                        tags[key] = {
                            namespace = tag.namespace,
                            tag_path = tag.tag_path,
                            media_ids = {}
                        }
                    end
                    table.insert(tags[key].media_ids, media.id)
                end
            end
        end
    end

    -- Convert map to list
    local tag_list = {}
    for _, tag in pairs(tags) do
        table.insert(tag_list, tag)
    end

    return tag_list
end

-- Get all available tag namespaces
function M.get_tag_namespaces()
    local media_items = M.load_media()
    local namespaces = {}

    for _, media in ipairs(media_items) do
        if media.tags then
            for _, tag in ipairs(media.tags) do
                if not namespaces[tag.namespace] then
                    namespaces[tag.namespace] = true
                end
            end
        end
    end

    -- Convert to list
    local namespace_list = {}
    for ns, _ in pairs(namespaces) do
        table.insert(namespace_list, ns)
    end

    table.sort(namespace_list)  -- Sort alphabetically
    return namespace_list
end

local function build_bin_lookup(bins)
    local ordered = {}
    local lookup = {}
    for index, bin in ipairs(bins or {}) do
        if type(bin) == "table" then
            local id = bin.id
            local name = trim_text(bin.name)
            if type(id) == "string" and id ~= "" and name ~= "" then
                local parent_id = bin.parent_id
                if type(parent_id) ~= "string" or parent_id == "" then
                    parent_id = nil
                end
                local entry = {
                    id = id,
                    name = name,
                    parent_id = parent_id
                }
                lookup[id] = entry
                table.insert(ordered, entry)
            end
        end
    end
    table.sort(ordered, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    for sort_index, entry in ipairs(ordered) do
        entry.sort_index = sort_index
    end
    return ordered, lookup
end

local function resolve_bin_path(bin_id, lookup, cache, stack)
    local node = lookup[bin_id]
    if not node then
        return nil
    end
    if cache[bin_id] then
        return cache[bin_id]
    end
    stack = stack or {}
    if stack[bin_id] then
        return nil
    end
    stack[bin_id] = true
    local parent_path = nil
    local parent_id = node.parent_id
    if parent_id and lookup[parent_id] then
        parent_path = resolve_bin_path(parent_id, lookup, cache, stack)
        if not parent_path then
            node.parent_id = nil
        end
    else
        node.parent_id = nil
    end
    stack[bin_id] = nil
    local path = parent_path and (parent_path .. "/" .. node.name) or node.name
    cache[bin_id] = path
    return path
end

local function validate_bin_id(project_id, bin_id)
    if not bin_id or bin_id == "" or not db_connection then
        return false
    end
    local stmt = db_connection:prepare([[
        SELECT 1 FROM tags
        WHERE id = ? AND project_id = ? AND namespace_id = ?
        LIMIT 1
    ]])
    if not stmt then
        return false
    end
    stmt:bind_value(1, bin_id)
    stmt:bind_value(2, project_id)
    stmt:bind_value(3, BIN_NAMESPACE)
    local exists = false
    if stmt:exec() and stmt:next() then
        exists = true
    end
    stmt:finalize()
    return exists
end

function M.load_bins(project_id, opts)
    if not project_id or project_id == "" then
        error("FATAL: load_bins requires project_id", 2)
    end
    if not db_connection then
        error("FATAL: No database connection - cannot load bins")
    end

    require_tag_tables()

    local namespace_id, display_name = resolve_namespace(opts)
    ensure_tag_namespace(namespace_id, display_name)

    local stmt = db_connection:prepare([[
        SELECT id, name, parent_id
        FROM tags
        WHERE project_id = ? AND namespace_id = ?
        ORDER BY sort_index ASC, path ASC
    ]])
    if not stmt then
        return {}
    end
    stmt:bind_value(1, project_id)
    stmt:bind_value(2, namespace_id)

    local bins = {}
    if stmt:exec() then
        while stmt:next() do
            table.insert(bins, {
                id = stmt:value(0),
                name = stmt:value(1),
                parent_id = stmt:value(2)
            })
        end
    end
    stmt:finalize()
    return bins
end

function M.save_bins(project_id, bins, opts)
    if not project_id or project_id == "" then
        local reason = "save_bins: Missing project_id"
        logger.warn("database", reason)
        return false, reason
    end
    if not db_connection then
        local reason = "save_bins: No database connection"
        logger.warn("database", reason)
        return false, reason
    end

    require_tag_tables()

    local namespace_id, display_name = resolve_namespace(opts)
    ensure_tag_namespace(namespace_id, display_name)

    local ordered, lookup = build_bin_lookup(bins)
    local path_cache = {}
    for _, bin in ipairs(ordered) do
        local path = resolve_bin_path(bin.id, lookup, path_cache, {})
        if not path or path == "" then
            local reason = string.format("save_bins: invalid hierarchy for bin %s", tostring(bin.id))
            logger.warn("database", reason)
            return false, reason
        end
    end

    local started, begin_err = begin_write_transaction()
    if started == nil then
        local reason = "save_bins: failed to begin transaction: " .. tostring(begin_err)
        logger.warn("database", reason)
        return false, reason
    end

    local purge_stmt = db_connection:prepare([[
        DELETE FROM tags
        WHERE project_id = ? AND namespace_id = ?
    ]])
    if purge_stmt then
        purge_stmt:bind_value(1, project_id)
        purge_stmt:bind_value(2, namespace_id)
        purge_stmt:exec()
        purge_stmt:finalize()
    end

    local upsert_stmt = db_connection:prepare([[
        INSERT INTO tags (id, project_id, namespace_id, name, path, parent_id, sort_index)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]])
    if not upsert_stmt then
        rollback_transaction(started)
        return false, "save_bins: failed to prepare upsert statement"
    end

    local inserted = {}
    for _, bin in ipairs(ordered) do
        if upsert_stmt.reset then
            upsert_stmt:reset()
        end
        upsert_stmt:clear_bindings()
        local path = path_cache[bin.id]
        upsert_stmt:bind_value(1, bin.id)
        upsert_stmt:bind_value(2, project_id)
        upsert_stmt:bind_value(3, namespace_id)
        upsert_stmt:bind_value(4, bin.name)
        upsert_stmt:bind_value(5, path)
        if bin.parent_id and lookup[bin.parent_id] then
            upsert_stmt:bind_value(6, bin.parent_id)
        elseif upsert_stmt.bind_null then
            upsert_stmt:bind_null(6)
        else
            upsert_stmt:bind_value(6, nil)
        end
        upsert_stmt:bind_value(7, bin.sort_index or 0)
        local success = upsert_stmt:exec()
        if success == false then
            local reason = string.format(
                "save_bins: failed to upsert bin %s (project_id=%s, ns=%s, error=%s, rc=%s)",
                tostring(bin.id),
                tostring(project_id),
                tostring(namespace_id),
                tostring(upsert_stmt:last_error() or "unknown error"),
                tostring(upsert_stmt:last_result_code() or "?")
            )
            upsert_stmt:finalize()
            rollback_transaction(started)
            return false, reason
        end
        inserted[bin.id] = true
    end
    upsert_stmt:finalize()

    local select_stmt = db_connection:prepare([[
        SELECT id
        FROM tags
        WHERE project_id = ? AND namespace_id = ?
    ]])
        if not select_stmt then
            rollback_transaction(started)
            return false, "save_bins: failed to prepare select statement"
        end
    select_stmt:bind_value(1, project_id)
    select_stmt:bind_value(2, BIN_NAMESPACE)

    local stale_ids = {}
    if select_stmt:exec() then
        while select_stmt:next() do
            local existing_id = select_stmt:value(0)
            if existing_id and not inserted[existing_id] then
                table.insert(stale_ids, existing_id)
            end
        end
    end
    select_stmt:finalize()

    if #stale_ids > 0 then
        local delete_stmt = db_connection:prepare([[
            DELETE FROM tags
            WHERE project_id = ? AND namespace_id = ? AND id = ?
        ]])
        if not delete_stmt then
            rollback_transaction(started)
            return false, "save_bins: failed to prepare stale delete statement"
        end
        for _, stale_id in ipairs(stale_ids) do
            delete_stmt:bind_value(1, project_id)
            delete_stmt:bind_value(2, namespace_id)
            delete_stmt:bind_value(3, stale_id)
            local success = delete_stmt:exec()
            delete_stmt:clear_bindings()
        if success == false then
            local reason = string.format(
                "save_bins: failed to delete stale bin %s (%s, rc=%s)",
                tostring(stale_id),
                tostring(delete_stmt:last_error() or "unknown error"),
                tostring(delete_stmt:last_result_code() or "?")
            )
            delete_stmt:finalize()
            rollback_transaction(started)
            return false, reason
            end
        end
        delete_stmt:finalize()
    end

    if not commit_transaction(started, "save_bins") then
        return false, "save_bins: commit failed"
    end
    return true
end

function M.load_master_clip_bin_map(project_id)
    if not project_id or project_id == "" then
        error("FATAL: load_master_clip_bin_map requires project_id", 2)
    end
    local assignments = {}
    if not db_connection then
        return assignments
    end

    require_tag_tables()

    local stmt = db_connection:prepare([[
        SELECT entity_id, tag_id
        FROM tag_assignments
        WHERE project_id = ? AND namespace_id = ? AND entity_type = 'master_clip'
    ]])
    if not stmt then
        return assignments
    end
    stmt:bind_value(1, project_id)
    stmt:bind_value(2, BIN_NAMESPACE)

    if stmt:exec() then
        while stmt:next() do
            local entity_id = stmt:value(0)
            local tag_id = stmt:value(1)
            if entity_id and tag_id then
                assignments[entity_id] = tag_id
            end
        end
    end
    stmt:finalize()
    return assignments
end

function M.save_master_clip_bin_map(project_id, bin_map)
    if not project_id or project_id == "" then
        return false
    end
    if not db_connection then
        return false
    end

    require_tag_tables()

    ensure_tag_namespace(BIN_NAMESPACE, "Bins")

    local started, begin_err = begin_write_transaction()
    if started == nil then
        logger.warn("database", "save_master_clip_bin_map: failed to begin transaction: " .. tostring(begin_err))
        return false
    end

    local delete_stmt = db_connection:prepare([[
        DELETE FROM tag_assignments
        WHERE project_id = ? AND namespace_id = ? AND entity_type = 'master_clip'
    ]])
    if not delete_stmt then
        rollback_transaction(started)
        return false
    end
    delete_stmt:bind_value(1, project_id)
    delete_stmt:bind_value(2, BIN_NAMESPACE)
    if delete_stmt:exec() == false then
        delete_stmt:finalize()
        rollback_transaction(started)
        return false
    end
    delete_stmt:finalize()

    local insert_stmt = db_connection:prepare([[
        INSERT INTO tag_assignments(tag_id, project_id, namespace_id, entity_type, entity_id)
        VALUES (?, ?, ?, 'master_clip', ?)
    ]])
    if not insert_stmt then
        rollback_transaction(started)
        return false
    end

    for clip_id, bin_id in pairs(bin_map or {}) do
        if type(clip_id) == "string" and clip_id ~= "" and type(bin_id) == "string" and bin_id ~= "" then
            if not validate_bin_id(project_id, bin_id) then
                logger.warn("database", string.format("save_master_clip_bin_map: bin %s does not exist", tostring(bin_id)))
                insert_stmt:finalize()
                rollback_transaction(started)
                return false
            end
            insert_stmt:bind_value(1, bin_id)
            insert_stmt:bind_value(2, project_id)
            insert_stmt:bind_value(3, BIN_NAMESPACE)
            insert_stmt:bind_value(4, clip_id)
            local success = insert_stmt:exec()
            insert_stmt:clear_bindings()
            if success == false then
                insert_stmt:finalize()
                rollback_transaction(started)
                return false
            end
        end
    end
    insert_stmt:finalize()

    if not commit_transaction(started, "save_master_clip_bin_map") then
        return false
    end
    return true
end

function M.assign_master_clips_to_bin(project_id, clip_ids, bin_id)
    if not project_id or project_id == "" then
        return false, "Missing project_id"
    end
    if not db_connection then
        return false, "No database connection"
    end
    if type(clip_ids) ~= "table" or #clip_ids == 0 then
        return true
    end

    require_tag_tables()
    ensure_tag_namespace(BIN_NAMESPACE, "Bins")

    if bin_id and (type(bin_id) ~= "string" or bin_id == "" or not validate_bin_id(project_id, bin_id)) then
        local message = string.format("assign_master_clips_to_bin: invalid bin %s", tostring(bin_id))
        logger.warn("database", message)
        return false, message
    end

    local started, begin_err = begin_write_transaction()
    if started == nil then
        local message = "assign_master_clips_to_bin: failed to begin transaction: " .. tostring(begin_err)
        logger.warn("database", message)
        return false, message
    end

    for _, clip_id in ipairs(clip_ids) do
        if type(clip_id) == "string" and clip_id ~= "" then
            local delete_stmt = db_connection:prepare([[
                DELETE FROM tag_assignments
                WHERE project_id = ? AND namespace_id = ? AND entity_type = 'master_clip' AND entity_id = ?
            ]])
            if not delete_stmt then
                rollback_transaction(started)
                return false, "assign_master_clips_to_bin: failed to prepare delete statement"
            end
            delete_stmt:bind_value(1, project_id)
            delete_stmt:bind_value(2, BIN_NAMESPACE)
            delete_stmt:bind_value(3, clip_id)
            local success = delete_stmt:exec()
            local delete_detail = delete_stmt:last_error()
            local delete_rc = delete_stmt:last_result_code()
            delete_stmt:finalize()
            if success == false then
                rollback_transaction(started)
                return false, string.format("assign_master_clips_to_bin: delete failed for clip %s (%s, rc=%s)", tostring(clip_id), tostring(delete_detail or "unknown error"), tostring(delete_rc))
            end

            if bin_id then
                local insert_stmt = db_connection:prepare([[
                    INSERT INTO tag_assignments(tag_id, project_id, namespace_id, entity_type, entity_id)
                    VALUES (?, ?, ?, 'master_clip', ?)
                ]])
                if not insert_stmt then
                    rollback_transaction(started)
                    return false, "assign_master_clips_to_bin: failed to prepare insert statement"
                end
                insert_stmt:bind_value(1, bin_id)
                insert_stmt:bind_value(2, project_id)
                insert_stmt:bind_value(3, BIN_NAMESPACE)
                insert_stmt:bind_value(4, clip_id)
                success = insert_stmt:exec()
                local insert_detail = insert_stmt:last_error()
                local insert_rc = insert_stmt:last_result_code()
                insert_stmt:finalize()
                if success == false then
                    rollback_transaction(started)
                    return false, string.format("assign_master_clips_to_bin: insert failed for clip %s (%s, rc=%s)", tostring(clip_id), tostring(insert_detail or "unknown error"), tostring(insert_rc))
                end
            end
        end
    end

    if not commit_transaction(started, "assign_master_clips_to_bin") then
        return false, "assign_master_clips_to_bin: commit failed"
    end
    return true
end

function M.assign_master_clip_to_bin(project_id, clip_id, bin_id)
    if not clip_id or clip_id == "" then
        return false
    end
    return M.assign_master_clips_to_bin(project_id, {clip_id}, bin_id)
end

-- REMOVED: import_media() - Stub function that returned dummy data
-- Use media_reader.lua and ImportMedia command instead

return M
