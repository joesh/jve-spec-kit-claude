--- SelectBrowserItems Command - Handle project browser item selection
--
-- Encapsulates browser selection logic:
-- - Command modifier: toggle (add if not selected, remove if selected)
-- - No modifier: replace selection
--
-- @file select_browser_items.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        items = { required = true, kind = "table" },
        context = { required = false, kind = "table" },
        modifiers = { required = false, kind = "table" },
    },
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SelectBrowserItems"] = function(command)
        local args = command:get_all_parameters()
        local items = args.items or {}
        local context = args.context or {}
        local modifiers = args.modifiers or {}

        local browser_state_ok, browser_state = pcall(require, "ui.project_browser.browser_state")
        if not browser_state_ok or not browser_state then
            return { success = false, error_message = "SelectBrowserItems: browser_state not available" }
        end

        local current_items = browser_state.get_selected_items() or {}

        -- Build lookup of current selection by a unique key
        local function item_key(item)
            return (item.type or "") .. ":" .. (item.id or item.tree_id or "")
        end

        local current_set = {}
        for _, item in ipairs(current_items) do
            current_set[item_key(item)] = item
        end

        -- Check if all targets are already selected
        local all_selected = #items > 0
        for _, item in ipairs(items) do
            if not current_set[item_key(item)] then
                all_selected = false
                break
            end
        end

        local new_selection = {}

        if modifiers.command then
            if all_selected then
                -- Remove targets from selection
                local target_set = {}
                for _, item in ipairs(items) do
                    target_set[item_key(item)] = true
                end
                for _, item in ipairs(current_items) do
                    if not target_set[item_key(item)] then
                        table.insert(new_selection, item)
                    end
                end
            else
                -- Add targets to selection
                for _, item in ipairs(current_items) do
                    table.insert(new_selection, item)
                end
                for _, item in ipairs(items) do
                    if not current_set[item_key(item)] then
                        table.insert(new_selection, item)
                    end
                end
            end
        else
            -- Replace selection
            new_selection = items
        end

        -- Apply selection
        browser_state.update_selection(new_selection, context)

        return {
            success = true,
            selected_count = #new_selection,
        }
    end

    return {
        ["SelectBrowserItems"] = {
            executor = command_executors["SelectBrowserItems"],
            spec = SPEC,
        },
    }
end

return M
