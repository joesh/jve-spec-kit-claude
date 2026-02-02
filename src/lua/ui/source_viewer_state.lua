--- Source Viewer State Module
--
-- Responsibilities:
-- - Manages per-clip marks (in/out) and playhead for the source viewer
-- - Loads/saves state from/to clips table via database helpers
-- - Notifies listeners on state changes (for mark bar, viewer panel, etc.)
-- - Debounces DB persistence to avoid per-frame writes during playback
--
-- Non-goals:
-- - Does not own video decoding or display (viewer_panel does that)
-- - Does not handle keyboard input (keyboard_shortcuts routes to us)
--
-- @file source_viewer_state.lua

local logger = require("core.logger")
local database = require("core.database")

local M = {}

-- Current clip state
M.current_clip_id = nil
M.total_frames = 0
M.fps_num = nil
M.fps_den = nil
M.playhead = 0          -- int frame
M.mark_in = nil         -- int frame or nil
M.mark_out = nil        -- int frame or nil

-- Listener pattern
local listeners = {}

function M.add_listener(fn)
    assert(type(fn) == "function",
        "source_viewer_state.add_listener: fn must be a function")
    listeners[#listeners + 1] = fn
end

function M.remove_listener(fn)
    for i = #listeners, 1, -1 do
        if listeners[i] == fn then
            table.remove(listeners, i)
            return true
        end
    end
    return false
end

local function notify()
    for _, fn in ipairs(listeners) do
        fn()
    end
end

-- Debounced DB persistence
local DEBOUNCE_MS = 200
local persist_generation = 0

local function schedule_persist()
    persist_generation = persist_generation + 1
    local gen = persist_generation

    if not M.current_clip_id then return end
    if not database.has_connection() then return end

    -- Use Qt timer if available, otherwise persist immediately (tests)
    if _G.qt_create_single_shot_timer then
        _G.qt_create_single_shot_timer(DEBOUNCE_MS, function()
            if gen ~= persist_generation then return end  -- stale
            M.save_to_db()
        end)
    else
        M.save_to_db()
    end
end

--- Persist current state to database.
function M.save_to_db()
    if not M.current_clip_id then return end
    if not database.has_connection() then return end

    database.save_clip_marks(
        M.current_clip_id,
        M.mark_in,
        M.mark_out,
        M.playhead
    )
end

--- Load clip state from database and initialize viewer state.
-- @param clip_id string: clip row ID
-- @param total_frames number: total source frames
-- @param fps_num number: FPS numerator
-- @param fps_den number: FPS denominator
function M.load_clip(clip_id, total_frames, fps_num, fps_den)
    assert(clip_id and clip_id ~= "",
        "source_viewer_state.load_clip: clip_id required")
    assert(total_frames and total_frames > 0,
        "source_viewer_state.load_clip: total_frames must be > 0")
    assert(fps_num and fps_num > 0,
        "source_viewer_state.load_clip: fps_num must be > 0")
    assert(fps_den and fps_den > 0,
        "source_viewer_state.load_clip: fps_den must be > 0")

    -- Save previous clip's state before switching
    if M.current_clip_id and M.current_clip_id ~= clip_id then
        M.save_to_db()
    end

    M.current_clip_id = clip_id
    M.total_frames = total_frames
    M.fps_num = fps_num
    M.fps_den = fps_den

    -- Load persisted marks from DB
    local marks = database.load_clip_marks(clip_id)
    if marks then
        M.mark_in = marks.mark_in_frame
        M.mark_out = marks.mark_out_frame
        M.playhead = marks.playhead_frame or 0
    else
        -- Clip exists but no marks row (shouldn't happen with DEFAULT 0, but be safe)
        M.mark_in = nil
        M.mark_out = nil
        M.playhead = 0
    end

    logger.info("source_viewer_state", string.format(
        "Loaded clip %s: playhead=%d, mark_in=%s, mark_out=%s",
        clip_id, M.playhead,
        tostring(M.mark_in), tostring(M.mark_out)))

    notify()
end

--- Unload current clip (saves state first).
function M.unload()
    if M.current_clip_id then
        M.save_to_db()
    end

    M.current_clip_id = nil
    M.total_frames = 0
    M.fps_num = nil
    M.fps_den = nil
    M.playhead = 0
    M.mark_in = nil
    M.mark_out = nil

    notify()
end

--- Check if a clip is loaded.
function M.has_clip()
    return M.current_clip_id ~= nil
end

--- Set playhead position (clamped to valid range).
-- @param frame number: frame index
function M.set_playhead(frame)
    assert(frame ~= nil, "source_viewer_state.set_playhead: frame is nil")

    local clamped = math.max(0, math.min(math.floor(frame), M.total_frames - 1))
    if clamped == M.playhead then return end

    M.playhead = clamped
    notify()
    schedule_persist()
end

--- Set mark in at given frame.
-- @param frame number: frame index
function M.set_mark_in(frame)
    assert(frame ~= nil, "source_viewer_state.set_mark_in: frame is nil")
    assert(M.current_clip_id,
        "source_viewer_state.set_mark_in: no clip loaded")

    M.mark_in = math.floor(frame)

    logger.info("source_viewer_state", string.format(
        "Mark IN set to frame %d (clip %s)", M.mark_in, M.current_clip_id))

    notify()
    schedule_persist()
end

--- Set mark out at given frame.
-- @param frame number: frame index
function M.set_mark_out(frame)
    assert(frame ~= nil, "source_viewer_state.set_mark_out: frame is nil")
    assert(M.current_clip_id,
        "source_viewer_state.set_mark_out: no clip loaded")

    M.mark_out = math.floor(frame)

    logger.info("source_viewer_state", string.format(
        "Mark OUT set to frame %d (clip %s)", M.mark_out, M.current_clip_id))

    notify()
    schedule_persist()
end

--- Clear both marks (playhead preserved).
function M.clear_marks()
    if not M.current_clip_id then return end

    M.mark_in = nil
    M.mark_out = nil

    logger.info("source_viewer_state", string.format(
        "Marks cleared (clip %s)", M.current_clip_id))

    notify()
    schedule_persist()
end

return M
