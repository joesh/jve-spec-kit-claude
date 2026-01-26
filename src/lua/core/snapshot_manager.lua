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
-- Size: ~408 LOC
-- Volatility: unknown
--
-- @file snapshot_manager.lua
-- Original intent (unreviewed):
-- Snapshot Manager Module
-- Handles periodic state snapshots for fast event replay
-- Part of the event sourcing architecture
local uuid = require("uuid")
local Rational = require("core.rational")
local asserts = require("core.asserts")

local M = {}

-- Configuration
M.SNAPSHOT_INTERVAL = 50  -- Create snapshot every N commands

local function ensure_snapshots_table(db)
    if not db then
        return false
    end

    local ok = db:exec([[
        CREATE TABLE IF NOT EXISTS snapshots (
            id TEXT PRIMARY KEY,
            sequence_id TEXT NOT NULL,
            sequence_number INTEGER NOT NULL,
            clips_state TEXT NOT NULL,
            created_at INTEGER NOT NULL
        )
    ]])

    if not ok then
        print("WARNING: snapshot_manager: Failed to ensure snapshots table")
    end

    return ok
end

local function require_field(context, entity, field, value)
    assert(value ~= nil, string.format("snapshot_manager.%s: %s missing required field '%s'", context, entity, field))
    return value
end

local function fetch_sequence_record(db, sequence_id)
    local query = db:prepare([[
        SELECT id, project_id, name, kind,
               fps_numerator, fps_denominator, audio_rate,
               width, height,
               view_start_frame, view_duration_frames, playhead_frame,
               mark_in_frame, mark_out_frame,
               selected_clip_ids, selected_edge_infos, selected_gap_infos,
               current_sequence_number
        FROM sequences
        WHERE id = ?
    ]])

    if not query then
        error("snapshot_manager.fetch_sequence_record: Failed to prepare sequence query")
    end

    query:bind_value(1, sequence_id)

    local record = nil
    if query:exec() and query:next() then
        record = {
            id = query:value(0),
            project_id = query:value(1),
            name = query:value(2),
            kind = query:value(3),
            fps_numerator = query:value(4),
            fps_denominator = query:value(5),
            audio_rate = query:value(6),
            width = query:value(7),
            height = query:value(8),
            view_start_frame = query:value(9),
            view_duration_frames = query:value(10),
            playhead_frame = query:value(11),
            mark_in_frame = query:value(12),
            mark_out_frame = query:value(13),
            selected_clip_ids = query:value(14),
            selected_edge_infos = query:value(15),
            selected_gap_infos = query:value(16),
            current_sequence_number = query:value(17)
        }
    end

    query:finalize()

    if not record then
        error(string.format("snapshot_manager.fetch_sequence_record: Sequence %s not found", tostring(sequence_id)))
    end

    return record
end

local function fetch_tracks(db, sequence_id)
    local query = db:prepare([[
        SELECT id, sequence_id, name, track_type, track_index,
               enabled, locked, muted, soloed, volume, pan
        FROM tracks
        WHERE sequence_id = ?
        ORDER BY track_type, track_index
    ]])

    if not query then
        error("snapshot_manager.fetch_tracks: Failed to prepare track query")
    end

    query:bind_value(1, sequence_id)

    local tracks = {}
    if query:exec() then
        while query:next() do
            tracks[#tracks + 1] = {
                id = query:value(0),
                sequence_id = query:value(1),
                name = query:value(2),
                track_type = query:value(3),
                track_index = query:value(4),
                enabled = query:value(5),
                locked = query:value(6),
                muted = query:value(7),
                soloed = query:value(8),
                volume = query:value(9),
                pan = query:value(10)
            }
        end
    end

    query:finalize()
    return tracks
end

