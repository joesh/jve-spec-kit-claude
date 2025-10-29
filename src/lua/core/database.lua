-- Database module for Lua
-- Provides simple interface to SQLite database

local M = {}
local sqlite3 = require("core.sqlite3")
local json = require("dkjson")

-- Database connection
local db_connection = nil
local db_path = nil

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

    db_path = path
    print("Database path set to: " .. path)

    -- Open database connection
    local db, err = sqlite3.open(path)
    if not db then
        print("ERROR: Failed to open database: " .. (err or "unknown error"))
        return false
    end

    db_connection = db

    -- Configure busy timeout so we wait for locks instead of failing immediately
    if db_connection.busy_timeout then
        db_connection:busy_timeout(5000)  -- 5 seconds
    else
        -- Fallback for drivers without helper
        db_connection:exec("PRAGMA busy_timeout = 5000;")
    end

    -- Enable WAL to reduce writer contention when multiple tools touch the DB
    db_connection:exec("PRAGMA journal_mode = WAL;")

    print("Database connection opened successfully")
    return true
end

-- Get database path
function M.get_path()
    return db_path
end

-- Get database connection (for use by command_manager, models, etc.)
function M.get_connection()
    return db_connection
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
                local project_id = args.project_id or "default_project"
                if file_path and project_id then
                    local MediaReader = require('media.media_reader')
                    local new_id, _, import_err = MediaReader.import_media(file_path, db_connection, project_id, media_id)
                    if new_id == media_id then
                        restored = true
                        break
                    else
                        if import_err then
                            print("WARNING: ensure_media_record: failed to reimport media: " .. tostring(import_err))
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
-- Creates a default project if none exists (ensures app can always run)
-- TODO: Implement multi-project support with user selection
function M.get_current_project_id()
    if not db_connection then
        error("FATAL: No database connection - cannot get current project")
    end

    -- Check if default project exists
    local stmt = db_connection:prepare("SELECT id FROM projects WHERE id = ?")
    if not stmt then
        error("FATAL: Failed to prepare project query")
    end

    local default_id = "default_project"
    stmt:bind_value(1, default_id)

    if not stmt:exec() then
        stmt:finalize()
        error("FATAL: Failed to execute project query")
    end

    local exists = stmt:next()
    stmt:finalize()

    -- If default project doesn't exist, create it
    if not exists then
        local Project = require('models.project')
        local project = Project.create_with_id(default_id, "Default Project")
        if not project then
            error("FATAL: Failed to create default project")
        end
        if not project:save(db_connection) then
            error("FATAL: Failed to save default project to database")
        end
        print("INFO: Created default project")
    end

    return default_id
end

-- Load all tracks for a sequence
function M.load_tracks(sequence_id)
    if not sequence_id then
        error("FATAL: load_tracks() requires sequence_id parameter")
    end

    print("Loading tracks for sequence: " .. sequence_id)

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
        error("FATAL: Failed to prepare track query")
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

    print(string.format("Loaded %d tracks from database", #tracks))
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
        SELECT c.id, c.clip_kind, c.name, c.track_id, c.media_id,
               c.parent_clip_id, c.owner_sequence_id, c.start_time, c.duration,
               c.source_in, c.source_out, c.enabled, c.offline,
               m.name, m.file_path
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        LEFT JOIN media m ON c.media_id = m.id
        WHERE t.sequence_id = ?
        ORDER BY c.start_time ASC
    ]])

    if not query then
        error("FATAL: Failed to prepare clip query")
    end

    query:bind_value(1, sequence_id)

    local clips = {}
    local function extract_filename(path)
        if not path or path == "" then
            return nil
        end
        local filename = path:match("([^/\\]+)$")
        return filename
    end

    if query:exec() then
        while query:next() do
            local clip_id = query:value(0)
            local media_name = query:value(13)
            local media_path = query:value(14)
            local label = media_name
            if label == nil or label == "" then
                label = extract_filename(media_path)
            end
            if label == nil or label == "" then
                label = clip_id and ("Clip " .. clip_id:sub(1, 8)) or ""
                print(string.format("WARNING: Clip %s missing media metadata (media_id=%s); using generated label '%s'", tostring(clip_id), tostring(query:value(2)), label))
            end

            local clip = {
                id = clip_id,
                clip_kind = query:value(1),
                name = query:value(2),
                track_id = query:value(3),
                media_id = query:value(4),
                parent_clip_id = query:value(5),
                owner_sequence_id = query:value(6),
                start_time = query:value(7),
                duration = query:value(8),
                source_in = query:value(9),
                source_out = query:value(10),
                enabled = query:value(11) == 1,
                offline = query:value(12) == 1,
                media_name = media_name,
                media_path = media_path,
                label = label
            }
            if not clip.name or clip.name == "" then
                clip.name = "Clip " .. (clip_id and clip_id:sub(1, 8) or "")
            end
            local display_label = clip.name
            if (not display_label or display_label == "") and media_name and media_name ~= "" then
                display_label = media_name
            end
            if (not display_label or display_label == "") and label and label ~= "" then
                display_label = label
            end
            clip.label = display_label
            table.insert(clips, clip)
        end
    end

    return clips
