-- scripts/core/qt_constants.lua
-- PURPOSE: Qt binding constants and function mappings for Lua inspector
-- Maps to the real qt_constants table provided by the C++ application

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
    if not qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER then
        print("DEBUG qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER missing")
    end
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER = qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER or require_global_function("qt_set_button_click_handler")
    if not qt_constants.CONTROL.SET_WIDGET_CLICK_HANDLER then
        print("DEBUG qt_constants.CONTROL.SET_WIDGET_CLICK_HANDLER missing")
    end
    qt_constants.CONTROL.SET_WIDGET_CLICK_HANDLER = qt_constants.CONTROL.SET_WIDGET_CLICK_HANDLER or require_global_function("qt_set_widget_click_handler")
    if not qt_constants.CONTROL.SET_TREE_ITEM_ICON then
        print("DEBUG qt_constants.CONTROL.SET_TREE_ITEM_ICON missing")
    end
    qt_constants.CONTROL.SET_TREE_ITEM_ICON = qt_constants.CONTROL.SET_TREE_ITEM_ICON or require_global_function("qt_set_tree_item_icon")
    if not qt_constants.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER then
        print("DEBUG qt_constants.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER missing")
    end
    qt_constants.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER = qt_constants.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER or require_global_function("qt_set_tree_item_double_click_handler")
    if not qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER then
        print("DEBUG qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER missing")
    end
    qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER = qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER or require_global_function("qt_set_tree_selection_handler")
    if not qt_constants.CONTROL.SET_TREE_SELECTION_MODE then
        print("DEBUG qt_constants.CONTROL.SET_TREE_SELECTION_MODE missing")
    end
    qt_constants.CONTROL.SET_TREE_SELECTION_MODE = qt_constants.CONTROL.SET_TREE_SELECTION_MODE or require_global_function("qt_set_tree_selection_mode")

    -- Note: CONTROL section is now provided by the real qt_constants from C++
    -- SET_SCROLL_AREA_WIDGET is implemented as lua_set_scroll_area_widget
end

-- Return the global qt_constants table that's injected by the C++ application
-- This provides access to the real Qt bindings, not stub functions
return qt_constants
