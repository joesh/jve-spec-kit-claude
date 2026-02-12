--- Timeline Playback: sequence/clip-based playback logic
--
-- Responsibilities:
-- - Timeline-specific tick() logic → returns result struct, does NOT mutate state
-- - Clip resolution via timeline_resolver
-- - Source switching when clips change
--
-- Contract:
-- - tick() receives a READ-ONLY tick_in table and returns a tick_result table
-- - resolve_and_display() receives explicit params, returns new current_clip_id
-- - playback_controller is the ONLY module that commits state changes
-- - playback_controller owns the tick ordering: resolve → commit position → sync callback
-- - Side effects limited to: viewer_panel.show_frame_at_time()/show_gap(),
--   media_cache.activate()/set_playhead(), audio_playback.set_source()
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
-- tick_in contract (asserted at entry):
--   pos            number  current frame position
--   direction      number  -1, 0, or 1
--   speed          number  magnitude (0.5, 1, 2, 4, 8)
--   fps_num        number  > 0
--   fps_den        number  > 0
--   total_frames   number  >= 1
--   sequence_id    string  non-empty
--   current_clip_id string|nil  clip currently playing (for switch detection)
--   last_audio_frame number|nil  last frame audio reported (for stuckness detection)
--
-- tick_result:
--   continue        boolean  true = keep ticking, false = stop
--   new_pos         number   updated frame position
--   current_clip_id string|nil  updated clip id (may change on clip switch)
--   frame_idx       number|nil  integer frame index (for sync callback)
--   audio_frame     number|nil  audio-reported frame (nil when frame-based/no audio)
--------------------------------------------------------------------------------

local function assert_tick_in(tick_in)
    assert(type(tick_in) == "table",
        "timeline_playback.tick: tick_in must be a table")
    assert(type(tick_in.pos) == "number",
        "timeline_playback.tick: tick_in.pos must be a number")
    assert(tick_in.direction == -1 or tick_in.direction == 0 or tick_in.direction == 1,
        "timeline_playback.tick: tick_in.direction must be -1, 0, or 1")
    assert(type(tick_in.speed) == "number" and tick_in.speed > 0,
        "timeline_playback.tick: tick_in.speed must be a positive number")
    assert(type(tick_in.fps_num) == "number" and tick_in.fps_num > 0,
        "timeline_playback.tick: tick_in.fps_num must be > 0")
    assert(type(tick_in.fps_den) == "number" and tick_in.fps_den > 0,
        "timeline_playback.tick: tick_in.fps_den must be > 0")
    assert(type(tick_in.total_frames) == "number" and tick_in.total_frames >= 1,
        "timeline_playback.tick: tick_in.total_frames must be >= 1")
    assert(type(tick_in.sequence_id) == "string" and tick_in.sequence_id ~= "",
        "timeline_playback.tick: tick_in.sequence_id must be a non-empty string")
    assert(tick_in.context_id,
        "timeline_playback.tick: tick_in.context_id is required")
end

--------------------------------------------------------------------------------
-- Resolve + Display
--------------------------------------------------------------------------------

--- Resolve which clip is at frame_idx and display the correct source frame.
-- Used by both tick() during playback and seek() when parked.
-- @param fps_num number FPS numerator
-- @param fps_den number FPS denominator
-- @param sequence_id string Sequence to resolve within
-- @param current_clip_id string|nil Currently active clip (for switch detection)
-- @param direction number|nil Playback direction (for prefetch; nil = parked)
-- @param speed number|nil Playback speed (for prefetch; nil = parked)
-- @param viewer_panel table Viewer panel module reference
-- @param audio_playback table|nil Audio module for source switching during playback
-- @param frame_idx number Timeline frame index to resolve
-- @param context_id string Media cache context ID
-- @return new_current_clip_id string|nil Updated clip id
function M.resolve_and_display(fps_num, fps_den, sequence_id, current_clip_id,
                                direction, speed, viewer_panel, audio_playback, frame_idx, context_id)
    assert(viewer_panel, "timeline_playback.resolve_and_display: viewer_panel not set")
    assert(fps_num and fps_den,
        "timeline_playback.resolve_and_display: fps must be set")
    assert(sequence_id, "timeline_playback.resolve_and_display: sequence_id required")
    assert(context_id, "timeline_playback.resolve_and_display: context_id required")

    local resolved = timeline_resolver.resolve_at_time(frame_idx, sequence_id)

    if resolved then
        -- Check if clip changed - need to switch source
        if resolved.clip.id ~= current_clip_id then
            current_clip_id = resolved.clip.id
            -- Activate reader in pool (pool lookup, no I/O if cached)
            media_cache.activate(resolved.media_path, context_id)

            -- Apply rotation from media metadata (phone footage portrait/landscape)
            local asset_info = media_cache.get_asset_info(context_id)
            if asset_info then
                viewer_panel.set_rotation(asset_info.rotation or 0)
            end

            logger.debug("timeline_playback",
                string.format("Switched to clip %s at media %s (rotation=%d)",
                    resolved.clip.id:sub(1,8), resolved.media_path,
                    asset_info and asset_info.rotation or 0))
        end

        -- Show the correct source frame using integer index (no time round-trip).
        -- show_frame_at_time(source_time_us) would lose a frame at 24fps due to
        -- floor(frame*1e6/24) → floor(result*24/1e6) = frame-1 for non-multiples of 3.
        viewer_panel.show_frame(resolved.source_frame)

        -- Update prefetch thread with source-space position so background
        -- decoder stays ahead of playback. Only during active playback
        -- (direction != 0); parked seeks don't need prefetch.
        if direction and direction ~= 0 then
            media_cache.set_playhead(resolved.source_frame, direction, speed, context_id)
        end
    else
        -- Gap at playhead - show black
        viewer_panel.show_gap()
        -- Reset clip tracking so next clip triggers switch
        current_clip_id = nil
    end

    local source_time_us = resolved and resolved.source_time_us or nil
    return current_clip_id, source_time_us
