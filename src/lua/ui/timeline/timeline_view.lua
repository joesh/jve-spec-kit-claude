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
-- Size: ~106 LOC
-- Volatility: unknown
--
-- @file timeline_view.lua
-- Original intent (unreviewed):
-- Timeline View (Coordinator)
-- Assembles Renderer, Input Handler, and Layout Logic
local M = {}
local renderer = require("ui.timeline.view.timeline_view_renderer")
local input = require("ui.timeline.view.timeline_view_input")
local ui_constants = require("core.ui_constants")

function M.create(widget, state_module, track_filter_fn, options)
    options = options or {}

    local view = {
        widget = widget,
        state = state_module,
        track_filter = track_filter_fn,
        vertical_scroll_offset = options.vertical_scroll_offset or 0,
        render_bottom_to_top = options.render_bottom_to_top or false,
        on_drag_start = options.on_drag_start,
        filtered_tracks = {},
        track_layout_cache = {by_index={}, by_id={}},
        potential_drag = nil,
        drag_state = nil,
        debug_id = options.debug_id or tostring(widget)
    }

    -- Layout Logic
    function view.get_track_visual_height(track_id)
        local h = state_module.get_track_height(track_id) or state_module.dimensions.default_track_height
        return math.max(0, h)
    end

    function view.update_layout_cache(widget_height)
        view.filtered_tracks = {}
        local all = state_module.get_all_tracks()
        for _, t in ipairs(all) do
            if track_filter_fn(t) then table.insert(view.filtered_tracks, t) end
        end

        local layout_by_index = {}
        local layout_by_id = {}
        
        if view.render_bottom_to_top then
            local cursor = widget_height
            for i, track in ipairs(view.filtered_tracks) do
                local h = view.get_track_visual_height(track.id)
                cursor = cursor - h
                local entry = { id = track.id, y = cursor - view.vertical_scroll_offset, height = h, track_type = track.track_type }
                layout_by_index[i] = entry
                layout_by_id[track.id] = entry
            end
        else
            local cursor = 0
            for i, track in ipairs(view.filtered_tracks) do
                local h = view.get_track_visual_height(track.id)
                local entry = { id = track.id, y = cursor - view.vertical_scroll_offset, height = h, track_type = track.track_type }
                layout_by_index[i] = entry
                layout_by_id[track.id] = entry
                cursor = cursor + h
            end
        end
        view.track_layout_cache = {by_index=layout_by_index, by_id=layout_by_id}
        
        -- Update widget min height
        local total = 0
        for _, t in ipairs(view.filtered_tracks) do total = total + view.get_track_visual_height(t.id) end
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(widget, total)
    end

    function view.get_track_y_by_id(track_id, height)
        -- Check cache first
        if view.track_layout_cache.by_id[track_id] then
            return view.track_layout_cache.by_id[track_id].y
        end
        -- Fallback (force recalc if needed, but usually render calls update_layout_cache first)
        view.update_layout_cache(height)
        if view.track_layout_cache.by_id[track_id] then
            return view.track_layout_cache.by_id[track_id].y
        end
        return -1
    end

    function view.get_track_id_at_y(y, height)
        if not view.track_layout_cache.by_index[1] then view.update_layout_cache(height) end
        for _, entry in pairs(view.track_layout_cache.by_id) do
            if y >= entry.y and y < entry.y + entry.height then return entry.id end
        end
        return nil
    end

    function view.render()
        renderer.render(view)
    end

    -- Event Wiring
    local function on_mouse(type, x, y, btn, mods)
        local command_manager = require("core.command_manager")
        local owns_event = not command_manager.peek_command_event_origin()
        if owns_event then
            command_manager.begin_command_event("ui")
        end
        input.handle_mouse(view, type, x, y, btn, mods)
        if owns_event then
            command_manager.end_command_event()
        end
    end
    local function on_wheel(dx, dy, mods)
        input.handle_wheel(view, dx, dy, mods)
    end

    timeline.set_lua_state(widget)
    local hname = "tl_mouse_" .. tostring(widget):gsub("[^%w]", "_")
    _G[hname] = function(e) 
        if e.type == "wheel" then on_wheel(e.delta_x, e.delta_y, e.modifiers)
        else on_mouse(e.type, e.x, e.y, e.button, e) end
    end
    timeline.set_mouse_event_handler(widget, hname)

    local rname = "tl_resize_" .. tostring(widget):gsub("[^%w]", "_")
    _G[rname] = function(e) view.render() end
    timeline.set_resize_event_handler(widget, rname)

    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(widget, "Expanding", "Expanding")

    -- State Listener
    state_module.add_listener(function()
        view.render()
    end)

    -- Initial Render
    view.render()

    return {
        widget = widget,
        render = view.render,
        set_vertical_scroll = function(off) view.vertical_scroll_offset = off; view.render() end,
        get_vertical_scroll = function() return view.vertical_scroll_offset end,
        on_mouse_event = on_mouse,
        on_wheel_event = on_wheel
    }
end

return M