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

-- Delete a clip
function M.delete_clip(clip_id)
    print("Deleting clip: " .. clip_id)
    -- TODO: Implement actual SQLite delete via C++ bindings
    return true
end

-- Load all media
function M.load_media()
    print("Loading media library")
    -- TODO: Implement actual SQLite query via C++ bindings
    return {
        {id = "media1", file_name = "beach.mp4", file_path = "/path/to/beach.mp4", duration = 10000},
        {id = "media2", file_name = "music.mp3", file_path = "/path/to/music.mp3", duration = 180000},
        {id = "media3", file_name = "title.png", file_path = "/path/to/title.png", duration = 5000},
    }
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
