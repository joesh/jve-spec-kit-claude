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
-- Size: ~264 LOC
-- Volatility: unknown
--
-- @file resolve_database_importer.lua
-- Original intent (unreviewed):
-- - DaVinci Resolve SQLite Database Importer
-- Imports projects directly from Resolve's disk-based SQLite databases
--
-- Database locations:
-- macOS: ~/Movies/DaVinci Resolve/Resolve Disk Database/Resolve Projects/Users/{user}/Projects/{project}.drp/
-- Windows: %APPDATA%\Blackmagic Design\DaVinci Resolve\Resolve Disk Database\...
--
-- Key tables:
-- - projects: Project metadata (name, resolution, frame rate)
-- - timelines: Timeline sequences
-- - tracks: Video/audio tracks within timelines
-- - clips: Individual clips on tracks
-- - media: Media pool items (source files)
--
-- Usage:
-- local resolve_db = require("importers.resolve_database_importer")
-- local result = resolve_db.import_from_database("/path/to/resolve.db")
local M = {}

local sqlite3 = require("lsqlite3")

--- Open Resolve SQLite database
-- @param db_path string: Path to Resolve .db file
-- @return userdata|nil: SQLite database handle, or nil on error
-- @return string|nil: Error message if failed
local function open_resolve_database(db_path)
    local db = sqlite3.open(db_path, sqlite3.OPEN_READONLY)

    if not db then
        return nil, "Failed to open Resolve database: " .. db_path
    end

    return db, nil
end

--- Get Resolve database schema version
-- @param db userdata: SQLite database handle
-- @return number: Schema version number
local function get_schema_version(db)
    local version = 0

    local stmt = db:prepare("SELECT version FROM schema_version LIMIT 1")
    if stmt then
        if stmt:step() == sqlite3.ROW then
            version = stmt:get_value(0) or 0
        end
        stmt:finalize()
    end

    return version
end

--- List tables in Resolve database
-- @param db userdata: SQLite database handle
-- @return table: Array of table names
local function list_tables(db)
    local tables = {}

    local stmt = db:prepare([[
        SELECT name FROM sqlite_master
        WHERE type='table'
        ORDER BY name
    ]])

    if stmt then
        while stmt:step() == sqlite3.ROW do
            table.insert(tables, stmt:get_value(0))
        end
        stmt:finalize()
    end

    return tables
end

--- Get table schema
-- @param db userdata: SQLite database handle
-- @param table_name string: Name of table
-- @return table: Array of column definitions {name, type, notnull, dflt_value, pk}
local function get_table_schema(db, table_name)
    local columns = {}

    local stmt = db:prepare(string.format("PRAGMA table_info(%s)", table_name))
    if stmt then
        while stmt:step() == sqlite3.ROW do
            table.insert(columns, {
                cid = stmt:get_value(0),
                name = stmt:get_value(1),
                type = stmt:get_value(2),
                notnull = stmt:get_value(3),
                dflt_value = stmt:get_value(4),
                pk = stmt:get_value(5)
            })
        end
        stmt:finalize()
    end

    return columns
end

--- Extract project metadata from Resolve database
-- @param db userdata: Resolve SQLite database handle
-- @return table|nil: Project metadata {name, width, height, frame_rate}
local function extract_project_metadata(db)
    -- Try common Resolve table names for project data
    local queries = {
        -- Resolve 18+ schema
        "SELECT name, width, height, timelineFrameRate as frame_rate FROM project LIMIT 1",
        -- Resolve 17 schema
        "SELECT projectName as name, width, height, fps as frame_rate FROM settings LIMIT 1",
        -- Generic fallback
        "SELECT * FROM project LIMIT 1"
    }

    for _, query in ipairs(queries) do
        local stmt = db:prepare(query)
        if stmt then
            if stmt:step() == sqlite3.ROW then
                local project = {
                    name = stmt:get_value(0) or "Untitled Project",
                    width = tonumber(stmt:get_value(1)) or 1920,
                    height = tonumber(stmt:get_value(2)) or 1080,
                    frame_rate = tonumber(stmt:get_value(3)) or 30.0
                }
                stmt:finalize()
                return project
            end
            stmt:finalize()
        end
    end

    -- Default fallback
    return {
        name = "Imported Resolve Project",
        width = 1920,
        height = 1080,
        frame_rate = 30.0
    }
