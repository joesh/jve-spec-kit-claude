-- scripts/core/qt_constants.lua
-- PURPOSE: Qt binding constants and function mappings for Lua inspector
-- Maps to the real qt_constants table provided by the C++ application

-- Helper function for lazy evaluation
local function lazy_function(func_name)
    return function(...)
        if _G[func_name] then
            return _G[func_name](...)
        else
            error("Qt function not available: " .. func_name)
        end
    end
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
    qt_constants.LAYOUT.SET_STRETCH_FACTOR = qt_constants.LAYOUT.SET_STRETCH_FACTOR or lazy_function("qt_set_layout_stretch_factor")
    qt_constants.LAYOUT.SET_ALIGNMENT = qt_constants.LAYOUT.SET_ALIGNMENT or lazy_function("qt_set_layout_alignment")
    qt_constants.LAYOUT.ALIGN_TOP = "AlignTop"
    
    -- Properties Functions - add missing alignment support
    qt_constants.PROPERTIES = qt_constants.PROPERTIES or {}
    qt_constants.PROPERTIES.SET_ALIGNMENT = qt_constants.PROPERTIES.SET_ALIGNMENT or lazy_function("qt_set_widget_alignment")
    qt_constants.PROPERTIES.ALIGN_RIGHT = "AlignRight"
    qt_constants.PROPERTIES.ALIGN_LEFT = "AlignLeft"
    qt_constants.PROPERTIES.ALIGN_CENTER = "AlignCenter"
    qt_constants.PROPERTIES.ALIGN_TOP = "AlignTop"

    -- Widget Functions - add parent relationship support
    qt_constants.WIDGET = qt_constants.WIDGET or {}
    qt_constants.WIDGET.SET_PARENT = qt_constants.WIDGET.SET_PARENT or lazy_function("qt_set_parent")
    
    -- Note: CONTROL section is now provided by the real qt_constants from C++
    -- SET_SCROLL_AREA_WIDGET is implemented as lua_set_scroll_area_widget
end

-- Return the global qt_constants table that's injected by the C++ application
-- This provides access to the real Qt bindings, not stub functions
return qt_constants