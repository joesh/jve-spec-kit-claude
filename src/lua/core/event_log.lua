-- Event log integration for Lua command manager.
-- Persists JSONL event stream and maintains read-model SQLite projections.

local sqlite3 = require("core.sqlite3")
local json = require("dkjson")
local logger = require("core.logger")

local M = {}

local function compute_repo_root()
    local info = debug.getinfo(1, "S")
    if not info or not info.source or info.source == "" then
        error("event_log: unable to resolve module path")
    end

    local source_path
    if info.source:sub(1, 1) == "@" then
        source_path = info.source:sub(2)
    else
        source_path = info.source
    end

    -- Attempt to find the repository root by looking for the "src/lua/core" pattern.
    -- This makes it more robust to how the script is invoked (e.g., from project root, or directly)
    local root_match = source_path:match("^(.*)/src/lua/core/event_log%.lua$")
    if root_match then
        return root_match
    end

    -- If the full path doesn't match, assume we are already in the root or a subdirectory
    -- and event_log.lua is in 'src/lua/core' relative to the current working directory.
    -- This is a common pattern for running tests from the project root.
    if source_path:match("^src/lua/core/event_log%.lua$") then
        return "." -- Current working directory is the repo root
    end

    error("event_log: failed to derive repository root from path: " .. source_path)
end

local repo_root = compute_repo_root()

local event_root_dir = nil
local events_log_path = nil
local readmodel_path = nil
local readmodel_db = nil

local schema_files = {
    repo_root .. "/schema/eventlog/00_timeline.sql",
    repo_root .. "/schema/eventlog/01_media.sql",
    repo_root .. "/schema/eventlog/02_ui.sql",
    repo_root .. "/schema/eventlog/03_browser.sql",
}

local function ensure_dir(path)
    if not path or path == "" then
        error("event_log.ensure_dir: path is required")
    end
    -- os.execute returns true on macOS/Linux; no fallback allowed.
    local ok = os.execute(string.format('mkdir -p "%s"', path))
    if ok ~= 0 and ok ~= true then
        error(string.format("event_log.ensure_dir: failed to create directory '%s'", path))
    end
end

local function close_readmodel()
    if readmodel_db and readmodel_db.close then
        readmodel_db:close()
    end
    readmodel_db = nil
end

local function load_schema()
    for _, schema_path in ipairs(schema_files) do
        local file = io.open(schema_path, "r")
        if not file then
            error(string.format("event_log: missing schema file '%s'", schema_path))
        end
        local sql = file:read("*a")
        file:close()

        local ok, err = readmodel_db:exec(sql)
        if not ok then
            error(string.format("event_log: failed to apply schema %s: %s", schema_path, tostring(err)))
        end
    end
end

local function validate_readmodel_schema()
    if not readmodel_db then return false end
    -- Try to prepare the V5 insert statement to verify column existence and types
    local stmt = readmodel_db:prepare([[
        INSERT INTO tl_clips(seq_id,clip_id,media_id,track,t_in,t_out,src_in,src_out,enable,attrs_json)
        VALUES(?,?,?,?,?,?,?,?,?,json('{}'))
    ]])
    if not stmt then
        return false
    end
    stmt:finalize()
    return true
end

local function open_readmodel(path)
    close_readmodel()

    local db, err = sqlite3.open(path)
    if not db then
        error(string.format("event_log: failed to open read model database: %s", err or "unknown error"))
    end

    readmodel_db = db
    local ok, pragma_err = readmodel_db:exec("PRAGMA journal_mode = WAL;")
    if not ok then
        error("event_log: failed to enable WAL mode: " .. tostring(pragma_err))
    end

    ok, pragma_err = readmodel_db:exec("PRAGMA foreign_keys = ON;")
    if not ok then
        error("event_log: failed to enable foreign key enforcement: " .. tostring(pragma_err))
    end

    load_schema()
    
    if not validate_readmodel_schema() then
        logger.warn("event_log", "Read model schema mismatch detected. Rebuilding database...")
        close_readmodel()
        os.remove(path)
        os.remove(path .. "-wal")
        os.remove(path .. "-shm")
        
        db, err = sqlite3.open(path)
        if not db then
             error(string.format("event_log: failed to re-open read model database: %s", err or "unknown error"))
        end
        readmodel_db = db
        readmodel_db:exec("PRAGMA journal_mode = WAL;")
        readmodel_db:exec("PRAGMA foreign_keys = ON;")
        load_schema()
    end