local function build_snapshot_payload(db, sequence_id, clips)
    local database = require('core.database')
    local ok, media_items = pcall(database.load_media)
    if not ok then
        error(string.format("snapshot_manager.build_snapshot_payload: failed to load media library: %s", tostring(media_items)))
    end

    local media_lookup = {}
    for _, media in ipairs(media_items) do
        media_lookup[media.id] = media
    end

    local sequence_record = fetch_sequence_record(db, sequence_id)
    local tracks = fetch_tracks(db, sequence_id)

    local media_data_lookup = {}
    local clip_data = {}
    for _, clip in ipairs(clips) do
        require_field("build_snapshot_payload", "clip", "id", clip.id)
        require_field("build_snapshot_payload", "clip", "clip_kind", clip.clip_kind)
        -- V5: Use Rational properties
        -- Ensure we extract frames/ticks for storage
        local start_frame = clip.timeline_start and clip.timeline_start.frames
        local dur_frames = clip.duration and clip.duration.frames
        local src_in_frame = clip.source_in and clip.source_in.frames
        local src_out_frame = clip.source_out and clip.source_out.frames
        
        -- Fallback for missing Rational objects (should be caught by require_field ideally)
        if not start_frame then start_frame = 0 end -- Error?
        
        table.insert(clip_data, {
            id = clip.id,
            clip_kind = clip.clip_kind,
            name = clip.name or "",
            project_id = clip.project_id,
            track_id = clip.track_id,
            owner_sequence_id = clip.owner_sequence_id,
            parent_clip_id = clip.parent_clip_id,
            source_sequence_id = clip.source_sequence_id,
            media_id = clip.media_id,
            
            timeline_start_frame = start_frame,
            duration_frames = dur_frames,
            source_in_frame = src_in_frame,
            source_out_frame = src_out_frame,
            
            fps_numerator = clip.rate and clip.rate.fps_numerator,
            fps_denominator = clip.rate and clip.rate.fps_denominator,
            
            enabled = clip.enabled and 1 or 0,
            offline = clip.offline and 1 or 0
        })

        if clip.media_id and clip.media_id ~= "" then
            local media = media_lookup[clip.media_id]
            if media and not media_data_lookup[clip.media_id] then
                media_data_lookup[clip.media_id] = {
                    id = media.id,
                    project_id = media.project_id,
                    name = media.name,
                    file_path = media.file_path,
                    duration_frames = media.duration and media.duration.frames,
                    fps_numerator = media.frame_rate and media.frame_rate.fps_numerator,
                    fps_denominator = media.frame_rate and media.frame_rate.fps_denominator,
                    width = media.width,
                    height = media.height,
                    audio_channels = media.audio_channels,
                    codec = media.codec,
                    metadata = media.metadata,
                    created_at = media.created_at,
                    modified_at = media.modified_at
                }
            end
        end
    end

    local media_data = {}
    for _, media in pairs(media_data_lookup) do
        table.insert(media_data, media)
    end

    return {
        sequence = sequence_record,
        tracks = tracks,
        clips = clip_data,
        media = media_data
    }
end

local function serialize_snapshot_payload(payload)
    local success, json_str = pcall(qt_json_encode, payload)
    if success then
        return json_str
    else
        error("snapshot_manager.serialize_snapshot_payload: Failed to encode snapshot payload: " .. tostring(json_str))
    end
end

local function deserialize_snapshot_payload(json_str)
    if not json_str or json_str == "" or json_str == "[]" then
        return {
            sequence = nil,
            tracks = {},
            clips = {},
            media = {}
        }
    end

    local success, payload = pcall(qt_json_decode, json_str)
    if not success then
        error("snapshot_manager.deserialize_snapshot_payload: Failed to decode snapshot payload: " .. tostring(payload))
    end

    if type(payload) ~= "table" then
        error("snapshot_manager.deserialize_snapshot_payload: Snapshot payload is not a table")
    end

    if payload.sequence then
        require_field("deserialize_snapshot_payload", "sequence", "id", payload.sequence.id)
        require_field("deserialize_snapshot_payload", "sequence", "project_id", payload.sequence.project_id)
        require_field("deserialize_snapshot_payload", "sequence", "name", payload.sequence.name)
        require_field("deserialize_snapshot_payload", "sequence", "kind", payload.sequence.kind)
        require_field("deserialize_snapshot_payload", "sequence", "fps_numerator", payload.sequence.fps_numerator)
        require_field("deserialize_snapshot_payload", "sequence", "fps_denominator", payload.sequence.fps_denominator)
        require_field("deserialize_snapshot_payload", "sequence", "audio_rate", payload.sequence.audio_rate)
        require_field("deserialize_snapshot_payload", "sequence", "width", payload.sequence.width)
        require_field("deserialize_snapshot_payload", "sequence", "height", payload.sequence.height)
        require_field("deserialize_snapshot_payload", "sequence", "view_start_frame", payload.sequence.view_start_frame)
        require_field("deserialize_snapshot_payload", "sequence", "view_duration_frames", payload.sequence.view_duration_frames)
        require_field("deserialize_snapshot_payload", "sequence", "playhead_frame", payload.sequence.playhead_frame)
    end

    local tracks = {}
    if payload.tracks then
        for _, track in ipairs(payload.tracks) do
            require_field("deserialize_snapshot_payload", "track", "id", track.id)
            require_field("deserialize_snapshot_payload", "track", "sequence_id", track.sequence_id)
            require_field("deserialize_snapshot_payload", "track", "name", track.name)
            require_field("deserialize_snapshot_payload", "track", "track_type", track.track_type)
            require_field("deserialize_snapshot_payload", "track", "track_index", track.track_index)
            tracks[#tracks + 1] = {
                id = track.id,
                sequence_id = track.sequence_id,
                name = track.name,
                track_type = track.track_type,
                track_index = track.track_index,
                enabled = track.enabled,
                locked = track.locked,
                muted = track.muted,
                soloed = track.soloed,
                volume = track.volume,
                pan = track.pan
            }
        end
    end

    local clips = {}
    if payload.clips then
        for _, data in ipairs(payload.clips) do
            require_field("deserialize_snapshot_payload", "clip", "id", data.id)
            require_field("deserialize_snapshot_payload", "clip", "clip_kind", data.clip_kind)
            
            assert(data.fps_numerator, "deserialize_snapshot_payload: clip " .. data.id .. " missing fps_numerator")
            assert(data.fps_denominator, "deserialize_snapshot_payload: clip " .. data.id .. " missing fps_denominator")
            local num = data.fps_numerator
            local den = data.fps_denominator
            
            clips[#clips + 1] = {
                id = data.id,
                clip_kind = data.clip_kind,
                name = data.name,
                project_id = data.project_id,
                owner_sequence_id = data.owner_sequence_id,
                parent_clip_id = data.parent_clip_id,
                source_sequence_id = data.source_sequence_id,
                track_id = data.track_id,
                media_id = data.media_id,
                
                timeline_start = Rational.new(data.timeline_start_frame or 0, num, den),
                duration = Rational.new(data.duration_frames or 0, num, den),
                source_in = Rational.new(data.source_in_frame or 0, num, den),
                source_out = Rational.new(data.source_out_frame or 0, num, den),
                
                rate = { fps_numerator = num, fps_denominator = den },
                
                enabled = data.enabled == 1,
                offline = data.offline == 1
            }
        end
    end

    local media = {}
    if payload.media then
        for _, media_data in ipairs(payload.media) do
            require_field("deserialize_snapshot_payload", "media", "id", media_data.id)
            
            local num = require_field("deserialize_snapshot_payload", "media", "fps_numerator", media_data.fps_numerator)
            local den = require_field("deserialize_snapshot_payload", "media", "fps_denominator", media_data.fps_denominator)
            
            media[#media + 1] = {
                id = media_data.id,
                project_id = media_data.project_id,
                name = media_data.name,
                file_path = media_data.file_path,
                
                duration = Rational.new(media_data.duration_frames or 0, num, den),
                frame_rate = { fps_numerator = num, fps_denominator = den },
                
                width = media_data.width,
                height = media_data.height,
                audio_channels = media_data.audio_channels,
                codec = media_data.codec,
                metadata = media_data.metadata,
                created_at = media_data.created_at,
                modified_at = media_data.modified_at
            }
        end
    end

    return {
        sequence = payload.sequence,
        tracks = tracks,
        clips = clips,
        media = media
    }
