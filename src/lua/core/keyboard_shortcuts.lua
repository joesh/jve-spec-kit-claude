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
    -- print(string.format("Key pressed: key=%d, modifiers=%d, text='%s'", key, modifiers, text))

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
            timeline_state.clear_selection()
            timeline_state.notify_state_changed()
            print(string.format("Deleted %d clips", #selected_clips))
            return true
        end
    end

    -- Cmd/Ctrl + A: Select all clips
    if key == KEY.A and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if timeline_state then
            local all_clips = timeline_state.get_clips()
            timeline_state.clear_selection()
            for _, clip in ipairs(all_clips) do
                timeline_state.toggle_clip_selection(clip.id)
            end
            timeline_state.notify_state_changed()
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
                local new_position = math.max(0, clip.position + nudge_amount)
                timeline_state.update_clip_position(clip.id, new_position)
            end
            timeline_state.notify_state_changed()
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

    return false  -- Event not handled
end

return keyboard_shortcuts
