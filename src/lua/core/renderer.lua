--- Renderer: resolves TMB video output and returns display-ready frames.
--
-- Responsibilities:
-- - Iterates video tracks in priority order (highest track_index = topmost)
-- - Calls TMB_GET_VIDEO_FRAME per track
-- - Handles offline via offline_frame_cache
-- - Returns EMP frame handle for display (or nil for gaps)
-- - Provides sequence info (resolution, fps, total_frames) for any sequence kind
--
-- No sequence-kind branching. No media_cache calls. TMB owns reader lifecycle,
-- decoding, caching, and pre-buffering internally.
--
-- @file renderer.lua

local qt_constants = require("core.qt_constants")
local offline_frame_cache = require("core.media.offline_frame_cache")
local Sequence = require("models.sequence")

local M = {}

--- Get video frame via TMB for tracks at a given playhead position.
-- @param tmb userdata TMB handle (from TMB_CREATE)
-- @param video_track_indices table array of track indices (priority order: highest first)
-- @param playhead_frame integer
-- @return frame_handle|nil, metadata_table|nil
function M.get_video_frame(tmb, video_track_indices, playhead_frame)
    assert(tmb, "renderer.get_video_frame: tmb is nil")
    assert(type(video_track_indices) == "table",
        "renderer.get_video_frame: video_track_indices must be a table")
    assert(type(playhead_frame) == "number",
        "renderer.get_video_frame: playhead_frame must be integer")

    local EMP = qt_constants.EMP

    -- Iterate tracks in priority order (highest track_index = topmost = wins)
    for _, track_idx in ipairs(video_track_indices) do
        local frame_handle, metadata = EMP.TMB_GET_VIDEO_FRAME(
            tmb, track_idx, playhead_frame)

        if metadata.offline then
            -- TMB reports offline: compose offline frame
            local frame = offline_frame_cache.get_frame(metadata)
            assert(frame, string.format(
                "renderer.get_video_frame: offline_frame_cache.get_frame returned nil "
                .. "for clip_id=%s, media_path=%s at frame %d",
                tostring(metadata.clip_id), tostring(metadata.media_path),
                playhead_frame))
            return frame, metadata
        end

        if frame_handle then
            return frame_handle, metadata
        end
        -- nil frame + not offline = gap on this track, try next
    end

    -- All tracks are gaps at this position
    return nil, nil
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
