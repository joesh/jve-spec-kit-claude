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
-- Size: ~193 LOC
-- Volatility: unknown
--
-- @file sequence.lua
-- Original intent (unreviewed):
-- Lua representation of timeline sequences.
-- Mirrors the behaviour of the legacy C++ model closely enough for imports and commands.
local database = require("core.database")
local uuid = require("uuid")

local Sequence = {}
Sequence.__index = Sequence

local function resolve_db()
    local conn = database.get_connection()
    if not conn then
        error("Sequence: No database connection available")
    end
    return conn
end

local function validate_frame_rate(val)
    if type(val) == "number" and val > 0 then
        return { fps_numerator = math.floor(val), fps_denominator = 1 } -- Simple integer rate
    end
    if type(val) == "table" and val.fps_numerator and val.fps_denominator then
        return val
    end
    -- FAIL FAST: No silent fallbacks - frame rate is required
    error("Sequence: frame_rate is required (got " .. type(val) .. ")")
end

function Sequence.create(name, project_id, frame_rate, width, height, opts)
    assert(name and name ~= "", "Sequence.create: name is required")
    assert(project_id and project_id ~= "", "Sequence.create: project_id is required")

    local fr = validate_frame_rate(frame_rate)
    
    assert(type(width) == "number" and width > 0, "Sequence.create: width is required and must be positive")
    assert(type(height) == "number" and height > 0, "Sequence.create: height is required and must be positive")
    local w = math.floor(width)
    local h = math.floor(height)

    opts = opts or {}
    local now = os.time()

    -- Integer frame coordinates (fps is metadata in frame_rate)
    local playhead_pos = opts.playhead_frame or 0
    local viewport_start = opts.view_start_frame or 0
    -- Default viewport: 10 seconds worth of frames
    local viewport_dur = opts.view_duration_frames or math.floor(10.0 * fr.fps_numerator / fr.fps_denominator)

    local sequence = {
        id = opts.id or uuid.generate(),
        project_id = project_id,
        name = name,
        kind = opts.kind or "timeline",
        frame_rate = fr,
        width = w,
        height = h,
        audio_sample_rate = opts.audio_rate or 48000,

        -- Integer frame coordinates (fps is metadata in frame_rate)
        playhead_position = playhead_pos,
        viewport_start_time = viewport_start,
        viewport_duration = viewport_dur,

        mark_in = opts.mark_in_frame,   -- nil or integer
        mark_out = opts.mark_out_frame, -- nil or integer

        -- Selection state (JSON strings)
        selected_clip_ids_json = opts.selected_clip_ids_json or "[]",
        selected_edge_infos_json = opts.selected_edge_infos_json or "[]",

        created_at = opts.created_at or now,
        modified_at = opts.modified_at or now
    }

    return setmetatable(sequence, Sequence)
end

function Sequence.load(id)
    assert(id and id ~= "", "Sequence.load: id is required")

    local conn = resolve_db()
    if not conn then
        return nil
    end

            local stmt = conn:prepare([[
                SELECT id, project_id, name, kind, fps_numerator, fps_denominator, width, height,
                       playhead_frame, view_start_frame,
                       view_duration_frames, mark_in_frame, mark_out_frame, audio_rate,
                       selected_clip_ids, selected_edge_infos
                FROM sequences WHERE id = ?
            ]])
    
            assert(stmt, string.format("Sequence.load: failed to prepare query: %s", conn:last_error()))
    
            stmt:bind_value(1, id)
            if not stmt:exec() then
                local err = stmt:last_error()
                stmt:finalize()
                error(string.format("Sequence.load: query failed for %s: %s", id, tostring(err)))
            end
    
            if not stmt:next() then
                stmt:finalize()
                return nil
            end
    
            local fps_num = stmt:value(4)
            local fps_den = stmt:value(5)
            local audio_rate = stmt:value(13)
            local selected_clip_ids = stmt:value(14)  -- JSON string
            local selected_edge_infos = stmt:value(15)  -- JSON string

            local fr = { fps_numerator = fps_num, fps_denominator = fps_den }

            local sequence = {
                id = stmt:value(0),
                project_id = stmt:value(1),
                name = stmt:value(2),
                kind = stmt:value(3),
                frame_rate = fr,
                audio_sample_rate = audio_rate,
                width = stmt:value(6),
                height = stmt:value(7),

                -- Integer frame coordinates (fps is metadata in frame_rate)
                playhead_position = assert(stmt:value(8), "Sequence.load: playhead_frame is NULL for id=" .. tostring(id)),
                viewport_start_time = assert(stmt:value(9), "Sequence.load: view_start_frame is NULL for id=" .. tostring(id)),
                viewport_duration = assert(stmt:value(10), "Sequence.load: view_duration_frames is NULL for id=" .. tostring(id)),

                -- Selection state (JSON strings from database)
                selected_clip_ids_json = selected_clip_ids,  -- Let caller parse JSON
                selected_edge_infos_json = selected_edge_infos,

                created_at = os.time(),
                modified_at = os.time()
            }

            -- Optional Marks (integer frames or nil)
            sequence.mark_in = stmt:value(11)
            sequence.mark_out = stmt:value(12)
    stmt:finalize()
    return setmetatable(sequence, Sequence)