end

local function derive_root(project_path)
    if project_path:sub(-4) == ".jvp" then
        return project_path .. ".events"
    end
    return project_path .. ".events"
end

-- Compute ULID-like identifier using sequence number for determinism.
local function deterministic_event_id(sequence_number)
    if type(sequence_number) ~= "number" or sequence_number < 0 then
        sequence_number = 0
    end
    return string.format("%026d", sequence_number)
end

local function write_event_line(event_record)
    local encoded, encode_err = json.encode(event_record, { indent = false })
    if not encoded then
        return false, "Failed to encode event: " .. tostring(encode_err)
    end

    local file = io.open(events_log_path, "a")
    if not file then
        return false, "Failed to open event log file for append"
    end

    file:write(encoded)
    file:write("\n")
    file:close()
    return true
end

local function to_frames(val)
    if type(val) == "table" and val.frames then
        return val.frames
    end
    return val
end

local function apply_timeline_event(payload)
    if not payload then
        return true
    end

    if payload.type == "InsertClip" then
        local stmt = readmodel_db:prepare([[
            INSERT INTO tl_clips(seq_id,clip_id,media_id,track,t_in,t_out,src_in,src_out,enable,attrs_json)
            VALUES(?,?,?,?,?,?,?,?,?,json('{}'))
        ]])
        if not stmt then
            return false, "event_log: failed to prepare tl_clips insert: " .. (readmodel_db:last_error() or "unknown")
        end
        stmt:bind_value(1, payload.seq_id)
        stmt:bind_value(2, payload.clip_id)
        stmt:bind_value(3, payload.media_id)
        stmt:bind_value(4, payload.track)
        stmt:bind_value(5, to_frames(payload.t_in))
        stmt:bind_value(6, to_frames(payload.t_out))
        stmt:bind_value(7, to_frames(payload.src_in))
        stmt:bind_value(8, to_frames(payload.src_out))
        stmt:bind_value(9, payload.enable and 1 or 0)
        local ok = stmt:exec()
        stmt:finalize()
        if not ok then
            return false, "event_log: failed to apply InsertClip payload"
        end
        return true
    elseif payload.type == "AddMarker" then
        local stmt = readmodel_db:prepare([[
            INSERT INTO tl_markers(seq_id,marker_id,t,color,name)
            VALUES(?,?,?,?,?)
        ]])
        if not stmt then
            return false, "event_log: failed to prepare tl_markers insert"
        end
        stmt:bind_value(1, payload.seq_id)
        stmt:bind_value(2, payload.marker_id)
        stmt:bind_value(3, to_frames(payload.time))
        stmt:bind_value(4, payload.color or "yellow")
        stmt:bind_value(5, payload.name or "")
        local ok = stmt:exec()
        stmt:finalize()
        if not ok then
            return false, "event_log: failed to apply AddMarker payload"
        end
        return true
    end

    return true
end

local function apply_media_event(payload)
    if not payload then
        return true
    end

    if payload.type ~= "ImportMedia" then
        return true
    end

    local stmt = readmodel_db:prepare([[
        INSERT OR REPLACE INTO media(media_id,uri,sha3,duration,time_base,audio_layout,tags_json)
        VALUES(?,?,?,?,?,?,json(?))
    ]])
    if not stmt then
        return false, "event_log: failed to prepare media upsert"
    end

    stmt:bind_value(1, payload.media_id)
    stmt:bind_value(2, payload.uri)
    stmt:bind_value(3, payload.sha3 or "")
    stmt:bind_value(4, payload.duration_ticks or 0)
    stmt:bind_value(5, payload.time_base or 0)
    stmt:bind_value(6, payload.audio_layout or "")
    stmt:bind_value(7, json.encode(payload.tags or {}))
    local ok = stmt:exec()
    stmt:finalize()
    if not ok then
        return false, "event_log: failed to apply ImportMedia payload"
    end
    return true
end

