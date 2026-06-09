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
        render_bottom_to_top = options.render_bottom_to_top or false,
        on_drag_start = options.on_drag_start,
        -- Vertical scroll is model-owned (single-owner redesign,
        -- 2026-06-09); the view never holds a scroll position of its
        -- own. The panel injects these entry points so gestures and
        -- scroll-into-view route through the model write path:
        --   vertical_scroll.by(dy)        — wheel delta (widget px)
        --   vertical_scroll.to(value)     — absolute scrollbar value
        --   vertical_scroll.metrics()     — value, max, pageStep
        vertical_scroll = options.vertical_scroll,
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
        local all = state_module.get_tab_strip():displayed_tracks()
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
                local entry = { id = track.id, y = cursor, height = h, track_type = track.track_type }
                layout_by_index[i] = entry
                layout_by_id[track.id] = entry
            end
        else
            local cursor = 0
            for i, track in ipairs(view.filtered_tracks) do
                local h = view.get_track_visual_height(track.id)
                local entry = { id = track.id, y = cursor, height = h, track_type = track.track_type }
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

    --- 019 FR-026: Resolve the clip (or nil) under cursor coordinates.
    --- Wraps the file-local hit-test in timeline_view_input so view-using
    --- code (Qt double-click dispatch, future trim-handle drag) can ask
    --- "what's at (x, y)?" without reaching into private helpers.
    function view.hit_test_clip(x, y)
        local timeline_view_input = require("ui.timeline.view.timeline_view_input")
        local width, height = timeline.get_dimensions(view.widget)
        return timeline_view_input._find_clip_under_cursor(view, x, y, width, height)
    end

    -- Scroll vertically so every track in the given list is visible.
    -- Called by the viewport_surface_tracks signal after undo/redo of a
    -- multi-track edit. If the union of requested tracks fits within
    -- the visible viewport, center it; otherwise anchor the topmost
    -- track near the top edge. No-op when all tracks are already in
    -- view. Scroll-into-view is intentional navigation: the target
    -- routes through the model write path (vertical_scroll.to) exactly
    -- like a user gesture.
    function view.ensure_tracks_visible(track_ids)
        if type(track_ids) ~= "table" or #track_ids == 0 then return end
        assert(view.vertical_scroll,
            "timeline_view.ensure_tracks_visible: view created without a "
            .. "vertical_scroll entry point (panel must inject it)")
        -- Track Ys are content (widget) coordinates; the visible window
        -- is the scroll area's [value, value + pageStep).
        local value, _, page = view.vertical_scroll.metrics()
        if not value or page <= 0 then return end  -- not laid out yet
        local widget_height = qt_constants.PROPERTIES.GET_HEIGHT
            and qt_constants.PROPERTIES.GET_HEIGHT(widget)
            or 0
        if widget_height <= 0 then return end
        view.update_layout_cache(widget_height)

        local min_y, max_y = nil, nil
        for _, track_id in ipairs(track_ids) do
            local entry = view.track_layout_cache.by_id[track_id]
            if entry then
                local bottom = entry.y + entry.height
                if not min_y or entry.y < min_y then min_y = entry.y end
                if not max_y or bottom > max_y then max_y = bottom end
            end
        end
        if not min_y then return end

        local visible_top = value
        local visible_bottom = value + page
        local union_height = max_y - min_y

        local target
        if min_y >= visible_top and max_y <= visible_bottom then
            return  -- already visible, no-op
        elseif union_height <= page then
            -- Center the union within the viewport.
            local mid = (min_y + max_y) / 2
            target = math.floor(mid - page / 2)
        else
            -- Union taller than viewport: anchor top of union near the
            -- top edge, leaving a small padding above so the topmost
            -- track doesn't butt against the ruler.
            local padding = math.floor(page * VERTICAL_SURFACE_PADDING_FRACTION)
            target = min_y - padding
        end
        view.vertical_scroll.to(target)
    end

    -- Event Wiring
    local function on_mouse(type, x, y, btn, mods)
        -- Batch all commands from this mouse interaction into one event
        local command_manager = require("core.command_manager")
        command_manager.begin_command_event("ui")
        input.handle_mouse(view, type, x, y, btn, mods)
        command_manager.end_command_event()
    end
    local function on_wheel(dx, dy, mods, phase)
        return input.handle_wheel(view, dx, dy, mods, phase)
    end

    timeline.set_lua_state(widget)
    local hname = "tl_mouse_" .. tostring(widget):gsub("[^%w]", "_")
    _G[hname] = function(e)
        if e.type == "wheel" then
            return on_wheel(e.delta_x, e.delta_y, e.modifiers, e.scroll_phase)
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
        ensure_tracks_visible = view.ensure_tracks_visible,
        -- Coord → track query; consumed by external drop handlers
        -- (patch-drag strip drops, FR-010a). Same function the view's
        -- internal input/renderer helpers already use.
        get_track_id_at_y = view.get_track_id_at_y,
        -- Track-id → widget-y / pixel-height. Same primitives the
        -- renderer consumes; exposed so external consumers (drop
        -- handlers, test-helpers asking "where on screen is clip X?")
        -- don't re-implement layout math against the internal view
        -- table. y is in content (widget) coordinates; the QScrollArea
        -- pans the widget, so widget-local y needs no scroll term.
        get_track_y_by_id = view.get_track_y_by_id,
        get_track_visual_height = view.get_track_visual_height,
        on_mouse_event = on_mouse,
        on_wheel_event = on_wheel
    }
end

return M