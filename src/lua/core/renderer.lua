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
local media_status = require("core.media.media_status")
local Sequence = require("models.sequence")

local M = {}

--- Compute effective video track indices given per-track mute/solo state.
-- Mirrors the audio any_solo rule (audio_playback.lua:261-274):
--   solo context (≥1 soloed): only soloed tracks participate; solo wins over mute.
--   no-solo context: muted tracks are excluded, all others participate.
-- Result is sorted descending (topmost track index first).
-- @param tracks table  array of {track_index:int, muted:bool, soloed:bool}
-- @return table  array of track_index integers, descending
function M.compute_effective_video_indices(tracks)
    assert(type(tracks) == "table",
        "renderer.compute_effective_video_indices: tracks must be a table")
    local any_solo = false
    for _, track in ipairs(tracks) do
        assert(type(track.track_index) == "number",
            "renderer.compute_effective_video_indices: track_index must be a number")
        assert(type(track.muted) == "boolean",
            "renderer.compute_effective_video_indices: muted must be a boolean")
        assert(type(track.soloed) == "boolean",
            "renderer.compute_effective_video_indices: soloed must be a boolean")
        if track.soloed then any_solo = true end
    end

    local indices = {}
    for _, track in ipairs(tracks) do
        local include = any_solo and track.soloed or (not any_solo and not track.muted)
        if include then
            indices[#indices + 1] = track.track_index
        end
    end
    table.sort(indices, function(a, b) return a > b end)
    return indices
end

--- Get video frame via TMB for tracks at a given playhead position.
--- Pure function of its inputs — MUST NOT touch the DB on the render
--- path. Partial-coverage diagnostics come from `media_status` (in-memory
--- cache, primed at project open + updated on media_changed) and the
--- clip source-range snapshot the PlaybackEngine hands in.
--- @param tmb userdata TMB handle (from TMB_CREATE)
--- @param video_track_indices table array of track indices (priority order: highest first)
--- @param playhead_frame integer
--- @param clip_info_by_id table {[clip_id] = {source_in, source_out}} from PlaybackEngine
--- @return frame_handle|nil, metadata_table|nil
function M.get_video_frame(tmb, video_track_indices, playhead_frame, clip_info_by_id)
    assert(tmb, "renderer.get_video_frame: tmb is nil")
    assert(type(video_track_indices) == "table",
        "renderer.get_video_frame: video_track_indices must be a table")
    assert(type(playhead_frame) == "number",
        "renderer.get_video_frame: playhead_frame must be integer")
    assert(type(clip_info_by_id) == "table",
        "renderer.get_video_frame: clip_info_by_id table required")

    local EMP = qt_constants.EMP

    -- Iterate tracks in priority order (highest track_index = topmost = wins)
    for _, track_idx in ipairs(video_track_indices) do
        local frame_handle, metadata = EMP.TMB_GET_VIDEO_FRAME(
            tmb, track_idx, playhead_frame)
        assert(type(metadata) == "table", string.format(
            "renderer.get_video_frame: TMB_GET_VIDEO_FRAME returned nil metadata "
            .. "for track=%d frame=%d", track_idx, playhead_frame))

        local media_path = metadata.media_path
        local has_path = type(media_path) == "string" and media_path ~= ""

        if metadata.offline then
            -- READ the relinker's offline_note for partial-coverage overlay
            -- text. media_status is updated by authoritative writers ONLY
            -- (bg codec probe, FS watcher, relinker) — NOT by the renderer.
            -- A renderer-side write here would treat TMB's per-frame
            -- offline (EOFReached on past-coverage frames) as a file-level
            -- status flip, broadcasting media_status_changed to every
            -- engine. With partial-coverage playback the playhead crossing
            -- the coverage boundary oscillates the status, every engine
            -- calls RELOAD_ALL_CLIPS, and unrelated monitors' TMB clip
            -- layouts get cleared mid-render → gap-black surfaces with no
            -- offline overlay (TSO 2026-05-15 02:46). The contract is
            -- pinned by test_renderer_does_not_flip_media_status.lua and
            -- test_partial_coverage_no_cross_engine_reload.lua.
            if has_path then
                metadata.offline_note = media_status.get_offline_note(media_path)
            end

            -- Per-clip source range for the partial-coverage frame. Absent
            -- when the clip isn't in the engine's current window (rare —
            -- offline_frame_cache then falls through to the generic
            -- "File not found" composition).
            local info = clip_info_by_id[metadata.clip_id]
            if info then
                metadata.clip = { source_in = info.source_in, source_out = info.source_out }
            end

            local frame = offline_frame_cache.get_frame(metadata)
            assert(frame, string.format(
                "renderer.get_video_frame: offline_frame_cache.get_frame returned nil "
                .. "for clip_id=%s, media_path=%s at frame %d",
                tostring(metadata.clip_id), tostring(media_path), playhead_frame))
            return frame, metadata
        end

        if frame_handle then
            -- Successful decode. Do NOT write media_status from here.
            -- See the comment above on offline_note for why the renderer
            -- isn't a media_status writer. If status is stale (file came
            -- back online), the FS watcher's reprobe path is authoritative.
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
