-- Timeline State Data
-- Holds the central state table and notification system

local M = {}
local Rational = require("core.rational")
local ui_constants = require("core.ui_constants")

-- State listeners
local listeners = {}
local notify_timer = nil
local NOTIFY_DEBOUNCE_MS = ui_constants.TIMELINE.NOTIFY_DEBOUNCE_MS or 10

-- Qt timer bridge
local function create_single_shot_timer(delay_ms, callback)
    if type(qt_create_single_shot_timer) == "function" then
        return qt_create_single_shot_timer(delay_ms, callback)
    end
    callback()
    return nil
end

local function fresh_state()
    return {
        -- Data
        tracks = {},
        clips = {},
        project_id = nil,
        sequence_id = nil,
        
        -- Rate
        sequence_frame_rate = { fps_numerator = 30, fps_denominator = 1 },
        sequence_audio_rate = 48000,
        sequence_timecode_start_frame = 0,

        -- Viewport (Rational)
        viewport_start_time = Rational.new(0, 1, 1),
        viewport_duration = Rational.new(300, 1, 1), 

        -- Playhead (Rational)
        playhead_position = Rational.new(0, 1, 1),

        -- Selection
        selected_clips = {},
        selected_edges = {},
        selected_gaps = {},
        mark_in_value = nil,
        mark_out_value = nil,

        -- Interaction
        dragging_playhead = false,
        dragging_clip = nil,
        drag_selecting = false,
        drag_select_start_value = 0,

        -- Active edge drag (shared across timeline panes; not persisted)
        active_edge_drag_state = nil,
    }
end

-- The central state instance
M.state = fresh_state()

-- Dimensions (shared)
M.dimensions = {
    default_track_height = ui_constants.TIMELINE.TRACK_HEIGHT or 50,
    track_height = ui_constants.TIMELINE.TRACK_HEIGHT or 50,
    track_header_width = ui_constants.TIMELINE.TRACK_HEADER_WIDTH or 240,
    ruler_height = ui_constants.TIMELINE.RULER_HEIGHT or 32,
}

function M.reset()
    M.state = fresh_state()
    listeners = {}
    notify_timer = nil
end

function M.add_listener(callback)
    table.insert(listeners, callback)
end

function M.remove_listener(callback)
    for i, listener in ipairs(listeners) do
        if listener == callback then
            table.remove(listeners, i)
            return
        end
    end
end

function M.notify_listeners()
    if notify_timer then return end
    notify_timer = create_single_shot_timer(NOTIFY_DEBOUNCE_MS, function()
        notify_timer = nil
        for _, listener in ipairs(listeners) do
            listener()
        end
    end)
end

return M
