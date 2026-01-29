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

local M = {}

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

    -- Boundary detection (timeline stops at boundaries, no latching)
    local hit_start = (state.direction < 0 and state.frame <= 0)
    local hit_end = (state.direction > 0 and state.frame >= state.total_frames - 1)

    if hit_start or hit_end then
        local boundary_frame = hit_start and 0 or (state.total_frames - 1)
        state.frame = boundary_frame
        logger.debug("timeline_playback", hit_start and "Hit start boundary" or "Hit end boundary")
        return false  -- stop playback at timeline boundaries
    end

    -- Resolve clip at current playhead position
    local frame_idx = math.floor(state.frame)
    local playhead_rat = helpers.frame_to_rational(frame_idx, state.fps_num, state.fps_den)
    local resolved = timeline_resolver.resolve_at_time(playhead_rat, state.sequence_id)

    if resolved then
        -- Check if clip changed - need to switch source
        if resolved.clip.id ~= state.current_clip_id then
            state.current_clip_id = resolved.clip.id
            -- Switch viewer source to new clip's media
            if viewer_panel.set_source_for_timeline then
                viewer_panel.set_source_for_timeline(resolved.media_path)
            end
            -- Also update audio source
            if audio_playback and audio_playback.set_source then
                audio_playback.set_source(resolved.media_path)
            end
            logger.debug("timeline_playback",
                string.format("Switched to clip %s at media %s",
                    resolved.clip.id:sub(1,8), resolved.media_path))
        end

        -- Show the correct source frame (using source_time_us)
        if viewer_panel.show_frame_at_time then
            viewer_panel.show_frame_at_time(resolved.source_time_us)
        else
            -- Fallback: convert source_time_us to frame and show
            local source_frame = helpers.calc_frame_from_time_us(
                resolved.source_time_us, state.fps_num, state.fps_den)
            viewer_panel.show_frame(source_frame)
        end
    else
        -- Gap at playhead - show black
        if viewer_panel.show_gap then
            viewer_panel.show_gap()
        end
        -- Reset clip tracking so next clip triggers switch
        state.current_clip_id = nil
    end

    -- Call timeline sync callback to update timeline playhead
    if state.timeline_sync_callback then
        state.timeline_sync_callback(frame_idx)
    end

    return true  -- continue ticking
end

return M