end

-- REMOVED: save_clip() - Stub implementation violated event sourcing
-- Use command system instead: Command.create("AddClip", ...)

-- Update clip position - PRESERVED (has real SQL implementation)
function M.update_clip_position(clip_id, start_time, duration)
    if not clip_id then
        error("FATAL: update_clip_position() requires clip_id parameter")
    end
    if not start_time then
        error("FATAL: update_clip_position() requires start_time parameter")
    end
    if not duration then
        error("FATAL: update_clip_position() requires duration parameter")
    end

    if not db_connection then
        error("FATAL: No database connection - cannot update clip position")
    end

    local query = db_connection:prepare([[
        UPDATE clips
        SET start_time = ?, duration = ?, modified_at = strftime('%s','now')
        WHERE id = ?
    ]])

    if not query then
        error("FATAL: Failed to prepare UPDATE query for clip position")
    end

    query:bind_value(1, start_time)
    query:bind_value(2, duration)
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
    print("Loading media library from database")

    if not db_connection then
        error("FATAL: No database connection - cannot load media")
    end

    local query = db_connection:prepare([[
        SELECT id, project_id, name, file_path, duration, frame_rate,
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
            table.insert(media_items, {
                id = query:value(0),
                project_id = query:value(1),
                name = query:value(2),
                file_name = query:value(2),  -- Alias for backward compatibility
                file_path = query:value(3),
                duration = query:value(4),
                frame_rate = query:value(5),
                width = query:value(6),
                height = query:value(7),
                audio_channels = query:value(8),
                codec = query:value(9),
                created_at = query:value(10),
                modified_at = query:value(11),
                metadata = query:value(12),
                tags = {}  -- TODO: Load tags from media_tags table when implemented
            })
        end
    end

    print(string.format("Loaded %d media items from database", #media_items))
    return media_items
end

function M.load_master_clips(project_id)
    project_id = project_id or M.get_current_project_id()

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
            c.duration,
            c.source_in,
            c.source_out,
            c.enabled,
            c.offline,
            c.created_at,
            c.modified_at,
            m.project_id,
            m.name,
            m.file_path,
            m.duration,
            m.frame_rate,
            m.width,
            m.height,
            m.audio_channels,
            m.codec,
            m.metadata,
            m.created_at,
            m.modified_at,
            s.project_id,
            s.frame_rate,
            s.width,
            s.height
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
            local duration = query:value(5)
            local source_in = query:value(6) or 0
            local source_out = query:value(7) or duration
            local enabled = query:value(8) == 1
            local offline = query:value(9) == 1
            local created_at = query:value(10)
            local modified_at = query:value(11)

            local media_project_id = query:value(12)
            local media_name = query:value(13)
            local media_path = query:value(14)
            local media_duration = query:value(15)
            local media_frame_rate = query:value(16)
            local media_width = query:value(17)
            local media_height = query:value(18)
            local media_channels = query:value(19)
            local media_codec = query:value(20)
            local media_metadata = query:value(21)
            local media_created_at = query:value(22)
            local media_modified_at = query:value(23)

            local sequence_project_id = query:value(24)
            local sequence_frame_rate = query:value(25)
            local sequence_width = query:value(26)
            local sequence_height = query:value(27)

            local media_info = {
                id = media_id,
                project_id = media_project_id,
                name = media_name,
                file_name = media_name,
                file_path = media_path,
                duration = media_duration,
                frame_rate = media_frame_rate,
                width = media_width,
                height = media_height,
                audio_channels = media_channels,
                codec = media_codec,
                metadata = media_metadata,
                created_at = media_created_at,
                modified_at = media_modified_at,
            }

            local sequence_info = {
                id = source_sequence_id,
                project_id = sequence_project_id,
                frame_rate = sequence_frame_rate,
                width = sequence_width,
                height = sequence_height,
            }

            local clip_entry = {
                clip_id = clip_id,
                project_id = clip_project_id or media_project_id or sequence_project_id,
                name = clip_name or (media_name or clip_id),
                media_id = media_id,
                source_sequence_id = source_sequence_id,
                duration = duration,
                source_in = source_in,
                source_out = source_out,
                enabled = enabled,
                offline = offline,
                created_at = created_at,
                modified_at = modified_at,
                media = media_info,
                sequence = sequence_info,
            }

            -- Convenience fields for consumers
            clip_entry.file_path = media_path
            clip_entry.frame_rate = media_frame_rate or sequence_frame_rate
            clip_entry.width = media_width or sequence_width
            clip_entry.height = media_height or sequence_height
            clip_entry.codec = media_codec

            table.insert(clips, clip_entry)
        end
    end

    query:finalize()

    print(string.format("Loaded %d master clips from database", #clips))
    return clips
end

function M.load_sequences(project_id)
    project_id = project_id or M.get_current_project_id()
    if not db_connection then
        print("WARNING: load_sequences: No database connection")
        return {}
    end

    local sequences = {}
    local query = db_connection:prepare([[SELECT id, name, kind, frame_rate, width, height, playhead_time FROM sequences WHERE project_id = ? ORDER BY name]])
    if not query then
        print("WARNING: load_sequences: Failed to prepare query")
        return sequences
    end

    query:bind_value(1, project_id)
    if query:exec() then
        while query:next() do
            table.insert(sequences, {
                id = query:value(0),
                name = query:value(1),
                kind = query:value(2),
                frame_rate = query:value(3),
                width = query:value(4),
                height = query:value(5),
                playhead_time = query:value(6),
            })
        end
    end
    query:finalize()

    -- Compute duration for each sequence (max clip end)
    for _, sequence in ipairs(sequences) do
        local clips = M.load_clips(sequence.id)
        local max_end = 0
        for _, clip in ipairs(clips) do
            local clip_end = (clip.start_time or 0) + (clip.duration or 0)
            if clip_end > max_end then
                max_end = clip_end
            end
        end
        sequence.duration = max_end
    end

    return sequences
end

local function decode_settings_json(raw)
    if not raw or raw == "" then
        return {}
    end

    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == "table" then
        return decoded
    end

    return {}
end

function M.get_project_settings(project_id)
    project_id = project_id or M.get_current_project_id()
    if not db_connection then
        print("WARNING: get_project_settings: No database connection")
        return {}
    end

    local stmt = db_connection:prepare("SELECT settings FROM projects WHERE id = ?")
    if not stmt then
        print("WARNING: get_project_settings: Failed to prepare query")
        return {}
    end

    stmt:bind_value(1, project_id)
    local settings_json = "{}"
    if stmt:exec() and stmt:next() then
        settings_json = stmt:value(0) or "{}"
    end
    stmt:finalize()

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

    project_id = project_id or M.get_current_project_id()
    if not db_connection then
        print("WARNING: set_project_setting: No database connection")
        return false
    end

    local settings = M.get_project_settings(project_id)
    if value == nil then
        settings[key] = nil
    else
        settings[key] = value
    end

    local encoded, encode_err = json.encode(settings)
    if not encoded then
        print("WARNING: set_project_setting: Failed to encode settings JSON: " .. tostring(encode_err))
        return false
    end

    local stmt = db_connection:prepare([[
        UPDATE projects
        SET settings = ?, modified_at = strftime('%s', 'now')
        WHERE id = ?
    ]])

    if not stmt then
        print("WARNING: set_project_setting: Failed to prepare update statement")
        return false
    end

    stmt:bind_value(1, encoded)
    stmt:bind_value(2, project_id)
    local ok = stmt:exec()
    if not ok then
        print("WARNING: set_project_setting: Update failed for project " .. tostring(project_id))
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

-- Legacy compatibility: load bins from "bin" namespace tags
function M.load_bins()
    print("Loading bins from tag namespace")
    local bins = {}
    local bin_map = {}

    -- Extract all unique bin tag paths
    local media_items = M.load_media()
    for _, media in ipairs(media_items) do
        if media.tags then
            for _, tag in ipairs(media.tags) do
                if tag.namespace == "bin" and tag.tag_path then
                    -- Parse hierarchical path (e.g., "Footage/Interviews")
                    local parts = {}
                    for part in tag.tag_path:gmatch("[^/]+") do
                        table.insert(parts, part)
                    end

                    -- Create bin entries for each level
                    local current_path = ""
                    local parent_path = nil
                    for i, part in ipairs(parts) do
                        if i == 1 then
                            current_path = part
                        else
                            current_path = current_path .. "/" .. part
                        end

                        if not bin_map[current_path] then
                            bin_map[current_path] = {
                                id = "bin_" .. current_path:gsub("/", "_"),
                                name = part,
                                parent_id = parent_path and bin_map[parent_path].id or nil
                            }
                        end

                        parent_path = current_path
                    end
                end
            end
        end
    end

    -- Convert to list
    for _, bin in pairs(bin_map) do
        table.insert(bins, bin)
    end

    -- Sort bins alphabetically by name
    table.sort(bins, function(a, b)
        return a.name < b.name
    end)

    return bins
end

-- REMOVED: import_media() - Stub function that returned dummy data
-- Use media_reader.lua and ImportMedia command instead

return M