end

--- Extract media items from Resolve database
-- @param db userdata: Resolve SQLite database handle
-- @return table: Array of media items {id, name, file_path, duration}
local function extract_media_items(db)
    local media_items = {}

    -- Try Resolve media pool table
    local queries = {
        -- Resolve 18+
        "SELECT id, name, filePath as file_path, duration FROM mediaPoolItem",
        -- Resolve 17
        "SELECT clipId as id, clipName as name, sourceFile as file_path, duration FROM clip",
        -- Generic
        "SELECT * FROM media"
    }

    for _, query in ipairs(queries) do
        local stmt = db:prepare(query)
        if stmt then
            while stmt:step() == sqlite3.ROW do
                local media_item = {
                    resolve_id = tostring(stmt:get_value(0) or ""),
                    name = stmt:get_value(1) or "Untitled",
                    file_path = stmt:get_value(2) or "",
                    duration = tonumber(stmt:get_value(3)) or 0
                }
                table.insert(media_items, media_item)
            end
            stmt:finalize()

            if #media_items > 0 then
                break  -- Found media, stop trying other queries
            end
        end
    end

    return media_items
end

--- Extract timelines from Resolve database
-- @param db userdata: Resolve SQLite database handle
-- @return table: Array of timelines {id, name, duration, frame_rate}
local function extract_timelines(db)
    local timelines = {}

    -- Try Resolve timeline table
    local queries = {
        -- Resolve 18+
        "SELECT id, name, duration, frameRate FROM timeline",
        -- Resolve 17
        "SELECT timelineId as id, name, duration, fps as frameRate FROM sequence",
        -- Generic
        "SELECT * FROM timelines"
    }

    for _, query in ipairs(queries) do
        local stmt = db:prepare(query)
        if stmt then
            while stmt:step() == sqlite3.ROW do
                local timeline = {
                    resolve_id = tostring(stmt:get_value(0) or ""),
                    name = stmt:get_value(1) or "Untitled Timeline",
                    duration = tonumber(stmt:get_value(2)) or 0,
                    frame_rate = tonumber(stmt:get_value(3)) or 30.0
                }
                table.insert(timelines, timeline)
            end
            stmt:finalize()

            if #timelines > 0 then
                break
            end
        end
    end

    return timelines
end

--- Extract tracks for a timeline
-- @param db userdata: Resolve SQLite database handle
-- @param timeline_id string: Resolve timeline ID
-- @return table: Array of tracks {id, type, index}
local function extract_tracks(db, timeline_id)
    local tracks = {}

    local queries = {
        -- Resolve 18+
        string.format([[
            SELECT id, trackType as type, trackIndex as index
            FROM track
            WHERE timelineId = '%s'
            ORDER BY trackType, trackIndex
        ]], timeline_id),
        -- Resolve 17
        string.format([[
            SELECT trackId as id, type, idx as index
            FROM tracks
            WHERE sequenceId = '%s'
            ORDER BY type, idx
        ]], timeline_id)
    }

    for _, query in ipairs(queries) do
        local stmt = db:prepare(query)
        if stmt then
            while stmt:step() == sqlite3.ROW do
                local track = {
                    resolve_id = tostring(stmt:get_value(0) or ""),
                    type = stmt:get_value(1) or "video",
                    index = tonumber(stmt:get_value(2)) or 1
                }

                -- Normalize track type
                if track.type:lower():find("video") or track.type == "v" then
                    track.type = "VIDEO"
                elseif track.type:lower():find("audio") or track.type == "a" then
                    track.type = "AUDIO"
                end

                table.insert(tracks, track)
            end
            stmt:finalize()

            if #tracks > 0 then
                break
            end
        end
    end

    return tracks
end

