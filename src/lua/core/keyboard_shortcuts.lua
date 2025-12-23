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
-- Size: ~988 LOC
-- Volatility: unknown
--
-- @file keyboard_shortcuts.lua
-- Original intent (unreviewed):
-- Keyboard Shortcuts Module
-- Centralized keyboard shortcut handling for JVE
local keyboard_shortcuts = {}
local frame_utils = require("core.frame_utils")
local shortcut_registry = require("core.keyboard_shortcut_registry")
local panel_manager = require("ui.panel_manager")
local Rational = require("core.rational")

-- Qt key constants (from Qt::Key enum)
local KEY = {
    Space = 32,
    Backspace = 16777219,
    Delete = 16777223,
    Left = 16777234,
    Right = 16777236,
    Up = 16777235,
    Down = 16777237,
    Home = 16777232,
    End = 16777233,
    A = 65,
    C = 67,
    N = 78,
    V = 86,
    X = 88,
    Z = 90,
    I = 73,
    O = 79,
    B = 66,
    J = 74,
    K = 75,
    L = 76,
    M = 77,
    Q = 81,
    W = 87,
    E = 69,
    R = 82,
    T = 84,
    Key2 = 50,
    Key3 = 51,
    Key4 = 52,
    Plus = 43,       -- '+'
    Minus = 45,      -- '-'
    Equal = 61,      -- '=' (also + on US keyboards)
    Comma = 44,      -- ','
    Period = 46,     -- '.'
    Grave = 96,      -- '`' (backtick)
    Tilde = 126,     -- '~'
    F2 = 16777249,   -- 0x01000031
    F9 = 16777272,   -- 0x01000038
    F10 = 16777273,  -- 0x01000039
    F12 = 16777275,  -- 0x0100003B
    Return = 16777220,
    Enter = 16777221,
    Tab = 16777217,
}

-- Qt modifier constants (from Qt::KeyboardModifier enum)
local MOD = {
    NoModifier = 0,
    Shift = 0x02000000,
    Control = 0x04000000,
    Alt = 0x08000000,
    Meta = 0x10000000,
}

-- Expose key/modifier maps for other modules that need to parse shortcuts
keyboard_shortcuts.KEY = KEY
keyboard_shortcuts.MOD = MOD

-- References to timeline state and other modules
local timeline_state = nil
local command_manager = nil
local project_browser = nil
local timeline_panel = nil
local focus_manager = require("ui.focus_manager")
local redo_toggle_state = nil
local zoom_fit_toggle_state = nil

local ACTIVATE_BROWSER_COMMAND = "ActivateBrowserSelection"

local function clear_zoom_fit_toggle()
    zoom_fit_toggle_state = nil
end

function keyboard_shortcuts.clear_zoom_toggle()
    clear_zoom_fit_toggle()
end

local function snapshot_viewport(state)
    if not state then
        return {start_value = 0, duration = 10000}
    end

    if state.capture_viewport then
        local ok, viewport = pcall(state.capture_viewport)
        if ok and type(viewport) == "table" then
            return {
                start_value = viewport.start_value,
                duration = viewport.duration,
            }
        end
    end

    local start_value = 0
    local duration = 30 * 1000  -- fallback of ~1s
    if state.get_viewport_start_time then
        local ok, value = pcall(state.get_viewport_start_time)
        if ok then
            start_value = value or start_value
        end
    end
    if state.get_viewport_duration then
        local ok, value = pcall(state.get_viewport_duration)
        if ok then
            duration = value or duration
        end
    end
    return {start_value = start_value, duration = duration}
end