end

-- Create a snapshot of current state
-- Saves clips state at a specific sequence number
function M.create_snapshot(db, sequence_id, sequence_number, clips)
    if asserts.enabled() then
        assert(db ~= nil and sequence_id ~= nil and sequence_number ~= nil and clips ~= nil, "snapshot_manager.create_snapshot: missing required parameters")
    elseif (not db) or (not sequence_id) or (sequence_number == nil) or (clips == nil) then
        return false
    end

    ensure_snapshots_table(db)

    print(string.format("Creating snapshot at sequence %d with %d clips",
        sequence_number, #clips))

    -- Build snapshot payload (sequence + tracks + clips + media)
    local payload = build_snapshot_payload(db, sequence_id, clips)
    local snapshot_json = serialize_snapshot_payload(payload)

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

    query:bind_value(1, uuid.generate())
    query:bind_value(2, sequence_id)
    query:bind_value(3, sequence_number)
    query:bind_value(4, snapshot_json)
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
    if asserts.enabled() then
        assert(db ~= nil and sequence_id ~= nil, "snapshot_manager.load_snapshot: missing required parameters")
    elseif (not db) or (not sequence_id) then
        return nil
    end

    ensure_snapshots_table(db)

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

    local snapshot_state = deserialize_snapshot_payload(clips_json)
    local clips = snapshot_state.clips or {}
    print(string.format("✅ Loaded snapshot with %d clips", #clips))

    return {
        sequence_number = sequence_number,
        sequence = snapshot_state.sequence,
        tracks = snapshot_state.tracks or {},
        clips = clips,
        media = snapshot_state.media or {}
    }
end

function M.load_project_snapshots(db, project_id, target_sequence_number, exclude_sequence_id)
    if not db or not project_id then
        return {}
    end

    ensure_snapshots_table(db)

    local query = db:prepare([[
        SELECT s.sequence_id, s.sequence_number, s.clips_state
        FROM snapshots s
        JOIN sequences seq ON seq.id = s.sequence_id
        WHERE seq.project_id = ? AND s.sequence_number <= ?
    ]])

    if not query then
        print("WARNING: load_project_snapshots: Failed to prepare query")
        return {}
    end

    query:bind_value(1, project_id)
    query:bind_value(2, target_sequence_number or 0)

    local snapshots = {}
    if query:exec() then
        while query:next() do
            local seq_id = query:value(0)
            if seq_id ~= exclude_sequence_id then
                local seq_number = query:value(1)
                local payload_json = query:value(2)
                local state = deserialize_snapshot_payload(payload_json)
                snapshots[seq_id] = {
                    sequence_number = seq_number,
                    sequence = state.sequence,
                    tracks = state.tracks or {},
                    clips = state.clips or {},
                    media = state.media or {}
                }
            end
        end
    end

    query:finalize()
    return snapshots
end

-- Check if we should create a snapshot after this command
function M.should_snapshot(sequence_number)
    return sequence_number > 0 and (sequence_number % M.SNAPSHOT_INTERVAL == 0)
end

return M
