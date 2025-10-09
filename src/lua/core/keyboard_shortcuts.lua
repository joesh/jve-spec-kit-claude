-- Keyboard Shortcuts Module
-- Centralized keyboard shortcut handling for the video editor

local keyboard_shortcuts = {}

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
}

-- Qt modifier constants (from Qt::KeyboardModifier enum)
local MOD = {
    NoModifier = 0,
    Shift = 0x02000000,
    Control = 0x04000000,
    Alt = 0x08000000,
    Meta = 0x10000000,
}

-- References to timeline state and other modules
local timeline_state = nil
local command_manager = nil

-- Initialize with references to other modules
function keyboard_shortcuts.init(state, cmd_mgr)
    timeline_state = state
    command_manager = cmd_mgr
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

    -- Debug output
    print(string.format("Key pressed: key=%d, modifiers=%d, text='%s'", key, modifiers, text))

    -- Direct test for B key
    if key == 66 then
        print(string.format("RAW B DETECTED! KEY.B=%d, match=%s", KEY.B, tostring(key == KEY.B)))
    end

    -- Cmd/Ctrl + Z: Undo
    if key == KEY.Z and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if has_modifier(modifiers, MOD.Shift) then
            -- Cmd/Ctrl + Shift + Z: Redo
            if command_manager then
                command_manager.redo()
                print("Redo")
            end
        else
            -- Cmd/Ctrl + Z: Undo
            if command_manager then
                command_manager.undo()
                print("Undo")
            end
        end
        return true  -- Event handled
    end

    -- Delete/Backspace: Delete selected clips
    if (key == KEY.Delete or key == KEY.Backspace) and timeline_state then
        local selected_clips = timeline_state.get_selected_clips()
        if #selected_clips > 0 then
            for _, clip in ipairs(selected_clips) do
                timeline_state.remove_clip(clip.id)
            end
            timeline_state.set_selection({})
            print(string.format("Deleted %d clips", #selected_clips))
            return true
        end
    end

    -- Cmd/Ctrl + A: Select all clips
    if key == KEY.A and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if timeline_state then
            local all_clips = timeline_state.get_clips()
            timeline_state.set_selection(all_clips)
            print(string.format("Selected all %d clips", #all_clips))
            return true
        end
    end

    -- Arrow keys: Nudge selected clips
    if (key == KEY.Left or key == KEY.Right) and timeline_state then
        local selected_clips = timeline_state.get_selected_clips()
        if #selected_clips > 0 then
            local nudge_amount = 100  -- 100ms
            if has_modifier(modifiers, MOD.Shift) then
                nudge_amount = 1000  -- 1 second with Shift
            end
            if key == KEY.Left then
                nudge_amount = -nudge_amount
            end

            for _, clip in ipairs(selected_clips) do
                local new_start_time = math.max(0, clip.start_time + nudge_amount)
                timeline_state.update_clip(clip.id, {start_time = new_start_time})
            end
            timeline_state.notify_state_changed()
            print(string.format("Nudged %d clips by %dms", #selected_clips, nudge_amount))
            return true
        end
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

    -- Cmd/Ctrl + B: Blade tool - split selected clip at playhead
    if key == KEY.B and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if timeline_state and command_manager then
            local selected_clips = timeline_state.get_selected_clips()
            local playhead_time = timeline_state.get_playhead_time()

            if #selected_clips == 1 then
                local clip = selected_clips[1]
                -- Check if playhead is within the clip bounds
                if playhead_time > clip.start_time and playhead_time < (clip.start_time + clip.duration) then
                    -- Create proper Command object
                    local Command = require("command")
                    local split_command = Command.create("SplitClip", "default_project")
                    split_command:set_parameter("clip_id", clip.id)
                    split_command:set_parameter("split_time", playhead_time)

                    local result = command_manager.execute(split_command)
                    if result.success then
                        -- Reload clips from database to pick up the split
                        timeline_state.reload_clips()
                        print(string.format("Split clip at playhead %dms", playhead_time))
                    else
                        print(string.format("Failed to split clip: %s", result.error_message))
                    end
                else
                    print("Playhead is not within selected clip bounds")
                end
            elseif #selected_clips == 0 then
                print("No clip selected for blade tool")
            else
                print("Blade tool requires exactly one selected clip")
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

    return false  -- Event not handled
end

return keyboard_shortcuts
