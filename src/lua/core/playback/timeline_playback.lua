--- Timeline Playback: sequence/clip-based playback logic
--
-- Responsibilities:
-- - Timeline-specific _tick() logic
-- - Clip resolution via timeline_resolver
-- - Source switching when clips change
-- - Timeline sync callback for playhead updates
--
-- Non-goals:
-- - Does not own master playback state (owned by playback_controller)
-- - Does not handle source-mode playback
-- - Does not handle latching (timeline stops at boundaries, doesn't latch)
--
-- @file timeline_playback.lua

local logger = require("core.logger")
local timeline_resolver = require("core.playback.timeline_resolver")
local helpers = require("core.playback.playback_helpers")
local media_cache = require("core.media.media_cache")

local M = {}

--------------------------------------------------------------------------------
-- Resolve + Display
--------------------------------------------------------------------------------

--- Resolve which clip is at frame_idx and display the correct source frame.
-- Used by both tick() during playback and seek() when parked.
-- @param state Playback state table (needs fps_num, fps_den, sequence_id, current_clip_id)
-- @param viewer_panel Viewer panel module reference
-- @param frame_idx integer: timeline frame index to resolve
-- @param audio_playback optional: audio module for source switching during playback
function M.resolve_and_display(state, viewer_panel, frame_idx, audio_playback)
    assert(viewer_panel, "timeline_playback.resolve_and_display: viewer_panel not set")
    assert(state.fps_num and state.fps_den,
        "timeline_playback.resolve_and_display: fps must be set")
    assert(state.sequence_id, "timeline_playback.resolve_and_display: sequence_id required")

    local playhead_rat = helpers.frame_to_rational(frame_idx, state.fps_num, state.fps_den)
    local resolved = timeline_resolver.resolve_at_time(playhead_rat, state.sequence_id)

    if resolved then
        -- Check if clip changed - need to switch source
        if resolved.clip.id ~= state.current_clip_id then
            state.current_clip_id = resolved.clip.id
            -- Activate reader in pool (pool lookup, no I/O if cached)
            media_cache.activate(resolved.media_path)
            -- Also update audio source during playback
            if audio_playback and audio_playback.set_source then
                audio_playback.set_source(resolved.media_path)
            end
            logger.debug("timeline_playback",
                string.format("Switched to clip %s at media %s",
                    resolved.clip.id:sub(1,8), resolved.media_path))
        end

        -- Show the correct source frame (using source_time_us)
        viewer_panel.show_frame_at_time(resolved.source_time_us)

        -- Update prefetch thread with source-space position so background
        -- decoder stays ahead of playback. Only during active playback
        -- (direction != 0); parked seeks don't need prefetch.
        if state.direction and state.direction ~= 0 then
            local asset_info = media_cache.get_asset_info()
            local source_frame = math.floor(
                resolved.source_time_us * asset_info.fps_num
                / (asset_info.fps_den * 1000000))
            media_cache.set_playhead(source_frame, state.direction, state.speed)
        end
    else
        -- Gap at playhead - show black
        viewer_panel.show_gap()
        -- Reset clip tracking so next clip triggers switch
        state.current_clip_id = nil
    end
end

--------------------------------------------------------------------------------
-- Timeline Mode Tick
--------------------------------------------------------------------------------

--- Execute one tick of timeline playback
-- @param state Playback state table (must have timeline_mode=true, sequence_id set)
-- @param audio_playback Audio playback module reference
-- @param viewer_panel Viewer panel module reference
-- @return continue boolean: true to continue ticking, false to stop
function M.tick(state, audio_playback, viewer_panel)
    assert(viewer_panel, "timeline_playback.tick: viewer_panel not set")
    assert(state.fps_num and state.fps_num > 0 and state.fps_den and state.fps_den > 0,
        "timeline_playback.tick: fps must be set and positive")
    assert(state.timeline_mode, "timeline_playback.tick: timeline_mode must be true")
    assert(state.sequence_id, "timeline_playback.tick: sequence_id required")

    -- Frame advancement: video ALWAYS follows audio when audio is active (Rule V1)
    -- Use local var to avoid repeated Rational conversions within the tick
    local pos
    if audio_playback and audio_playback.initialized and audio_playback.playing then
        -- AUDIO ACTIVE: Video follows audio time (spec Rule V1)
        local t_vid_us = audio_playback.get_media_time_us()
        pos = helpers.calc_frame_from_time_us(t_vid_us, state.fps_num, state.fps_den)
    else
        -- NO AUDIO: Advance frame independently (fallback only)
        pos = state.get_position() + (state.direction * state.speed)
    end

    -- Clamp to valid range
    pos = math.max(0, math.min(pos, state.total_frames - 1))

    -- Boundary detection (timeline stops at boundaries, no latching)
    local hit_start = (state.direction < 0 and pos <= 0)
    local hit_end = (state.direction > 0 and pos >= state.total_frames - 1)

    if hit_start or hit_end then
        local boundary_frame = hit_start and 0 or (state.total_frames - 1)
        state.set_position(boundary_frame)
        logger.debug("timeline_playback", hit_start and "Hit start boundary" or "Hit end boundary")
        return false  -- stop playback at timeline boundaries
    end

    -- Resolve and display FIRST so decode completes before UI update.
    -- set_position fires set_playhead_position → debounced listener notifications.
    -- If set_position ran first, listeners would queue repaints that can't process
    -- until after the potentially-blocking decode, causing visual stutter.
    local frame_idx = math.floor(pos)
    M.resolve_and_display(state, viewer_panel, frame_idx, audio_playback)

    -- Now commit position → fires set_playhead_position → UI repaints
    state.set_position(pos)

    -- Page-scroll callback (may adjust viewport)
    if state.timeline_sync_callback then
        state.timeline_sync_callback(frame_idx)
    end

    return true  -- continue ticking
end

return M