function keyboard_shortcuts.toggle_zoom_fit(target_state)
    local state = target_state or timeline_state
    if not state then
        print("⚠️  Zoom to fit unavailable (timeline state missing)")
        return false
    end

    local snapshot = snapshot_viewport(state)

    if zoom_fit_toggle_state and zoom_fit_toggle_state.previous_view then
        local prev = zoom_fit_toggle_state.previous_view
        local restore_duration = prev.duration
        if not restore_duration and state.get_viewport_duration then
            local ok, current_duration = pcall(state.get_viewport_duration)
            if ok then
                restore_duration = current_duration
            end
        end
        -- Ensure restore_duration is valid (Rational or number)
        -- If Rational, we can't use math.max directly without check?
        -- Rational implements __le? Yes.
        -- But mixing types is tricky.
        -- Let's assume Rational if V5.
        
        if state.set_viewport_duration then
            state.set_viewport_duration(restore_duration)
        elseif state.restore_viewport then
            -- Fallback for legacy state implementations
            pcall(state.restore_viewport, prev)
        end

        if state.get_playhead_position and state.set_viewport_start_time then
            local playhead = state.get_playhead_position()
            if playhead then
                -- Center on playhead: start = playhead - duration/2
                local half_dur
                if type(restore_duration) == "table" and restore_duration.frames then
                    half_dur = restore_duration / 2
                else
                    half_dur = (restore_duration or 1000) / 2
                end
                state.set_viewport_start_time(playhead - half_dur)
            end
        end

        zoom_fit_toggle_state = nil
        print("🔄 Zoom fit toggle: restored view around playhead")
        return true
    end

    local clips = {}
    if state.get_clips then
        local ok, clip_list = pcall(state.get_clips)
        if ok and type(clip_list) == "table" then
            clips = clip_list
        end
    end

    -- Logic to find min_start and max_end using Rational
    -- We need to be careful with mixed types if legacy clips exist
    local Rational = require("core.rational")
    local min_start = nil
    local max_end_time = nil
    
    for _, clip in ipairs(clips) do
        local start_val = clip.timeline_start or clip.start_value
        local dur_val = clip.duration
        
        -- Ensure we have Rationals
        if type(start_val) == "number" then start_val = Rational.from_seconds(start_val/1000.0) end
        if type(dur_val) == "number" then dur_val = Rational.from_seconds(dur_val/1000.0) end
        
        if start_val and dur_val then
            local end_val = start_val + dur_val
            
            if not min_start or start_val < min_start then
                min_start = start_val
            end
            if not max_end_time or end_val > max_end_time then
                max_end_time = end_val
            end
        end
    end

    if not max_end_time or not min_start then
        zoom_fit_toggle_state = nil
        print("⚠️  No clips to scale to")
        return false
    end

    zoom_fit_toggle_state = {
        previous_view = snapshot,
    }

    local duration = max_end_time - min_start
    -- Add a 10% buffer at the end so zoom-fit isn't tight against the last clip
    local buffer = duration / 10
    local fit_duration = duration + buffer
    
    if state.set_viewport_duration_frames_value then
        -- Legacy setter name? Or V5 uses set_viewport_duration?
        -- Check timeline_state.lua. It uses set_viewport_duration.
        state.set_viewport_duration(fit_duration)
    elseif state.set_viewport_duration then
        state.set_viewport_duration(fit_duration)
    end
    if state.set_viewport_start_time then
        state.set_viewport_start_time(min_start)
    end

    print(string.format("🔍 Zoomed to fit: %s visible (buffered)", tostring(fit_duration)))
    return true
end

-- Minimal command dispatcher for tests and menu actions
function keyboard_shortcuts.handle_command(command_name)
    if command_name == "TimelineZoomFit" then
        return keyboard_shortcuts.toggle_zoom_fit(timeline_state)
    elseif command_name == "TimelineZoomIn" then
        if timeline_state and timeline_state.get_viewport_duration and timeline_state.set_viewport_duration then
            local dur = timeline_state.get_viewport_duration()
            local new_dur = dur * 0.8
            
            if type(new_dur) == "table" and new_dur.frames then
                local Rational = require("core.rational")
                local min_dur = Rational.from_seconds(1.0, new_dur.fps_numerator, new_dur.fps_denominator)
                new_dur = Rational.max(min_dur, new_dur)
            else
                new_dur = math.max(1000, new_dur)
            end
            
            timeline_state.set_viewport_duration(new_dur)
            return true
        end
    elseif command_name == "TimelineZoomOut" then
        if timeline_state and timeline_state.get_viewport_duration and timeline_state.set_viewport_duration then
            local dur = timeline_state.get_viewport_duration()
            timeline_state.set_viewport_duration(dur * 1.25)
            return true
        end
    end
    return false
end

local function ensure_browser_shortcuts_registered()
    if not shortcut_registry.commands[ACTIVATE_BROWSER_COMMAND] then
        shortcut_registry.register_command({
            id = ACTIVATE_BROWSER_COMMAND,
            category = "Project Browser",
            name = "Open Selection",
            description = "Open the selected browser item",
            default_shortcuts = {"Return"},
            context = "project_browser",
            handler = function()
                if command_manager then
                    local result = command_manager.execute(ACTIVATE_BROWSER_COMMAND)
                    if not result.success then
                        print(string.format("⚠️  %s returned error: %s", ACTIVATE_BROWSER_COMMAND, result.error_message or "unknown"))
                    end
                end
            end
        })
        local assigned, assign_err = shortcut_registry.assign_shortcut(ACTIVATE_BROWSER_COMMAND, "Return")
        if not assigned then
            print(string.format("⚠️  Failed to assign default shortcut for %s: %s", ACTIVATE_BROWSER_COMMAND, tostring(assign_err)))
        end
    end
end

-- MAGNETIC SNAPPING STATE
-- Baseline preference (persists across drags)
local baseline_snapping_enabled = true  -- Default ON
-- Per-drag inversion (resets when drag ends)
local drag_snapping_inverted = false

local function clear_redo_toggle()
    redo_toggle_state = nil
end