end

function Sequence:save()
    assert(self and self.id and self.id ~= "", "Sequence.save: invalid sequence or missing id")
    assert(self.project_id and self.project_id ~= "", "Sequence.save: project_id is required")

    local conn = resolve_db()
    if not conn then
        return false
    end

    self.modified_at = os.time()

    -- Coordinates are now plain integers
    local db_fps_num = self.frame_rate.fps_numerator
    local db_fps_den = self.frame_rate.fps_denominator

    local db_playhead = self.playhead_position
    local db_view_start = self.viewport_start_time
    local db_view_dur = self.viewport_duration

    local db_mark_in = self.mark_in  -- nil or integer
    local db_mark_out = self.mark_out  -- nil or integer
    
    assert(self.audio_sample_rate, "Sequence.save: audio_sample_rate is required for sequence " .. tostring(self.id))
    local db_audio_rate = self.audio_sample_rate

    -- CRITICAL: Use ON CONFLICT DO UPDATE instead of INSERT OR REPLACE
    -- INSERT OR REPLACE triggers DELETE first, which cascades to delete clips via foreign keys!
    local stmt = conn:prepare([[
        INSERT INTO sequences
        (id, project_id, name, kind, fps_numerator, fps_denominator, width, height,
         playhead_frame, view_start_frame, view_duration_frames, mark_in_frame, mark_out_frame, audio_rate,
         selected_clip_ids, selected_edge_infos,
         created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id,
            name = excluded.name,
            kind = excluded.kind,
            fps_numerator = excluded.fps_numerator,
            fps_denominator = excluded.fps_denominator,
            width = excluded.width,
            height = excluded.height,
            playhead_frame = excluded.playhead_frame,
            view_start_frame = excluded.view_start_frame,
            view_duration_frames = excluded.view_duration_frames,
            mark_in_frame = excluded.mark_in_frame,
            mark_out_frame = excluded.mark_out_frame,
            audio_rate = excluded.audio_rate,
            selected_clip_ids = excluded.selected_clip_ids,
            selected_edge_infos = excluded.selected_edge_infos,
            modified_at = excluded.modified_at
    ]])

    if not stmt then
        local err = conn.last_error and conn:last_error() or "unknown error"
        error("Sequence.save: failed to prepare insert statement: " .. err)
    end

    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.project_id)
    stmt:bind_value(3, self.name)
    stmt:bind_value(4, self.kind or "timeline")
    stmt:bind_value(5, db_fps_num)
    stmt:bind_value(6, db_fps_den)
    stmt:bind_value(7, self.width)
    stmt:bind_value(8, self.height)
    stmt:bind_value(9, db_playhead)
    stmt:bind_value(10, db_view_start)
    stmt:bind_value(11, db_view_dur)
    
    if db_mark_in then 
        stmt:bind_value(12, db_mark_in) 
    else 
        if stmt.bind_null then
            stmt:bind_null(12) 
        else
            stmt:bind_value(12, nil)
        end
    end
    
    if db_mark_out then 
        stmt:bind_value(13, db_mark_out) 
    else 
        if stmt.bind_null then
            stmt:bind_null(13)
        else
            stmt:bind_value(13, nil)
        end
    end
    
    stmt:bind_value(14, db_audio_rate)
    stmt:bind_value(15, self.selected_clip_ids_json or "")
    stmt:bind_value(16, self.selected_edge_infos_json or "")
    stmt:bind_value(17, self.created_at or os.time())
    stmt:bind_value(18, self.modified_at)

    local ok = stmt:exec()
    if not ok then
        local err = stmt:last_error()
        stmt:finalize()
        error(string.format("Sequence.save: failed for %s: %s", tostring(self.id), tostring(err)))
    end

    stmt:finalize()
    return ok
