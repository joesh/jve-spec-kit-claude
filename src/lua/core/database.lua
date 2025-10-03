-- Database module for Lua
-- Provides simple interface to SQLite database

local M = {}

-- Database path (will be set by application)
local db_path = nil

-- Set database path
function M.set_path(path)
    db_path = path
    print("Database path set to: " .. path)
end

-- Get database path
function M.get_path()
    return db_path
end

-- Load all tracks for a sequence
function M.load_tracks(sequence_id)
    -- For now, return mock data
    -- TODO: Implement actual SQLite query via C++ bindings
    print("Loading tracks for sequence: " .. (sequence_id or "default"))

    return {
        {id = "video1", name = "Video 1", type = "video", track_index = 1},
        {id = "audio1", name = "Audio 1", type = "audio", track_index = 1},
        {id = "video2", name = "Video 2", type = "video", track_index = 2},
    }
end

-- Load all clips for a sequence
function M.load_clips(sequence_id)
    -- For now, return mock data
    -- TODO: Implement actual SQLite query via C++ bindings
    print("Loading clips for sequence: " .. (sequence_id or "default"))

    return {
        {id = "clip1", track_id = "video1", start_time = 0, duration = 5000, name = "Beach Scene", media_id = "media1"},
        {id = "clip2", track_id = "audio1", start_time = 1000, duration = 8000, name = "Music Track", media_id = "media2"},
        {id = "clip3", track_id = "video2", start_time = 3000, duration = 4000, name = "Title Card", media_id = "media3"},
    }
end

-- Save a clip
function M.save_clip(clip)
    print(string.format("Saving clip: %s (start=%d, duration=%d)",
        clip.name or clip.id, clip.start_time, clip.duration))
    -- TODO: Implement actual SQLite insert/update via C++ bindings
    return true
end

-- Update clip position
function M.update_clip_position(clip_id, start_time, duration)
    print(string.format("Updating clip %s position: start=%d, duration=%d",
        clip_id, start_time, duration))
    -- TODO: Implement actual SQLite update via C++ bindings
    return true
end

-- Update a single clip property
function M.update_clip_property(clip_id, property_name, value)
    print(string.format("Updating clip %s property '%s' = '%s'",
        clip_id, property_name, tostring(value)))
    -- TODO: Implement actual SQLite update via C++ bindings
    -- For now, just return success since we're using mock data
    return true
end

-- Delete a clip
function M.delete_clip(clip_id)
    print("Deleting clip: " .. clip_id)
    -- TODO: Implement actual SQLite delete via C++ bindings
    return true
end

-- Load all media with tag associations
function M.load_media()
    print("Loading media library")
    -- Returns media with tags across multiple namespaces
    return {
        -- Root level media (no bin tag)
        {
            id = "media1",
            file_name = "intro.mp4",
            file_path = "/path/to/intro.mp4",
            duration = 5000,
            tags = {
                {namespace = "bin", tag_path = nil},  -- Root level
                {namespace = "project", tag_path = "Corporate"},
                {namespace = "status", tag_path = "Approved"}
            }
        },
        {
            id = "media2",
            file_name = "logo.png",
            file_path = "/path/to/logo.png",
            duration = 3000,
            tags = {
                {namespace = "bin", tag_path = nil},  -- Root level
                {namespace = "type", tag_path = "Graphics"},
                {namespace = "project", tag_path = "Corporate"}
            }
        },

        -- Media in Footage bin
        {
            id = "media3",
            file_name = "beach.mp4",
            file_path = "/path/to/beach.mp4",
            duration = 10000,
            tags = {
                {namespace = "bin", tag_path = "Footage"},
                {namespace = "location", tag_path = "Beach"},
                {namespace = "status", tag_path = "Raw"}
            }
        },
        {
            id = "media4",
            file_name = "sunset.mp4",
            file_path = "/path/to/sunset.mp4",
            duration = 8000,
            tags = {
                {namespace = "bin", tag_path = "Footage"},
                {namespace = "location", tag_path = "Beach"},
                {namespace = "status", tag_path = "Raw"}
            }
        },

        -- Media in Graphics bin
        {
            id = "media5",
            file_name = "title.png",
            file_path = "/path/to/title.png",
            duration = 5000,
            tags = {
                {namespace = "bin", tag_path = "Graphics"},
                {namespace = "type", tag_path = "Graphics/Title"},
                {namespace = "project", tag_path = "Documentary"}
            }
        },

        -- Media in nested Interviews bin
        {
            id = "media6",
            file_name = "interview1.mp4",
            file_path = "/path/to/interview1.mp4",
            duration = 120000,
            tags = {
                {namespace = "bin", tag_path = "Footage/Interviews"},
                {namespace = "person", tag_path = "Expert/John Smith"},
                {namespace = "status", tag_path = "Transcribed"}
            }
        },
        {
            id = "media7",
            file_name = "interview2.mp4",
            file_path = "/path/to/interview2.mp4",
            duration = 150000,
            tags = {
                {namespace = "bin", tag_path = "Footage/Interviews"},
                {namespace = "person", tag_path = "Expert/Jane Doe"},
                {namespace = "status", tag_path = "Transcribed"}
            }
        },

        -- More media in Footage bin
        {
            id = "media8",
            file_name = "music.mp3",
            file_path = "/path/to/music.mp3",
            duration = 180000,
            tags = {
                {namespace = "bin", tag_path = "Footage"},
                {namespace = "type", tag_path = "Audio/Music"},
                {namespace = "mood", tag_path = "Ambient"}
            }
        },
    }
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
