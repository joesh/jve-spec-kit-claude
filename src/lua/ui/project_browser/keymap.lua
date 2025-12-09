local M = {}

local KEY_RETURN = 16777220
local KEY_ENTER = 16777221

local function is_toggle_key(event)
    if not event then
        return false
    end

    local keycode = nil
    local t = type(event)
    if t == "table" then
        keycode = tonumber(event.key)
    elseif t == "number" or t == "string" then
        keycode = tonumber(event)
    end

    if not keycode then
        return false
    end

    return keycode == KEY_RETURN or keycode == KEY_ENTER
end

local function toggle_bin(item, ctx)
    if not ctx or not item then
        return false
    end

    local controls = ctx.controls
    local tree = ctx.tree_widget and ctx.tree_widget()
    if not tree or not controls or not controls.SET_TREE_ITEM_EXPANDED then
        return false
    end

    local tree_id = ctx.resolve_tree_id and ctx.resolve_tree_id(item)
    if not tree_id then
        return false
    end

    local expanded = false
    if controls.IS_TREE_ITEM_EXPANDED then
        local ok, value = pcall(controls.IS_TREE_ITEM_EXPANDED, tree, tree_id)
        if ok then
            expanded = value and true or false
        end
    end

    controls.SET_TREE_ITEM_EXPANDED(tree, tree_id, not expanded)
    if ctx.focus_tree then
        ctx.focus_tree()
    end
    return true
end

function M.handle(event, ctx)
    if not is_toggle_key(event) or not ctx then
        return false
    end

    local selected = ctx.get_selected_item and ctx.get_selected_item()
    if not selected then
        return false
    end

    if selected.type == "timeline" then
        if ctx.activate_sequence then
            ctx.activate_sequence()
        end
        if ctx.focus_tree then
            ctx.focus_tree()
        end
        return true
    elseif selected.type == "bin" then
        return toggle_bin(selected, ctx)
    end

    return false
end

return M
