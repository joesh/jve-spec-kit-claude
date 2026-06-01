--- Database module for Lua
-- Provides simple interface to SQLite database
local M = {}
local sqlite3 = require("core.sqlite3")
local json = require("dkjson")
local log = require("core.logger").for_area("database")

-- Expected schema version. Projects with a different version cannot be
-- opened — per the no-backward-compat rule, incompatible projects must
-- be re-imported from the original source (.drp) to create a fresh DB
-- at the current version. No ALTER TABLE migration path.
M.SCHEMA_VERSION = 12
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
        log.warn("Failed to remove %s: %s", tostring(path), tostring(err))
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

--- Flush all WAL pages to the main database file and truncate the WAL.
--- After this returns true, the .jvp main file alone carries every write
--- made up to now — cross-process consumers (smoke runner copying just
--- the .jvp; backup / sync tools that skip sidecars) won't lose data.
--- The active connection stays open and resumes writing to a fresh WAL.
--- @return boolean ok, string|nil err
function M.checkpoint_wal()
    if not db_connection then return true end
    local ok, err = db_connection:exec("PRAGMA wal_checkpoint(TRUNCATE);")
    if ok == false then
        return false, "wal_checkpoint failed: " .. tostring(err)
    end
    return true
end

local function checkpoint_and_disable_wal(opts)
    if not db_connection then
        return true
    end

    opts = opts or {}

    local ok, err = M.checkpoint_wal()
    if not ok then
        if opts.best_effort then
            log.warn("wal_checkpoint failed during shutdown (best_effort): %s", tostring(err))
            return true
        end
        return false, err
    end

    ok, err = db_connection:exec("PRAGMA journal_mode = DELETE;")
    if ok == false then
        if opts.best_effort then
            log.warn("journal_mode=DELETE failed during shutdown (best_effort): %s", tostring(err))
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

    assert(ok ~= false, "ensure_sequence_track_layouts_table: CREATE TABLE failed: " .. tostring(err or "unknown error"))
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

