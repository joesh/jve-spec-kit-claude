--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~172 LOC
-- Volatility: unknown
--
-- @file viewport_state.lua
-- Original intent (unreviewed):
-- Timeline Viewport State
-- Manages viewport position, zoom, playhead, and pixel conversions
local M = {}
local data = require("ui.timeline.state.timeline_state_data")
local perf_log = require("core.logger").for_area("ui.scroll_perf")

local viewport_guard_count = 0

-- Helper: Compute content length based on clips in state (integer frames)
local function compute_sequence_content_length()
    local t0 = os.clock()
    local clips = data.state.clips
    assert(type(clips) == "table",
        "viewport_state.compute_sequence_content_length: data.state.clips is not a table")
    local max_end = 0
    for _, clip in ipairs(clips) do
        if type(clip.timeline_start) == "number" and type(clip.duration) == "number" then
            local clip_end = clip.timeline_start + clip.duration
            if clip_end > max_end then
                max_end = clip_end
            end
        end
    end
    perf_log.detail("compute_sequence_content_length: %.3fms n=%d max_end=%d",
        (os.clock() - t0) * 1000, #clips, max_end)
    return max_end
end

-- Helper: Calculate timeline extent (content + playhead + buffer) in frames.
--
-- `hypothetical_start` is the viewport start to consider when computing the
-- ceiling. Clamping callers pass the DESIRED start so the ceiling grows
-- ahead of the gesture in a single call. Readers (scrollbar) pass nil to
-- use the current viewport start — "how far can the timeline be scrolled
-- given where it sits right now".
--
-- Why this parameter exists: using the current start in the clamp path
-- caps each rightward call at (current_start + buffer_frames), throttling
-- large gestures to one buffer's worth of motion per event — downstream
-- scrolling felt orders of magnitude slower than upstream because of it.
local function calculate_timeline_extent(hypothetical_start)
    assert(hypothetical_start == nil
        or (type(hypothetical_start) == "number"
            and hypothetical_start == math.floor(hypothetical_start)),
        "viewport_state.calculate_timeline_extent: hypothetical_start must be nil or integer, got "
            .. tostring(hypothetical_start))
    local t0 = os.clock()
    local state = data.state
    local max_end = compute_sequence_content_length()

    local seq_fps = state.sequence_frame_rate
    assert(seq_fps and seq_fps.fps_numerator and seq_fps.fps_denominator,
        "viewport_state: missing sequence_frame_rate")

    if state.playhead_position > max_end then
        max_end = state.playhead_position
    end

    -- Explicit nil-check — hypothetical_start == 0 is a legitimate caller
    -- value (scrolling to frame 0), not a request for the default.
    local start_for_extent = hypothetical_start
    if start_for_extent == nil then
        start_for_extent = state.viewport_start_time
    end
    if start_for_extent and state.viewport_duration then
        local viewport_end = start_for_extent + state.viewport_duration
        if viewport_end > max_end then
            max_end = viewport_end
        end
    end

    local fps = seq_fps.fps_numerator / seq_fps.fps_denominator
    local buffer_frames = math.floor(10 * fps)
    local min_extent_frames = math.floor(60 * fps)

    local extent = math.max(min_extent_frames, max_end + buffer_frames)
    perf_log.detail("calculate_timeline_extent: %.3fms extent=%d hypothetical=%s",
        (os.clock() - t0) * 1000, extent, tostring(hypothetical_start))
    return extent
end

local function scroll_direction(delta)
    if delta > 0 then return "RIGHT" end
    if delta < 0 then return "LEFT" end
    return "ZERO"
end

-- Helper: Clamp viewport start (all integer frames)
local function clamp_viewport_start(desired_start, duration)
    assert(type(desired_start) == "number" and desired_start == math.floor(desired_start),
        "viewport_state: desired_start must be integer, got " .. tostring(desired_start))
    assert(type(duration) == "number" and duration == math.floor(duration),
        "viewport_state: duration must be integer, got " .. tostring(duration))

    -- Pass desired_start so the extent ceiling reflects where the viewport
    -- WANTS to go, not where it currently sits. See calculate_timeline_extent.
    local total_extent = calculate_timeline_extent(desired_start)
    -- Floor is start_timecode_frame (prevents scrolling into dead space before content)
    local floor = data.state.sequence_timecode_start_frame or 0
    local max_start = math.max(floor, total_extent - duration)

    if desired_start < floor then return floor end
    if desired_start > max_start then return max_start end
    return desired_start
end

local function ensure_playhead_visible()
    if viewport_guard_count > 0 then return false end
    -- Only auto-scroll during playback; when parked, user must be free to scroll
    if not data.state.is_playing then return false end
    local state = data.state

    local duration = state.viewport_duration
    if type(duration) ~= "number" or duration <= 0 then return false end

    local start = state.viewport_start_time
    local end_time = start + duration
    local playhead = state.playhead_position

    if playhead < start or playhead > end_time then
        local desired_start = playhead - math.floor(duration / 2)
        local clamped = clamp_viewport_start(desired_start, duration)
        if state.viewport_start_time ~= clamped then
            state.viewport_start_time = clamped
            return true
        end
    end
    return false
end

-- Padding applied when a change region must be scrolled into view and
-- the playhead can't share the frame. Fractional because viewports scale
-- with zoom; 5% reads as "a bit of space before the change" across zooms.
local REGION_SCROLL_PADDING_FRACTION = 0.05

--- Scroll the viewport to reveal a timeline range, preferring to keep
-- the playhead in view. Used by viewport_policy on undo/redo to surface
-- the change region of the undone/redone command.
--
-- Rules:
--   1. If the union of [start_frame, end_frame] and the playhead fits
--      inside the viewport, center that union's midpoint. Playhead and
--      the change region are both visible.
--   2. Otherwise — the playhead is far from the region, or the region
--      itself is wider than the viewport — anchor the range's upstream
--      edge to the viewport's left side plus a small padding. The
--      playhead may fall outside; region wins.
-- Viewport-guard-aware (skips when guarded, like surface_playhead).
-- Coordinates are integer frames.
function M.surface_range(start_frame, end_frame, persist_callback)
    assert(type(start_frame) == "number" and start_frame == math.floor(start_frame),
        "viewport_state.surface_range: start_frame must be integer")
    assert(type(end_frame) == "number" and end_frame == math.floor(end_frame),
        "viewport_state.surface_range: end_frame must be integer")
    assert(end_frame >= start_frame,
        "viewport_state.surface_range: end_frame must be >= start_frame")

    if viewport_guard_count > 0 then return false end
    local state = data.state
    local duration = state.viewport_duration
    if type(duration) ~= "number" or duration <= 0 then return false end

    local playhead = state.playhead_position
    local union_start = math.min(start_frame, playhead)
    local union_end = math.max(end_frame, playhead)
    local union_width = union_end - union_start

    local desired_start
    if union_width <= duration then
        -- Everything fits — center the union so both change region and
        -- playhead sit inside the viewport with balanced slack.
        local midpoint = math.floor((union_start + union_end) / 2)
        desired_start = midpoint - math.floor(duration / 2)
    else
        -- Region wins: upstream edge at viewport.start + padding.
        local padding = math.floor(duration * REGION_SCROLL_PADDING_FRACTION)
        desired_start = start_frame - padding
    end

    local clamped = clamp_viewport_start(desired_start, duration)
    if state.viewport_start_time ~= clamped then
        state.viewport_start_time = clamped
        data.notify_listeners()
        if persist_callback then persist_callback() end
        return true
    end
    return false
end

--- Explicitly scroll viewport to center on the playhead.
-- Unlike ensure_playhead_visible (playback-only auto-scroll),
-- this works when parked. Used by Find navigate_to_clip.
function M.surface_playhead(persist_callback)
    local state = data.state
    local duration = state.viewport_duration
    if type(duration) ~= "number" or duration <= 0 then return false end

    local playhead = state.playhead_position
    local start = state.viewport_start_time
    local end_time = start + duration

    -- Only scroll if playhead is outside viewport
    if playhead < start or playhead > end_time then
        local desired_start = playhead - math.floor(duration / 2)
        local clamped = clamp_viewport_start(desired_start, duration)
        if state.viewport_start_time ~= clamped then
            state.viewport_start_time = clamped
            data.notify_listeners()
            if persist_callback then persist_callback() end
            return true
        end
    end
    return false
end

function M.get_viewport_start_time()
    return data.state.viewport_start_time
end

--- Return the timeline extent in integer frames — the total scrollable
-- range given current content, playhead, and the current viewport
-- position. Intended for readers like the scrollbar that draw thumb
-- geometry against a stable total. Callers evaluating a scroll target
-- must go through set_viewport_start_time, which clamps against an
-- extent computed from the desired position rather than the current one.
function M.get_timeline_extent()
    return calculate_timeline_extent(nil)
end

function M.get_viewport_duration()
    return data.state.viewport_duration
end

function M.set_viewport_start_time(time_obj, persist_callback)
    assert(type(time_obj) == "number" and time_obj == math.floor(time_obj),
        "viewport_state.set_viewport_start_time: time must be integer, got " .. tostring(time_obj))
    local state = data.state
    assert(type(state.viewport_start_time) == "number",
        "viewport_state.set_viewport_start_time: viewport_start_time not initialized")

    local prev_start = state.viewport_start_time
    local t0 = os.clock()
    local clamped = clamp_viewport_start(time_obj, state.viewport_duration)
    local t_after_clamp = os.clock()

    local notified = prev_start ~= clamped
    if notified then
        state.viewport_start_time = clamped
        data.notify_listeners()
        if persist_callback then persist_callback() end
    end

    perf_log.detail(
        "set_viewport_start_time: %s desired_delta=%d clamped_to=%d notified=%s clamp=%.3fms total=%.3fms",
        scroll_direction(time_obj - prev_start), time_obj - prev_start, clamped, tostring(notified),
        (t_after_clamp - t0) * 1000, (os.clock() - t0) * 1000)
end

--- Resolve the anchor frame for a duration change.
-- Returns the frame in the OLD viewport whose pixel fraction should be
-- preserved in the new viewport. See set_viewport_duration for the opts
-- contract.
local function resolve_anchor_frame(opts, old_start, old_duration, playhead)
    if opts == nil then
        -- Auto: playhead if it lies inside the current viewport, else center.
        local old_end = old_start + old_duration
        if playhead >= old_start and playhead <= old_end then
            return playhead
        end
        return old_start + math.floor(old_duration / 2)
    end

    assert(type(opts) == "table",
        "viewport_state.set_viewport_duration: opts must be a table or nil")

    local mode = opts.zoom_around
    if mode == "playhead" then
        return playhead
    elseif mode == "center" then
        return old_start + math.floor(old_duration / 2)
    elseif mode == "frame" then
        local anchor = opts.anchor_frame
        assert(type(anchor) == "number" and anchor == math.floor(anchor),
            "viewport_state.set_viewport_duration: zoom_around='frame' requires integer anchor_frame")
        return anchor
    end

    assert(false, string.format(
        "viewport_state.set_viewport_duration: unknown zoom_around %q (expected 'playhead', 'center', or 'frame')",
        tostring(mode)))
end

--- Change the viewport duration while holding an anchor point's pixel
-- fraction fixed within the viewport.
--
-- @param duration_obj  integer frames — new viewport duration
-- @param opts          optional table:
--                        zoom_around  = "playhead" | "center" | "frame"
--                        anchor_frame = integer (required iff zoom_around="frame")
--                      When nil: auto (playhead if visible, else center).
-- @param persist_callback  optional function called after the state change
function M.set_viewport_duration(duration_obj, opts, persist_callback)
    local state = data.state
    assert(type(duration_obj) == "number" and duration_obj == math.floor(duration_obj),
        "viewport_state.set_viewport_duration: duration must be integer, got " .. tostring(duration_obj))

    if state.viewport_duration == duration_obj then return end

    local old_start = state.viewport_start_time
    local old_duration = state.viewport_duration
    local playhead = state.playhead_position
    local anchor = resolve_anchor_frame(opts, old_start, old_duration, playhead)

    -- Preserve the anchor's pixel fraction within the viewport.
    -- Clamp to [0,1] so an anchor outside the current viewport (e.g. the
    -- playhead after scrolling away) snaps to the nearest edge rather
    -- than pushing the viewport further away from it.
    local fraction = (anchor - old_start) / old_duration
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end
    local desired_start = math.floor(anchor - fraction * duration_obj + 0.5)
    local clamped_start = clamp_viewport_start(desired_start, duration_obj)

    state.viewport_duration = duration_obj
    state.viewport_start_time = clamped_start
    data.notify_listeners()
    if persist_callback then persist_callback() end
end

function M.get_playhead_position()
    return data.state.playhead_position
end

function M.set_playhead_position(time_obj, persist_callback, selection_callback)
    local state = data.state
    assert(type(time_obj) == "number" and time_obj == math.floor(time_obj),
        "viewport_state.set_playhead_position: time must be integer frame, got " .. tostring(time_obj))

    local floor = state.sequence_timecode_start_frame or 0
    local clamped = math.max(floor, time_obj)
    local changed = state.playhead_position ~= clamped
    state.playhead_position = clamped

    local viewport_adjusted = ensure_playhead_visible()

    if changed or viewport_adjusted then
        data.notify_listeners()
        if persist_callback then persist_callback() end
        if changed and selection_callback then selection_callback() end
    end
end

-- Convert time (integer frame) to pixel position
function M.time_to_pixel(time_obj, viewport_width)
    local state = data.state
    assert(type(time_obj) == "number" and math.floor(time_obj) == time_obj,
        "viewport_state.time_to_pixel: time must be integer frame")

    local start_frames = state.viewport_start_time
    local duration_frames = state.viewport_duration

    if type(start_frames) ~= "number" or type(duration_frames) ~= "number" then
        return 0
    end
    if duration_frames <= 0 then return 0 end

    local delta_frames = time_obj - start_frames
    local pixels_per_frame = viewport_width / duration_frames
    return math.floor(delta_frames * pixels_per_frame)
end

-- Convert pixel position to time (returns integer frame)
function M.pixel_to_time(pixel, viewport_width)
    local state = data.state
    local start_frames = state.viewport_start_time
    local duration_frames = state.viewport_duration

    if type(start_frames) ~= "number" or type(duration_frames) ~= "number" then
        return 0
    end
    if duration_frames <= 0 then
        return start_frames
    end

    local pixels_per_frame = viewport_width / duration_frames
    local delta_frames = pixel / pixels_per_frame
    return math.max(0, math.floor(start_frames + delta_frames + 0.5))
end

function M.push_viewport_guard()
    viewport_guard_count = viewport_guard_count + 1
    return viewport_guard_count
end

function M.pop_viewport_guard()
    if viewport_guard_count > 0 then
        viewport_guard_count = viewport_guard_count - 1
    end
    return viewport_guard_count
end

return M
