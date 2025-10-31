-- Keyboard Shortcuts Module
-- Centralized keyboard shortcut handling for the video editor

local keyboard_shortcuts = {}
local frame_utils = require("core.frame_utils")

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
    Q = 81,
    W = 87,
    E = 69,
    R = 82,
    T = 84,
    Plus = 43,       -- '+'
    Minus = 45,      -- '-'
    Equal = 61,      -- '=' (also + on US keyboards)
    Comma = 44,      -- ','
    Period = 46,     -- '.'
    F9 = 16777272,   -- 0x01000038
    F10 = 16777273,  -- 0x01000039
    Return = 16777220,
    Enter = 16777221,
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
        if type(rate) == "number" and rate > 0 then
            return rate
        end
    end
    return frame_utils.default_frame_rate
end

-- Initialize with references to other modules
function keyboard_shortcuts.init(state, cmd_mgr, proj_browser, panel)
    timeline_state = state
    command_manager = cmd_mgr
    project_browser = proj_browser
    timeline_panel = panel
    redo_toggle_state = nil
end

-- Get effective snapping state (baseline XOR drag_inverted)
function keyboard_shortcuts.is_snapping_enabled()
    local effective = baseline_snapping_enabled
    if drag_snapping_inverted then
        effective = not effective
    end

    if (key == KEY.Return or key == KEY.Enter) then
        if focus_manager and focus_manager.get_focused_panel and focus_manager.get_focused_panel() == "project_browser" then
            if command_manager then
                local result = command_manager.execute("ActivateBrowserSelection")
                if not result.success then
                    print(string.format("⚠️  ActivateBrowserSelection returned error: %s", result.error_message or "unknown"))
                end
            end
            return true
        end
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

-- Check if a modifier is active (LuaJIT compatible bitwise AND)
local function has_modifier(modifiers, mod)
    local bit = require("bit")
    return bit.band(modifiers, mod) ~= 0
end

