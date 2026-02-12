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

local logger = require("core.logger")
local media_cache = require("core.media.media_cache")
local Sequence = require("models.sequence")

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

    -- Decode frame
    local frame = media_cache.get_video_frame(top.source_frame, context_id)

    local metadata = {
        clip_id = top.clip.id,
        media_path = top.media_path,
        source_frame = top.source_frame,
        rotation = info and info.rotation or 0,
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