end

--------------------------------------------------------------------------------
-- Timeline Mode Tick
--------------------------------------------------------------------------------

--- Execute one tick of timeline playback.
-- Pure function: reads tick_in, returns tick_result. Does NOT commit state —
-- playback_controller owns the ordering: resolve → commit position → sync callback.
-- @param tick_in table READ-ONLY snapshot of playback state (see contract above)
-- @param audio_playback Audio playback module reference
-- @param viewer_panel Viewer panel module reference
-- @return tick_result table with { continue, new_pos, current_clip_id, frame_idx }
function M.tick(tick_in, audio_playback, viewer_panel)
    assert(viewer_panel, "timeline_playback.tick: viewer_panel not set")
    assert_tick_in(tick_in)

    -- Frame advancement: video ALWAYS follows audio when audio is active (Rule V1)
    -- STUCKNESS DETECTION: if audio reports the same frame as last_audio_frame,
    -- it hasn't advanced (exhaustion, J-cut, gap). Switch to frame-based.
    -- last_audio_frame is tracked separately from displayed frame to avoid oscillation:
    -- frame-based advance changes displayed frame but must NOT reset the audio tracker.
    local pos
    local result_audio_frame = nil  -- non-nil when audio is driving (for tracker update)
    local audio_can_drive = audio_playback and audio_playback.is_ready()
        and audio_playback.playing and audio_playback.has_audio

    if audio_can_drive then
        local timeline_time_us = audio_playback.get_time_us()
        local audio_frame = helpers.calc_frame_from_time_us(
            timeline_time_us, tick_in.fps_num, tick_in.fps_den)

        if tick_in.last_audio_frame ~= nil
           and audio_frame == tick_in.last_audio_frame then
            -- Audio stuck: advance frame-based (J-cut, gap, end of content)
            pos = tick_in.pos + (tick_in.direction * tick_in.speed)
            -- result_audio_frame stays nil → controller won't update tracker
        else
            -- Audio advancing: video follows audio time (Rule V1)
            pos = audio_frame
            result_audio_frame = audio_frame
        end
    else
        -- NO AUDIO: Advance frame independently
        pos = tick_in.pos + (tick_in.direction * tick_in.speed)
    end

    -- Clamp to valid range
    pos = math.max(0, math.min(pos, tick_in.total_frames - 1))

    -- Boundary detection (timeline stops at boundaries, no latching)
    local hit_start = (tick_in.direction < 0 and pos <= 0)
    local hit_end = (tick_in.direction > 0 and pos >= tick_in.total_frames - 1)

    if hit_start or hit_end then
        local boundary_frame = hit_start and 0 or (tick_in.total_frames - 1)
        logger.debug("timeline_playback", hit_start and "Hit start boundary" or "Hit end boundary")
        return {
            continue = false,
            new_pos = boundary_frame,
            current_clip_id = tick_in.current_clip_id,
            frame_idx = math.floor(boundary_frame),
        }
    end

    -- Resolve and display FIRST so decode completes before controller commits
    -- position (which fires listener notifications → UI repaints).
    local frame_idx = math.floor(pos)
    local new_clip_id, source_time_us = M.resolve_and_display(
        tick_in.fps_num, tick_in.fps_den, tick_in.sequence_id, tick_in.current_clip_id,
        tick_in.direction, tick_in.speed, viewer_panel, audio_playback, frame_idx, tick_in.context_id)

    return {
        continue = true,
        new_pos = pos,
        current_clip_id = new_clip_id,
        frame_idx = frame_idx,
        source_time_us = source_time_us,
        audio_frame = result_audio_frame,
    }
end

return M