-- Global key handler function (called from Qt event filter)
function keyboard_shortcuts.handle_key(event)
    local key = event.key
    local modifiers = event.modifiers
    local text = event.text

    local modifier_meta = has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)
    local modifier_shift = has_modifier(modifiers, MOD.Shift)
    local modifier_alt = has_modifier(modifiers, MOD.Alt)

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

    -- Left/Right arrows: Move playhead (frame or 1-second jumps with Shift)
    if (key == KEY.Left or key == KEY.Right) and timeline_state then
        if not modifier_meta and not modifier_alt then
            local frame_rate = get_active_frame_rate()
            local current_time = timeline_state.get_playhead_time and timeline_state.get_playhead_time() or 0
            local current_frame = frame_utils.time_to_frame(current_time, frame_rate)
            local step_frames = modifier_shift and math.max(1, math.floor(frame_rate + 0.5)) or 1
            if key == KEY.Left then
                current_frame = math.max(0, current_frame - step_frames)
            else
                current_frame = current_frame + step_frames
            end
            local new_time = frame_utils.frame_to_time(current_frame, frame_rate)
            timeline_state.set_playhead_time(new_time)
            return true
        end
    end

    -- Mark In/Out controls
    if key == KEY.I and timeline_state then
        if not modifier_meta and not modifier_alt then
            if modifier_shift then
                local mark_in = timeline_state.get_mark_in and timeline_state.get_mark_in()
                if mark_in then
                    timeline_state.set_playhead_time(mark_in)
                end
            else
                local playhead = timeline_state.get_playhead_time and timeline_state.get_playhead_time() or 0
                timeline_state.set_mark_in(playhead)
            end
            return true
        end
    end

    if key == KEY.O and timeline_state then
        if not modifier_meta and not modifier_alt then
            if modifier_shift then
                local mark_out = timeline_state.get_mark_out and timeline_state.get_mark_out()
                if mark_out then
                    timeline_state.set_playhead_time(mark_out)
                end
            else
                local playhead = timeline_state.get_playhead_time and timeline_state.get_playhead_time() or 0
                timeline_state.set_mark_out(playhead)
            end
            return true
        end
    end

    if key == KEY.X and timeline_state then
        if modifier_alt and not modifier_meta then
            timeline_state.clear_marks()
            return true
        elseif not modifier_meta and not modifier_alt then
            local playhead = timeline_state.get_playhead_time and timeline_state.get_playhead_time() or 0
            local clips = timeline_state.get_clips and timeline_state.get_clips() or {}
            local best_clip = nil
            local best_priority = nil

            for _, clip in ipairs(clips) do
                local clip_start = clip.start_time or 0
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
                local clip_start = best_clip.start_time or 0
                local clip_out = clip_start + (best_clip.duration or 0)
                timeline_state.set_mark_in(clip_start)
                timeline_state.set_mark_out(clip_out)
            end
            return true
        end
    end

    -- Delete/Backspace: contextual delete (project browser or timeline)
    if key == KEY.Delete or key == KEY.Backspace then
        local focused_panel = focus_manager and focus_manager.get_focused_panel and focus_manager.get_focused_panel()
        if project_browser and focused_panel == "project_browser" then
            if project_browser.delete_selected_items and project_browser.delete_selected_items() then
                clear_redo_toggle()
            end
            return true
        end

        if not (timeline_state and command_manager) then
            return false
        end

        local selected_clips = timeline_state.get_selected_clips()
        local shift_held = has_modifier(modifiers, MOD.Shift)
        clear_redo_toggle()

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

            -- Build array of delete command specs for batch operation
            local command_specs = {}
            for _, clip in ipairs(selected_clips) do
                table.insert(command_specs, {
                    command_type = "DeleteClip",
                    parameters = {
                        clip_id = clip.id
                    }
                })
            end

            -- Execute as single batch command (single undo entry)
            local commands_json = json.encode(command_specs)
            local batch_cmd = Command.create("BatchCommand", "default_project")
            batch_cmd:set_parameter("commands_json", commands_json)

            local result = command_manager.execute(batch_cmd)
            if result.success then
                timeline_state.set_selection({})
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
                gap_start = gap.start_time,
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
                print(string.format("Ripple deleted gap of %dms on track %s", gap.duration, tostring(gap.track_id)))
            else
                print(string.format("Failed to ripple delete gap: %s", result.error_message or "unknown error"))
            end
            return true
        end
    end

    -- Cmd/Ctrl + A: Select all clips
    -- Shift + Cmd/Ctrl + A: Deselect all
    if key == KEY.A and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if command_manager then
            local command_name
            if has_modifier(modifiers, MOD.Shift) then
                command_name = "DeselectAll"
            else
                command_name = "SelectAll"
            end

            local result = command_manager.execute(command_name)
            if not result.success then
                print(string.format("⚠️  %s returned error: %s", command_name, result.error_message or "unknown"))
            end
            return true
        end
    end

    if key == KEY.Up and command_manager then
        local result = command_manager.execute("GoToPrevEdit")
        if not result.success then
            print(string.format("⚠️  GoToPrevEdit returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    if key == KEY.Down and command_manager then
        local result = command_manager.execute("GoToNextEdit")
        if not result.success then
            print(string.format("⚠️  GoToNextEdit returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    if key == KEY.Home and command_manager then
        local result = command_manager.execute("GoToStart")
        if not result.success then
            print(string.format("⚠️  GoToStart returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    if key == KEY.End and command_manager then
        local result = command_manager.execute("GoToEnd")
        if not result.success then
            print(string.format("⚠️  GoToEnd returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    -- Comma/Period: Frame-accurate nudge for clips and edges
    -- Comma (,) = left, Period (.) = right
    -- Without Shift: 1 frame, With Shift: 5 frames
    if (key == KEY.Comma or key == KEY.Period) and timeline_state and command_manager and not modifier_meta and not modifier_alt then
        local frame_rate = get_active_frame_rate()
        local nudge_frames = modifier_shift and 5 or 1
        local nudge_ms = frame_utils.frame_to_time(nudge_frames, frame_rate)
        if key == KEY.Comma then
            nudge_ms = -nudge_ms
        end
        clear_redo_toggle()

        local direction = (nudge_ms < 0) and "left" or "right"
        local frame_count = math.abs(nudge_frames)
        local timecode_str
        do
            local ok, formatted = pcall(frame_utils.format_timecode, math.abs(nudge_ms), frame_rate)
            if ok and formatted then
                timecode_str = formatted
            else
                timecode_str = string.format("%d frame(s)", frame_count)
            end
        end

        local selected_clips = timeline_state.get_selected_clips()
        local selected_edges = timeline_state.get_selected_edges()

        local Command = require("command")

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
                local batch_cmd = Command.create("BatchRippleEdit", "default_project")
                batch_cmd:set_parameter("edge_infos", edge_infos)
                batch_cmd:set_parameter("delta_ms", nudge_ms)
                batch_cmd:set_parameter("sequence_id", "default_sequence")
                result = command_manager.execute(batch_cmd)
            elseif #edge_infos == 1 then
                local ripple_cmd = Command.create("RippleEdit", "default_project")
                ripple_cmd:set_parameter("edge_info", edge_infos[1])
                ripple_cmd:set_parameter("delta_ms", nudge_ms)
                ripple_cmd:set_parameter("sequence_id", "default_sequence")
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

            local nudge_cmd = Command.create("Nudge", "default_project")
            nudge_cmd:set_parameter("nudge_amount_ms", nudge_ms)
            nudge_cmd:set_parameter("selected_clip_ids", clip_ids)

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

    -- Space: Play/Pause (placeholder - actual playback not implemented yet)
    if key == KEY.Space then
        print("Play/Pause (not implemented yet)")
        return true
    end

    -- I: Mark in point (placeholder)
    if key == KEY.I then
        print("Mark In (not implemented yet)")
        return true
    end

    -- O: Mark out point (placeholder)
    if key == KEY.O then
        print("Mark Out (not implemented yet)")
        return true
    end

    -- Cmd/Ctrl + B: Blade tool - split clips at playhead
    if key == KEY.B and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if timeline_state and command_manager then
            local selected_clips = timeline_state.get_selected_clips()
            local playhead_time = timeline_state.get_playhead_time()

            local target_clips
            if selected_clips and #selected_clips > 0 then
                target_clips = timeline_state.get_clips_at_time(playhead_time, selected_clips)
            else
                target_clips = timeline_state.get_clips_at_time(playhead_time)
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
                local start_time = clip.start_time
                local end_time = clip.start_time + clip.duration
                if playhead_time > start_time and playhead_time < end_time then
                    table.insert(specs, {
                        command_type = "SplitClip",
                        parameters = {
                            clip_id = clip.id,
                            split_time = playhead_time
                        }
                    })
                end
            end

            if #specs == 0 then
                print("Blade: No valid clips to split at current playhead position")
                return true
            end

            local batch_cmd = Command.create("BatchCommand", "default_project")
            batch_cmd:set_parameter("commands_json", json.encode(specs))

            local result = command_manager.execute(batch_cmd)
            if result.success then
                print(string.format("Blade: Split %d clip(s) at %dms", #specs, playhead_time))
            else
                print(string.format("Blade: Failed to split clips: %s", result.error_message or "unknown error"))
            end
        end
        return true
    end

    -- J/K/L: Playback controls (industry standard)
    if key == KEY.J then
        print("Reverse playback (not implemented yet)")
        return true
    end
    if key == KEY.K then
        print("Pause (not implemented yet)")
        return true
    end
    if key == KEY.L then
        print("Forward playback (not implemented yet)")
        return true
    end

    -- Q/W/E/R/T: Tool switching
    if key == KEY.Q then
        print("Select tool (not implemented yet)")
        return true
    end
    if key == KEY.W then
        print("Track select tool (not implemented yet)")
        return true
    end
    if key == KEY.E then
        print("Trim tool (not implemented yet)")
        return true
    end
    if key == KEY.R then
        print("Ripple tool (not implemented yet)")
        return true
    end
    if key == KEY.T then
        print("Roll tool (not implemented yet)")
        return true
    end

    -- F9: INSERT at playhead (ripple subsequent clips forward)
    if key == KEY.F9 then
        if command_manager and timeline_state and project_browser then
            -- Get selected media from project browser
            local selected_clip = project_browser.get_selected_media()
            if not selected_clip then
                print("❌ INSERT: No media selected in project browser")
                return true
            end

            local media_id = selected_clip.media_id or (selected_clip.media and selected_clip.media.id)
            if not media_id then
                print("❌ INSERT: Selected clip missing media reference")
                return true
            end

            local clip_duration = selected_clip.duration or (selected_clip.media and selected_clip.media.duration) or 0

            local Command = require("command")
            local playhead_time = timeline_state.get_playhead_time()
            local project_id = timeline_state.get_project_id and timeline_state.get_project_id() or "default_project"
            local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or "default_sequence"
            local track_id = timeline_state.get_default_video_track_id and timeline_state.get_default_video_track_id() or nil
            if not track_id or track_id == "" then
                print("❌ INSERT: Active sequence has no video tracks")
                return true
            end

            local insert_cmd = Command.create("Insert", project_id)
            insert_cmd:set_parameter("master_clip_id", selected_clip.clip_id)
            insert_cmd:set_parameter("media_id", media_id)
            insert_cmd:set_parameter("sequence_id", sequence_id)
            insert_cmd:set_parameter("track_id", track_id)
            insert_cmd:set_parameter("insert_time", playhead_time)
            insert_cmd:set_parameter("duration", clip_duration)
            insert_cmd:set_parameter("source_in", 0)
            insert_cmd:set_parameter("source_out", clip_duration)
            insert_cmd:set_parameter("project_id", project_id)
            insert_cmd:set_parameter("advance_playhead", true)  -- Command will move playhead
            local result = command_manager.execute(insert_cmd)
            if result.success then
                print(string.format("✅ INSERT: Added %s at %dms, rippled subsequent clips", selected_clip.name or media_id, playhead_time))
            else
                print("❌ INSERT failed: " .. (result.error_message or "unknown error"))
            end
        end
        return true
    end

    -- F10: OVERWRITE at playhead (trim/replace existing clips)
    if key == KEY.F10 then
        if command_manager and timeline_state and project_browser then
            -- Get selected media from project browser
            local selected_clip = project_browser.get_selected_media()
            if not selected_clip then
                print("❌ OVERWRITE: No media selected in project browser")
                return true
            end

            local media_id = selected_clip.media_id or (selected_clip.media and selected_clip.media.id)
            if not media_id then
                print("❌ OVERWRITE: Selected clip missing media reference")
                return true
            end

            local clip_duration = selected_clip.duration or (selected_clip.media and selected_clip.media.duration) or 0

            local Command = require("command")
            local playhead_time = timeline_state.get_playhead_time()
            local project_id = timeline_state.get_project_id and timeline_state.get_project_id() or "default_project"
            local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or "default_sequence"
            local track_id = timeline_state.get_default_video_track_id and timeline_state.get_default_video_track_id() or nil
            if not track_id or track_id == "" then
                print("❌ OVERWRITE: Active sequence has no video tracks")
                return true
            end

            local overwrite_cmd = Command.create("Overwrite", project_id)
            overwrite_cmd:set_parameter("master_clip_id", selected_clip.clip_id)
            overwrite_cmd:set_parameter("media_id", media_id)
            overwrite_cmd:set_parameter("sequence_id", sequence_id)
            overwrite_cmd:set_parameter("track_id", track_id)
            overwrite_cmd:set_parameter("overwrite_time", playhead_time)
            overwrite_cmd:set_parameter("duration", clip_duration)
            overwrite_cmd:set_parameter("source_in", 0)
            overwrite_cmd:set_parameter("source_out", clip_duration)
            overwrite_cmd:set_parameter("project_id", project_id)
            overwrite_cmd:set_parameter("advance_playhead", true)  -- Command will move playhead
            local result = command_manager.execute(overwrite_cmd)
            if result.success then
                print(string.format("✅ OVERWRITE: Added %s at %dms, trimmed overlapping clips", selected_clip.name or media_id, playhead_time))
            else
                print("❌ OVERWRITE failed: " .. (result.error_message or "unknown error"))
            end
        end
        return true
    end

    -- Shift + Z: Scale timeline to fit (zoom to show all content)
    if key == KEY.Z and has_modifier(modifiers, MOD.Shift) then
        if timeline_state then
            -- Calculate total timeline duration needed to show all clips
            local clips = timeline_state.get_clips()
            local max_end_time = 0
            for _, clip in ipairs(clips) do
                local clip_end = clip.start_time + clip.duration
                if clip_end > max_end_time then
                    max_end_time = clip_end
                end
            end

            if max_end_time > 0 then
                -- Add 10% padding on the right side for breathing room
                local viewport_duration = math.floor(max_end_time * 1.1)
                timeline_state.set_viewport_duration(viewport_duration)
                timeline_state.set_viewport_start_time(0)
                print(string.format("Scaled to fit: showing 0 - %dms", viewport_duration))
            else
                print("No clips to scale to")
            end
        end
        return true
    end

    -- Cmd/Ctrl + Plus/Equal: Zoom in
    if (key == KEY.Plus or key == KEY.Equal) and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if timeline_state then
            local current_duration = timeline_state.get_viewport_duration()
            local new_duration = math.floor(current_duration / 1.5)  -- Zoom in by 50%
            if new_duration < 100 then
                new_duration = 100  -- Minimum zoom level
            end
            timeline_state.set_viewport_duration(new_duration)
            print(string.format("Zoomed in: viewport duration %dms", new_duration))
        end
        return true
    end

    -- Cmd/Ctrl + Minus: Zoom out
    if key == KEY.Minus and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if timeline_state then
            local current_duration = timeline_state.get_viewport_duration()
            local new_duration = math.floor(current_duration * 1.5)  -- Zoom out by 50%
            timeline_state.set_viewport_duration(new_duration)
            print(string.format("Zoomed out: viewport duration %dms", new_duration))
        end
        return true
    end

    -- Option/Alt + Up: Move selected clips up one track
    -- Video: up means higher track number (V1→V2→V3)
    -- Audio: up means lower track number (A3→A2→A1)
    if key == KEY.Up and has_modifier(modifiers, MOD.Alt) then
        if timeline_state and command_manager then
            local selected_clips = timeline_state.get_selected_clips()
            if #selected_clips > 0 then
                -- Check if all clips are on the same track
                local first_track_id = selected_clips[1].track_id
                local all_same_track = true
                print(string.format("DEBUG: Alt+Up - checking %d clips, first on track %s",
                    #selected_clips, first_track_id))
                for i, clip in ipairs(selected_clips) do
                    print(string.format("  Clip %d: %s on track %s",
                        i, clip.id:sub(1,8), clip.track_id))
                    if clip.track_id ~= first_track_id then
                        all_same_track = false
                        break
                    end
                end

                if not all_same_track then
                    print("Cannot move clips: selection spans multiple tracks")
                    return true
                end

                -- Store clip IDs before moving (clip objects will become stale)
                local clip_ids = {}
                for _, clip in ipairs(selected_clips) do
                    table.insert(clip_ids, clip.id)
                end

                local tracks = timeline_state.get_all_tracks()
                local moved_count = 0

                -- Move each clip by ID, reloading fresh data each time
                for _, clip_id in ipairs(clip_ids) do
                    -- Get fresh clip data from timeline_state
                    local all_clips = timeline_state.get_clips()
                    local clip = nil
                    for _, c in ipairs(all_clips) do
                        if c.id == clip_id then
                            clip = c
                            break
                        end
                    end

                    if not clip then
                        print(string.format("WARNING: Clip %s not found", clip_id))
                        goto continue
                    end

                    -- Find current track
                    local current_track_index = -1
                    local current_track = nil
                    for i, track in ipairs(tracks) do
                        if track.id == clip.track_id then
                            current_track_index = i
                            current_track = track
                            break
                        end
                    end

                    if current_track then
                        local target_track_index = -1

                        -- For VIDEO tracks: "up" means higher index (V1→V2→V3)
                        -- For AUDIO tracks: "up" means lower index (A3→A2→A1)
                        if current_track.track_type == "VIDEO" then
                            target_track_index = current_track_index + 1
                        else  -- AUDIO
                            target_track_index = current_track_index - 1
                        end

                        -- Validate target track exists and is same type
                        if target_track_index >= 1 and target_track_index <= #tracks then
                            local target_track = tracks[target_track_index]

                            if target_track.track_type == current_track.track_type then
                                local Command = require("command")
                                local move_cmd = Command.create("MoveClipToTrack", "default_project")
                                move_cmd:set_parameter("clip_id", clip.id)
                                move_cmd:set_parameter("target_track_id", target_track.id)

                                local result = command_manager.execute(move_cmd)
                                if result.success then
                                    moved_count = moved_count + 1
                                end
                            end
                        end
                    end

                    ::continue::
                end

                if moved_count > 0 then
                    print(string.format("Moved %d clip(s) up one track", moved_count))
                else
                    print("Cannot move clips up (at limit or type mismatch)")
                end
            else
                print("No clips selected to move")
            end
        end
        return true
    end

    -- Option/Alt + Down: Move selected clips down one track
    -- Video: down means lower track number (V3→V2→V1)
    -- Audio: down means higher track number (A1→A2→A3)
    if key == KEY.Down and has_modifier(modifiers, MOD.Alt) then
        if timeline_state and command_manager then
            local selected_clips = timeline_state.get_selected_clips()
            if #selected_clips > 0 then
                -- Check if all clips are on the same track
                local first_track_id = selected_clips[1].track_id
                local all_same_track = true
                print(string.format("DEBUG: Alt+Down - checking %d clips, first on track %s",
                    #selected_clips, first_track_id))
                for i, clip in ipairs(selected_clips) do
                    print(string.format("  Clip %d: %s on track %s",
                        i, clip.id:sub(1,8), clip.track_id))
                    if clip.track_id ~= first_track_id then
                        all_same_track = false
                        break
                    end
                end

                if not all_same_track then
                    print("Cannot move clips: selection spans multiple tracks")
                    return true
                end

                -- Store clip IDs before moving (clip objects will become stale)
                local clip_ids = {}
                for _, clip in ipairs(selected_clips) do
                    table.insert(clip_ids, clip.id)
                end

                local tracks = timeline_state.get_all_tracks()
                local moved_count = 0

                -- Move each clip by ID, reloading fresh data each time
                for _, clip_id in ipairs(clip_ids) do
                    -- Get fresh clip data from timeline_state
                    local all_clips = timeline_state.get_clips()
                    local clip = nil
                    for _, c in ipairs(all_clips) do
                        if c.id == clip_id then
                            clip = c
                            break
                        end
                    end

                    if not clip then
                        print(string.format("WARNING: Clip %s not found", clip_id))
                        goto continue
                    end

                    -- Find current track
                    local current_track_index = -1
                    local current_track = nil
                    for i, track in ipairs(tracks) do
                        if track.id == clip.track_id then
                            current_track_index = i
                            current_track = track
                            break
                        end
                    end

                    if current_track then
                        local target_track_index = -1

                        -- For VIDEO tracks: "down" means lower index (V3→V2→V1)
                        -- For AUDIO tracks: "down" means higher index (A1→A2→A3)
                        if current_track.track_type == "VIDEO" then
                            target_track_index = current_track_index - 1
                        else  -- AUDIO
                            target_track_index = current_track_index + 1
                        end

                        -- Validate target track exists and is same type
                        if target_track_index >= 1 and target_track_index <= #tracks then
                            local target_track = tracks[target_track_index]
                            if target_track.track_type == current_track.track_type then
                                local Command = require("command")
                                local move_cmd = Command.create("MoveClipToTrack", "default_project")
                                move_cmd:set_parameter("clip_id", clip.id)
                                move_cmd:set_parameter("target_track_id", target_track.id)

                                local result = command_manager.execute(move_cmd)
                                if result.success then
                                    moved_count = moved_count + 1
                                end
                            end
                        end
                    end

                    ::continue::
                end

                if moved_count > 0 then
                    print(string.format("Moved %d clip(s) down one track", moved_count))
                else
                    print("Cannot move clips down (at limit or type mismatch)")
                end
            else
                print("No clips selected to move")
            end
        end
        return true
    end

    -- N: Toggle magnetic snapping (context-aware)
    if key == KEY.N and not has_modifier(modifiers, MOD.Shift) and
       not has_modifier(modifiers, MOD.Control) and not has_modifier(modifiers, MOD.Meta) then
        if keyboard_shortcuts.is_dragging() then
            -- During drag: invert snapping for this drag only
            keyboard_shortcuts.invert_drag_snapping()
        else
            -- At rest: toggle baseline preference
            keyboard_shortcuts.toggle_baseline_snapping()
        end
        return true
    end

    return false  -- Event not handled
end

return keyboard_shortcuts
