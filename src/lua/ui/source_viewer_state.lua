--- Source Viewer State Module
--
-- Responsibilities:
-- - Manages playhead for the source viewer
-- - Provides access to master clip marks via stream clips
-- - Notifies listeners on state changes (for mark bar, viewer panel, etc.)
-- - Debounces DB persistence for playhead to avoid per-frame writes during playback
--
-- Invariants:
-- - Source viewer only shows master clips
-- - Marks are stored in stream clips (source_in/source_out), not local state
-- - Playhead is persisted to DB, marks are persisted via stream clip save
--
-- Non-goals:
-- - Does not own video decoding or display (viewer_panel does that)
-- - Does not handle keyboard input (keyboard_shortcuts routes to us)
--
-- @file source_viewer_state.lua

local logger = require("core.logger")
local database = require("core.database")
local Clip = require("models.clip")

local M = {}

-- Current clip state
M.current_clip_id = nil
M.current_master_clip = nil  -- Clip object for stream access (must be master clip)
M.total_frames = 0
M.fps_num = nil
M.fps_den = nil
M.playhead = 0          -- int frame (persisted to DB)

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

-- Debounced DB persistence for playhead
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
            M.save_playhead_to_db()
        end)
    else
        M.save_playhead_to_db()
    end
end

--- Persist playhead to database.
-- Marks are persisted via stream clip save, not here.
function M.save_playhead_to_db()
    if not M.current_clip_id then return end
    if not database.has_connection() then return end

    -- Only save playhead; marks are in stream clips
    database.save_clip_marks(
        M.current_clip_id,
        nil,  -- mark_in stored in stream clips
        nil,  -- mark_out stored in stream clips
        M.playhead
    )
end

--- Load clip state and initialize viewer state.
-- Asserts if clip is not a master clip.
-- @param clip_id string: clip row ID (must be master clip)
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

    -- Save previous clip's playhead before switching
    if M.current_clip_id and M.current_clip_id ~= clip_id then
        M.save_playhead_to_db()
    end

    -- Load master clip - must be a master clip for source viewer
    local master_clip = Clip.load(clip_id)
    assert(master_clip:is_master_clip(), string.format(
        "source_viewer_state.load_clip: clip %s is not a master clip (kind=%s)",
        clip_id, tostring(master_clip.clip_kind)))

    M.current_clip_id = clip_id
    M.current_master_clip = master_clip
    M.total_frames = total_frames
    M.fps_num = fps_num
    M.fps_den = fps_den

    -- Load playhead from DB
    local marks = database.load_clip_marks(clip_id)
    M.playhead = (marks and marks.playhead_frame) or 0

    -- Marks come from stream clips - no local state
    local mark_in = M.get_mark_in()
    local mark_out = M.get_mark_out()

    logger.info("source_viewer_state", string.format(
        "Loaded clip %s: playhead=%d, mark_in=%s, mark_out=%s",
        clip_id, M.playhead,
        tostring(mark_in), tostring(mark_out)))

    notify()
end

--- Unload current clip (saves playhead first).
function M.unload()
    if M.current_clip_id then
        M.save_playhead_to_db()
    end

    M.current_clip_id = nil
    M.current_master_clip = nil
    M.total_frames = 0
    M.fps_num = nil
    M.fps_den = nil
    M.playhead = 0

    notify()
end

--- Check if a clip is loaded.
function M.has_clip()
    return M.current_clip_id ~= nil
end

--- Get mark in from stream clips (video frame value)
-- @return number|nil Video frame position, or nil if marks not synced
function M.get_mark_in()
    if not M.current_master_clip then
        return nil
    end
    return M.current_master_clip:get_all_streams_in()
end

--- Get mark out from stream clips (video frame value)
-- @return number|nil Video frame position, or nil if marks not synced
function M.get_mark_out()
    if not M.current_master_clip then
        return nil
    end
    return M.current_master_clip:get_all_streams_out()
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
-- Updates stream clips in master clip.
-- @param frame number: frame index (in video frames)
function M.set_mark_in(frame)
    assert(frame ~= nil, "source_viewer_state.set_mark_in: frame is nil")
    assert(M.current_master_clip,
        "source_viewer_state.set_mark_in: no clip loaded")

    local mark_frame = math.floor(frame)
    M.current_master_clip:set_all_streams_in(mark_frame)

    logger.info("source_viewer_state", string.format(
        "Mark IN set to frame %d (clip %s)", mark_frame, M.current_clip_id))

    notify()
end

--- Set mark out at given frame.
-- Updates stream clips in master clip.
-- @param frame number: frame index (in video frames)
function M.set_mark_out(frame)
    assert(frame ~= nil, "source_viewer_state.set_mark_out: frame is nil")
    assert(M.current_master_clip,
        "source_viewer_state.set_mark_out: no clip loaded")

    local mark_frame = math.floor(frame)
    M.current_master_clip:set_all_streams_out(mark_frame)

    logger.info("source_viewer_state", string.format(
        "Mark OUT set to frame %d (clip %s)", mark_frame, M.current_clip_id))

    notify()
end

--- Clear both marks (playhead preserved).
-- Resets stream clips to full media duration.
function M.clear_marks()
    assert(M.current_master_clip,
        "source_viewer_state.clear_marks: no clip loaded")

    -- Reset in to 0
    M.current_master_clip:set_all_streams_in(0)

    -- Reset out to full duration (video if available, else audio)
    local video = M.current_master_clip:video_stream()
    if video then
        M.current_master_clip:set_all_streams_out(video.source_out)
    else
        -- Audio-only: use total_frames (which is in sample units for audio-only)
        local audio_streams = M.current_master_clip:audio_streams()
        assert(#audio_streams > 0, string.format(
            "source_viewer_state.clear_marks: master clip %s has no streams",
            M.current_clip_id))
        M.current_master_clip:set_all_streams_out(audio_streams[1].source_out)
    end

    logger.info("source_viewer_state", string.format(
        "Marks cleared (clip %s)", M.current_clip_id))

    notify()
end

--- Clear state that shouldn't persist across projects
function M.on_project_change()
    M.unload()
end

-- Register for project_changed signal
local Signals = require("core.signals")
Signals.connect("project_changed", M.on_project_change, 50)

return M
