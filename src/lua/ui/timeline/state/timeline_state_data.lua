--- Timeline state data: the module-level state table that every
--- timeline-state-concern (core, clips, tracks, selection, viewport,
--- geometry) reads and writes through. Also owns the change-listener
--- list: subscribers call add_listener / remove_listener and receive
--- a debounced notification whenever model state changes.
---
--- @file timeline_state_data.lua
local M = {}
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
        -- Spec 022 Phase 1.3f: tracks / clips / content_length live on
        -- TimelineTab.cache (the per-tab cache architecture). Reads
        -- come through strip:displayed_tracks() / displayed_clips() and
        -- track_state / clip_state, both routing to the displayed tab.
        project_id = nil,
        sequence_id = nil,

        -- Tab/sequence pointers (FR-005 / data-model.md §3)
        -- active_sequence_id is the Record sequence targeted by edits; backed
        -- by sequence_id (kept as the canonical internal name to avoid touching
        -- every internal call site). The displayed tab id is NOT carried in
        -- data.state — it lives exclusively on the TimelineTabStrip (015 #6).
        -- Use timeline_state.get_displayed_tab_id() (or strip_holder for
        -- modules that can't import timeline_state directly).

        -- Rate
        sequence_frame_rate = { fps_numerator = 30, fps_denominator = 1 },
        sequence_audio_rate = 48000,
        sequence_timecode_start_frame = 0,

        -- Viewport (integer frames)
        viewport_start_time = 0,
        viewport_duration = 300,

        -- Vertical scroll offsets (pixels, per-widget)
        video_scroll_offset = 0,
        audio_scroll_offset = 0,
        video_audio_split_ratio = 0.5,

        -- Playhead (integer frame)
        playhead_position = 0,
        is_playing = false,

        -- Selection
        selected_clips = {},
        selected_edges = {},
        selected_gaps = {},

        -- Interaction
        dragging_playhead = false,
        dragging_clip = nil,
        drag_selecting = false,
        drag_select_start_value = 0,

        -- Active edge drag (shared across timeline panes; not persisted)
        active_edge_drag_state = nil,

        -- Last pointer position in frames (updated by timeline_view_input on
        -- mouse move). Consumed by zoom-at-pointer commands. Nil until the
        -- cursor has been over a timeline widget.
        last_pointer_frame = nil,
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
    M.sequence = nil
    -- Strip-authoritative (015 #6): data.source_sequence cache removed;
    -- readers pull via tab_strip:get_source_tab() then Sequence.load.
    listeners = {}
    notify_timer = nil
end

--- Full state reset that preserves listener subscriptions.
-- Used on project change: views are long-lived and must stay subscribed
-- across projects so they re-paint when the new model is loaded (or stay
-- blank when the new project has no active sequence, per feature 010).
-- Unlike reset(), this does NOT touch the listener list.
function M.reset_state_preserve_listeners()
    M.state = fresh_state()
    M.sequence = nil
    -- Strip-authoritative (015 #6): data.source_sequence cache removed;
    -- readers pull via tab_strip:get_source_tab() then Sequence.load.
    notify_timer = nil
end

-- Spec 022 Phase 1.3f: set_clips + update_content_length DELETED.
-- Clip data lives on TimelineTab.cache; content_length is maintained
-- in-place by recompute_gap_clips_for_tab / tab:apply_mutations.

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

local function run_listeners()
    for _, listener in ipairs(listeners) do
        listener()
    end
end

function M.notify_listeners()
    if notify_timer then return end
    -- Mark scheduled BEFORE creating the timer. With a synchronous timer
    -- (test stubs), the callback runs inside create_single_shot_timer and
    -- resets notify_timer to nil; we must not clobber that nil with the
    -- timer's return value after it fires. Dropping the return handle is
    -- safe — nothing cancels the timer. Each scheduling uses a fresh token
    -- so that flush_pending_notify() can neutralise a pending timer by
    -- replacing the token without needing to cancel the Qt timer itself.
    local token = {}
    notify_timer = token
    create_single_shot_timer(NOTIFY_DEBOUNCE_MS, function()
        if notify_timer ~= token then return end  -- flushed early or superseded
        notify_timer = nil
        run_listeners()
    end)
end

-- Run pending listeners synchronously on the current tick. Used by interactive
-- viewport mutations (wheel, scrollbar, ruler scrub) so that every subscribed
-- widget repaints on the same frame instead of the input-receiving widget
-- rendering now and everyone else catching up ~NOTIFY_DEBOUNCE_MS later. The
-- pending Qt timer, if any, becomes a no-op when it fires because we clear
-- notify_timer here; the in-flight closure compares against its captured token.
function M.flush_pending_notify()
    if not notify_timer then return end
    notify_timer = nil
    run_listeners()
end

return M
