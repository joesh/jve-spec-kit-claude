--- models/sequence/streams.lua — Sequence:video_stream / :audio_streams /
--- :num_audio_streams / :invalidate_stream_cache, plus the load helpers
--- ensure_stream_clips uses to materialise a master's media_refs as
--- "stream clips" for the legacy V8-shaped contract.
---
--- Extracted from models/sequence.lua (2.6: ~150-LOC cluster, internal
--- to the master-sequence API). Installed onto Sequence via
--- M.install(Sequence). load helpers (load_master_video_streams,
--- load_master_audio_streams, ensure_stream_clips) are file-private.

local database = require("core.database")

local function resolve_db()
    local conn = database.get_connection()
    assert(conn, "models.sequence.streams: no database connection")
    return conn
end

local M = {}

function M.install(Sequence)

--- V13: enumerate the media_refs inside a kind='master' sequence as
-- "stream clips" for legacy callers. Each returned record is shaped to
-- match the V8 clip-stream contract that callers depend on:
--   .id, .track_id, .sequence_start, .duration,
--   .source_in, .source_out, .media_id,
--   .frame_rate = {fps_numerator, fps_denominator} for video streams,
--   .sample_rate = N (Hz, integer) for audio streams.
-- Source-unit semantics: video source coords are frames at frame_rate;
-- audio source coords are samples at sample_rate.
-- @return table {video_clips = {...}, audio_clips = {...}}
-- Common row-shape for one media_ref reshaped into a "stream clip". Video
-- clips carry frame_rate (sequence-level); audio clips carry sample_rate
-- (per-media_ref, non-NULL on every audio media_ref — masters have no
-- aggregate audio_sample_rate per FR-004).
local function load_master_video_streams(conn, track_id, video_frame_rate)
    local out = {}
    local stmt = conn:prepare([[
        SELECT id, track_id, media_id, source_in_frame, source_out_frame,
               sequence_start_frame, duration_frames,
               enabled, volume, mark_in_frame, mark_out_frame, playhead_frame
        FROM media_refs WHERE track_id = ?
        ORDER BY sequence_start_frame ASC
    ]])
    assert(stmt, "ensure_stream_clips: video media_refs prepare failed")
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "ensure_stream_clips: video media_refs exec failed")
    while stmt:next() do
        out[#out + 1] = {
            id             = stmt:value(0),
            track_id       = stmt:value(1),
            media_id       = stmt:value(2),
            source_in      = stmt:value(3),
            source_out     = stmt:value(4),
            sequence_start = stmt:value(5),
            duration       = stmt:value(6),
            enabled        = stmt:value(7) == 1,
            volume         = stmt:value(8),
            mark_in        = stmt:value(9),
            mark_out       = stmt:value(10),
            playhead_frame = stmt:value(11),
            frame_rate     = video_frame_rate,
        }
    end
    stmt:finalize()
    return out
end

local function load_master_audio_streams(conn, track_id, master_seq_id)
    local out = {}
    -- 018 (FR-004): every AUDIO media_ref carries mr.audio_sample_rate at
    -- insert (denormalized from media). The per-master single-rate
    -- assumption is gone (FR-034).
    local stmt = conn:prepare([[
        SELECT id, track_id, media_id, source_in_frame, source_out_frame,
               sequence_start_frame, duration_frames,
               enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
               audio_sample_rate
        FROM media_refs WHERE track_id = ?
        ORDER BY sequence_start_frame ASC
    ]])
    assert(stmt, "ensure_stream_clips: audio media_refs prepare failed")
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "ensure_stream_clips: audio media_refs exec failed")
    while stmt:next() do
        local rate = stmt:value(12)
        assert(rate and rate > 0, string.format(
            "ensure_stream_clips: audio media_ref %s on master %s "
            .. "missing audio_sample_rate (FR-004)",
            tostring(stmt:value(0)), tostring(master_seq_id)))
        out[#out + 1] = {
            id             = stmt:value(0),
            track_id       = stmt:value(1),
            media_id       = stmt:value(2),
            source_in      = stmt:value(3),
            source_out     = stmt:value(4),
            sequence_start = stmt:value(5),
            duration       = stmt:value(6),
            enabled        = stmt:value(7) == 1,
            volume         = stmt:value(8),
            mark_in        = stmt:value(9),
            mark_out       = stmt:value(10),
            playhead_frame = stmt:value(11),
            sample_rate    = rate,
        }
    end
    stmt:finalize()
    return out
end

local function ensure_stream_clips(self)
    assert(self.kind == "master", string.format(
        "Sequence.ensure_stream_clips: sequence %s is not a master (kind=%s)",
        tostring(self.id), tostring(self.kind)))

    if self._cached_stream_clips then
        return self._cached_stream_clips
    end

    -- Master sequences are constructed with NOT NULL fps by
    -- Sequence.ensure_master. Master.audio_sample_rate is NULL per FR-004 —
    -- per-rate is per-media_ref now. Assert frame_rate before any
    -- DB work so a malformed master row fails loud at the source.
    local video_frame_rate = self.frame_rate
    assert(video_frame_rate
        and video_frame_rate.fps_numerator
        and video_frame_rate.fps_denominator,
        string.format("ensure_stream_clips: master sequence %s missing frame_rate",
            tostring(self.id)))

    local Track = require("models.track")
    local conn = resolve_db()
    local video_tracks = Track.find_by_sequence(self.id, "VIDEO")
    local audio_tracks = Track.find_by_sequence(self.id, "AUDIO")

    local video_clips, audio_clips = {}, {}
    for _, t in ipairs(video_tracks) do
        for _, r in ipairs(load_master_video_streams(conn, t.id, video_frame_rate)) do
            video_clips[#video_clips + 1] = r
        end
    end
    for _, t in ipairs(audio_tracks) do
        for _, r in ipairs(load_master_audio_streams(conn, t.id, self.id)) do
            audio_clips[#audio_clips + 1] = r
        end
    end

    local result = { video_clips = video_clips, audio_clips = audio_clips }
    self._cached_stream_clips = result
    return result
end

--- Get the video stream from this master sequence (a media_ref reshaped
--- as a "clip" for callers that haven't been moved off the V8 stream-clip
--- shape yet). Asserts if called on a non-master sequence.
-- @return table|nil video media_ref reshaped as clip, or nil if none exists
function Sequence:video_stream()
    local streams = ensure_stream_clips(self)
    return streams.video_clips[1]
end

--- Get all audio streams from this master sequence (media_refs reshaped as
--- clips). Asserts if called on a non-master sequence.
-- @return table Array of audio media_ref-shaped clips (may be empty)
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

end -- M.install

return M