local function apply_ui_event(payload)
    if not payload then
        return true
    end

    if payload.type == "SetPlayhead" then
        local stmt = readmodel_db:prepare([[
            INSERT INTO ui_state(id,active_seq,playhead_value,last_panel)
            VALUES(1,COALESCE((SELECT active_seq FROM ui_state WHERE id=1),''),?,COALESCE((SELECT last_panel FROM ui_state WHERE id=1),'timeline'))
            ON CONFLICT(id) DO UPDATE SET playhead_value=excluded.playhead_value
        ]])
        if not stmt then
            return false, "event_log: failed to prepare UI playhead upsert"
        end
        stmt:bind_value(1, to_frames(payload.time) or 0)
        local ok = stmt:exec()
        stmt:finalize()
        if not ok then
            return false, "event_log: failed to apply SetPlayhead payload"
        end
    elseif payload.type == "SetActiveSequence" then
        local stmt = readmodel_db:prepare([[
            INSERT INTO ui_state(id,active_seq,playhead_value,last_panel)
            VALUES(1,?,0,'timeline')
            ON CONFLICT(id) DO UPDATE SET active_seq=excluded.active_seq
        ]])
        if not stmt then
            return false, "event_log: failed to prepare UI sequence upsert"
        end
        stmt:bind_value(1, payload.seq_id)
        local ok = stmt:exec()
        stmt:finalize()
        if not ok then
            return false, "event_log: failed to apply SetActiveSequence payload"
        end
    end

    return true
end

local function apply_event(event_record)
    if not readmodel_db then
        return false, "event_log: read model database not initialized"
    end

    readmodel_db:exec("BEGIN IMMEDIATE;")

    local ok, err = apply_media_event(event_record.media_payload)
    if not ok then
        readmodel_db:exec("ROLLBACK;")
        return false, err
    end

    ok, err = apply_timeline_event(event_record.timeline_payload)
    if not ok then
        readmodel_db:exec("ROLLBACK;")
        return false, err
    end

    ok, err = apply_ui_event(event_record.ui_payload)
    if not ok then
        readmodel_db:exec("ROLLBACK;")
        return false, err
    end

    readmodel_db:exec("COMMIT;")
    return true
end

local function normalize_clip_payload(command, context)
    local seq_id = context.sequence_id or command:get_parameter("sequence_id") or "default_sequence"
    local duration = command:get_parameter("duration")
    local insert_time = command:get_parameter("insert_time")
    local src_in = command:get_parameter("source_in") or 0
    
    -- Calculate derived values using Rational arithmetic if present
    local src_out = command:get_parameter("source_out")
    if not src_out then
        if type(src_in) == "table" and src_in.frames and type(duration) == "table" and duration.frames then
             -- Assume Rational
             -- We cannot perform arithmetic here without loading Rational module or assuming metatable.
             -- command parameters SHOULD have metatable if set properly.
             -- But let's try to be safe. If metatables are missing, we can't add.
             -- However, normalize_clip_payload is called during record_command, where Rationals are live.
             src_out = src_in + duration
        else
             src_out = src_in + (duration or 0)
        end
    end
    
    local t_out
    if insert_time and duration then
        if type(insert_time) == "table" and insert_time.frames and type(duration) == "table" and duration.frames then
            t_out = insert_time + duration
        else
            t_out = insert_time + duration
        end
    else
        t_out = insert_time
    end

    return {
        type = "InsertClip",
        seq_id = seq_id,
        clip_id = command:get_parameter("clip_id"),
        media_id = command:get_parameter("media_id"),
        track = command:get_parameter("track_id"),
        t_in = insert_time,
        t_out = t_out,
        src_in = src_in,
        src_out = src_out,
        enable = true,
    }
end

local function normalize_media_payload(command)
    local metadata = command:get_parameter("media_metadata") or {}
    local tags = metadata.tags or {}
    if type(tags) ~= "table" then
        tags = {}
    end
    return {
        type = "ImportMedia",
        media_id = command:get_parameter("media_id"),
        uri = command:get_parameter("file_path"),
        sha3 = metadata.sha3 or "",
        duration_ticks = math.floor((metadata.duration_ms or 0) * (metadata.time_base or 1)),
        time_base = metadata.time_base or 1000,
        audio_layout = metadata.audio and metadata.audio.channels and (metadata.audio.channels .. "ch") or "stereo",
        tags = tags,
    }
end

