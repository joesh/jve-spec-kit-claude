--[[
NSF Test: Source Viewer State API Contract

Ensures callers use the correct API for source_viewer_state.
After IS-a refactor: masterclip IS a sequence, so:
- current_clip_id → current_sequence_id
- mark_in/mark_out properties → get_mark_in()/get_mark_out() methods
]]

require("test_env")

local source_viewer_state = require("ui.source_viewer_state")

-- Test: API uses current_sequence_id (not current_clip_id)
local function test_current_sequence_id_exists()
    -- The correct field after IS-a refactor (can be nil when no clip loaded)
    local _ = source_viewer_state.current_sequence_id  -- Should not throw

    -- The OLD field should THROW an error when accessed (fail-fast guard)
    local ok, err = pcall(function() return source_viewer_state.current_clip_id end)
    assert(not ok, "current_clip_id access should throw DEPRECATED error")
    assert(err:find("DEPRECATED"), "Error should mention DEPRECATED")

    print("  ✓ Uses current_sequence_id (current_clip_id throws)")
end

-- Test: Marks are methods, not properties
local function test_marks_are_methods()
    -- Methods must exist
    assert(type(source_viewer_state.get_mark_in) == "function",
        "get_mark_in must be a function")
    assert(type(source_viewer_state.get_mark_out) == "function",
        "get_mark_out must be a function")
    assert(type(source_viewer_state.set_mark_in) == "function",
        "set_mark_in must be a function")
    assert(type(source_viewer_state.set_mark_out) == "function",
        "set_mark_out must be a function")

    -- Direct property access should THROW (fail-fast guard)
    local ok1, err1 = pcall(function() return source_viewer_state.mark_in end)
    assert(not ok1, "mark_in property access should throw DEPRECATED error")
    assert(err1:find("DEPRECATED"), "Error should mention DEPRECATED")

    local ok2, err2 = pcall(function() return source_viewer_state.mark_out end)
    assert(not ok2, "mark_out property access should throw DEPRECATED error")
    assert(err2:find("DEPRECATED"), "Error should mention DEPRECATED")

    print("  ✓ Marks are methods (properties throw)")
end

-- Test: Correct pattern for checking marks before insert
local function test_correct_marks_check_pattern()
    -- WRONG pattern (what project_browser.lua was doing):
    -- if source_viewer_state.current_clip_id == clip.clip_id
    --    and source_viewer_state.mark_in ~= nil
    --    and source_viewer_state.mark_out ~= nil then

    -- CORRECT pattern:
    local has_clip = source_viewer_state.has_clip()
    source_viewer_state.get_mark_in()  -- verify callable
    source_viewer_state.get_mark_out() -- verify callable

    -- When no clip loaded, all should be nil/false
    assert(has_clip == false or has_clip == true,
        "has_clip() must return boolean")
    -- mark_in/mark_out can be nil (no marks or not synced) or number

    if has_clip then
        -- If clip loaded, current_sequence_id should be set
        assert(source_viewer_state.current_sequence_id ~= nil,
            "current_sequence_id should be set when has_clip() is true")
    end

    print("  ✓ Correct pattern for checking marks")
end

-- Test: No callers use deprecated API patterns
local function test_no_deprecated_api_usage()
    local files_to_check = {
        "../src/lua/ui/project_browser.lua",
        "../src/lua/ui/source_mark_bar.lua",
    }

    for _, path in ipairs(files_to_check) do
        local f = io.open(path, "r")
        if not f then
            f = io.open(path:gsub("^%.%./", ""), "r")
        end
        assert(f, "Could not open " .. path)
        local content = f:read("*a")
        f:close()

        local filename = path:match("[^/]+$")

        -- Check for deprecated patterns
        assert(not content:find("source_viewer_state%.current_clip_id"),
            "DEPRECATED: " .. filename .. " uses source_viewer_state.current_clip_id - use current_sequence_id")
        assert(not content:find("source_viewer_state%.mark_in[^%(]"),
            "DEPRECATED: " .. filename .. " uses source_viewer_state.mark_in property - use get_mark_in()")
        assert(not content:find("source_viewer_state%.mark_out[^%(]"),
            "DEPRECATED: " .. filename .. " uses source_viewer_state.mark_out property - use get_mark_out()")
    end

    print("  ✓ No deprecated API usage in callers")
end

print("test_nsf_source_viewer_state_api.lua")
test_current_sequence_id_exists()
test_marks_are_methods()
test_correct_marks_check_pattern()
test_no_deprecated_api_usage()
print("✅ test_nsf_source_viewer_state_api.lua passed")
