--- Source Playback: single media file playback logic
--
-- Responsibilities:
-- - Source-specific tick() logic → returns result struct, does NOT mutate state
-- - Latch/unlatch boundary detection (returns latch state, does not own it)
-- - media_cache prefetch signaling
--
-- Contract:
-- - tick() receives a READ-ONLY tick_in table and returns a tick_result table
-- - playback_controller is the ONLY module that commits state changes
-- - Side effects limited to: viewer_panel.show_frame(), audio_playback.latch(),
--   media_cache.set_playhead()
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
-- tick_in contract (asserted at entry):
--   pos            number  current frame position
--   direction      number  -1, 0, or 1
--   speed          number  magnitude (0.5, 1, 2, 4, 8)
--   fps_num        number  > 0
--   fps_den        number  > 0
--   total_frames   number  >= 1
--   transport_mode string  "none" | "shuttle" | "play"
--   latched        boolean
--   latched_boundary string|nil  "start" | "end" | nil
--
-- tick_result:
--   continue          boolean  true = keep ticking, false = stop
--   new_pos           number   updated frame position
--   latched           boolean  updated latch state
--   latched_boundary  string|nil  updated latch boundary
--------------------------------------------------------------------------------

local function assert_tick_in(tick_in)
    assert(type(tick_in) == "table",
        "source_playback.tick: tick_in must be a table")
    assert(type(tick_in.pos) == "number",
        "source_playback.tick: tick_in.pos must be a number")
    assert(tick_in.direction == -1 or tick_in.direction == 0 or tick_in.direction == 1,
        "source_playback.tick: tick_in.direction must be -1, 0, or 1")
    assert(type(tick_in.speed) == "number" and tick_in.speed > 0,
        "source_playback.tick: tick_in.speed must be a positive number")
    assert(type(tick_in.fps_num) == "number" and tick_in.fps_num > 0,
        "source_playback.tick: tick_in.fps_num must be > 0")
    assert(type(tick_in.fps_den) == "number" and tick_in.fps_den > 0,
        "source_playback.tick: tick_in.fps_den must be > 0")
    assert(type(tick_in.total_frames) == "number" and tick_in.total_frames >= 1,
        "source_playback.tick: tick_in.total_frames must be >= 1")
    assert(tick_in.transport_mode == "none" or tick_in.transport_mode == "shuttle" or tick_in.transport_mode == "play",
        "source_playback.tick: tick_in.transport_mode must be 'none', 'shuttle', or 'play'")
    assert(type(tick_in.latched) == "boolean",
        "source_playback.tick: tick_in.latched must be a boolean")
end

--------------------------------------------------------------------------------
-- Boundary Latch (shuttle mode only)
--------------------------------------------------------------------------------

--- Compute latch side-effects: freeze audio, show boundary frame.
-- Called internally when tick detects boundary in shuttle mode.
-- @param boundary_frame Frame at boundary (0 or total_frames-1)
-- @param fps_num FPS numerator
-- @param fps_den FPS denominator
-- @param audio_playback Audio playback module reference
-- @param viewer_panel Viewer panel module reference
local function apply_latch_effects(boundary_frame, fps_num, fps_den, audio_playback, viewer_panel)
    -- Deterministic time for boundary frame (rational math)
    local t_us = helpers.calc_time_us_from_frame(boundary_frame, fps_num, fps_den)

    -- Clamp to valid media range
    if audio_playback and audio_playback.max_media_time_us then
        t_us = math.max(0, math.min(t_us, audio_playback.max_media_time_us))
    else
        t_us = math.max(0, t_us)
    end

    -- Transport event: freeze audio at boundary time
    if audio_playback and audio_playback.is_ready() and audio_playback.latch then
        audio_playback.latch(t_us)
    end

    viewer_panel.show_frame(boundary_frame)

    logger.debug("source_playback", string.format(
        "Latched at %s boundary (frame %d, t=%.3fs)",
        boundary_frame == 0 and "start" or "end", boundary_frame, t_us / 1000000))
end

--- Get media time for unlatch resume.
-- @param audio_playback Audio playback module reference
-- @return resume_time_us number
function M.get_unlatch_resume_time(audio_playback)
    if audio_playback and audio_playback.is_ready() then
        return audio_playback.get_media_time_us()
    end
    return 0
end

--------------------------------------------------------------------------------
-- Source Mode Tick
--------------------------------------------------------------------------------

--- Execute one tick of source playback.
-- Pure function: reads tick_in, returns tick_result. Does NOT mutate external state
-- except viewer_panel.show_frame(), audio_playback.latch(), media_cache.set_playhead().
-- @param tick_in table READ-ONLY snapshot of playback state (see contract above)
-- @param audio_playback Audio playback module reference
-- @param viewer_panel Viewer panel module reference
-- @return tick_result table with { continue, new_pos, latched, latched_boundary }
function M.tick(tick_in, audio_playback, viewer_panel)
    assert(viewer_panel, "source_playback.tick: viewer_panel not set")
    assert_tick_in(tick_in)

    -- Early return while latched (no advancement, just keep ticking)
    if tick_in.latched then
        viewer_panel.show_frame(tick_in.pos)
        return {
            continue = true,
            new_pos = tick_in.pos,
            latched = true,
            latched_boundary = tick_in.latched_boundary,
        }
    end

    -- Frame advancement: video ALWAYS follows audio when audio is active (Rule V1)
    local pos
    if audio_playback and audio_playback.is_ready() and audio_playback.playing then
        -- AUDIO ACTIVE: Video follows audio time (spec Rule V1)
        local t_vid_us = audio_playback.get_media_time_us()
        pos = helpers.calc_frame_from_time_us(t_vid_us, tick_in.fps_num, tick_in.fps_den)
    else
        -- NO AUDIO: Advance frame independently (fallback only)
        pos = tick_in.pos + (tick_in.direction * tick_in.speed)
    end

    -- Clamp to valid range
    pos = math.max(0, math.min(pos, tick_in.total_frames - 1))

    -- Boundary detection
    local hit_start = (tick_in.direction < 0 and pos <= 0)
    local hit_end = (tick_in.direction > 0 and pos >= tick_in.total_frames - 1)

    if hit_start or hit_end then
        local boundary_frame = hit_start and 0 or (tick_in.total_frames - 1)

        if tick_in.transport_mode == "shuttle" then
            -- Shuttle mode: latch at boundary, continue ticking
            apply_latch_effects(boundary_frame, tick_in.fps_num, tick_in.fps_den,
                audio_playback, viewer_panel)
            return {
                continue = true,
                new_pos = boundary_frame,
                latched = true,
                latched_boundary = hit_start and "start" or "end",
            }
        else
            -- Normal play mode: stop at boundary
            logger.debug("source_playback", hit_start and "Hit start boundary" or "Hit end boundary")
            return {
                continue = false,
                new_pos = boundary_frame,
                latched = false,
                latched_boundary = nil,
            }
        end
    end

    -- Display frame
    local frame_idx = math.floor(pos)
    viewer_panel.show_frame(frame_idx)

    -- Notify media_cache of playhead change (triggers prefetch in travel direction)
    if media_cache.is_loaded() then
        media_cache.set_playhead(frame_idx, tick_in.direction, tick_in.speed)
    end

    return {
        continue = true,
        new_pos = pos,
        latched = false,
        latched_boundary = nil,
    }
end

return M
