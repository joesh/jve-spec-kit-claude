-- Selection Hub
-- Centralizes active selection state across panels and notifies interested listeners.

local M = {}

local selections = {}
local listeners = {}
local next_token = 0
local active_panel_id = nil

local function get_items(panel_id)
    if not panel_id then
        return {}
    end
    return selections[panel_id] or {}
end

local function notify(panel_id)
    local items = get_items(panel_id)
    for token, callback in pairs(listeners) do
        if type(callback) == "function" then
            local ok, err = pcall(callback, items, panel_id)
            if not ok then
                print(string.format("WARNING: selection_hub listener %s raised error: %s", tostring(token), tostring(err)))
            end
        end
    end
end

function M.update_selection(panel_id, items)
    if not panel_id then
        return
    end

    selections[panel_id] = items or {}

    if panel_id == active_panel_id then
        notify(panel_id)
    end
end

function M.clear_selection(panel_id)
    if not panel_id then
        return
    end

    selections[panel_id] = {}

    if panel_id == active_panel_id then
        notify(panel_id)
    end
end

function M.set_active_panel(panel_id)
    active_panel_id = panel_id
    notify(active_panel_id)
end

function M.get_active_selection()
    return get_items(active_panel_id), active_panel_id
end

function M.get_selection(panel_id)
    return get_items(panel_id)
end

function M.register_listener(callback)
    if type(callback) ~= "function" then
        error("selection_hub.register_listener requires a callback function")
    end
    next_token = next_token + 1
    listeners[next_token] = callback

    local items = get_items(active_panel_id)
    callback(items, active_panel_id)

    return next_token
end

function M.unregister_listener(token)
    listeners[token] = nil
end

function M._reset_for_tests()
    selections = {}
    listeners = {}
    next_token = 0
    active_panel_id = nil
end

return M