--- Extract clips for a track
-- @param db userdata: Resolve SQLite database handle
-- @param track_id string: Resolve track ID
-- @return table: Array of clips {name, start_value, duration, source_in, source_out, media_id}
local function extract_clips(db, track_id)
    local clips = {}

    local queries = {
        -- Resolve 18+
        string.format([[
            SELECT name, startTime, duration, sourceIn, sourceOut, mediaPoolItemId
            FROM clipItem
            WHERE trackId = '%s'
            ORDER BY startTime
        ]], track_id),
        -- Resolve 17
        string.format([[
            SELECT clipName as name, start as startTime, duration, inPoint as sourceIn,
                   outPoint as sourceOut, clipId as mediaPoolItemId
            FROM clips
            WHERE trackId = '%s'
            ORDER BY start
        ]], track_id)
    }

    for _, query in ipairs(queries) do
        local stmt = db:prepare(query)
        if stmt then
            while stmt:step() == sqlite3.ROW do
                local clip = {
                    name = stmt:get_value(0) or "Untitled Clip",
                    start_value = tonumber(stmt:get_value(1)) or 0,
                    duration = tonumber(stmt:get_value(2)) or 0,
                    source_in = tonumber(stmt:get_value(3)) or 0,
                    source_out = tonumber(stmt:get_value(4)) or 0,
                    resolve_media_id = tostring(stmt:get_value(5) or "")
                }
                table.insert(clips, clip)
            end
            stmt:finalize()

            if #clips > 0 then
                break
            end
        end
    end

    return clips
end

--- Main entry point: Import from Resolve SQLite database
-- @param db_path string: Path to Resolve .db file
-- @return table: Result with success flag and imported data
--   {
--     success = true/false,
--     error = "error message" (if failed),
--     project = {name, width, height, frame_rate},
--     media_items = {...},
--     timelines = {...}
--   }
function M.import_from_database(db_path)
    -- Open Resolve database
    local resolve_db, err = open_resolve_database(db_path)
    if not resolve_db then
        return {success = false, error = err}
    end

    -- Get schema version for debugging
    local schema_version = get_schema_version(resolve_db)
    print(string.format("Resolve database schema version: %d", schema_version))

    -- List tables for debugging
    local tables = list_tables(resolve_db)
    print(string.format("Found %d tables in Resolve database:", #tables))
    for _, table_name in ipairs(tables) do
        print(string.format("  - %s", table_name))
    end

    -- Extract project metadata
    local project = extract_project_metadata(resolve_db)
    print(string.format("Project: %s (%dx%d @ %.2ffps)",
        project.name, project.width, project.height, project.frame_rate))

    -- Extract media items
    local media_items = extract_media_items(resolve_db)
    print(string.format("Found %d media items", #media_items))

    -- Extract timelines with full structure
    local timelines = extract_timelines(resolve_db)
    print(string.format("Found %d timelines", #timelines))

    for _, timeline in ipairs(timelines) do
        -- Extract tracks for this timeline
        timeline.tracks = extract_tracks(resolve_db, timeline.resolve_id)
        print(string.format("  Timeline '%s': %d tracks", timeline.name, #timeline.tracks))

        -- Extract clips for each track
        for _, track in ipairs(timeline.tracks) do
            track.clips = extract_clips(resolve_db, track.resolve_id)
            print(string.format("    Track %s%d: %d clips", track.type, track.index, #track.clips))
        end
    end

    -- Close database
    resolve_db:close()

    return {
        success = true,
        project = project,
        media_items = media_items,
        timelines = timelines
    }
end

--- Analyze Resolve database schema (diagnostic tool)
-- @param db_path string: Path to Resolve .db file
-- @return table: Schema information for all tables
function M.analyze_schema(db_path)
    local db, err = open_resolve_database(db_path)
    if not db then
        return {success = false, error = err}
    end

    local schema = {}
    local tables = list_tables(db)

    for _, table_name in ipairs(tables) do
        schema[table_name] = get_table_schema(db, table_name)
    end

    db:close()

    return {success = true, schema = schema, table_count = #tables}
end

return M
