--- Source Viewer State Module
--
-- Responsibilities:
-- - Manages playhead for the source viewer
-- - Provides access to masterclip marks via stream clips
-- - Notifies listeners on state changes (for mark bar, viewer panel, etc.)
-- - Debounces DB persistence for playhead to avoid per-frame writes during playback
--
-- Invariants:
-- - Source viewer only shows masterclip sequences (kind="masterclip")
-- - Marks are stored in stream clips (source_in/source_out), not local state
-- - Playhead is persisted to DB via sequence record
--
-- Non-goals:
-- - Does not own video decoding or display (viewer_panel does that)
-- - Does not handle keyboard input (keyboard_shortcuts routes to us)
--
-- @file source_viewer_state.lua

local logger = require("core.logger")
local database = require("core.database")
local Sequence = require("models.sequence")

local M = {}

-- Current state
M.current_sequence_id = nil
M.current_masterclip = nil  -- Sequence object for stream access (must be masterclip)
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

    if not M.current_sequence_id then return end
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
-- Saves to the masterclip sequence's playhead_frame field.
function M.save_playhead_to_db()
    if not M.current_masterclip then return end
    if not database.has_connection() then return end

    M.current_masterclip.playhead_position = M.playhead
    M.current_masterclip:save()
end

--- Load masterclip sequence and initialize viewer state.
-- Asserts if sequence is not a masterclip.
-- @param sequence_id string: masterclip sequence ID
-- @param total_frames number: total source frames
-- @param fps_num number: FPS numerator
-- @param fps_den number: FPS denominator
function M.load_masterclip(sequence_id, total_frames, fps_num, fps_den)
    assert(sequence_id and sequence_id ~= "",
        "source_viewer_state.load_masterclip: sequence_id required")
    assert(total_frames and total_frames > 0,
        "source_viewer_state.load_masterclip: total_frames must be > 0")
    assert(fps_num and fps_num > 0,
        "source_viewer_state.load_masterclip: fps_num must be > 0")
    assert(fps_den and fps_den > 0,
        "source_viewer_state.load_masterclip: fps_den must be > 0")

    -- Save previous masterclip's playhead before switching
    if M.current_sequence_id and M.current_sequence_id ~= sequence_id then
        M.save_playhead_to_db()
    end

    -- Load masterclip sequence
    local masterclip = Sequence.load(sequence_id)
    assert(masterclip, string.format(
        "source_viewer_state.load_masterclip: sequence %s not found", sequence_id))
    assert(masterclip:is_masterclip(), string.format(
        "source_viewer_state.load_masterclip: sequence %s is not a masterclip (kind=%s)",
        sequence_id, tostring(masterclip.kind)))

    M.current_sequence_id = sequence_id
    M.current_masterclip = masterclip
    M.total_frames = total_frames
    M.fps_num = fps_num
    M.fps_den = fps_den

    -- Load playhead from sequence record
    M.playhead = masterclip.playhead_position or 0

    -- Marks come from stream clips - no local state
    local mark_in = M.get_mark_in()
    local mark_out = M.get_mark_out()

    logger.info("source_viewer_state", string.format(
        "Loaded masterclip %s: playhead=%d, mark_in=%s, mark_out=%s",
        sequence_id, M.playhead,
        tostring(mark_in), tostring(mark_out)))

    notify()
end

--- Unload current masterclip (saves playhead first).
function M.unload()
    if M.current_sequence_id then
        M.save_playhead_to_db()
    end

    M.current_sequence_id = nil
    M.current_masterclip = nil
    M.total_frames = 0
    M.fps_num = nil
    M.fps_den = nil
    M.playhead = 0

    notify()
end

--- Check if a masterclip is loaded.
function M.has_clip()
    return M.current_sequence_id ~= nil
end

--- Get mark in from stream clips (video frame value)
-- @return number|nil Video frame position, or nil if marks not synced
function M.get_mark_in()
    if not M.current_masterclip then
        return nil
    end
    return M.current_masterclip:get_all_streams_in()
end

--- Get mark out from stream clips (video frame value)
-- @return number|nil Video frame position, or nil if marks not synced
function M.get_mark_out()
    if not M.current_masterclip then
        return nil
    end
    return M.current_masterclip:get_all_streams_out()
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
-- Updates stream clips in masterclip sequence.
-- @param frame number: frame index (in video frames)
function M.set_mark_in(frame)
    assert(frame ~= nil, "source_viewer_state.set_mark_in: frame is nil")
    assert(M.current_masterclip,
        "source_viewer_state.set_mark_in: no masterclip loaded")

    local mark_frame = math.floor(frame)
    M.current_masterclip:set_all_streams_in(mark_frame)

    logger.info("source_viewer_state", string.format(
        "Mark IN set to frame %d (masterclip %s)", mark_frame, M.current_sequence_id))

    notify()
end

--- Set mark out at given frame.
-- Updates stream clips in masterclip sequence.
-- @param frame number: frame index (in video frames)
function M.set_mark_out(frame)
    assert(frame ~= nil, "source_viewer_state.set_mark_out: frame is nil")
    assert(M.current_masterclip,
        "source_viewer_state.set_mark_out: no masterclip loaded")

    local mark_frame = math.floor(frame)
    M.current_masterclip:set_all_streams_out(mark_frame)

    logger.info("source_viewer_state", string.format(
        "Mark OUT set to frame %d (masterclip %s)", mark_frame, M.current_sequence_id))

    notify()
end

--- Clear both marks (playhead preserved).
-- Resets stream clips to full media duration.
function M.clear_marks()
    assert(M.current_masterclip,
        "source_viewer_state.clear_marks: no masterclip loaded")

    -- Reset in to 0
    M.current_masterclip:set_all_streams_in(0)

    -- Reset out to full duration (video if available, else audio)
    local video = M.current_masterclip:video_stream()
    if video then
        M.current_masterclip:set_all_streams_out(video.source_out)
    else
        -- Audio-only: use total_frames (which is in sample units for audio-only)
        local audio_streams = M.current_masterclip:audio_streams()
        assert(#audio_streams > 0, string.format(
            "source_viewer_state.clear_marks: masterclip %s has no streams",
            M.current_sequence_id))
        M.current_masterclip:set_all_streams_out(audio_streams[1].source_out)
    end

    logger.info("source_viewer_state", string.format(
        "Marks cleared (masterclip %s)", M.current_sequence_id))

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
