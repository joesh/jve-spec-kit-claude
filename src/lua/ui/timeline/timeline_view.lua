--- Timeline View (Coordinator)
-- Assembles Renderer, Input Handler, and Layout Logic
local M = {}
local renderer = require("ui.timeline.view.timeline_view_renderer")
local input = require("ui.timeline.view.timeline_view_input")
local ui_constants = require("core.ui_constants")
local Signals = require("core.signals")

-- Vertical-scroll padding applied when a track set must be surfaced but
-- the union of track extents is taller than the widget. Matches the
-- horizontal REGION_SCROLL_PADDING_FRACTION used by viewport_state so
-- both axes feel consistent.
local VERTICAL_SURFACE_PADDING_FRACTION = 0.05

function M.create(widget, state_module, track_filter_fn, options)
    options = options or {}

    local view = {
        widget = widget,
        state = state_module,
        track_filter = track_filter_fn,
        vertical_scroll_offset = options.vertical_scroll_offset or 0,
        render_bottom_to_top = options.render_bottom_to_top or false,
        on_drag_start = options.on_drag_start,
        on_scroll_changed = options.on_scroll_changed,  -- callback(offset) for persistence
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

    -- Scroll vertically so every track in the given list is visible.
    -- Called by the viewport_surface_tracks signal after undo/redo of a
    -- multi-track edit. If the union of requested tracks fits within
    -- the widget height, center it; otherwise anchor the topmost track
    -- near the top edge. No-op when all tracks are already in view.
    function view.ensure_tracks_visible(track_ids)
        if type(track_ids) ~= "table" or #track_ids == 0 then return end
        -- Widget height is queried lazily via Qt; cache misses go through
        -- update_layout_cache(height), so read the widget height first.
        local widget_height = qt_constants.PROPERTIES.GET_HEIGHT
            and qt_constants.PROPERTIES.GET_HEIGHT(widget)
            or 0
        if widget_height <= 0 then return end
        view.update_layout_cache(widget_height)

        -- Convert each track's current screen Y back to "pre-scroll" Y
        -- (layout Y) so we can compute an offset against a stable frame.
        local min_layout_y, max_layout_y = nil, nil
        for _, track_id in ipairs(track_ids) do
            local entry = view.track_layout_cache.by_id[track_id]
            if entry then
                local top = entry.y + view.vertical_scroll_offset
                local bottom = top + entry.height
                if not min_layout_y or top < min_layout_y then min_layout_y = top end
                if not max_layout_y or bottom > max_layout_y then max_layout_y = bottom end
            end
        end
        if not min_layout_y then return end

        local current_offset = view.vertical_scroll_offset
        local visible_top = current_offset
        local visible_bottom = current_offset + widget_height
        local union_height = max_layout_y - min_layout_y

        local new_offset
        if min_layout_y >= visible_top and max_layout_y <= visible_bottom then
            return  -- already visible, no-op
        elseif union_height <= widget_height then
            -- Center the union within the viewport.
            local mid = (min_layout_y + max_layout_y) / 2
            new_offset = math.floor(mid - widget_height / 2)
        else
            -- Union taller than viewport: anchor top of union near the
            -- top edge, leaving a small padding above so the topmost
            -- track doesn't butt against the ruler.
            local padding = math.floor(widget_height * VERTICAL_SURFACE_PADDING_FRACTION)
            new_offset = min_layout_y - padding
        end
        if new_offset < 0 then new_offset = 0 end
        view.vertical_scroll_offset = new_offset
        view.render()
        if view.on_scroll_changed then view.on_scroll_changed(new_offset) end
    end

    -- Event Wiring
    local function on_mouse(type, x, y, btn, mods)
        -- Batch all commands from this mouse interaction into one event
        local command_manager = require("core.command_manager")
        command_manager.begin_command_event("ui")
        input.handle_mouse(view, type, x, y, btn, mods)
        command_manager.end_command_event()
    end
    local function on_wheel(dx, dy, mods)
        return input.handle_wheel(view, dx, dy, mods)
    end

    timeline.set_lua_state(widget)
    local hname = "tl_mouse_" .. tostring(widget):gsub("[^%w]", "_")
    _G[hname] = function(e)
        if e.type == "wheel" then
            return on_wheel(e.delta_x, e.delta_y, e.modifiers)
        else
            on_mouse(e.type, e.x, e.y, e.button, e)
        end
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

    -- Subscribe to vertical-surface signal from viewport_policy so
    -- undo/redo of multi-track edits scrolls affected tracks into view.
    Signals.connect("viewport_surface_tracks", function(track_ids)
        view.ensure_tracks_visible(track_ids)
    end)

    -- Initial Render
    view.render()

    return {
        widget = widget,
        render = view.render,
        set_vertical_scroll = function(off)
            view.vertical_scroll_offset = off
            view.render()
            if view.on_scroll_changed then view.on_scroll_changed(off) end
        end,
        get_vertical_scroll = function() return view.vertical_scroll_offset end,
        ensure_tracks_visible = view.ensure_tracks_visible,
        on_mouse_event = on_mouse,
        on_wheel_event = on_wheel
    }
end

return M