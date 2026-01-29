--- Source Playback: single media file playback logic
--
-- Responsibilities:
-- - Source-specific _tick() logic
-- - Latch/unlatch boundary handling for shuttle mode
-- - media_cache prefetch management
--
-- Non-goals:
-- - Does not own master playback state (owned by playback_controller)
-- - Does not handle timeline clip resolution
--
-- @file source_playback.lua

local logger = require("core.logger")
local media_cache = require("core.media.media_cache")
local helpers = require("core.playback.playback_helpers")

local M = {}

--------------------------------------------------------------------------------
-- Boundary Latch (shuttle mode only)
--------------------------------------------------------------------------------

--- Clear latch state without side effects
-- @param state Playback state table
function M.clear_latch(state)
    state.latched = false
    state.latched_boundary = nil
end

--- Latch at boundary (transport event)
-- PIN: One-shot, side-effect controlled, computes boundary time from frame.
-- PIN: Latch time is frame-derived, NOT sampled from AOP.
-- @param state Playback state table
-- @param boundary_frame Frame at boundary (0 or total_frames-1)
-- @param audio_playback Audio playback module reference
-- @param viewer_panel Viewer panel module reference
function M.latch(state, boundary_frame, audio_playback, viewer_panel)
    if state.latched then return end

    assert(state.fps_num > 0 and state.fps_den > 0,
        "source_playback.latch: fps must be set")

    state.latched = true
    state.latched_boundary = (boundary_frame == 0) and "start" or "end"
    state.frame = boundary_frame

    -- Deterministic time for boundary frame (rational math)
    local t_us = helpers.calc_time_us_from_frame(boundary_frame, state.fps_num, state.fps_den)

    -- Clamp to valid media range
    if audio_playback and audio_playback.max_media_time_us then
        t_us = math.max(0, math.min(t_us, audio_playback.max_media_time_us))
    else
        t_us = math.max(0, t_us)
    end

    -- Transport event: freeze audio at boundary time
    if audio_playback and audio_playback.initialized and audio_playback.latch then
        audio_playback.latch(t_us)
    end

    if viewer_panel then
        viewer_panel.show_frame(state.frame)
    end

    logger.debug("source_playback", string.format(
        "Latched at %s boundary (frame %d, t=%.3fs)",
        state.latched_boundary, boundary_frame, t_us / 1000000))
end

--- Unlatch and resume playback (transport event)
-- Called when user changes direction while latched.
-- @param state Playback state table
-- @param audio_playback Audio playback module reference
function M.unlatch_resume(state, audio_playback)
    if not state.latched then return end

    -- Get current media time (while not playing, this is media_time_us)
    local t_us = 0
    if audio_playback and audio_playback.initialized then
        t_us = audio_playback.get_media_time_us()
    end

    M.clear_latch(state)

    -- Transport event sequence: seek, sync speed, start
    if audio_playback and audio_playback.initialized then
        audio_playback.seek(t_us)
        local signed_speed = state.direction * state.speed
        audio_playback.set_speed(signed_speed)
        audio_playback.start()
    end

    logger.debug("source_playback", "Unlatched and resumed")
end

--------------------------------------------------------------------------------
-- Source Mode Tick
--------------------------------------------------------------------------------

--- Execute one tick of source playback
-- @param state Playback state table
-- @param audio_playback Audio playback module reference
-- @param viewer_panel Viewer panel module reference
-- @return continue boolean: true to continue ticking, false to stop
function M.tick(state, audio_playback, viewer_panel)
    assert(viewer_panel, "source_playback.tick: viewer_panel not set")
    assert(state.fps_num and state.fps_num > 0 and state.fps_den and state.fps_den > 0,
        "source_playback.tick: fps must be set and positive")

    -- Early return while latched (no advancement, just keep ticking)
    if state.latched then
        viewer_panel.show_frame(state.frame)
        return true  -- continue ticking
    end

    -- Frame advancement: video ALWAYS follows audio when audio is active (Rule V1)
    if audio_playback and audio_playback.initialized and audio_playback.playing then
        -- AUDIO ACTIVE: Video follows audio time (spec Rule V1)
        local t_vid_us = audio_playback.get_media_time_us()
        state.frame = helpers.calc_frame_from_time_us(t_vid_us, state.fps_num, state.fps_den)
    else
        -- NO AUDIO: Advance frame independently (fallback only)
        state.frame = state.frame + (state.direction * state.speed)
    end

    -- Clamp to valid range
    state.frame = math.max(0, math.min(state.frame, state.total_frames - 1))

    -- Boundary detection
    local hit_start = (state.direction < 0 and state.frame <= 0)
    local hit_end = (state.direction > 0 and state.frame >= state.total_frames - 1)

    if hit_start or hit_end then
        local boundary_frame = hit_start and 0 or (state.total_frames - 1)
        state.frame = boundary_frame

        if state.transport_mode == "shuttle" then
            -- Shuttle mode: latch at boundary, continue ticking
            M.latch(state, boundary_frame, audio_playback, viewer_panel)
            return true  -- continue ticking while latched
        else
            -- Normal play mode: stop at boundary
            logger.debug("source_playback", hit_start and "Hit start boundary" or "Hit end boundary")
            return false  -- stop playback
        end
    end

    -- Display frame
    local frame_idx = math.floor(state.frame)
    viewer_panel.show_frame(frame_idx)

    -- Notify media_cache of playhead change (triggers prefetch in travel direction)
    if media_cache.is_loaded() then
        media_cache.set_playhead(frame_idx, state.direction, state.speed)
    end

    return true  -- continue ticking
end

return M