end

-- Count all sequences in the database
function Sequence.count()
    local database = require("core.database")
    local conn = assert(database.get_connection(), "Sequence.count: no database connection")
    local stmt = assert(conn:prepare("SELECT COUNT(*) FROM sequences"), "Sequence.count: failed to prepare query")
    assert(stmt:exec(), "Sequence.count: query execution failed")
    assert(stmt:next(), "Sequence.count: no result row")
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

-- Ensure a default sequence exists for a project, creating one if needed
-- Returns the default sequence (existing or newly created)
function Sequence.ensure_default(project_id)
    assert(project_id, "Sequence.ensure_default: project_id is required")

    local existing = Sequence.load("default_sequence")
    if existing then
        return existing
    end

    -- Create default sequence with standard settings
    local frame_rate = {fps_numerator = 30, fps_denominator = 1}
    local sequence = Sequence.create("Default Sequence", project_id, frame_rate, 1920, 1080, {
        id = "default_sequence",
        audio_rate = 48000
    })
    if sequence and sequence:save() then
        return sequence
    end
    return nil
end

-- Find the most recently modified sequence in the database
-- Returns sequence object, or nil if none exist
function Sequence.find_most_recent()
    local conn = resolve_db()

    local stmt = assert(conn:prepare([[
        SELECT id FROM sequences
        ORDER BY modified_at DESC, created_at DESC, id ASC
        LIMIT 1
    ]]), "Sequence.find_most_recent: failed to prepare query")

    if not stmt:exec() or not stmt:next() then
        stmt:finalize()
        return nil
    end

    local id = stmt:value(0)
    stmt:finalize()

    if not id or id == "" then
        return nil
    end

    return Sequence.load(id)
end

-- =============================================================================
-- MASTERCLIP SEQUENCE METHODS (for kind="masterclip")
-- =============================================================================

--- Check if this is a masterclip sequence (appears in project browser as source)
-- @return boolean true if kind == "masterclip"
function Sequence:is_masterclip()
    return self.kind == "masterclip"
end

