--- Lua-side façade over the C++-injected `qt_constants` global.
--
-- Responsibilities:
-- - Augment the C++-provided `qt_constants` table with sections/functions the
--   binding layer doesn't pre-populate (LAYOUT, GEOMETRY, PROPERTIES, WIDGET,
--   CONTROL extras, MENU.SHOW_POPUP).
-- - Resolve named C++ binding functions out of `_G` via `require_global_function`,
--   asserting (`error`) when a binding is missing rather than nil-propagating.
--
-- Non-goals:
-- - Owning Qt enums or constants — those live in C++ (`qt_bindings.cpp`) and
--   are surfaced here as string aliases (e.g. "AlignTop") only when needed.
-- - Providing fallbacks/stubs when the real binding is absent — missing
--   bindings raise.
--
-- Invariants:
-- - Must be required only after the C++ engine has injected the global
--   `qt_constants` table; the file is a no-op otherwise.
-- - Returns the same global table (mutated in place) — every importer sees one
--   shared `qt_constants` instance.
-- - Bindings registered here must exist as global functions at require time.
--
-- @file qt_constants.lua
local function require_global_function(func_name)
    local fn = _G[func_name]
    if fn == nil then
        error("Missing Qt binding: " .. func_name)
    end
    return fn
end

-- Ensure we have the real qt_constants table from C++, not stub functions
if qt_constants then
    -- Add missing sections with real Qt bindings
    
    -- Geometry Functions - use real Qt bindings
    qt_constants.GEOMETRY = qt_constants.GEOMETRY or {
        SET_SIZE_POLICY = qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY
    }
    
    -- Layout Functions - use real Qt bindings from CONTROL section
    qt_constants.LAYOUT = qt_constants.LAYOUT or {}
    qt_constants.LAYOUT.SET_SPACING = qt_constants.LAYOUT.SET_SPACING or qt_constants.CONTROL.SET_LAYOUT_SPACING
    qt_constants.LAYOUT.SET_MARGINS = qt_constants.LAYOUT.SET_MARGINS or qt_constants.CONTROL.SET_LAYOUT_MARGINS
    qt_constants.LAYOUT.SET_STRETCH_FACTOR = qt_constants.LAYOUT.SET_STRETCH_FACTOR or require_global_function("qt_set_layout_stretch_factor")
    qt_constants.LAYOUT.SET_ALIGNMENT = qt_constants.LAYOUT.SET_ALIGNMENT or require_global_function("qt_set_layout_alignment")
    qt_constants.LAYOUT.ALIGN_TOP = "AlignTop"
    
    -- Properties Functions - add missing alignment support
    qt_constants.PROPERTIES = qt_constants.PROPERTIES or {}
    qt_constants.PROPERTIES.SET_ALIGNMENT = qt_constants.PROPERTIES.SET_ALIGNMENT or require_global_function("qt_set_widget_alignment")
    qt_constants.PROPERTIES.ALIGN_RIGHT = "AlignRight"
    qt_constants.PROPERTIES.ALIGN_LEFT = "AlignLeft"
    qt_constants.PROPERTIES.ALIGN_CENTER = "AlignCenter"
    qt_constants.PROPERTIES.ALIGN_TOP = "AlignTop"
    qt_constants.PROPERTIES.SET_TOOLTIP = qt_constants.PROPERTIES.SET_TOOLTIP or require_global_function("qt_set_tooltip")
    qt_constants.PROPERTIES.SET_WINDOW_APPEARANCE = qt_constants.PROPERTIES.SET_WINDOW_APPEARANCE or require_global_function("qt_set_window_appearance")

    -- Input state queries (spec 025 FR-005: Alt+click on M/S track buttons).
    -- GET_KEYBOARD_MODIFIERS() → { alt, shift, cmd, ctrl } booleans, the live
    -- modifier state of the event being processed (valid in a click handler).
    qt_constants.INPUT = qt_constants.INPUT or {}
    qt_constants.INPUT.GET_KEYBOARD_MODIFIERS = qt_constants.INPUT.GET_KEYBOARD_MODIFIERS or require_global_function("qt_keyboard_modifiers")

    -- Widget Functions - add parent relationship support
    qt_constants.WIDGET = qt_constants.WIDGET or {}
    qt_constants.WIDGET.SET_PARENT = qt_constants.WIDGET.SET_PARENT or require_global_function("qt_set_parent")
    qt_constants.WIDGET.CREATE_RUBBER_BAND = qt_constants.WIDGET.CREATE_RUBBER_BAND or require_global_function("qt_create_rubber_band")
    qt_constants.WIDGET.SET_RUBBER_BAND_GEOMETRY = qt_constants.WIDGET.SET_RUBBER_BAND_GEOMETRY or require_global_function("qt_set_rubber_band_geometry")
    qt_constants.WIDGET.GRAB_MOUSE = qt_constants.WIDGET.GRAB_MOUSE or require_global_function("qt_grab_mouse")
    qt_constants.WIDGET.RELEASE_MOUSE = qt_constants.WIDGET.RELEASE_MOUSE or require_global_function("qt_release_mouse")
    qt_constants.WIDGET.MAP_POINT_FROM = qt_constants.WIDGET.MAP_POINT_FROM or require_global_function("qt_map_point_from")
    qt_constants.WIDGET.MAP_RECT_FROM = qt_constants.WIDGET.MAP_RECT_FROM or require_global_function("qt_map_rect_from")

    -- Control Functions - add click handler support
    qt_constants.CONTROL = qt_constants.CONTROL or {}
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER = qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER or require_global_function("qt_set_button_click_handler")
    qt_constants.CONTROL.SET_WIDGET_CLICK_HANDLER = qt_constants.CONTROL.SET_WIDGET_CLICK_HANDLER or require_global_function("qt_set_widget_click_handler")
    qt_constants.CONTROL.SET_WIDGET_DOUBLE_CLICK_HANDLER = qt_constants.CONTROL.SET_WIDGET_DOUBLE_CLICK_HANDLER or require_global_function("qt_set_widget_double_click_handler")
    qt_constants.CONTROL.SET_CONTEXT_MENU_HANDLER = qt_constants.CONTROL.SET_CONTEXT_MENU_HANDLER or require_global_function("qt_set_context_menu_handler")
    qt_constants.CONTROL.SET_TREE_ITEM_ICON = qt_constants.CONTROL.SET_TREE_ITEM_ICON or require_global_function("qt_set_tree_item_icon")
    qt_constants.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER = qt_constants.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER or require_global_function("qt_set_tree_item_double_click_handler")
    qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER = qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER or require_global_function("qt_set_tree_selection_handler")
    qt_constants.CONTROL.SET_TREE_SELECTION_MODE = qt_constants.CONTROL.SET_TREE_SELECTION_MODE or require_global_function("qt_set_tree_selection_mode")
    qt_constants.CONTROL.SET_TREE_EXPANDS_ON_DOUBLE_CLICK = qt_constants.CONTROL.SET_TREE_EXPANDS_ON_DOUBLE_CLICK or require_global_function("qt_set_tree_expands_on_double_click")
    qt_constants.CONTROL.SET_TREE_DRAG_DROP_MODE = qt_constants.CONTROL.SET_TREE_DRAG_DROP_MODE or require_global_function("qt_set_tree_drag_drop_mode")
    qt_constants.CONTROL.SET_TREE_DROP_HANDLER = qt_constants.CONTROL.SET_TREE_DROP_HANDLER or require_global_function("qt_set_tree_drop_handler")
    qt_constants.CONTROL.SET_TREE_KEY_HANDLER = qt_constants.CONTROL.SET_TREE_KEY_HANDLER or require_global_function("qt_set_tree_key_handler")
    qt_constants.CONTROL.IS_TREE_ITEM_EXPANDED = qt_constants.CONTROL.IS_TREE_ITEM_EXPANDED or require_global_function("qt_is_tree_item_expanded")
    qt_constants.CONTROL.GET_TREE_ITEM_AT = qt_constants.CONTROL.GET_TREE_ITEM_AT or require_global_function("qt_get_tree_item_at")
    qt_constants.CONTROL.SET_TREE_HEADER_CLICK_HANDLER = qt_constants.CONTROL.SET_TREE_HEADER_CLICK_HANDLER or require_global_function("qt_set_tree_header_click_handler")
    qt_constants.CONTROL.SET_TREE_EXPAND_COLLAPSE_HANDLER = qt_constants.CONTROL.SET_TREE_EXPAND_COLLAPSE_HANDLER or require_global_function("qt_set_tree_expand_collapse_handler")
    qt_constants.CONTROL.SET_WIDGET_DRAG_HANDLER = qt_constants.CONTROL.SET_WIDGET_DRAG_HANDLER or require_global_function("qt_set_widget_drag_handler")
    qt_constants.CONTROL.WIDGET_AT_GLOBAL = qt_constants.CONTROL.WIDGET_AT_GLOBAL or require_global_function("qt_widget_at_global")

    -- Note: CONTROL section is now provided by the real qt_constants from C++
    -- SET_SCROLL_AREA_WIDGET is implemented as lua_set_scroll_area_widget
end

if qt_constants and qt_constants.MENU then
    qt_constants.MENU.SHOW_POPUP = qt_constants.MENU.SHOW_POPUP or require_global_function("qt_show_menu_popup")
end

-- Return the global qt_constants table that's injected by the C++ application
-- This provides access to the real Qt bindings, not stub functions
return qt_constants