-- V13 clip query row layout (used by load_clips, load_clip_entry):
--   0: c.id
--   1: c.project_id
--   2: c.name
--   3: c.track_id
--   4: c.owner_sequence_id
--   5: c.sequence_id
--   6: c.sequence_start_frame
--   7: c.duration_frames
--   8: c.source_in_frame
--   9: c.source_out_frame
--   10: c.source_in_subframe    (018; NULL for video, INTEGER for audio)
--   11: c.source_out_subframe   (018; NULL for video, INTEGER for audio)
--   12: c.master_layer_track_id
--   13: c.master_audio_track_id
--   14: c.fps_mismatch_policy
--   15: c.enabled
--   16: c.created_at
--   17: c.modified_at
--   18: t.sequence_id            (track's owning sequence — must match owner_sequence_id)
--   19: t.track_type             ('VIDEO' or 'AUDIO')
--   20: owner_seq.fps_numerator  (owner sequence timebase)
--   21: owner_seq.fps_denominator
--   22: nested_seq.kind          ('master' or 'sequence')
--   23: nested_seq.fps_numerator (clip-side / source-side timebase = nested seq's rate)
--   24: nested_seq.fps_denominator
--   25: mr.media_id              (NULL when nested is itself nested, or master has no media_ref)
--   26: m.name                   (NULL when no media join)
--   27: m.file_path              (NULL when no media join)
--   28: m.offline_note           (NULL when no media join)
local function build_clip_from_query_row(query, requested_sequence_id)
    if not query then
        return nil
    end

    local clip_id = query:value(0)
    local clip_project_id = query:value(1)
    if not clip_project_id then
        error(string.format(
            "FATAL: load_clips: clip %s missing project_id (sequence %s)",
            tostring(clip_id),
            tostring(requested_sequence_id)
        ))
    end

    local owner_sequence_id = query:value(4)
    local track_sequence_id = query:value(18)
    if not owner_sequence_id then
        error(string.format(
            "FATAL: load_clips: clip %s missing owner_sequence_id",
            tostring(clip_id)
        ))
    end
    if track_sequence_id ~= owner_sequence_id then
        error(string.format(
            "FATAL: load_clips: clip %s track.sequence_id=%s != owner_sequence_id=%s",
            tostring(clip_id), tostring(track_sequence_id), tostring(owner_sequence_id)
        ))
    end

    local sequence_id = query:value(5)
    if not sequence_id then
        error(string.format(
            "FATAL: load_clips: clip %s missing sequence_id",
            tostring(clip_id)
        ))
    end

    local source_kind = query:value(22)
    local nested_fps_num = query:value(23)
    local nested_fps_den = query:value(24)
    if not nested_fps_num or not nested_fps_den then
        error(string.format(
            "FATAL: load_clips: missing nested-sequence fps for clip %s (nested=%s)",
            tostring(clip_id), tostring(sequence_id)
        ))
    end

    local owner_fps_num = query:value(20)
    local owner_fps_den = query:value(21)
    if not owner_fps_num or not owner_fps_den then
        error(string.format(
            "FATAL: load_clips: missing owner-sequence fps for clip %s (owner=%s)",
            tostring(clip_id), tostring(owner_sequence_id)
        ))
    end

    local media_id = query:value(25)
    local media_name = query:value(26)
    local media_path = query:value(27)
    local offline_note = query:value(28)

    local track_type = query:value(19)

    -- clips.volume is NOT NULL DEFAULT 1.0 — a NULL here means a raw-SQL
    -- bypass or partial migration. Timeline-cache consumers (sift/find via
    -- timeline_panel:get_clips) require it as a number; assert loudly.
    local clip_volume = assert(query:value(29), string.format(
        "load_clips: clip %s missing volume", clip_id))

    local clip = {
        id = clip_id,
        project_id = clip_project_id,
        name = query:value(2),
        track_id = query:value(3),
        owner_sequence_id = owner_sequence_id,
        track_sequence_id = owner_sequence_id,
        sequence_id = sequence_id,
        source_sequence_kind = source_kind,
        master_layer_track_id = query:value(12),
        master_audio_track_id = query:value(13),
        fps_mismatch_policy = query:value(14),

        sequence_start = assert(query:value(6), string.format("load_clips: clip %s missing sequence_start", clip_id)),
        duration = assert(query:value(7), string.format("load_clips: clip %s missing duration", clip_id)),
        source_in = assert(query:value(8), string.format("load_clips: clip %s missing source_in", clip_id)),
        source_out = assert(query:value(9), string.format("load_clips: clip %s missing source_out", clip_id)),

        -- 018: subframe round-trips through load (NULL for video, INTEGER for audio).
        source_in_subframe = query:value(10),
        source_out_subframe = query:value(11),
        -- T018 tripwire (defense-in-depth mirror of FR-013 subframe-by-kind): if a row reaches
        -- the load path with a kind/subframe-presence mismatch, the schema
        -- triggers should have already blocked the write — but a raw SQL
        -- bypass or a partial migration would surface here at read time
        -- rather than silently producing wrong audio math at the resolver.
        -- Asserts are below after track_type is computed.

        -- The clip's source_in/out are in the source sequence's timebase.
        frame_rate = {
            fps_numerator = nested_fps_num,
            fps_denominator = nested_fps_den,
        },

        enabled = query:value(15) == 1,
        volume = clip_volume,
        created_at = query:value(16),
        modified_at = query:value(17),

        track_type = track_type,

    }

    -- T018 / 018 tripwire (defense-in-depth mirror of FR-013 subframe-by-kind): a clip's
    -- subframe presence must match its track_type. Schema triggers enforce
    -- this on writes; this load-side assert catches any raw-SQL bypass and
    -- dies loudly with the offending clip + track_type + subframe values
    -- (rule 1.14) rather than letting wrong audio math flow downstream.
    if track_type == "AUDIO" then
        assert(clip.source_in_subframe ~= nil
            and clip.source_out_subframe ~= nil,
            string.format(
            "load_clips (subframe-by-kind tripwire): AUDIO clip %s has NULL "
            .. "source_*_subframe (sub_in=%s, sub_out=%s)",
            tostring(clip_id),
            tostring(clip.source_in_subframe),
            tostring(clip.source_out_subframe)))
    elseif track_type == "VIDEO" then
        assert(clip.source_in_subframe == nil
            and clip.source_out_subframe == nil,
            string.format(
            "load_clips (subframe-by-kind tripwire): VIDEO clip %s has non-NULL "
            .. "source_*_subframe (sub_in=%s, sub_out=%s)",
            tostring(clip_id),
            tostring(clip.source_in_subframe),
            tostring(clip.source_out_subframe)))
    end
    -- V13-resolved chain leaf: nested→master→media_ref→media. Substructure
    -- so consumers see clearly that these are denormalized join results,
    -- not direct columns on `clips`. NULL when the nested sequence is itself
    -- nested (no terminal media_ref reachable in this single SELECT —
    -- deeper resolution is the resolver's job).
    if media_id then
        clip.resolved_media = {
            id = media_id,
            name = media_name,
            path = media_path,
            offline_note = offline_note,
        }
        -- Flat denormalised fields for the only two consumers that care:
        --   * timeline_core_state — keys clips by media_path on the
        --     media_status_changed signal to flip clip.offline live.
        --   * timeline_view_renderer — reads clip.offline to colour
        --     offline clips on the timeline.
        -- The structured leaf media is on clip.resolved_media for
        -- everything else. (clip.media_id and .media_name were also
        -- denormed here but had no V13 timeline-clip readers; dropped.)
        clip.media_path = media_path
        clip.offline = (offline_note ~= nil)
    else
        clip.offline = false
    end

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
        log.warn("%s: failed to commit: %s", tostring(context or "database"), tostring(err))
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

-- Helpers for set_path — declared above so the closures resolve to
-- the locals (Lua scoping). See rule 2.5 (algorithm-style).

-- Reads the outgoing project_id without letting a corrupt outgoing DB
-- block the switch. Per Joe's log-and-continue policy: errors are
-- logged loud (so operators see them) and the lookup falls through to
-- nil, which the pre-switch handler treats as cold-start. Returning
-- nil unconditionally on a corrupt DB is safer than failing to detach
-- (would leave the editor stuck on an unusable project).
local function lookup_outgoing_project_id()
    if not db_connection then return nil end
    local ok, id_or_err = pcall(M.get_current_project_id)
    if ok then return id_or_err end
    log.error("set_path: failed to read outgoing project_id (%s) — treating as cold-start.\n%s",
        tostring(id_or_err), debug.traceback("", 2))
    return nil
end

-- Emit project_will_change before the outgoing connection closes.
-- Lazy require on core.signals: signals → core.error_system → core.logger
-- → this module is the cycle the lazy load breaks. If the require fails
-- (rare; would mean signals.lua is broken), we still want the swap to
-- proceed — the bridge surfaces the require failure.
local function emit_pre_switch_signal(outgoing_id)
    local ok, Signals = pcall(require, "core.signals")
    if not ok or not Signals or not Signals.emit then
        log.error("set_path: failed to load core.signals (%s); skipping pre-switch emit",
            tostring(Signals))
        return
    end
    Signals.emit("project_will_change", outgoing_id)
end

local function close_outgoing_connection()
    if db_connection and db_connection.close then
        db_connection:close()
        db_connection = nil
    end
    tag_tables_supported = nil
end

-- Set database path and open connection.
--
-- Emits the project_will_change signal BEFORE closing the outgoing
-- connection so handlers see the outgoing project's DB as live (per
-- contracts/signal_will_change.md, feature 014). Cold start is the
-- nil → P transition: outgoing_id is nil; handlers must be
-- nil-tolerant. Per Signals dispatcher contract, individual handler
-- errors are caught and logged; the swap proceeds regardless.
function M.set_path(path)
    -- Algorithm: emit pre-switch → close outgoing → open incoming
    -- → apply schema. Pre-switch phase runs while db_connection still
    -- resolves to the outgoing project.
    emit_pre_switch_signal(lookup_outgoing_project_id())
    close_outgoing_connection()

    db_path = path
    log.event("Database path set to: %s", tostring(path))

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
        log.error("Failed to open database: %s%s", tostring(err or "unknown error"), extra)
        return false
    end

    db_connection = db

    -- Schema version gate: if DB already has a schema_version table, check it
    -- BEFORE applying schema (which would silently insert the new version).
    local sv_check = db:prepare("SELECT MAX(version) FROM schema_version")
    if sv_check then
        -- Table exists (existing project) — verify version
        if sv_check:exec() and sv_check:next() then
            local existing_version = sv_check:value(0)
            sv_check:finalize()
            if existing_version and existing_version ~= M.SCHEMA_VERSION then
                db_connection:close()
                db_connection = nil
                error(string.format(
                    "Project schema V%d is incompatible with this version of JVE (requires V%d).\n\n" ..
                    "Re-import from the original source (.drp) to create a compatible project.",
                    existing_version, M.SCHEMA_VERSION))
            end
        else
            sv_check:finalize()
        end
    end
    -- If sv_check is nil, table doesn't exist yet (new DB) — schema will create it.

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

    log.event("Database connection opened successfully")
    return db_connection
end

-- Get database path
function M.get_path()
    return db_path
end

--- Get the peak cache directory for the current project.
--- Returns <project>.jvp-cache/peaks/ and ensures the directory exists.
--- @return string absolute path to peaks cache directory
function M.get_peak_cache_dir()
    assert(db_path, "database.get_peak_cache_dir: no project open (db_path is nil)")
    local cache_dir = db_path .. "-cache/peaks"
    os.execute(string.format("mkdir -p %q", cache_dir))
    return cache_dir
end

-- SQL ISOLATION ENFORCEMENT - ACTIVE
-- Models (models/*.lua) = ONLY SQL layer
-- Commands (core/commands/*.lua) = call models
-- UI (ui/*.lua) = call models
-- Tests (tests/*.lua) = SQL allowed for setup/assertions

local ALLOWED_SQL_CALLERS = {
    ["models/"] = true,
    ["core/database.lua"] = true,
    ["command.lua"] = true,  -- Command model (loads itself from DB)
    -- command_manager.lua needs connection access ONLY to pass to sub-modules (registry, history, state)
    -- during init(). It does NOT execute raw SQL itself - all queries go through model methods.
    ["core/command_manager.lua"] = true,
}

local function validate_sql_access()
    local info = debug.getinfo(3, "S")
    assert(info, "validate_sql_access: failed to get caller info")

    local source = info.source:match("@?(.+)")
    assert(source, "validate_sql_access: failed to extract source path")

    -- Tests use direct SQL for setup/assertions (legacy direct-DB access;
    -- migration to model abstractions tracked in TODO.md).
    if source:match("test_[^/]+%.lua$") or source:match("tests/") then
        return
    end

    local relative_path = source:match("src/lua/(.+)$")
    if not relative_path then
        relative_path = source:match("([^/]+%.lua)$")
    end
    assert(relative_path, string.format(
        "validate_sql_access: caller outside src/lua: %s",
        source
    ))

    -- Check if caller is in allowed list
    for allowed_prefix, _ in pairs(ALLOWED_SQL_CALLERS) do
        if relative_path:match("^" .. allowed_prefix) then
            return  -- Access granted
        end
    end

    -- FAIL FAST with actionable error
    assert(false, string.format(
        "SQL ISOLATION VIOLATION: %s attempted to get database connection.\n" ..
        "Only models/ can execute SQL in production code.\n" ..
        "Fix: Add method to appropriate model (Track, Clip, Media, Sequence, etc.)",
        relative_path
    ))
end

-- Get database connection (for use by command_manager, models, etc.)
function M.set_connection(conn)
    db_connection = conn
end

-- Check if database connection exists (no SQL access granted, just a boolean check)
-- Use this instead of get_connection() when you only need to verify connectivity
function M.has_connection()
    return db_connection ~= nil
end

function M.get_connection()
    assert(db_connection, "database.get_connection: no active database connection")

    -- Enforce SQL isolation at connection access point
    validate_sql_access()

    return db_connection
end

-- Transaction management API
function M.begin_transaction()
    assert(db_connection, "database.begin_transaction: no connection")
    local stmt = db_connection:prepare("BEGIN TRANSACTION")
    if not stmt then return false end
    local ok = stmt:exec()
    stmt:finalize()
    return ok
end

function M.commit()
    assert(db_connection, "database.commit: no connection")
    return db_connection:exec("COMMIT")
end

function M.rollback()
    assert(db_connection, "database.rollback: no connection")
    return db_connection:exec("ROLLBACK")
end

function M.savepoint(name)
    assert(db_connection, "database.savepoint: no connection")
    assert(name and name ~= "", "database.savepoint: name required")
    return db_connection:exec("SAVEPOINT " .. name)
end

function M.release_savepoint(name)
    assert(db_connection, "database.release_savepoint: no connection")
    assert(name and name ~= "", "database.release_savepoint: name required")
    return db_connection:exec("RELEASE SAVEPOINT " .. name)
end

function M.rollback_to_savepoint(name)
    assert(db_connection, "database.rollback_to_savepoint: no connection")
    assert(name and name ~= "", "database.rollback_to_savepoint: name required")
    return db_connection:exec("ROLLBACK TO SAVEPOINT " .. name)
end

-- Schema migration: ensure commands table has all required columns
function M.ensure_commands_table_columns()
    assert(db_connection, "ensure_commands_table_columns: no database connection")

    local needed = {
        selected_clip_ids_pre = true,
        selected_edge_infos_pre = true,
        selected_gap_infos = true,
        selected_gap_infos_pre = true
    }

    local pragma = db_connection:prepare("PRAGMA table_info(commands)")
    assert(pragma, "ensure_commands_table_columns: failed to prepare PRAGMA table_info(commands)")

    if pragma:exec() then
        while pragma:next() do
            needed[pragma:value(1)] = nil
        end
    end
    pragma:finalize()

    for col, _ in pairs(needed) do
        local ok, err = db_connection:exec("ALTER TABLE commands ADD COLUMN " .. col .. " TEXT DEFAULT '[]'")
        assert(ok ~= false, string.format(
            "ensure_commands_table_columns: ALTER TABLE ADD COLUMN %s failed: %s", col, tostring(err)))
    end
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
                    log.warn("ensure_media_record: ImportMedia args missing project_id for media %s", tostring(media_id))
                elseif file_path and file_path ~= "" then
                    local MediaReader = require('media.media_reader')
                    local new_id, _, import_err = MediaReader.import_media(file_path, db_connection, project_id, media_id)
                    if new_id == media_id then
                        restored = true
                        break
                    else
                        if import_err then
                            log.warn("ensure_media_record: failed to reimport media: %s", tostring(import_err))
                        end
                    end
                end
            end
        end
    end

    cmd_stmt:finalize()
    return restored
end

-- Check whether the database contains any projects (non-erroring startup check)
function M.has_projects()
    assert(db_connection, "FATAL: No database connection - cannot check projects")
    local stmt = db_connection:prepare("SELECT count(*) FROM projects")
    assert(stmt, "FATAL: Failed to prepare project count query")
    assert(stmt:exec(), "FATAL: Failed to execute project count query")
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count > 0
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

    log.event("Loading tracks for sequence: %s", tostring(sequence_id))

    if not db_connection then
        error("FATAL: No database connection - cannot load tracks")
    end

    local query = db_connection:prepare([[
        SELECT id, name, track_type, track_index, enabled, muted, soloed, locked, sync_mode, autoselect
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
            local sync_mode = query:value(8)
            assert(sync_mode and sync_mode ~= "", string.format(
                "load_tracks: track %s has NULL sync_mode — project DB is older than 015",
                tostring(query:value(0))))
            table.insert(tracks, {
                id = query:value(0),
                name = query:value(1),
                track_type = query:value(2),  -- Keep as "VIDEO" or "AUDIO"
                track_index = query:value(3),
                enabled = query:value(4) == 1,
                muted = query:value(5) == 1,
                soloed = query:value(6) == 1,
                locked = query:value(7) == 1,
                sync_mode = sync_mode,
                autoselect = query:value(9) == 1,
            })
        end
    end

    log.event("Loaded %d tracks from database", #tracks)
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

    -- V13: a clip's nested master sequence may carry both V and A
    -- media_refs (one media file with both streams). The clip itself plays
    -- ONE medium — the one matching its owner-side track_type. JOIN
    -- media_refs through tracks so it picks the matching-medium media_ref
    -- only, otherwise the LEFT JOIN multiplies clips by media_ref count.
    local query = db_connection:prepare([[
        SELECT c.id, c.project_id, c.name, c.track_id,
               c.owner_sequence_id, c.sequence_id,
               c.sequence_start_frame, c.duration_frames,
               c.source_in_frame, c.source_out_frame,
               c.source_in_subframe, c.source_out_subframe,
               c.master_layer_track_id, c.master_audio_track_id,
               c.fps_mismatch_policy,
               c.enabled, c.created_at, c.modified_at,
               t.sequence_id, t.track_type,
               owner_seq.fps_numerator, owner_seq.fps_denominator,
               nested_seq.kind, nested_seq.fps_numerator, nested_seq.fps_denominator,
               mr.media_id, m.name, m.file_path, m.offline_note,
               c.volume
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN sequences owner_seq ON c.owner_sequence_id = owner_seq.id
        JOIN sequences nested_seq ON c.sequence_id = nested_seq.id
        LEFT JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
                                AND nested_seq.kind = 'master'
                                AND EXISTS (
                                    SELECT 1 FROM tracks mt
                                    WHERE mt.id = mr.track_id
                                      AND mt.track_type = t.track_type
                                )
        LEFT JOIN media m ON m.id = mr.media_id
        WHERE c.owner_sequence_id = ?
        GROUP BY c.id
        ORDER BY c.sequence_start_frame ASC
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

--- Load master sequence content as virtual clip-shaped rows.
-- Master sequences hold no `clips` rows — their playable content lives in
-- `media_refs` (each row is one continuous span of a media file pinned at
-- the file's TC origin on a master track). The timeline view renders
-- from the displayed TimelineTab's `cache.clips`, so to show a master in
-- the timeline view we synthesize one clip-shaped row per media_ref.
-- FR-007 is the consumer.
--
-- The synthesized rows are NOT persisted, NOT mutable through any clip
-- command path, and carry id="mref:<media_ref_id>" so they're trivially
-- distinguishable from real clips. Gap-recompute treats them as media
-- clips (is_gap = nil/false), so gaps fill any unused span on the track.
function M.load_master_virtual_clips(master_seq_id)
    assert(master_seq_id and master_seq_id ~= "",
        "load_master_virtual_clips: master_seq_id required")
    assert(db_connection, "load_master_virtual_clips: no db connection")

    -- 018 (V11): audio_sample_rate is now per-media_ref (denormalized from
    -- media at insert), not per-sequence. Masters have NULL
    -- sequences.audio_sample_rate per FR-004. Every AUDIO media_ref carries
    -- mr.audio_sample_rate at insert; VIDEO rows leave it NULL.
    local query = db_connection:prepare([[
        SELECT mr.id, mr.project_id, mr.track_id,
               mr.sequence_start_frame, mr.duration_frames,
               mr.source_in_frame, mr.source_out_frame,
               mr.enabled,
               t.track_type, t.name AS track_name,
               s.fps_numerator, s.fps_denominator,
               m.id, m.name, m.file_path, m.offline_note
        FROM media_refs mr
        JOIN tracks t ON t.id = mr.track_id
        JOIN sequences s ON s.id = mr.owner_sequence_id
        LEFT JOIN media m ON m.id = mr.media_id
        WHERE mr.owner_sequence_id = ?
        ORDER BY mr.sequence_start_frame ASC
    ]])
    assert(query, "load_master_virtual_clips: failed to prepare query")
    query:bind_value(1, master_seq_id)

    local clips = {}
    if query:exec() then
        while query:next() do
            local mref_id    = query:value(0)
            local proj_id    = query:value(1)
            local track_id   = query:value(2)
            local seq_start   = query:value(3)
            local duration   = query:value(4)
            local src_in     = query:value(5)
            local src_out    = query:value(6)
            local enabled    = query:value(7) == 1
            local track_type = query:value(8)
            local fps_num    = query:value(10)
            local fps_den    = query:value(11)
            local media_id   = query:value(12)
            local media_name = query:value(13)
            local media_path = query:value(14)
            local offline_note = query:value(15)

            assert(seq_start, "load_master_virtual_clips: media_ref missing sequence_start_frame")
            assert(duration, "load_master_virtual_clips: media_ref missing duration_frames")
            assert(src_in and src_out, "load_master_virtual_clips: media_ref missing source range")

            -- Post placement-unit unification (2026-05-16): every media_ref's
            -- sequence_start_frame and duration_frames live in master.fps
            -- frames regardless of track_type. For dual-medium masters that's
            -- video fps; for audio-only masters master.fps == sample_rate so
            -- "frames at master.fps" === samples. No per-track-type conversion
            -- needed here — the old samples→frames divide produced ~2000×
            -- under-sized audio virtual clips that vanished off-screen
            -- (TSO 2026-05-16: src tab on V+A master showed empty A1/A2).

            local clip = {
                id = "mref:" .. mref_id,
                project_id = proj_id,
                name = media_name or "",
                track_id = track_id,
                owner_sequence_id = master_seq_id,
                track_sequence_id = master_seq_id,
                sequence_id = master_seq_id,
                source_sequence_kind = "master",
                sequence_start = seq_start,
                duration = duration,
                source_in = src_in,    -- source-media units (samples for audio, frames for video)
                source_out = src_out,
                frame_rate = { fps_numerator = fps_num, fps_denominator = fps_den },
                enabled = enabled,
                track_type = track_type,
                is_master_virtual = true,  -- mark for any consumer that needs to special-case
            }
            if media_id then
                clip.resolved_media = {
                    id = media_id,
                    name = media_name,
                    path = media_path,
                    offline_note = offline_note,
                }
                clip.media_path = media_path
                clip.offline = (offline_note ~= nil)
            else
                clip.offline = false
            end
            clip.label = media_name and media_name ~= "" and media_name
                or (media_path and extract_filename(media_path))
                or ("Media " .. tostring(mref_id):sub(1, 8))

            table.insert(clips, clip)
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
        SELECT c.id, c.project_id, c.name, c.track_id,
               c.owner_sequence_id, c.sequence_id,
               c.sequence_start_frame, c.duration_frames,
               c.source_in_frame, c.source_out_frame,
               c.source_in_subframe, c.source_out_subframe,
               c.master_layer_track_id, c.master_audio_track_id,
               c.fps_mismatch_policy,
               c.enabled, c.created_at, c.modified_at,
               t.sequence_id, t.track_type,
               owner_seq.fps_numerator, owner_seq.fps_denominator,
               nested_seq.kind, nested_seq.fps_numerator, nested_seq.fps_denominator,
               mr.media_id, m.name, m.file_path, m.offline_note,
               c.volume
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN sequences owner_seq ON c.owner_sequence_id = owner_seq.id
        JOIN sequences nested_seq ON c.sequence_id = nested_seq.id
        LEFT JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
                                AND nested_seq.kind = 'master'
        LEFT JOIN media m ON m.id = mr.media_id
        WHERE c.id = ?
        LIMIT 1
    ]])

    if not query then
        error("FATAL: Failed to prepare clip entry query")
    end

    query:bind_value(1, clip_id)

    local clip = nil
    if query:exec() and query:next() then
        clip = build_clip_from_query_row(query, query:value(18))  -- 018: t.sequence_id shifted from 16 → 18 after subframe cols at 10,11
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
    assert(query, string.format(
        "load_clip_properties: failed to prepare query for clip %s", tostring(clip_id)))

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
-- REMOVED: update_clip_position() — dead code, referenced non-existent columns (start_value, duration_value)
-- REMOVED: update_clip_property() — stub that returned false success
-- Use command system instead: Command.create("SetClipProperty", ...)

-- REMOVED: delete_clip() - Stub that returned false success
-- Use command system instead: Command.create("DeleteClip", ...)

-- Load all media for the current project. The schema permits multiple
-- projects in one .jvp file (today rare, but DRP imports and migrations
-- can introduce rows with a non-active project_id); scoping the query
-- to the active project prevents cross-project leakage into the browser
-- and media-status views.
function M.load_media()
    if not db_connection then
        error("FATAL: No database connection - cannot load media")
    end

    local active_project_id = M.get_current_project_id()
    assert(active_project_id and active_project_id ~= "",
        "load_media: get_current_project_id returned nil/empty")

    local query = db_connection:prepare([[
        SELECT id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
               width, height, audio_channels, codec, created_at, modified_at, metadata,
               offline_note
        FROM media
        WHERE project_id = ?
        ORDER BY created_at DESC
    ]])

    if not query then
        error("FATAL: Failed to prepare media query")
    end
    query:bind_value(1, active_project_id)

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
                duration = query:value(4),  -- integer frames
                frame_rate = { fps_numerator = num, fps_denominator = den },
                width = query:value(7),
                height = query:value(8),
                audio_channels = query:value(9),
                codec = query:value(10),
                created_at = query:value(11),
                modified_at = query:value(12),
                metadata = query:value(13),
                offline_note = query:value(14),
                tags = {}
            })
        end
    end

    log.event("Loaded %d media items from database", #media_items)
    return media_items
end

-- Build the browser entry for one master-sequence row joined with its
-- media_ref/media. Under V13 a "master clip" IS the sequence (kind='master'),
-- so clip_id == sequence_id; media_id comes from the (possibly absent)
-- media_ref join. Used only by load_master_clips.
local function build_master_clip_entry(q)
    -- LEFT JOIN: if no media row, is_still stays nil (not false) so the
    -- browser classifier can distinguish "no media" from "has media, not still".
    local media_is_still
    local media_is_still_raw = q:value(24)
    if media_is_still_raw ~= nil then
        media_is_still = tonumber(media_is_still_raw) == 1
    end

    local seq_id            = q:value(0)
    local seq_project_id    = q:value(2)
    local seq_fps_num       = q:value(3)
    local seq_fps_den       = q:value(4)
    local seq_width         = q:value(5)
    local seq_height        = q:value(6)
    local media_id          = q:value(10)
    local media_path        = q:value(13)
    local media_duration    = q:value(14)
    local media_width       = q:value(17)
    local media_height      = q:value(18)
    local media_channels    = q:value(19)
    local media_codec       = q:value(20)

    local media_info = {
        id             = media_id,
        project_id     = q:value(11),
        name           = q:value(12),
        file_name      = q:value(12),
        file_path      = media_path,
        duration       = media_duration,
        frame_rate     = { fps_numerator = q:value(15), fps_denominator = q:value(16) },
        width          = media_width,
        height         = media_height,
        audio_channels = media_channels,
        codec          = media_codec,
        metadata       = q:value(21),
        created_at     = q:value(22),
        modified_at    = q:value(23),
        is_still       = media_is_still,
    }

    -- The masterclip sequence IS the masterclip (IS-a relationship).
    local sequence_info = {
        id                = seq_id,
        project_id        = seq_project_id,
        frame_rate        = { fps_numerator = seq_fps_num, fps_denominator = seq_fps_den },
        width             = seq_width,
        height            = seq_height,
        audio_sample_rate = q:value(7),
    }

    return {
        clip_id        = seq_id,
        sequence_id    = seq_id,
        project_id     = seq_project_id,
        name           = q:value(1),
        media_id       = media_id,

        -- Listing-level defaults (browsers display the whole master).
        sequence_start = 0,
        duration       = media_duration or 0,
        source_in      = 0,
        source_out     = media_duration or 0,

        frame_rate     = { fps_numerator = seq_fps_num, fps_denominator = seq_fps_den },
        enabled        = true,
        created_at     = q:value(8),
        modified_at    = q:value(9),
        media          = media_info,
        sequence       = sequence_info,

        -- Convenience fields for consumers.
        file_path      = media_path,
        width          = media_width or seq_width,
        height         = media_height or seq_height,
        codec          = media_codec,
        is_still       = media_is_still,
        audio_channels = media_channels,
    }
end

function M.load_master_clips(project_id)
    -- V13: master sequences hold media_refs (not clips). Each master sequence
    -- represents one media file; the media_ref join carries media_id, with
    -- media joined for metadata.
    if not project_id or project_id == "" then
        error("FATAL: load_master_clips requires project_id", 2)
    end
    if not db_connection then
        error("FATAL: No database connection - cannot load master clips")
    end

    local query = db_connection:prepare([[
        SELECT DISTINCT
            s.id, s.name, s.project_id,
            s.fps_numerator, s.fps_denominator,
            s.width, s.height,
            s.audio_sample_rate,
            s.created_at, s.modified_at,
            mr.media_id,
            m.project_id, m.name, m.file_path,
            m.duration_frames,
            m.fps_numerator, m.fps_denominator,
            m.width, m.height,
            m.audio_channels, m.codec, m.metadata,
            m.created_at, m.modified_at,
            m.is_still
        FROM sequences s
        LEFT JOIN media_refs mr ON mr.owner_sequence_id = s.id
        LEFT JOIN media m ON m.id = mr.media_id
        WHERE s.kind = 'master'
          AND s.project_id = ?
        GROUP BY s.id
        ORDER BY s.name
    ]])
    if not query then
        error("FATAL: Failed to prepare master clip query")
    end
    query:bind_value(1, project_id)

    local clips = {}
    if query:exec() then
        while query:next() do
            clips[#clips + 1] = build_master_clip_entry(query)
        end
    end
    query:finalize()

    log.event("Loaded %d master clips from database", #clips)
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
        SELECT id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height,
               playhead_frame, view_start_frame, view_duration_frames
        FROM sequences
        WHERE project_id = ? AND kind = 'sequence'
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
                audio_sample_rate = query:value(5), -- Maps to audio_sample_rate
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
        local max_end = 0  -- integer frames
        for _, clip in ipairs(clips) do
            if clip.sequence_start and clip.duration then
                local clip_end = clip.sequence_start + clip.duration
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
               selected_clip_ids, selected_edge_infos, audio_sample_rate
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

        -- width/height are NULL on audio-only masters (schema permits it
        -- for kind='master' specifically). For every other sequence both
        -- must be positive integers.
        if (sequence.width == nil) ~= (sequence.height == nil) then
            query:finalize()
            error(string.format("FATAL: sequence %s has only one of width/height set",
                tostring(sequence_id)))
        end
        if sequence.width == nil and sequence.kind ~= "master" then
            query:finalize()
            error(string.format(
                "FATAL: sequence %s has kind='%s' but NULL width/height "
                .. "(NULL is permitted only on masters)",
                tostring(sequence_id), tostring(sequence.kind)))
        end

        if not sequence.playhead_value or not sequence.viewport_start_value or not sequence.viewport_duration_frames_value then
            query:finalize()
            error(string.format("FATAL: sequence %s missing view/playhead fields", tostring(sequence_id)))
        end

        -- audio_sample_rate is NULL on video-only masters (schema permits
        -- this for kind='master' specifically). For every other sequence
        -- a positive rate is required.
        if sequence.audio_sample_rate ~= nil and sequence.audio_sample_rate <= 0 then
            query:finalize()
            error(string.format(
                "FATAL: sequence %s has invalid audio_sample_rate (must be NULL or > 0)",
                tostring(sequence_id)))
        end
        if sequence.audio_sample_rate == nil and sequence.kind ~= "master" then
            query:finalize()
            error(string.format(
                "FATAL: sequence %s has kind='%s' but NULL audio_sample_rate "
                .. "(NULL is permitted only on masters)",
                tostring(sequence_id), tostring(sequence.kind)))
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
            local decoded, decode_err = json.decode(raw)
            if not decoded then
                stmt:finalize()
                error("FATAL: load_sequence_track_heights: invalid JSON in database: " .. tostring(decode_err))
            end
            if type(decoded) ~= "table" or decoded[1] ~= nil then
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

local function assert_project_exists(project_id)
    assert(project_id and project_id ~= "", "assert_project_exists: project_id is required")
    assert(db_connection, "assert_project_exists: no database connection")

    -- Verify the project_id refers to a real row. The pre-013 variant
    -- additionally asserted SOLE project (catching stale-id-after-switch
    -- bugs), but that conflated "id is valid" with "DB is single-project";
    -- multiple projects coexist legitimately in import paths and tests.
    -- Existence is the load-bearing check; ambiguity over "current" is
    -- callers' responsibility (they were already passing project_id in).
    local stmt = db_connection:prepare("SELECT 1 FROM projects WHERE id = ?")
    assert(stmt, "assert_project_exists: prepare failed")
    stmt:bind_value(1, project_id)
    assert(stmt:exec(), "assert_project_exists: exec failed")
    local found = stmt:next()
    stmt:finalize()
    assert(found, string.format(
        "assert_project_exists: project_id '%s' not found in '%s'",
        tostring(project_id), tostring(db_path)))
end

-- ====================================================================
-- Layer 2 — assert_project_id_is_live: log+no-op for module-local
-- caches that may have gone stale during a project switch.
-- See specs/014-two-phase-project/contracts/persist_now_validation.md.
--
-- Layer 1 (assert_project_exists, above) hard-asserts on caller bugs:
-- someone passed a wrong id through a public API. Layer 2 logs and
-- returns false — the caller no-ops its write. Layer 2 catches the
-- TIMING bug where a deferred-work callback (single-shot timer body,
-- background worker callback) reads its module-local cached
-- current_project_id after the project has switched. That race is
-- an EXPECTED mode of the contract; hard-asserting would re-create
-- the silent-swallow bug feature 014 exists to fix.
-- ====================================================================

local function stale_check_possible(cached_id)
    return cached_id and cached_id ~= "" and db_connection ~= nil
end

local function log_stale_project_violation(caller_label, cached_id, live_id)
    log.error(
        "%s: stale project_id (cached=%s, live=%s) — no-op-ing write\n%s",
        tostring(caller_label),
        tostring(cached_id),
        tostring(live_id),
        debug.traceback("", 2))
end

--- Returns true when the cached project_id matches the live DB; false
--- otherwise. On mismatch logs at error level (the broken-invariant
--- tier per CLAUDE.md logger usage) and returns false. The caller
--- MUST no-op its write.
---
--- @param cached_id string|nil  module's cached project_id
--- @param caller_label string   e.g. "media_status.persist_now"
--- @return boolean is_live
function M.assert_project_id_is_live(cached_id, caller_label)
    if not stale_check_possible(cached_id) then return false end
    local live_id = M.get_current_project_id()
    if live_id == cached_id then return true end
    log_stale_project_violation(caller_label, cached_id, live_id)
    return false
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

    assert_project_exists(project_id)
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
    local lookup = {}
    local all_entries = {}
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
                table.insert(all_entries, entry)
            end
        end
    end

    -- Sort alphabetically first (for consistent sort_index within same level)
    table.sort(all_entries, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    -- Topological sort: parents must come before children for FK constraints
    local ordered = {}
    local inserted = {}
    local function insert_with_parents(entry)
        if inserted[entry.id] then return end
        -- Insert parent first if it exists
        if entry.parent_id and lookup[entry.parent_id] and not inserted[entry.parent_id] then
            insert_with_parents(lookup[entry.parent_id])
        end
        table.insert(ordered, entry)
        inserted[entry.id] = true
    end
    for _, entry in ipairs(all_entries) do
        insert_with_parents(entry)
    end

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
    assert(stmt, string.format(
        "load_bins: failed to prepare query for project %s", tostring(project_id)))
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

-- Capture every existing tag_assignment for (project_id, namespace_id) so
-- we can restore them after the bin purge cascades through. Returns the
-- list of assignments (possibly empty); never errors — failure here just
-- means we restore nothing.
local function snapshot_existing_assignments(project_id, namespace_id)
    local saved = {}
    local stmt = db_connection:prepare([[
        SELECT tag_id, entity_type, entity_id FROM tag_assignments
        WHERE project_id = ? AND namespace_id = ?
    ]])
    if not stmt then return saved end
    stmt:bind_value(1, project_id)
    stmt:bind_value(2, namespace_id)
    if stmt:exec() then
        while stmt:next() do
            saved[#saved + 1] = {
                tag_id      = stmt:value(0),
                entity_type = stmt:value(1),
                entity_id   = stmt:value(2),
            }
        end
    end
    stmt:finalize()
    return saved
end

-- DELETE every tag in the given namespace. tag_assignments cascades.
local function purge_namespace_tags(project_id, namespace_id)
    local stmt = db_connection:prepare([[
        DELETE FROM tags WHERE project_id = ? AND namespace_id = ?
    ]])
    if not stmt then return end
    stmt:bind_value(1, project_id)
    stmt:bind_value(2, namespace_id)
    stmt:exec()
    stmt:finalize()
end

-- INSERT each bin in the ordered list as a tag row. Returns (inserted_set, err)
-- — caller rolls back the surrounding transaction on err.
local function upsert_bin_rows(project_id, namespace_id, ordered, lookup, path_cache)
    local stmt = db_connection:prepare([[
        INSERT INTO tags (id, project_id, namespace_id, name, path, parent_id, sort_index)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then
        return nil, "save_bins: failed to prepare upsert statement"
    end
    local inserted = {}
    for _, bin in ipairs(ordered) do
        if stmt.reset then stmt:reset() end
        stmt:clear_bindings()
        stmt:bind_value(1, bin.id)
        stmt:bind_value(2, project_id)
        stmt:bind_value(3, namespace_id)
        stmt:bind_value(4, bin.name)
        stmt:bind_value(5, path_cache[bin.id])
        if bin.parent_id and lookup[bin.parent_id] then
            stmt:bind_value(6, bin.parent_id)
        elseif stmt.bind_null then
            stmt:bind_null(6)
        else
            stmt:bind_value(6, nil)
        end
        stmt:bind_value(7, bin.sort_index or 0)
        if stmt:exec() == false then
            local reason = string.format(
                "save_bins: failed to upsert bin %s (project_id=%s, ns=%s, error=%s, rc=%s)",
                tostring(bin.id), tostring(project_id), tostring(namespace_id),
                tostring(stmt:last_error() or "unknown error"),
                tostring(stmt:last_result_code() or "?"))
            stmt:finalize()
            return nil, reason
        end
        inserted[bin.id] = true
    end
    stmt:finalize()
    return inserted, nil
end

-- Find tag rows in this namespace that the upsert pass DIDN'T re-insert
-- (i.e., the caller dropped the bin). Returns the list of stale ids.
local function collect_stale_bin_ids(project_id, namespace_id, inserted)
    local stmt = db_connection:prepare([[
        SELECT id FROM tags WHERE project_id = ? AND namespace_id = ?
    ]])
    if not stmt then return nil, "save_bins: failed to prepare select statement" end
    stmt:bind_value(1, project_id)
    stmt:bind_value(2, namespace_id)
    local stale_ids = {}
    if stmt:exec() then
        while stmt:next() do
            local id = stmt:value(0)
            if id and not inserted[id] then
                stale_ids[#stale_ids + 1] = id
            end
        end
    end
    stmt:finalize()
    return stale_ids
end

-- DELETE the stale bin tags. Returns (true, nil) on success, (false, reason)
-- on the first failed delete.
local function delete_stale_bin_ids(project_id, namespace_id, stale_ids)
    if #stale_ids == 0 then return true end
    local stmt = db_connection:prepare([[
        DELETE FROM tags WHERE project_id = ? AND namespace_id = ? AND id = ?
    ]])
    if not stmt then return false, "save_bins: failed to prepare stale delete statement" end
    for _, stale_id in ipairs(stale_ids) do
        stmt:bind_value(1, project_id)
        stmt:bind_value(2, namespace_id)
        stmt:bind_value(3, stale_id)
        local ok = stmt:exec()
        stmt:clear_bindings()
        if ok == false then
            local reason = string.format(
                "save_bins: failed to delete stale bin %s (%s, rc=%s)",
                tostring(stale_id),
                tostring(stmt:last_error() or "unknown error"),
                tostring(stmt:last_result_code() or "?"))
            stmt:finalize()
            return false, reason
        end
    end
    stmt:finalize()
    return true
end

-- Re-INSERT the saved tag_assignments, but only for bins that survived
-- the purge/upsert (orphan assignments to deleted bins are dropped).
local function restore_bin_assignments(project_id, namespace_id, saved_assignments, inserted)
    if #saved_assignments == 0 then return end
    local stmt = db_connection:prepare([[
        INSERT OR IGNORE INTO tag_assignments
            (tag_id, project_id, namespace_id, entity_type, entity_id)
        VALUES (?, ?, ?, ?, ?)
    ]])
    if not stmt then
        log.warn("save_bins: failed to prepare restore statement")
        return
    end
    for _, a in ipairs(saved_assignments) do
        if inserted[a.tag_id] then
            if stmt.reset then stmt:reset() end
            stmt:bind_value(1, a.tag_id)
            stmt:bind_value(2, project_id)
            stmt:bind_value(3, namespace_id)
            stmt:bind_value(4, a.entity_type)
            stmt:bind_value(5, a.entity_id)
            stmt:exec()
            stmt:clear_bindings()
        end
    end
    stmt:finalize()
end

function M.save_bins(project_id, bins, opts)
    if not project_id or project_id == "" then
        local reason = "save_bins: Missing project_id"
        log.warn("%s", reason)
        return false, reason
    end
    if not db_connection then
        local reason = "save_bins: No database connection"
        log.warn("%s", reason)
        return false, reason
    end
    assert_project_exists(project_id)  -- Layer 1 (FR-005)

    require_tag_tables()

    local namespace_id, display_name = resolve_namespace(opts)
    ensure_tag_namespace(namespace_id, display_name)

    local ordered, lookup = build_bin_lookup(bins)
    local path_cache = {}
    for _, bin in ipairs(ordered) do
        local path = resolve_bin_path(bin.id, lookup, path_cache, {})
        if not path or path == "" then
            local reason = string.format("save_bins: invalid hierarchy for bin %s", tostring(bin.id))
            log.warn("%s", reason)
            return false, reason
        end
    end

    local started, begin_err = begin_write_transaction()
    if started == nil then
        local reason = "save_bins: failed to begin transaction: " .. tostring(begin_err)
        log.warn("%s", reason)
        return false, reason
    end

    -- Capture assignments before the cascade-delete wipes them.
    local saved_assignments = snapshot_existing_assignments(project_id, namespace_id)
    purge_namespace_tags(project_id, namespace_id)

    local inserted, upsert_err = upsert_bin_rows(
        project_id, namespace_id, ordered, lookup, path_cache)
    if not inserted then
        rollback_transaction(started)
        return false, upsert_err
    end

    -- Note: stale collection still uses BIN_NAMESPACE specifically, which
    -- mirrors the original behavior (a non-bin namespace still cleans only
    -- bin tags). resolve_namespace returns BIN_NAMESPACE by default.
    local stale_ids, stale_select_err = collect_stale_bin_ids(
        project_id, BIN_NAMESPACE, inserted)
    if not stale_ids then
        rollback_transaction(started)
        return false, stale_select_err
    end

    local del_ok, del_err = delete_stale_bin_ids(project_id, namespace_id, stale_ids)
    if not del_ok then
        rollback_transaction(started)
        return false, del_err
    end

    restore_bin_assignments(project_id, namespace_id, saved_assignments, inserted)

    if not commit_transaction(started, "save_bins") then
        return false, "save_bins: commit failed"
    end
    return true
end

--- Load bin assignments for a given entity type (many-to-many).
-- @param project_id string
-- @param entity_type string: e.g. "master_clip", "sequence"
-- @return table: {entity_id → {tag_id, ...}}
function M.load_bin_map(project_id, entity_type)
    assert(project_id and project_id ~= "",
        "database.load_bin_map: missing project_id")
    assert(entity_type and entity_type ~= "",
        "database.load_bin_map: missing entity_type")
    local assignments = {}
    if not db_connection then
        return assignments
    end

    require_tag_tables()

    local stmt = db_connection:prepare([[
        SELECT entity_id, tag_id
        FROM tag_assignments
        WHERE project_id = ? AND namespace_id = ? AND entity_type = ?
    ]])
    if not stmt then
        return assignments
    end
    stmt:bind_value(1, project_id)
    stmt:bind_value(2, BIN_NAMESPACE)
    stmt:bind_value(3, entity_type)

    if stmt:exec() then
        while stmt:next() do
            local entity_id = stmt:value(0)
            local tag_id = stmt:value(1)
            if entity_id and tag_id then
                assignments[entity_id] = assignments[entity_id] or {}
                table.insert(assignments[entity_id], tag_id)
            end
        end
    end
    stmt:finalize()
    return assignments
end

function M.load_master_clip_bin_map(project_id)
    return M.load_bin_map(project_id, "master_clip")
end

function M.save_master_clip_bin_map(project_id, bin_map)
    if not project_id or project_id == "" then
        return false
    end
    if not db_connection then
        return false
    end
    assert_project_exists(project_id)  -- Layer 1 (FR-005)

    require_tag_tables()

    ensure_tag_namespace(BIN_NAMESPACE, "Bins")

    local started, begin_err = begin_write_transaction()
    if started == nil then
        log.warn("save_master_clip_bin_map: failed to begin transaction: %s", tostring(begin_err))
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
                log.warn("save_master_clip_bin_map: bin %s does not exist", tostring(bin_id))
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

--- Add entities to a bin (INSERT OR IGNORE — idempotent, many-to-many safe).
-- Use for import paths where an entity may already be in the bin.
-- @param project_id string
-- @param entity_ids table: array of entity IDs
-- @param bin_id string: target bin ID
-- @param entity_type string: e.g. "master_clip"
function M.add_to_bin(project_id, entity_ids, bin_id, entity_type)
    assert(project_id and project_id ~= "", "database.add_to_bin: missing project_id")
    assert(bin_id and bin_id ~= "", "database.add_to_bin: missing bin_id")
    assert(entity_type and entity_type ~= "", "database.add_to_bin: missing entity_type")
    assert(db_connection, "database.add_to_bin: no database connection")
    assert_project_exists(project_id)  -- Layer 1 (FR-005)
    if type(entity_ids) ~= "table" or #entity_ids == 0 then
        return true
    end

    require_tag_tables()
    ensure_tag_namespace(BIN_NAMESPACE, "Bins")

    assert(validate_bin_id(project_id, bin_id),
        string.format("database.add_to_bin: bin %s not found in project %s", bin_id, project_id))

    local started, begin_err = begin_write_transaction()
    assert(started ~= nil, "database.add_to_bin: failed to begin transaction: " .. tostring(begin_err))

    for _, eid in ipairs(entity_ids) do
        if type(eid) == "string" and eid ~= "" then
            local stmt = db_connection:prepare([[
                INSERT OR IGNORE INTO tag_assignments(tag_id, project_id, namespace_id, entity_type, entity_id)
                VALUES (?, ?, ?, ?, ?)
            ]])
            assert(stmt, "database.add_to_bin: failed to prepare insert statement")
            stmt:bind_value(1, bin_id)
            stmt:bind_value(2, project_id)
            stmt:bind_value(3, BIN_NAMESPACE)
            stmt:bind_value(4, entity_type)
            stmt:bind_value(5, eid)
            local success = stmt:exec()
            local detail = stmt:last_error()
            local rc = stmt:last_result_code()
            stmt:finalize()
            if success == false then
                rollback_transaction(started)
                error(string.format("database.add_to_bin: insert failed for %s %s (%s, rc=%s)",
                    entity_type, eid, tostring(detail), tostring(rc)))
            end
        end
    end

    assert(commit_transaction(started, "add_to_bin"), "database.add_to_bin: commit failed")
    return true
end

--- Remove entities from a specific bin (DELETE targeted assignment only).
-- Preserves assignments to OTHER bins (many-to-many safe).
-- @param project_id string
-- @param entity_ids table: array of entity IDs
-- @param bin_id string: bin to remove from
-- @param entity_type string: e.g. "master_clip"
function M.remove_from_bin(project_id, entity_ids, bin_id, entity_type)
    assert(project_id and project_id ~= "", "database.remove_from_bin: missing project_id")
    assert(bin_id and bin_id ~= "", "database.remove_from_bin: missing bin_id")
    assert(entity_type and entity_type ~= "", "database.remove_from_bin: missing entity_type")
    assert(db_connection, "database.remove_from_bin: no database connection")
    assert_project_exists(project_id)  -- Layer 1 (FR-005)
    if type(entity_ids) ~= "table" or #entity_ids == 0 then
        return true
    end

    require_tag_tables()

    local started, begin_err = begin_write_transaction()
    assert(started ~= nil, "database.remove_from_bin: failed to begin transaction: " .. tostring(begin_err))

    for _, eid in ipairs(entity_ids) do
        if type(eid) == "string" and eid ~= "" then
            local stmt = db_connection:prepare([[
                DELETE FROM tag_assignments
                WHERE project_id = ? AND namespace_id = ? AND entity_type = ? AND entity_id = ? AND tag_id = ?
            ]])
            assert(stmt, "database.remove_from_bin: failed to prepare delete statement")
            stmt:bind_value(1, project_id)
            stmt:bind_value(2, BIN_NAMESPACE)
            stmt:bind_value(3, entity_type)
            stmt:bind_value(4, eid)
            stmt:bind_value(5, bin_id)
            local success = stmt:exec()
            local detail = stmt:last_error()
            local rc = stmt:last_result_code()
            stmt:finalize()
            if success == false then
                rollback_transaction(started)
                error(string.format("database.remove_from_bin: delete failed for %s %s from bin %s (%s, rc=%s)",
                    entity_type, eid, bin_id, tostring(detail), tostring(rc)))
            end
        end
    end

    assert(commit_transaction(started, "remove_from_bin"), "database.remove_from_bin: commit failed")
    return true
end

--- Move entities to a bin (DELETE old assignments + INSERT new).
-- Use for user-facing MoveToBin where entity should leave its old bin.
-- @param project_id string
-- @param entity_ids table: array of entity IDs
-- @param bin_id string|nil: target bin ID (nil = unassign)
-- @param entity_type string: e.g. "master_clip"
function M.set_bin(project_id, entity_ids, bin_id, entity_type)
    assert(project_id and project_id ~= "", "database.set_bin: missing project_id")
    assert(entity_type and entity_type ~= "", "database.set_bin: missing entity_type")
    assert(db_connection, "database.set_bin: no database connection")
    assert_project_exists(project_id)  -- Layer 1 (FR-005)
    if type(entity_ids) ~= "table" or #entity_ids == 0 then
        return true
    end

    require_tag_tables()
    ensure_tag_namespace(BIN_NAMESPACE, "Bins")

    if bin_id and (type(bin_id) ~= "string" or bin_id == "" or not validate_bin_id(project_id, bin_id)) then
        error(string.format("database.set_bin: invalid bin %s", tostring(bin_id)))
    end

    local started, begin_err = begin_write_transaction()
    assert(started ~= nil, "database.set_bin: failed to begin transaction: " .. tostring(begin_err))

    for _, eid in ipairs(entity_ids) do
        if type(eid) == "string" and eid ~= "" then
            -- Delete ALL existing assignments for this entity
            local delete_stmt = db_connection:prepare([[
                DELETE FROM tag_assignments
                WHERE project_id = ? AND namespace_id = ? AND entity_type = ? AND entity_id = ?
            ]])
            assert(delete_stmt, "database.set_bin: failed to prepare delete statement")
            delete_stmt:bind_value(1, project_id)
            delete_stmt:bind_value(2, BIN_NAMESPACE)
            delete_stmt:bind_value(3, entity_type)
            delete_stmt:bind_value(4, eid)
            local success = delete_stmt:exec()
            local delete_detail = delete_stmt:last_error()
            local delete_rc = delete_stmt:last_result_code()
            delete_stmt:finalize()
            if success == false then
                rollback_transaction(started)
                error(string.format("database.set_bin: delete failed for %s %s (%s, rc=%s)",
                    entity_type, eid, tostring(delete_detail), tostring(delete_rc)))
            end

            -- Insert new assignment (if bin_id provided)
            if bin_id then
                local insert_stmt = db_connection:prepare([[
                    INSERT INTO tag_assignments(tag_id, project_id, namespace_id, entity_type, entity_id)
                    VALUES (?, ?, ?, ?, ?)
                ]])
                assert(insert_stmt, "database.set_bin: failed to prepare insert statement")
                insert_stmt:bind_value(1, bin_id)
                insert_stmt:bind_value(2, project_id)
                insert_stmt:bind_value(3, BIN_NAMESPACE)
                insert_stmt:bind_value(4, entity_type)
                insert_stmt:bind_value(5, eid)
                success = insert_stmt:exec()
                local insert_detail = insert_stmt:last_error()
                local insert_rc = insert_stmt:last_result_code()
                insert_stmt:finalize()
                if success == false then
                    rollback_transaction(started)
                    error(string.format("database.set_bin: insert failed for %s %s (%s, rc=%s)",
                        entity_type, eid, tostring(insert_detail), tostring(insert_rc)))
                end
            end
        end
    end

    assert(commit_transaction(started, "set_bin"), "database.set_bin: commit failed")
    return true
end

-- Legacy aliases: delegate to generic functions.
-- These preserve the old (false, reason) error contract for existing callers.
function M.assign_master_clips_to_bin(project_id, clip_ids, bin_id)
    if not project_id or project_id == "" then
        return false, "Missing project_id"
    end
    assert_project_exists(project_id)  -- Layer 1 (FR-005); validates BEFORE empty-clip-ids short-circuit
    if type(clip_ids) ~= "table" or #clip_ids == 0 then
        return true
    end
    if bin_id and (type(bin_id) ~= "string" or bin_id == "") then
        return false, string.format("assign_master_clips_to_bin: invalid bin %s", tostring(bin_id))
    end
    local ok, err = pcall(M.set_bin, project_id, clip_ids, bin_id, "master_clip")
    if not ok then
        return false, tostring(err)
    end
    return true
end

function M.assign_master_clip_to_bin(project_id, clip_id, bin_id)
    if not project_id or project_id == "" then
        return false
    end
    assert_project_exists(project_id)  -- Layer 1 (FR-005); validates BEFORE clip_id short-circuit
    if not clip_id or clip_id == "" then
        return false
    end
    return M.assign_master_clips_to_bin(project_id, {clip_id}, bin_id)
end

-- REMOVED: import_media() - Stub function that returned dummy data
-- Use media_reader.lua and ImportMedia command instead

--------------------------------------------------------------------------------
-- Per-Clip Marks & Playhead
--------------------------------------------------------------------------------

--- Load mark_in, mark_out, playhead for a clip.
-- @param clip_id string: clip row ID
-- @return table {mark_in_frame, mark_out_frame, playhead_frame} or nil if clip not found
function M.load_clip_marks(clip_id)
    assert(clip_id and clip_id ~= "",
        "database.load_clip_marks: clip_id required")
    assert(db_connection,
        "database.load_clip_marks: no active database connection")

    local stmt = db_connection:prepare([[
        SELECT mark_in_frame, mark_out_frame, playhead_frame
        FROM clips
        WHERE id = ?
    ]])
    assert(stmt, "database.load_clip_marks: failed to prepare query")

    stmt:bind_value(1, clip_id)

    local result = nil
    if stmt:exec() and stmt:next() then
        result = {
            mark_in_frame = stmt:value(0),   -- nil when NULL
            mark_out_frame = stmt:value(1),  -- nil when NULL
            playhead_frame = stmt:value(2),
        }
    end

    stmt:finalize()
    return result
end

--- Persist mark_in, mark_out, playhead for a clip.
-- mark_in and mark_out may be nil (clears the mark).
-- @param clip_id string: clip row ID (must exist)
-- @param mark_in number|nil: mark in frame
-- @param mark_out number|nil: mark out frame
-- @param playhead number: playhead frame
function M.save_clip_marks(clip_id, mark_in, mark_out, playhead)
    assert(clip_id and clip_id ~= "",
        "database.save_clip_marks: clip_id required")
    assert(playhead ~= nil,
        "database.save_clip_marks: playhead required")
    assert(db_connection,
        "database.save_clip_marks: no active database connection")

    local stmt = db_connection:prepare([[
        UPDATE clips
        SET mark_in_frame = ?, mark_out_frame = ?, playhead_frame = ?,
            modified_at = strftime('%s','now')
        WHERE id = ?
    ]])
    assert(stmt, "database.save_clip_marks: failed to prepare update")

    -- bind_value with nil produces SQL NULL for nullable columns
    if mark_in ~= nil then
        stmt:bind_value(1, mark_in)
    elseif stmt.bind_null then
        stmt:bind_null(1)
    else
        stmt:bind_value(1, nil)
    end

    if mark_out ~= nil then
        stmt:bind_value(2, mark_out)
    elseif stmt.bind_null then
        stmt:bind_null(2)
    else
        stmt:bind_value(2, nil)
    end

    stmt:bind_value(3, playhead)
    stmt:bind_value(4, clip_id)

    local ok = stmt:exec()
    stmt:finalize()
    assert(ok ~= false, string.format(
        "database.save_clip_marks: UPDATE failed for clip %s", clip_id))
end

-- ============================================================================
-- Smart Bins
-- ============================================================================

function M.load_smart_bins(project_id)
    assert(project_id and project_id ~= "", "database.load_smart_bins: project_id required")
    assert(db_connection, "database.load_smart_bins: no active database connection")

    local results = {}
    local stmt = db_connection:prepare([[
        SELECT id, project_id, name, scope_bin_id, criteria_json, created_at, modified_at
        FROM smart_bins WHERE project_id = ? ORDER BY name
    ]])
    assert(stmt, "database.load_smart_bins: failed to prepare query")
    stmt:bind_value(1, project_id)
    if stmt:exec() then
        while stmt:next() do
            results[#results + 1] = {
                id = stmt:value(0),
                project_id = stmt:value(1),
                name = stmt:value(2),
                scope_bin_id = stmt:value(3),
                criteria_json = stmt:value(4),
                created_at = stmt:value(5),
                modified_at = stmt:value(6),
            }
        end
    end
    stmt:finalize()
    return results
end

return M
