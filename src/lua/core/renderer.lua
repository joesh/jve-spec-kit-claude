--- Renderer: resolves sequence content at playhead and returns display-ready frames.
--
-- Responsibilities:
-- - Sequence accessor + media_cache I/O + frame decode
-- - Returns EMP frame handle for display (or nil for gaps)
-- - Provides sequence info (resolution, fps, total_frames) for any sequence kind
--
-- No sequence-kind branching. All sequences are resolved uniformly via
-- Sequence:get_video_at(). Masterclips have one video track with one clip;
-- timelines have multiple tracks with priority ordering.
--
-- @file renderer.lua

local media_cache = require("core.media.media_cache")
local Sequence = require("models.sequence")
local logger = require("core.logger")

local M = {}

--- Get video frame for a sequence at a given playhead position.
-- @param sequence Sequence object
-- @param playhead_frame integer
-- @param context_id string media_cache context for this view
-- @return frame_handle|nil, metadata_table|nil
--   metadata = {clip_id, media_path, source_frame, rotation}
function M.get_video_frame(sequence, playhead_frame, context_id)
    assert(sequence, "renderer.get_video_frame: sequence is nil")
    assert(type(playhead_frame) == "number",
        "renderer.get_video_frame: playhead_frame must be integer")
    assert(context_id, "renderer.get_video_frame: context_id is required")

    local entries = sequence:get_video_at(playhead_frame)

    if #entries == 0 then
        -- Gap at playhead
        return nil, nil
    end

    -- Use topmost entry (first in list, lowest track_index = highest priority)
    local top = entries[1]

    -- Activate reader in pool for this context
    local info = media_cache.activate(top.media_path, context_id)

    -- Absolute timecode → file-relative frame (matches audio Mixer pattern).
    -- Camera footage embeds time-of-day TC (e.g., 14:28:00:00 → frame 1249920).
    -- DRP imports store these as source_in. Decoder needs file-relative (0-based).
    local file_frame = top.source_frame - (info.start_tc or 0)

    -- Decode using the clip's timebase (not the media's native rate).
    -- source_frame is in clip rate units (e.g., 24/1 for a 24fps timeline).
    -- If we used the media's rate (e.g., 24000/1001), the timestamp would drift
    -- and overshoot the file at clip boundaries.
    local clip_fps_num = top.clip.rate.fps_numerator
    local clip_fps_den = top.clip.rate.fps_denominator
    local frame = media_cache.get_video_frame(file_frame, context_id, clip_fps_num, clip_fps_den)
    if not frame then
        logger.warn("renderer", string.format(
            "DECODE_NIL playhead=%d source_frame=%d file_frame=%d start_tc=%s clip_fps=%d/%d "
            .. "src_in=%s src_out=%s dur=%s media=%s",
            playhead_frame, top.source_frame, file_frame,
            tostring(info.start_tc),
            clip_fps_num, clip_fps_den,
            tostring(top.clip.source_in), tostring(top.clip.source_out),
            tostring(top.clip.duration),
            tostring(top.media_path)))
        return nil, nil
    end

    local metadata = {
        clip_id = top.clip.id,
        media_path = top.media_path,
        source_frame = file_frame,
        rotation = info.rotation or 0,
        clip_fps_num = clip_fps_num,
        clip_fps_den = clip_fps_den,
    }

    return frame, metadata
end

--- Get sequence info for playback setup.
-- @param sequence_id string
-- @return table {fps_num, fps_den, width, height, total_frames, name, kind}
function M.get_sequence_info(sequence_id)
    assert(sequence_id and sequence_id ~= "",
        "renderer.get_sequence_info: sequence_id required")

    local seq = Sequence.load(sequence_id)
    assert(seq, string.format(
        "renderer.get_sequence_info: sequence %s not found", sequence_id))

    return {
        fps_num = seq.frame_rate.fps_numerator,
        fps_den = seq.frame_rate.fps_denominator,
        width = seq.width,
        height = seq.height,
        name = seq.name,
        kind = seq.kind,
        audio_sample_rate = seq.audio_sample_rate,
    }
end

return M