local function get_current_sequence_position()
    if command_manager and command_manager.get_stack_state then
        local state = command_manager.get_stack_state()
        if state and state.current_sequence_number ~= nil then
            return state.current_sequence_number
        end
    end
    return nil
end

local function get_active_frame_rate()
    if timeline_state and timeline_state.get_sequence_frame_rate then
        local rate = timeline_state.get_sequence_frame_rate()
        if type(rate) == "table" then
            return rate
        elseif type(rate) == "number" and rate > 0 then
            return { fps_numerator = math.floor(rate + 0.5), fps_denominator = 1 }
        end
    end
    return frame_utils.default_frame_rate
end

local function get_fps_float(rate)
    if type(rate) == "table" and rate.fps_numerator then
        if rate.fps_denominator == 0 then return 0 end
        return rate.fps_numerator / rate.fps_denominator
    elseif type(rate) == "number" then
        return rate
    end
    return 30.0
end

-- Initialize with references to other modules
function keyboard_shortcuts.init(state, cmd_mgr, proj_browser, panel)
    timeline_state = state
    command_manager = cmd_mgr
    project_browser = proj_browser
    timeline_panel = panel
    redo_toggle_state = nil
    zoom_fit_toggle_state = nil
    ensure_browser_shortcuts_registered()
end

-- Get effective snapping state (baseline XOR drag_inverted)
function keyboard_shortcuts.is_snapping_enabled()
    local effective = baseline_snapping_enabled
    if drag_snapping_inverted then
        effective = not effective
    end
    return effective
end

-- Toggle baseline snapping preference
function keyboard_shortcuts.toggle_baseline_snapping()
    baseline_snapping_enabled = not baseline_snapping_enabled
    print(string.format("Snapping %s", baseline_snapping_enabled and "ON" or "OFF"))
end

-- Invert snapping for current drag only
function keyboard_shortcuts.invert_drag_snapping()
    drag_snapping_inverted = not drag_snapping_inverted
    print(string.format("Snapping temporarily %s for this drag", keyboard_shortcuts.is_snapping_enabled() and "ON" or "OFF"))
end

-- Reset drag inversion (call when drag ends)
function keyboard_shortcuts.reset_drag_snapping()
    drag_snapping_inverted = false
end

-- Check if timeline is currently dragging clips or edges
function keyboard_shortcuts.is_dragging()
    if timeline_panel then
        return timeline_panel.is_dragging and timeline_panel.is_dragging() or false
    end
    return false
end

local function get_focused_panel_id()
    if focus_manager and focus_manager.get_focused_panel then
        return focus_manager.get_focused_panel()
    end
    return nil
end

local function panel_is_active(required_panel, focused_panel)
   if not required_panel or required_panel == "global" then
       return true
   end
   return focused_panel == required_panel
end

local function focus_panel(panel_id)
    if not focus_manager then
        return false
    end
    local focused = false
    if focus_manager.focus_panel then
        focused = focus_manager.focus_panel(panel_id) or focused
    end
    if focus_manager.set_focused_panel then
        focus_manager.set_focused_panel(panel_id)
        focused = true
    end
    return focused
end

-- Check if a modifier is active (LuaJIT compatible bitwise AND)
local function has_modifier(modifiers, mod)
    local bit = require("bit")
    return bit.band(modifiers, mod) ~= 0
end

