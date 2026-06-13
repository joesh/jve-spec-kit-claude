--- Selection Hub
-- Centralizes active selection state across panels and notifies interested listeners.
local M = {}

local selections = {}
local listeners = {}
local next_token = 0
local active_panel_id = nil

-- Last broadcast (panel_id, items_signature) — guards against redundant
-- notifications. Both set_active_panel and update_selection fire notify
-- unconditionally on their own; without this, a click in an already-
-- active panel + the immediately-following focus event each retrigger
-- listeners with the exact same payload. TSO 2026-05-12 recorded 4–5x
-- inspector.update_selection calls per focus toggle for this reason.
-- Dedup at the hub so every listener (inspector, effective_source, …)
-- benefits without per-listener guards.
local last_broadcast_panel = nil
local last_broadcast_signature = nil

local function get_items(panel_id)
    if not panel_id then
        return {}
    end
    return selections[panel_id] or {}
end

--- Stable order-independent signature of a selection items list.
--- Handles both browser items ({type, id}) and timeline items
--- ({item_type, clip.id / sequence_id}).
local function items_signature(items)
    if type(items) ~= "table" or #items == 0 then return "" end
    local parts = {}
    for i, it in ipairs(items) do
        local t = it and (it.type or it.item_type) or "nil"
        local id = it and (it.id or (it.clip and it.clip.id) or it.sequence_id) or "nil"
        parts[i] = string.format("%s:%s", tostring(t), tostring(id))
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

local function notify(panel_id)
    local items = get_items(panel_id)
    local sig = items_signature(items)
    if panel_id == last_broadcast_panel and sig == last_broadcast_signature then
        return
    end
    last_broadcast_panel = panel_id
    last_broadcast_signature = sig
    for token, callback in pairs(listeners) do
        if type(callback) == "function" then
            -- Fail-fast: don't swallow errors from listeners
            callback(items, panel_id)
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
    last_broadcast_panel = nil
    last_broadcast_signature = nil
end

return M