--- Ensure stream clips are loaded and cached for this masterclip sequence
-- Asserts if called on non-masterclip sequence
-- @return table {video_clips = {...}, audio_clips = {...}}
local function ensure_stream_clips(self)
    assert(self.kind == "masterclip", string.format(
        "Sequence.ensure_stream_clips: sequence %s is not a masterclip (kind=%s)",
        tostring(self.id), tostring(self.kind)))

    -- Check cache
    if self._cached_stream_clips then
        return self._cached_stream_clips
    end

    local Track = require("models.track")
    local Clip = require("models.clip")
    local conn = resolve_db()

    -- Get all tracks in this sequence
    local video_tracks = Track.find_by_sequence(self.id, "VIDEO")
    local audio_tracks = Track.find_by_sequence(self.id, "AUDIO")

    local video_clips = {}
    local audio_clips = {}

    -- Find clips on video tracks (for masterclip, just get all clips on track)
    for _, track in ipairs(video_tracks) do
        local stmt = conn:prepare([[
            SELECT id FROM clips
            WHERE track_id = ?
            ORDER BY timeline_start_frame ASC
        ]])
        assert(stmt, "Sequence.ensure_stream_clips: Failed to prepare video query")
        stmt:bind_value(1, track.id)
        local exec_ok = stmt:exec()
        assert(exec_ok, string.format(
            "Sequence.ensure_stream_clips: video query exec failed for track_id=%s",
            tostring(track.id)))
        while stmt:next() do
            local clip_id = stmt:value(0)
            local clip = Clip.load(clip_id)
            assert(clip, string.format(
                "Sequence.ensure_stream_clips: Failed to load video stream clip %s",
                tostring(clip_id)))
            video_clips[#video_clips + 1] = clip
        end
        stmt:finalize()
    end

    -- Find clips on audio tracks
    for _, track in ipairs(audio_tracks) do
        local stmt = conn:prepare([[
            SELECT id FROM clips
            WHERE track_id = ?
            ORDER BY timeline_start_frame ASC
        ]])
        assert(stmt, "Sequence.ensure_stream_clips: Failed to prepare audio query")
        stmt:bind_value(1, track.id)
        local exec_ok = stmt:exec()
        assert(exec_ok, string.format(
            "Sequence.ensure_stream_clips: audio query exec failed for track_id=%s",
            tostring(track.id)))
        while stmt:next() do
            local clip_id = stmt:value(0)
            local clip = Clip.load(clip_id)
            assert(clip, string.format(
                "Sequence.ensure_stream_clips: Failed to load audio stream clip %s",
                tostring(clip_id)))
            audio_clips[#audio_clips + 1] = clip
        end
        stmt:finalize()
    end

    local result = {
        video_clips = video_clips,
        audio_clips = audio_clips,
    }

    -- Cache for subsequent calls
    self._cached_stream_clips = result
    return result
end

--- Get the video stream clip from this masterclip sequence
-- Asserts if called on non-masterclip sequence
-- @return Clip|nil Video clip or nil if no video stream exists
function Sequence:video_stream()
    local streams = ensure_stream_clips(self)
    return streams.video_clips[1]
end

--- Get all audio stream clips from this masterclip sequence
-- Asserts if called on non-masterclip sequence
-- @return table Array of audio clips (may be empty)
function Sequence:audio_streams()
    local streams = ensure_stream_clips(self)
    return streams.audio_clips
end

--- Get the number of audio streams
-- @return number Count of audio streams
function Sequence:num_audio_streams()
    return #self:audio_streams()
end

--- Invalidate the cached stream clips (call after modifying stream clips)
function Sequence:invalidate_stream_cache()
    self._cached_stream_clips = nil
end

-- =============================================================================
-- TIMEBASE CONVERSION (for masterclip sequences)
-- =============================================================================

--- Convert video frames to audio samples using this sequence's video rate
-- and the first audio stream's sample rate
-- @param frame number Frame position in video timebase
-- @return number|nil Sample position, or nil if no audio stream
function Sequence:frame_to_samples(frame)
    assert(type(frame) == "number", "Sequence:frame_to_samples: frame must be a number")

    local audio = self:audio_streams()[1]
    if not audio then
        return nil
    end

    -- audio.rate.fps_numerator = sample_rate (e.g., 48000, 44100, 96000)
    -- audio.rate.fps_denominator = 1
    -- self.frame_rate.fps_numerator = video fps numerator
    -- self.frame_rate.fps_denominator = video fps denominator
    local sample_rate = audio.rate.fps_numerator
    local video_fps_num = self.frame_rate.fps_numerator
    local video_fps_den = self.frame_rate.fps_denominator

    -- samples = frame * (sample_rate / video_fps)
    --         = frame * sample_rate * video_fps_den / video_fps_num
    return math.floor(frame * sample_rate * video_fps_den / video_fps_num)
end

--- Convert audio samples to video frames using this sequence's video rate
-- and the first audio stream's sample rate
-- @param samples number Sample position in audio timebase
-- @return number|nil Frame position, or nil if no audio stream
function Sequence:samples_to_frame(samples)
    assert(type(samples) == "number", "Sequence:samples_to_frame: samples must be a number")

    local audio = self:audio_streams()[1]
    if not audio then
        return nil
    end

    local sample_rate = audio.rate.fps_numerator
    local video_fps_num = self.frame_rate.fps_numerator
    local video_fps_den = self.frame_rate.fps_denominator

    -- frame = samples * video_fps / sample_rate
    --       = samples * video_fps_num / (video_fps_den * sample_rate)
    return math.floor(samples * video_fps_num / (video_fps_den * sample_rate))
end

-- =============================================================================
-- STREAM MARK METHODS (set/get source_in/source_out on stream clips)
-- =============================================================================

--- Set in point for all streams in sync
-- Asserts if called on non-masterclip sequence
-- Video stream gets frame value; audio streams get converted sample value
-- @param frame number Frame position in video timebase
function Sequence:set_all_streams_in(frame)
    assert(type(frame) == "number", "Sequence:set_all_streams_in: frame must be a number")
    assert(self:is_masterclip(), string.format(
        "Sequence:set_all_streams_in: sequence %s is not a masterclip", tostring(self.id)))

    local video = self:video_stream()
    local audio_streams = self:audio_streams()

    -- Must have at least one stream
    assert(video or #audio_streams > 0, string.format(
        "Sequence:set_all_streams_in: masterclip %s has no streams", tostring(self.id)))

    if video then
        video.source_in = frame
        video:save()
    end

    local samples = self:frame_to_samples(frame)
    if samples then
        for _, audio in ipairs(audio_streams) do
            audio.source_in = samples
            audio:save()
        end
    end

    -- Invalidate cache since we modified stream clips
    self:invalidate_stream_cache()
end

--- Set out point for all streams in sync
-- Asserts if called on non-masterclip sequence
-- Video stream gets frame value; audio streams get converted sample value
-- @param frame number Frame position in video timebase
function Sequence:set_all_streams_out(frame)
    assert(type(frame) == "number", "Sequence:set_all_streams_out: frame must be a number")
    assert(self:is_masterclip(), string.format(
        "Sequence:set_all_streams_out: sequence %s is not a masterclip", tostring(self.id)))

    local video = self:video_stream()
    local audio_streams = self:audio_streams()

    -- Must have at least one stream
    assert(video or #audio_streams > 0, string.format(
        "Sequence:set_all_streams_out: masterclip %s has no streams", tostring(self.id)))

    if video then
        video.source_out = frame
        video:save()
    end

    local samples = self:frame_to_samples(frame)
    if samples then
        for _, audio in ipairs(audio_streams) do
            audio.source_out = samples
            audio:save()
        end
    end

    -- Invalidate cache since we modified stream clips
    self:invalidate_stream_cache()
