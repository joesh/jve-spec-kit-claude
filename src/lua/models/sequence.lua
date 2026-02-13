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
    local db = require("core.database")
    local conn = assert(db.get_connection(), "Sequence.count: no database connection")
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

    -- Filter out masterclip sequences - only return timeline sequences
    local stmt = assert(conn:prepare([[
        SELECT id FROM sequences
        WHERE kind IS NULL OR kind != 'masterclip'
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
-- MARK METHODS (read/write sequence-level mark_in/mark_out)
-- =============================================================================
-- Marks are UI metadata stored on the sequence record (mark_in_frame,
-- mark_out_frame columns). Stream clips keep source_in=0, source_out=full
-- always — marks do NOT constrain the rendering view.

--- Set mark-in point (video frame units). Masterclip only.
-- @param frame number Frame position in video timebase
function Sequence:set_in(frame)
    assert(type(frame) == "number", "Sequence:set_in: frame must be a number")
    assert(self:is_masterclip(), string.format(
        "Sequence:set_in: sequence %s is not a masterclip", tostring(self.id)))
    self.mark_in = frame
    self:save()
end

--- Set mark-out point (video frame units). Masterclip only.
-- @param frame number Frame position in video timebase
function Sequence:set_out(frame)
    assert(type(frame) == "number", "Sequence:set_out: frame must be a number")
    assert(self:is_masterclip(), string.format(
        "Sequence:set_out: sequence %s is not a masterclip", tostring(self.id)))
    self.mark_out = frame
    self:save()
end

--- Get mark-in point (video frame units, nil = no mark). Masterclip only.
-- @return number|nil
function Sequence:get_in()
    assert(self:is_masterclip(), string.format(
        "Sequence:get_in: sequence %s is not a masterclip", tostring(self.id)))
    return self.mark_in
end

--- Get mark-out point (video frame units, nil = no mark). Masterclip only.
-- @return number|nil
function Sequence:get_out()
    assert(self:is_masterclip(), string.format(
        "Sequence:get_out: sequence %s is not a masterclip", tostring(self.id)))
    return self.mark_out
end

--- Clear both marks. Masterclip only.
function Sequence:clear_marks()
    assert(self:is_masterclip(), string.format(
        "Sequence:clear_marks: sequence %s is not a masterclip", tostring(self.id)))
    self.mark_in = nil
    self.mark_out = nil
    self:save()
end

-- =============================================================================
-- PLAYHEAD RESOLUTION (used by Renderer and Mixer)
-- =============================================================================

--- Internal: Calculate source frame and time for a clip at a given playhead.
-- "Frames are frames": source_frame = source_in + timeline_offset (1:1 mapping).
-- A 24fps clip on a 30fps timeline plays each source frame at 1/30s — the clip
-- runs faster. No rate conversion here; the speed conform is intended behavior.
-- @param clip Clip object (timeline_start, source_in, rate)
-- @param playhead_frame integer playhead position in timeline frames
-- @return source_time_us (integer microseconds), source_frame (integer)
local function calc_source_time_us(clip, playhead_frame)
    assert(type(playhead_frame) == "number", "Sequence: playhead must be integer")
    assert(type(clip.timeline_start) == "number", "Sequence: timeline_start must be integer")
    assert(type(clip.source_in) == "number", "Sequence: source_in must be integer")

    local offset_frames = playhead_frame - clip.timeline_start
    local source_frame = clip.source_in + offset_frames

    local clip_rate = clip.rate
    assert(clip_rate and clip_rate.fps_numerator and clip_rate.fps_denominator,
        string.format("Sequence: clip %s has no rate", clip.id))

    -- Convert to microseconds: frame * 1000000 * fps_den / fps_num
    local source_time_us = math.floor(
        source_frame * 1000000 * clip_rate.fps_denominator / clip_rate.fps_numerator
    )
    return source_time_us, source_frame
end

--- Get ALL video clips at position, ordered by track_index ascending (topmost first).
-- Returns one entry per video track that has a clip at playhead.
-- Renderer uses first entry (topmost) for display. Future: composite all layers.
-- @param playhead_frame integer
-- @return list of {media_path, source_time_us, source_frame, clip, track} (may be empty = gap)
function Sequence:get_video_at(playhead_frame)
    assert(type(playhead_frame) == "number",
        "Sequence:get_video_at: playhead_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "VIDEO")
    if not tracks or #tracks == 0 then
        return {}
    end

    local results = {}
    -- Tracks are sorted by track_index ASC (topmost = lowest index = highest priority)
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_frame)
        if clip then
            local media = Media.load(clip.media_id)
            assert(media, string.format(
                "Sequence:get_video_at: clip %s references missing media %s",
                clip.id, tostring(clip.media_id)))

            local source_time_us, source_frame = calc_source_time_us(clip, playhead_frame)

            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
            }
        end
    end

    return results
end

--- Get all audio clips at position (works for any sequence kind).
-- @param playhead_frame integer
-- @return list of {media_path, source_time_us, source_frame, clip, track, media_fps_num, media_fps_den}
function Sequence:get_audio_at(playhead_frame)
    assert(type(playhead_frame) == "number",
        "Sequence:get_audio_at: playhead_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "AUDIO")
    if not tracks or #tracks == 0 then
        return {}
    end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_frame)
        if clip then
            local media = Media.load(clip.media_id)
            assert(media, string.format(
                "Sequence:get_audio_at: audio clip %s references missing media %s",
                clip.id, tostring(clip.media_id)))

            local source_time_us, source_frame = calc_source_time_us(clip, playhead_frame)

            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
                -- Media's video fps for "frames are frames" audio conform.
                media_fps_num = media.frame_rate.fps_numerator,
                media_fps_den = media.frame_rate.fps_denominator,
            }
        end
    end

    return results
end

--- Compute the furthest clip end frame in this sequence.
-- Returns max(timeline_start + duration) across all clips on all tracks.
-- @return integer  0 if no clips
function Sequence:compute_content_end()
    local database = require("core.database") -- luacheck: ignore 431
    assert(database.has_connection(),
        "Sequence:compute_content_end: no database connection")
    local db = database.get_connection()

    local stmt = db:prepare([[
        SELECT MAX(c.timeline_start_frame + c.duration_frames)
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ?
    ]])
    assert(stmt, "Sequence:compute_content_end: failed to prepare query")
    stmt:bind_value(1, self.id)
    assert(stmt:exec(), "Sequence:compute_content_end: query exec failed")

    local max_end = 0
    if stmt:next() then
        local val = stmt:value(0)
        if val then max_end = val end
    end
    stmt:finalize()

    return max_end
end

return Sequence