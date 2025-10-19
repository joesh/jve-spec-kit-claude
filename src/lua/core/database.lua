-- Database module for Lua
-- Provides simple interface to SQLite database

local M = {}
local sqlite3 = require("core.sqlite3")

-- Database connection
local db_connection = nil
local db_path = nil

-- Set database path and open connection
function M.set_path(path)
    db_path = path
    print("Database path set to: " .. path)

    -- Open database connection
    local db, err = sqlite3.open(path)
    if not db then
        print("ERROR: Failed to open database: " .. (err or "unknown error"))
        return false
    end

    db_connection = db
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

-- Get current project ID
-- For now, returns default project ID
-- TODO: Implement proper project tracking
function M.get_current_project_id()
    return "default_project"
end

-- Load all tracks for a sequence
function M.load_tracks(sequence_id)
    print("Loading tracks for sequence: " .. (sequence_id or "default"))

    if not db_connection then
        print("WARNING: No database connection")
        return {}
    end

    local query = db_connection:prepare([[
        SELECT id, name, track_type, track_index, enabled
        FROM tracks
        WHERE sequence_id = ?
        ORDER BY track_type DESC, track_index ASC
    ]])

    if not query then
        print("WARNING: Failed to prepare track query")
        return {}
    end

    query:bind_value(1, sequence_id or "default_sequence")

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
    if not db_connection then
        print("WARNING: No database connection")
        return {}
    end

    local query = db_connection:prepare([[
        SELECT c.id, c.track_id, c.media_id, c.start_time, c.duration,
               c.source_in, c.source_out, c.enabled
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ?
        ORDER BY c.start_time ASC
    ]])

    if not query then
        print("WARNING: Failed to prepare clip query")
        return {}
    end

    query:bind_value(1, sequence_id or "default_sequence")

    local clips = {}
    if query:exec() then
        while query:next() do
            local clip = {
                id = query:value(0),
                track_id = query:value(1),
                media_id = query:value(2),
                start_time = query:value(3),
                duration = query:value(4),
                source_in = query:value(5),
                source_out = query:value(6),
                enabled = query:value(7) == 1,
                name = "Clip " .. query:value(0):sub(1, 8)  -- TODO: Get from media table
            }
            table.insert(clips, clip)
        end
    end

    return clips
end

-- REMOVED: save_clip() - Stub implementation violated event sourcing
-- Use command system instead: Command.create("AddClip", ...)

-- Update clip position - PRESERVED (has real SQL implementation)
function M.update_clip_position(clip_id, start_time, duration)
    if not db_connection then
        print("WARNING: update_clip_position: No database connection")
        return false
    end

    local query = db_connection:prepare([[
        UPDATE clips
        SET start_time = ?, duration = ?
        WHERE id = ?
    ]])

    if not query then
        print("WARNING: update_clip_position: Failed to prepare UPDATE query")
        return false
    end

    query:bind_value(1, start_time)
    query:bind_value(2, duration)
    query:bind_value(3, clip_id)

    local success = query:exec()
    if not success then
        print(string.format("WARNING: update_clip_position: Failed to update clip %s", clip_id))
        return false
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
        print("WARNING: No database connection")
        return {}
    end

    local query = db_connection:prepare([[
        SELECT id, project_id, name, file_path, duration, frame_rate,
               width, height, audio_channels, codec, created_at, modified_at, metadata
        FROM media
        ORDER BY created_at DESC
    ]])

    if not query then
        print("WARNING: Failed to prepare media query")
        return {}
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

function M.load_sequences(project_id)
    project_id = project_id or M.get_current_project_id()
    if not db_connection then
        print("WARNING: load_sequences: No database connection")
        return {}
    end

    local sequences = {}
    local query = db_connection:prepare([[SELECT id, name, frame_rate, width, height, playhead_time FROM sequences WHERE project_id = ? ORDER BY name]])
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
                frame_rate = query:value(2),
                width = query:value(3),
                height = query:value(4),
                playhead_time = query:value(5),
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

-- Import media file
function M.import_media(file_path)
    local file_name = file_path:match("([^/]+)$")
    print("Importing media: " .. file_name)
    -- TODO: Implement actual SQLite insert via C++ bindings
    return {
        id = "media_" .. os.time(),
        file_name = file_name,
        file_path = file_path,
        duration = 10000, -- TODO: Get actual duration
    }
end

return M