end

--- Get the synced in point for all streams (video frame value)
-- Asserts if called on non-masterclip sequence
-- For A/V: Returns video stream's source_in if all streams synchronized
-- For audio-only: Returns nil (no video frame reference)
-- @return number|nil Video frame position, or nil if not synced or audio-only
function Sequence:get_all_streams_in()
    assert(self:is_masterclip(), string.format(
        "Sequence:get_all_streams_in: sequence %s is not a masterclip", tostring(self.id)))

    local video = self:video_stream()
    if not video then
        return nil  -- Audio-only: no video frame reference
    end

    local video_in = video.source_in
    local expected_samples = self:frame_to_samples(video_in)

    if expected_samples then
        for _, audio in ipairs(self:audio_streams()) do
            if audio.source_in ~= expected_samples then
                return nil  -- Not synced
            end
        end
    end

    return video_in
end

--- Get the synced out point for all streams (video frame value)
-- Asserts if called on non-masterclip sequence
-- For A/V: Returns video stream's source_out if all streams synchronized
-- For audio-only: Returns nil (no video frame reference)
-- @return number|nil Video frame position, or nil if not synced or audio-only
function Sequence:get_all_streams_out()
    assert(self:is_masterclip(), string.format(
        "Sequence:get_all_streams_out: sequence %s is not a masterclip", tostring(self.id)))

    local video = self:video_stream()
    if not video then
        return nil  -- Audio-only: no video frame reference
    end

    local video_out = video.source_out
    local expected_samples = self:frame_to_samples(video_out)

    if expected_samples then
        for _, audio in ipairs(self:audio_streams()) do
            if audio.source_out ~= expected_samples then
                return nil  -- Not synced
            end
        end
    end

    return video_out
end

return Sequence