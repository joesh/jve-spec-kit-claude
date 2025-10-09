-- Snapshot Manager Module
-- Handles periodic state snapshots for fast event replay
-- Part of the event sourcing architecture

local M = {}

-- Configuration
M.SNAPSHOT_INTERVAL = 50  -- Create snapshot every N commands

-- Generate UUID for snapshots
local function generate_uuid()
    local random = math.random
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and random(0, 0xf) or random(8, 0xb)
        return string.format('%x', v)
    end)
end

-- Serialize clips array to JSON
-- Takes an array of clip objects and returns a JSON string
function M.serialize_clips(clips)
    if not clips or #clips == 0 then
        return "[]"
    end

    local clip_data = {}
    for _, clip in ipairs(clips) do
        table.insert(clip_data, {
            id = clip.id,
            track_id = clip.track_id,
            media_id = clip.media_id,
            start_time = clip.start_time,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out,
            enabled = clip.enabled and 1 or 0,
            name = clip.name or ""
        })
    end

    -- Use Qt's JSON encoder (available via qt_json_encode binding)
    local success, json_str = pcall(qt_json_encode, clip_data)
    if success then
        return json_str
    else
        print("WARNING: Failed to serialize clips: " .. tostring(json_str))
        return "[]"
    end
end

-- Deserialize JSON back to clips array
-- Takes a JSON string and returns an array of clip objects
function M.deserialize_clips(json_str)
    if not json_str or json_str == "" or json_str == "[]" then
        return {}
    end

    local success, clip_data = pcall(qt_json_decode, json_str)
    if not success then
        print("WARNING: Failed to deserialize clips: " .. tostring(clip_data))
        return {}
    end

    -- Convert plain tables back to Clip objects
    local Clip = require('models.clip')
    local clips = {}
    for _, data in ipairs(clip_data) do
        local clip = Clip.create(data.name or "", data.media_id)
        clip.id = data.id
        clip.track_id = data.track_id
        clip.start_time = data.start_time
        clip.duration = data.duration
        clip.source_in = data.source_in
        clip.source_out = data.source_out
        clip.enabled = (data.enabled == 1)
        table.insert(clips, clip)
    end

    return clips
end

-- Create a snapshot of current state
-- Saves clips state at a specific sequence number
function M.create_snapshot(db, sequence_id, sequence_number, clips)
    if not db or not sequence_id then
        print("WARNING: create_snapshot: Missing required parameters")
        return false
    end

    print(string.format("Creating snapshot at sequence %d with %d clips",
        sequence_number, #clips))

    -- Serialize clips to JSON
    local clips_json = M.serialize_clips(clips)

    -- Delete any existing snapshot for this sequence (we only keep the latest)
    local delete_query = db:prepare("DELETE FROM snapshots WHERE sequence_id = ?")
    if delete_query then
        delete_query:bind_value(1, sequence_id)
        delete_query:exec()
    end

    -- Insert new snapshot
    local query = db:prepare([[
        INSERT INTO snapshots (id, sequence_id, sequence_number, clips_state, created_at)
        VALUES (?, ?, ?, ?, ?)
    ]])

    if not query then
        print("WARNING: create_snapshot: Failed to prepare insert query")
        return false
    end

    query:bind_value(1, generate_uuid())
    query:bind_value(2, sequence_id)
    query:bind_value(3, sequence_number)
    query:bind_value(4, clips_json)
    query:bind_value(5, os.time())

    if not query:exec() then
        print("WARNING: create_snapshot: Failed to insert snapshot")
        return false
    end

    print(string.format("✅ Snapshot created at sequence %d", sequence_number))
    return true
end

-- Load the most recent snapshot for a sequence
-- Returns: {sequence_number, clips} or nil if no snapshot exists
function M.load_snapshot(db, sequence_id)
    if not db or not sequence_id then
        print("WARNING: load_snapshot: Missing required parameters")
        return nil
    end

    local query = db:prepare([[
        SELECT sequence_number, clips_state
        FROM snapshots
        WHERE sequence_id = ?
        LIMIT 1
    ]])

    if not query then
        print("WARNING: load_snapshot: Failed to prepare query")
        return nil
    end

    query:bind_value(1, sequence_id)

    if not query:exec() or not query:next() then
        print("No snapshot found for sequence: " .. sequence_id)
        return nil
    end

    local sequence_number = query:value(0)
    local clips_json = query:value(1)

    print(string.format("Loading snapshot from sequence %d", sequence_number))

    local clips = M.deserialize_clips(clips_json)
    print(string.format("✅ Loaded snapshot with %d clips", #clips))

    return {
        sequence_number = sequence_number,
        clips = clips
    }
end

-- Check if we should create a snapshot after this command
function M.should_snapshot(sequence_number)
    return sequence_number > 0 and (sequence_number % M.SNAPSHOT_INTERVAL == 0)
end

return M
