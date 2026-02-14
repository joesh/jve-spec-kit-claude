--- Undo/redo dispatch + toggle state machine.
--
-- The redo toggle allows pressing Cmd+Shift+Z repeatedly to alternate
-- between redo and undo (toggling the last redo). This is the standard
-- behavior in most NLEs.
--
-- @file undo_redo_controller.lua
local M = {}

local redo_toggle_state = nil

local function get_current_sequence_position(command_manager)
    if command_manager and command_manager.get_stack_state then
        local state = command_manager.get_stack_state()
        if state and state.current_sequence_number ~= nil then
            return state.current_sequence_number
        end
    end
    return nil
end

function M.clear_toggle()
    redo_toggle_state = nil
end

--- Handle undo (Cmd+Z). Clears redo toggle state.
function M.handle_undo(command_manager)
    assert(command_manager, "undo_redo_controller.handle_undo: command_manager required")

    M.clear_toggle()
    if command_manager.can_undo and not command_manager.can_undo() then
        return
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

--- Handle redo toggle (Cmd+Shift+Z).
-- First press: redo. Second press at redo position: undo back.
-- Third press: redo again. Etc.
function M.handle_redo_toggle(command_manager)
    assert(command_manager, "undo_redo_controller.handle_redo_toggle: command_manager required")

    local current_pos = get_current_sequence_position(command_manager)

    -- Check if we're at the redo position → toggle back to undo
    if redo_toggle_state
        and redo_toggle_state.undo_position ~= nil
        and redo_toggle_state.redo_position ~= nil
        and current_pos == redo_toggle_state.redo_position then
        if command_manager.can_undo and not command_manager.can_undo() then
            M.clear_toggle()
            return
        end
        local undo_result = command_manager.undo()
        if not undo_result.success then
            M.clear_toggle()
            if undo_result.error_message then
                print("ERROR: Toggle redo failed - " .. undo_result.error_message)
            else
                print("ERROR: Toggle redo failed")
            end
        else
            local after_pos = get_current_sequence_position(command_manager)
            if after_pos ~= redo_toggle_state.undo_position then
                M.clear_toggle()
            else
                redo_toggle_state.last_action = "undo"
                print("Redo toggle: returned to pre-redo state")
            end
        end
        return
    end

    -- Not at redo position → do a redo
    if redo_toggle_state then
        local undo_pos = redo_toggle_state.undo_position
        if undo_pos ~= current_pos then
            M.clear_toggle()
        end
    end

    local before_pos = current_pos
    if command_manager.can_redo and not command_manager.can_redo() then
        M.clear_toggle()
        return
    end
    local redo_result = command_manager.redo()
    if redo_result.success then
        local after_pos = get_current_sequence_position(command_manager)
        if after_pos and after_pos ~= before_pos then
            redo_toggle_state = {
                undo_position = before_pos,
                redo_position = after_pos,
                last_action = "redo",
            }
            print("Redo complete")
        else
            M.clear_toggle()
        end
    else
        M.clear_toggle()
        if redo_result.error_message then
            print("Nothing to redo (" .. redo_result.error_message .. ")")
        else
            print("Nothing to redo")
        end
    end
end

return M