local function build_event_envelope(command, context)
    local sequence_number = context.sequence_number or command.sequence_number or 0
    local parent_sequence = command.parent_sequence_number
    local scope = context.scope or "command"
    local author = os.getenv("JVE_EVENT_AUTHOR")
    if not author or author == "" then
        author = "node:" .. (os.getenv("USER") or "jve")
    end

    local envelope = {
        id = deterministic_event_id(sequence_number),
        type = command.type,
        scope = scope,
        ts = math.floor((command.executed_at or os.time()) * 1000),
        author = author,
        parents = {},
        schema = 1,
        payload_v = 1,
        command_id = command.id,
        project_id = context.project_id or command.project_id or "default_project",
        stack_id = context.stack_id or "global",
        timeline_payload = nil,
        media_payload = nil,
        ui_payload = nil,
    }

    if parent_sequence and parent_sequence > 0 then
        table.insert(envelope.parents, deterministic_event_id(parent_sequence))
    end

    if command.type == "ImportMedia" then
        envelope.media_payload = normalize_media_payload(command)
        envelope.scope = "media"
    elseif command.type == "Insert" then
        envelope.timeline_payload = normalize_clip_payload(command, context)
        envelope.scope = string.format("timeline:%s", context.sequence_id or "default_sequence")
    elseif command.type == "SetActiveSequence" then
        envelope.ui_payload = {
            type = "SetActiveSequence",
            seq_id = command:get_parameter("sequence_id") or command:get_parameter("seq_id") or "default_sequence"
        }
        envelope.scope = "ui"
    elseif command.type == "SetPlayhead" then
        envelope.ui_payload = {
            type = "SetPlayhead",
            time = command:get_parameter("playhead_value") or command:get_parameter("time") or 0
        }
        envelope.scope = "ui"
    end

    return envelope
end

local function deep_copy_parameters(parameters)
    local copy = {}
    for key, value in pairs(parameters or {}) do
        if type(value) == "table" then
            copy[key] = deep_copy_parameters(value)
        else
            copy[key] = value
        end
    end
    return copy
end

local function attach_generic_payload(envelope, command)
    assert(type(command.get_persistable_parameters) == "function", "event_log: command missing get_persistable_parameters()")
    local parameters = command:get_persistable_parameters()
    envelope.generic_payload = {
        parameters = deep_copy_parameters(parameters),
        playhead_value = command.playhead_value,
        sequence_number = command.sequence_number,
    }
end

function M.init(project_path)
    if not project_path or project_path == "" then
        error("event_log.init requires a project path")
    end

    event_root_dir = derive_root(project_path)
    ensure_dir(event_root_dir)
    ensure_dir(event_root_dir .. "/events")
    ensure_dir(event_root_dir .. "/snapshots")

    events_log_path = event_root_dir .. "/events/events.jsonl"
    readmodel_path = event_root_dir .. "/readmodels.sqlite"

    open_readmodel(readmodel_path)
end

local function checkpoint_and_disable_wal(db_handle, label)
    if not db_handle then
        return
    end
    local ok, err = db_handle:exec("PRAGMA wal_checkpoint(TRUNCATE);")
    if ok == false then
        logger.warn("event_log", string.format("wal_checkpoint failed (%s): %s", tostring(label or "db"), tostring(err)))
    end
    ok, err = db_handle:exec("PRAGMA journal_mode = DELETE;")
    if ok == false then
        logger.warn("event_log", string.format("journal_mode=DELETE failed (%s): %s", tostring(label or "db"), tostring(err)))
    end
end

function M.shutdown()
    if readmodel_db then
        checkpoint_and_disable_wal(readmodel_db, "readmodel")
    end
    close_readmodel()
    if readmodel_path and readmodel_path ~= "" then
        os.remove(readmodel_path .. "-wal")
        os.remove(readmodel_path .. "-shm")
    end
end

function M.record_command(command, context)
    if not event_root_dir then
        return false, "event_log: init() must be called before recording commands"
    end
    if not command then
        return false, "event_log: command is required"
    end

    local envelope = build_event_envelope(command, context or {})
    attach_generic_payload(envelope, command)

    local ok, err = write_event_line(envelope)
    if not ok then
        return false, err
    end

    ok, err = apply_event(envelope)
    if not ok then
        return false, err
    end

    return true
end

return M
