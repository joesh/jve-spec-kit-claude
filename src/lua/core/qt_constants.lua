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
    
    -- Note: CONTROL section is now provided by the real qt_constants from C++
    -- SET_SCROLL_AREA_WIDGET is implemented as lua_set_scroll_area_widget
end

-- Return the global qt_constants table that's injected by the C++ application
-- This provides access to the real Qt bindings, not stub functions
return qt_constants