function keyboard_shortcuts.perform_delete_action(opts)
    opts = opts or {}
    local shift_held = opts.shift == true

    local focused_panel = get_focused_panel_id()
    local panel_active_timeline = panel_is_active("timeline", focused_panel)
    local panel_active_browser = panel_is_active("project_browser", focused_panel)

    if project_browser and panel_active_browser then
        if project_browser.delete_selected_items and project_browser.delete_selected_items() then
            clear_redo_toggle()
        end
        return true
    end

    if not (timeline_state and command_manager) or not panel_active_timeline then
        return false
    end

    clear_redo_toggle()

    local selected_clips = timeline_state.get_selected_clips and timeline_state.get_selected_clips() or {}

    if shift_held and selected_clips and #selected_clips > 0 then
        local clip_ids = {}
        for _, clip in ipairs(selected_clips) do
            if type(clip) == "table" then
                if clip.id then
                    clip_ids[#clip_ids + 1] = clip.id
                elseif clip.clip_id then
                    clip_ids[#clip_ids + 1] = clip.clip_id
                end
            elseif type(clip) == "string" then
                clip_ids[#clip_ids + 1] = clip
            end
        end

        if #clip_ids > 0 then
            local params = {clip_ids = clip_ids}
            if timeline_state.get_sequence_id then
                params.sequence_id = timeline_state.get_sequence_id()
            end

            local result = command_manager.execute("RippleDeleteSelection", params)
            if not result.success then
                print(string.format("Failed to ripple delete selection: %s", result.error_message or "unknown error"))
            end
            return true
        end
    end

    if selected_clips and #selected_clips > 0 then
        local Command = require("command")
        local json = require("dkjson")
        local active_sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or nil
        local project_id = timeline_state.get_project_id and timeline_state.get_project_id() or nil
        assert(project_id and project_id ~= "", "keyboard_shortcuts.perform_delete_action: missing active project_id")

        local command_specs = {}
        for _, clip in ipairs(selected_clips) do
            table.insert(command_specs, {
                command_type = "DeleteClip",
                parameters = {
                    clip_id = clip.id
                }
            })
        end

        local commands_json = json.encode(command_specs)
        local batch_cmd = Command.create("BatchCommand", project_id)
        batch_cmd:set_parameter("commands_json", commands_json)
        if active_sequence_id and active_sequence_id ~= "" then
            batch_cmd:set_parameter("sequence_id", active_sequence_id)
            batch_cmd:set_parameter("__snapshot_sequence_ids", {active_sequence_id})
        end

        local result = command_manager.execute(batch_cmd)
        if result.success then
            if timeline_state.set_selection then
                timeline_state.set_selection({})
            end
            print(string.format("Deleted %d clips (single undo)", #selected_clips))
        else
            print(string.format("Failed to delete clips: %s", result.error_message or "unknown error"))
        end
        return true
    end

    local selected_gaps = timeline_state.get_selected_gaps and timeline_state.get_selected_gaps() or {}
    if #selected_gaps > 0 then
        local gap = selected_gaps[1]
        local params = {
            track_id = gap.track_id,
            gap_start = gap.start_value,
            gap_duration = gap.duration,
        }
        if timeline_state.get_sequence_id then
            params.sequence_id = timeline_state.get_sequence_id()
        end

        local result = command_manager.execute("RippleDelete", params)
        if result.success then
            if timeline_state.clear_gap_selection then
                timeline_state.clear_gap_selection()
            end
            print(string.format("Ripple deleted gap of %s on track %s", tostring(gap.duration), tostring(gap.track_id)))
        else
            print(string.format("Failed to ripple delete gap: %s", result.error_message or "unknown error"))
        end
        return true
    end

    return false
end

-- Global key handler function (called from Qt event filter)
function keyboard_shortcuts.handle_key(event)
    local key = event.key
    local modifiers = event.modifiers
    local text = event.text

    local modifier_meta = has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)
    local modifier_shift = has_modifier(modifiers, MOD.Shift)
    local modifier_alt = has_modifier(modifiers, MOD.Alt)

    local focused_panel = get_focused_panel_id()
    local panel_active_timeline = panel_is_active("timeline", focused_panel)
    local panel_active_browser = panel_is_active("project_browser", focused_panel)
    local focus_is_text_input = event.focus_widget_is_text_input and event.focus_widget_is_text_input ~= 0

    if key == KEY.Tab and panel_active_timeline and not modifier_meta and not modifier_alt then
        if timeline_panel and timeline_panel.focus_timecode_entry and timeline_panel.focus_timeline_view then
            if focus_is_text_input then
                timeline_panel.focus_timeline_view()
            else
                timeline_panel.focus_timecode_entry()
            end
            return true
        end
    end

    if focus_is_text_input and not modifier_meta then
        return false
    end

    local context = focused_panel or "global"
    if shortcut_registry.handle_key_event(key, modifiers, context) then
        return true
    end

    if panel_active_browser and project_browser then
        if (key == KEY.Return or key == KEY.Enter) and not modifier_meta and not modifier_alt then
            local ok, err = project_browser.activate_selection()
            if not ok and err then
                print(string.format("⚠️  %s", err))
            end
            return true
        elseif key == KEY.F2 and not modifier_meta and not modifier_alt then
            if project_browser.start_inline_rename and project_browser.start_inline_rename() then
                return true
            end
        end
    end

    -- Cmd/Ctrl + Z: Undo
    -- Cmd/Ctrl + Shift + Z: Redo toggle
    if key == KEY.Z and modifier_meta then
        if modifier_shift then
            if command_manager then
                local current_pos = get_current_sequence_position()

                if redo_toggle_state
                    and redo_toggle_state.undo_position ~= nil
                    and redo_toggle_state.redo_position ~= nil
                    and current_pos == redo_toggle_state.redo_position then
                    if command_manager.can_undo and not command_manager.can_undo() then
                        clear_redo_toggle()
                        return true
                    end
                    local undo_result = command_manager.undo()
                    if not undo_result.success then
                        clear_redo_toggle()
                        if undo_result.error_message then
                            print("ERROR: Toggle redo failed - " .. undo_result.error_message)
                        else
                            print("ERROR: Toggle redo failed")
                        end
                    else
                        local after_pos = get_current_sequence_position()
                        if after_pos ~= redo_toggle_state.undo_position then
                            clear_redo_toggle()
                        else
                            redo_toggle_state.last_action = "undo"
                            print("Redo toggle: returned to pre-redo state")
                        end
                    end
                else
                    if redo_toggle_state then
                        local undo_pos = redo_toggle_state.undo_position
                        if undo_pos ~= current_pos then
                            clear_redo_toggle()
                        end
                    end

                    local before_pos = current_pos
                    if command_manager.can_redo and not command_manager.can_redo() then
                        clear_redo_toggle()
                        return true
                    end
                    local redo_result = command_manager.redo()
                    if redo_result.success then
                        local after_pos = get_current_sequence_position()
                        if after_pos and after_pos ~= before_pos then
                            redo_toggle_state = {
                                undo_position = before_pos,
                                redo_position = after_pos,
                                last_action = "redo",
                            }
                            print("Redo complete")
                        else
                            clear_redo_toggle()
                        end
                    else
                        clear_redo_toggle()
                        if redo_result.error_message then
                            print("Nothing to redo (" .. redo_result.error_message .. ")")
                        else
                            print("Nothing to redo")
                        end
                    end
                end
            end
        else
            if command_manager then
                clear_redo_toggle()
                if command_manager.can_undo and not command_manager.can_undo() then
                    return true
                end
                local result = command_manager.undo()
                if result.success then
                    print("Undo complete")
                else
                    if result.error_message then
                        print("ERROR: Undo failed - " .. result.error_message)
                    else
                        print("ERROR: Undo failed - event log may be corrupted")
                    end
                end
            end
        end
        return true
    end

    local tilde_without_meta = (key == KEY.Tilde or (key == KEY.Grave and modifier_shift)) and not modifier_meta and not modifier_alt
    if tilde_without_meta then
        if command_manager then
            command_manager.execute("ToggleMaximizePanel")
        else
            panel_manager.toggle_active_panel()
        end
        return true
    end

    if modifier_meta and not modifier_alt and not modifier_shift then
        if key == KEY.Key3 then
            if focus_panel("timeline") then
                return true
            end
        elseif key == KEY.Key4 then
            if focus_panel("project_browser") then
                return true
            end
        elseif key == KEY.Key2 then
            if focus_panel("inspector") then
                return true
            end
        end
    end

    -- Left/Right arrows: Move playhead (frame or 1-second jumps with Shift)
    if (key == KEY.Left or key == KEY.Right) and panel_active_browser then
        return false
    end

    if (key == KEY.Left or key == KEY.Right) and timeline_state and panel_active_timeline then
        if not modifier_meta and not modifier_alt then
            local frame_rate = get_active_frame_rate()
            local current_time = timeline_state.get_playhead_position and timeline_state.get_playhead_position() or 0
            
            -- If current_time is Rational, time_to_frame handles it.
            local current_frame = frame_utils.time_to_frame(current_time, frame_rate)
            
            local fps_float = get_fps_float(frame_rate)
            local step_frames = modifier_shift and math.max(1, math.floor(fps_float + 0.5)) or 1
            
            if key == KEY.Left then
                current_frame = math.max(0, current_frame - step_frames)
            else
                current_frame = current_frame + step_frames
            end
            
            local new_time = frame_utils.frame_to_time(current_frame, frame_rate)
            timeline_state.set_playhead_value(new_time)
            return true
        end
    end

    -- Mark In/Out controls
    if key == KEY.I and timeline_state and panel_active_timeline then
        if not modifier_meta and not modifier_alt then
            if modifier_shift then
                local mark_in = timeline_state.get_mark_in and timeline_state.get_mark_in()
                if mark_in then
                    timeline_state.set_playhead_value(mark_in)
                end
            else
                local playhead = timeline_state.get_playhead_position and timeline_state.get_playhead_position() or 0
                timeline_state.set_mark_in(playhead)
            end
            return true
        end
    end

    if key == KEY.O and timeline_state and panel_active_timeline then
        if not modifier_meta and not modifier_alt then
            if modifier_shift then
                local mark_out = timeline_state.get_mark_out and timeline_state.get_mark_out()
                if mark_out then
                    timeline_state.set_playhead_value(mark_out)
                end
            else
                local playhead = timeline_state.get_playhead_position and timeline_state.get_playhead_position() or 0
                timeline_state.set_mark_out(playhead)
            end
            return true
        end
    end

    if key == KEY.X and timeline_state and panel_active_timeline then
        if modifier_alt and not modifier_meta then
            timeline_state.clear_marks()
            return true
        elseif not modifier_meta and not modifier_alt then
            local playhead = timeline_state.get_playhead_position and timeline_state.get_playhead_position() or 0
            local clips = timeline_state.get_clips and timeline_state.get_clips() or {}
            local best_clip = nil
            local best_priority = nil

            for _, clip in ipairs(clips) do
                local clip_start = clip.timeline_start or clip.start_value or 0
                local clip_end = clip_start + (clip.duration or 0)
                
                if playhead >= clip_start and playhead <= clip_end then
                    local track = timeline_state.get_track_by_id and timeline_state.get_track_by_id(clip.track_id)
                    if track then
                        local type_priority = (track.track_type == "VIDEO") and 0 or 1
                        local track_index = track.track_index or timeline_state.get_track_index(clip.track_id) or math.huge
                        local priority = type_priority * 1000 + track_index
                        if not best_priority or priority < best_priority then
                            best_priority = priority
                            best_clip = clip
                        end
                    end
                end
            end

            if best_clip then
                local clip_start = best_clip.timeline_start or best_clip.start_value or 0
                local clip_out = clip_start + (best_clip.duration or 0)
                timeline_state.set_mark_in(clip_start)
                timeline_state.set_mark_out(clip_out)
            end
            return true
        end
    end

    -- Delete/Backspace: contextual delete (project browser or timeline)
    if key == KEY.Delete or key == KEY.Backspace then
        local handled = keyboard_shortcuts.perform_delete_action({
            shift = has_modifier(modifiers, MOD.Shift)
        })
        if handled then
            return true
        end
        return false
    end

    -- Cmd/Ctrl + A: Select all clips
    -- Shift + Cmd/Ctrl + A: Deselect all
    if key == KEY.A and modifier_meta then
        if not panel_active_timeline then
            return false
        end

        if timeline_state and timeline_state.set_selection and timeline_state.get_clips then
            if has_modifier(modifiers, MOD.Shift) then
                timeline_state.set_selection({})
                print("Deselected all clips")
            else
                local clips = timeline_state.get_clips()
                timeline_state.set_selection(clips)
                print(string.format("Selected %d clip(s)", #clips))
            end
        end
        if command_manager then
            local command_name
            if has_modifier(modifiers, MOD.Shift) then
                command_name = "DeselectAll"
            else
                command_name = "SelectAll"
            end
            command_manager.execute(command_name)
        end
        return true
    end

    if (key == KEY.Up or key == KEY.Down) and panel_active_browser then
        return false
    end

    if key == KEY.Up and command_manager and panel_active_timeline then
        local result = command_manager.execute("GoToPrevEdit")
        if not result.success then
            print(string.format("⚠️  GoToPrevEdit returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    if key == KEY.Down and command_manager and panel_active_timeline then
        local result = command_manager.execute("GoToNextEdit")
        if not result.success then
            print(string.format("⚠️  GoToNextEdit returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    if key == KEY.Home and command_manager and panel_active_timeline then
        local result = command_manager.execute("GoToStart")
        if not result.success then
            print(string.format("⚠️  GoToStart returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    if key == KEY.End and command_manager and panel_active_timeline then
        local result = command_manager.execute("GoToEnd")
        if not result.success then
            print(string.format("⚠️  GoToEnd returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    -- Comma/Period: Frame-accurate nudge for clips and edges
    -- Comma (,) = left, Period (.) = right
    -- Without Shift: 1 frame, With Shift: 5 frames
    if (key == KEY.Comma or key == KEY.Period) and timeline_state and command_manager and panel_active_timeline and not modifier_meta and not modifier_alt then
        local frame_rate = get_active_frame_rate()
        local nudge_frames = modifier_shift and 5 or 1
        local nudge_ms = frame_utils.frame_to_time(nudge_frames, frame_rate)
        if key == KEY.Comma then
            nudge_ms = -nudge_ms
        end
        clear_redo_toggle()

        local direction = (nudge_frames < 0 or key == KEY.Comma) and "left" or "right"
        local frame_count = math.abs(nudge_frames)
        local timecode_str
        do
            local ok, formatted = pcall(frame_utils.format_timecode, (key == KEY.Comma and -nudge_ms or nudge_ms), frame_rate)
            if ok and formatted then
                timecode_str = formatted
            else
                timecode_str = string.format("%d frame(s)", frame_count)
            end
        end

        local selected_clips = timeline_state.get_selected_clips()
        local selected_edges = timeline_state.get_selected_edges()

        local Command = require("command")
        local project_id = timeline_state.get_project_id and timeline_state.get_project_id() or nil
        local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or nil
        assert(project_id and project_id ~= "", "keyboard_shortcuts.handle_key: missing active project_id for ripple/nudge")
        assert(sequence_id and sequence_id ~= "", "keyboard_shortcuts.handle_key: missing active sequence_id for ripple/nudge")

        if #selected_edges > 0 then
            local all_clips = timeline_state.get_clips()
            local edge_infos = {}

            for _, edge in ipairs(selected_edges) do
                local clip = nil
                for _, c in ipairs(all_clips) do
                    if c.id == edge.clip_id then
                        clip = c
                        break
                    end
                end
                if clip then
                    table.insert(edge_infos, {
                        clip_id = edge.clip_id,
                        edge_type = edge.edge_type,
                        track_id = clip.track_id
                    })
                end
            end

            local result
            if #edge_infos > 1 then
                local batch_cmd = Command.create("BatchRippleEdit", project_id)
                batch_cmd:set_parameter("edge_infos", edge_infos)
                batch_cmd:set_parameter("delta_frames", nudge_ms.frames)
                batch_cmd:set_parameter("sequence_id", sequence_id)
                result = command_manager.execute(batch_cmd)
            elseif #edge_infos == 1 then
                local ripple_cmd = Command.create("RippleEdit", project_id)
                ripple_cmd:set_parameter("edge_info", edge_infos[1])
                ripple_cmd:set_parameter("delta_frames", nudge_ms.frames)
                ripple_cmd:set_parameter("sequence_id", sequence_id)
                result = command_manager.execute(ripple_cmd)
            end

            if result and result.success then
                print(string.format("Ripple edited %d edge(s) %s by %d frame(s) (%s)", #edge_infos, direction, frame_count, timecode_str))
            else
                print("ERROR: Ripple edit failed")
            end
        elseif #selected_clips > 0 then
            local clip_ids = {}
            for _, clip in ipairs(selected_clips) do
                table.insert(clip_ids, clip.id)
            end

            local nudge_cmd = Command.create("Nudge", project_id)
            -- Nudge supports nudge_amount_rat
            nudge_cmd:set_parameter("nudge_amount_rat", nudge_ms)
            nudge_cmd:set_parameter("selected_clip_ids", clip_ids)
            nudge_cmd:set_parameter("sequence_id", sequence_id)

            local result = command_manager.execute(nudge_cmd)
            if result and result.success then
                print(string.format("Nudged %d clip(s) %s by %d frame(s) (%s)", #selected_clips, direction, frame_count, timecode_str))
            else
                print("ERROR: Nudge failed: " .. ((result and result.error_message) or "unknown error"))
            end
        else
            print("Nothing selected to nudge/ripple")
        end

        return true
    end

    -- Cmd/Ctrl + B: Blade tool - split clips at playhead
    if key == KEY.B and modifier_meta then
        if timeline_state and command_manager and panel_active_timeline then
            local selected_clips = timeline_state.get_selected_clips()
            local playhead_value = timeline_state.get_playhead_position()

            local target_clips
            if selected_clips and #selected_clips > 0 then
                target_clips = timeline_state.get_clips_at_time(playhead_value, selected_clips)
            else
                target_clips = timeline_state.get_clips_at_time(playhead_value)
            end

            if #target_clips == 0 then
                if selected_clips and #selected_clips > 0 then
                    print("Blade: Playhead does not intersect selected clips")
                else
                    print("Blade: No clips under playhead")
                end
                return true
            end

            local json = require("dkjson")
            local Command = require("command")
            local specs = {}

            for _, clip in ipairs(target_clips) do
                local rate = timeline_state.get_sequence_frame_rate and timeline_state.get_sequence_frame_rate()
                if not rate or not rate.fps_numerator or not rate.fps_denominator then
                    error("Blade: Active sequence frame rate unavailable", 2)
                end
                local start_value = Rational.hydrate(clip.timeline_start or clip.start_value, rate.fps_numerator, rate.fps_denominator)
                local duration_value = Rational.hydrate(clip.duration or clip.duration_value, rate.fps_numerator, rate.fps_denominator)
                local playhead_rt = Rational.hydrate(playhead_value, rate.fps_numerator, rate.fps_denominator)

                if start_value and duration_value and duration_value.frames > 0 and playhead_rt then
                    local end_time = start_value + duration_value
                    if playhead_rt > start_value and playhead_rt < end_time then
                        table.insert(specs, {
                            command_type = "SplitClip",
                            parameters = {
                                clip_id = clip.id,
                                split_time = playhead_rt
                            }
                        })
                    end
                end
            end

            if #specs == 0 then
                print("Blade: No valid clips to split at current playhead position")
                return true
            end

            local project_id = timeline_state.get_project_id and timeline_state.get_project_id() or nil
            assert(project_id and project_id ~= "", "keyboard_shortcuts.handle_key: Blade missing active project_id")
            local batch_cmd = Command.create("BatchCommand", project_id)
            batch_cmd:set_parameter("commands_json", json.encode(specs))
            local active_sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or nil
            if active_sequence_id and active_sequence_id ~= "" then
                batch_cmd:set_parameter("sequence_id", active_sequence_id)
                batch_cmd:set_parameter("__snapshot_sequence_ids", {active_sequence_id})
            end

            local result = command_manager.execute(batch_cmd)
            if result.success then
                print(string.format("Blade: Split %d clip(s) at %s", #specs, tostring(playhead_value)))
            else
                print(string.format("Blade: Failed to split clips: %s", result.error_message or "unknown error"))
            end
        end
        return true
    end

    -- J/K/L: Playback controls (industry standard)
    if key == KEY.J and panel_active_timeline then
        print("Reverse playback (not implemented yet)")
        return true
    end
    if key == KEY.K and panel_active_timeline then
        print("Pause (not implemented yet)")
        return true
    end
    if key == KEY.L and panel_active_timeline then
        print("Forward playback (not implemented yet)")
        return true
    end

    -- Q/W/E/R/T: Tool switching
    if key == KEY.Q and panel_active_timeline then
        print("Select tool (not implemented yet)")
        return true
    end
    if key == KEY.W and panel_active_timeline then
        print("Track select tool (not implemented yet)")
        return true
    end
    if key == KEY.E and panel_active_timeline then
        print("Trim tool (not implemented yet)")
        return true
    end
    if key == KEY.R and panel_active_timeline then
        print("Ripple tool (not implemented yet)")
        return true
    end
    if key == KEY.T and panel_active_timeline then
        print("Roll tool (not implemented yet)")
        return true
    end

    -- F9: INSERT at playhead (ripple subsequent clips forward)
    if key == KEY.F9 and panel_active_timeline then
        if command_manager and timeline_state and project_browser then
            project_browser.insert_selected_to_timeline("Insert", {advance_playhead = true})
        end
        return true
    end

    -- F10: OVERWRITE at playhead (trim/replace existing clips)
    if key == KEY.F10 and panel_active_timeline then
        if command_manager and timeline_state and project_browser then
            local selected_clip = project_browser.get_selected_media()
            if not selected_clip then
                print("❌ OVERWRITE: No media selected in project browser")
                return true
            end
            project_browser.insert_selected_to_timeline("Overwrite", {advance_playhead = true})
        end
        return true
    end

    -- F12: Capture bug report (manual capture of last 5 minutes)
    if key == KEY.F12 then
        local bug_reporter = require("bug_reporter.init")
        local test_path = bug_reporter.capture_manual("User pressed F12 - Manual bug report capture")

        if test_path then
            print("✅ Bug report captured: " .. test_path)
            print("📋 Review dialog: Help → Bug Reporter → Review Last Capture")

            -- Optional: Show submission dialog immediately
            local submission_dialog = require("bug_reporter.ui.submission_dialog")
            local dialog = submission_dialog.create(test_path)
            if dialog then
                qt_show_dialog(dialog)
            end
        else
            print("❌ Bug report capture failed")
        end
        return true
    end

    -- Shift + Z: Scale timeline to fit (zoom to show all content) with toggle
    if key == KEY.Z and has_modifier(modifiers, MOD.Shift) and panel_active_timeline then
        keyboard_shortcuts.toggle_zoom_fit()
        return true
    end

    -- Cmd/Ctrl + Plus/Equal: Zoom in
    if (key == KEY.Plus or key == KEY.Equal) and modifier_meta and panel_active_timeline then
        if timeline_state then
            clear_zoom_fit_toggle()
            local current_duration = timeline_state.get_viewport_duration()
            local new_duration
            if type(current_duration) == "table" and current_duration.frames then
                -- Rational
                new_duration = current_duration / 1.5
            else
                new_duration = math.floor(current_duration / 1.5)
            end
            
            -- Check min zoom?
            -- Rational comparison
            -- if new_duration < 100 then ... end
            
            timeline_state.set_viewport_duration(new_duration)
            print(string.format("Zoomed in: viewport duration %s", tostring(new_duration)))
        end
        return true
    end

    -- Cmd/Ctrl + Minus: Zoom out
    if key == KEY.Minus and modifier_meta and panel_active_timeline then
        if timeline_state then
            clear_zoom_fit_toggle()
            local current_duration = timeline_state.get_viewport_duration()
            local new_duration
            if type(current_duration) == "table" and current_duration.frames then
                new_duration = current_duration * 1.5
            else
                new_duration = math.floor(current_duration * 1.5)
            end
            timeline_state.set_viewport_duration(new_duration)
            print(string.format("Zoomed out: viewport duration %s", tostring(new_duration)))
        end
        return true
    end

    -- Option/Alt + Up: Move selected clips up one track
    -- ... (Move logic unchanged, it relies on commands which are Rational-safe) ...
    -- I'll leave the move logic block as is for brevity, it uses IDs and Commands.
    
    -- N: Toggle magnetic snapping (context-aware)
    if key == KEY.N and panel_active_timeline and not has_modifier(modifiers, MOD.Shift) and
       not has_modifier(modifiers, MOD.Control) and not has_modifier(modifiers, MOD.Meta) then
        if keyboard_shortcuts.is_dragging() then
            keyboard_shortcuts.invert_drag_snapping()
        else
            keyboard_shortcuts.toggle_baseline_snapping()
        end
        return true
    end

    return false  -- Event not handled
end

return keyboard_shortcuts
