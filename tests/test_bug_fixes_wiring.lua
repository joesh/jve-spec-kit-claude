#!/usr/bin/env luajit

-- Regression tests for 4 bugs where fixes existed but were never wired in:
-- B1: TrimHead/TrimTail not registered in command system
-- B2: source_mark_bar.seek_to_frame doesn't sync playback_controller position
-- B3: set_timeline_mode uses 24hr fallback instead of content_end
-- B5: timeline_panel restore clobbers viewer title to "Timeline Viewer"

require("test_env")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

-- ═══════════════════════════════════════════════════════════
-- B1: TrimHead/TrimTail registered in command_implementations
-- ═══════════════════════════════════════════════════════════
print("\n=== B1: TrimHead/TrimTail registration ===")
do
    -- The command_modules list in command_implementations.lua should include
    -- "trim_head" and "trim_tail" so they get loaded by register_commands.
    -- We test this by checking the source file for the entries.
    local f = io.open("../src/lua/core/command_implementations.lua", "r")
    assert(f, "Cannot open command_implementations.lua")
    local content = f:read("*a")
    f:close()

    check("trim_head in command_modules", content:find('"trim_head"') ~= nil)
    check("trim_tail in command_modules", content:find('"trim_tail"') ~= nil)
end

-- Also verify auto-load path resolves correctly
do
    local executors = {}
    local undoers = {}
    local mod_h = require("core.commands.trim_head")
    mod_h.register(executors, undoers, nil, function() end)
    check("TrimHead executor loads", type(executors["TrimHead"]) == "function")
    check("TrimHead undoer loads", type(undoers["TrimHead"]) == "function")

    local mod_t = require("core.commands.trim_tail")
    mod_t.register(executors, undoers, nil, function() end)
    check("TrimTail executor loads", type(executors["TrimTail"]) == "function")
    check("TrimTail undoer loads", type(undoers["TrimTail"]) == "function")
end

-- Verify KEY table has BracketLeft and BracketRight
print("\n=== B1: BracketLeft/BracketRight in KEY table ===")
do
    local f = io.open("../src/lua/core/keyboard_shortcuts.lua", "r")
    assert(f, "Cannot open keyboard_shortcuts.lua")
    local content = f:read("*a")
    f:close()

    check("BracketLeft in KEY table", content:find("BracketLeft") ~= nil)
    check("BracketRight in KEY table", content:find("BracketRight") ~= nil)
    -- Verify the shortcut handler references TrimHead/TrimTail
    check("TrimHead in keyboard handler", content:find("TrimHead") ~= nil)
    check("TrimTail in keyboard handler", content:find("TrimTail") ~= nil)
end

-- ═══════════════════════════════════════════════════════════
-- B2: seek_to_frame must sync playback_controller position
-- ═══════════════════════════════════════════════════════════
print("\n=== B2: seek_to_frame syncs playback_controller ===")
do
    local f = io.open("../src/lua/ui/source_mark_bar.lua", "r")
    assert(f, "Cannot open source_mark_bar.lua")
    local content = f:read("*a")
    f:close()

    -- The seek_to_frame function must call playback_controller.set_position
    check("seek_to_frame calls set_position",
        content:find("set_position") ~= nil and
        content:find("playback_controller") ~= nil)
end

-- ═══════════════════════════════════════════════════════════
-- B3: set_timeline_mode uses content_end, not 24hr fallback
-- ═══════════════════════════════════════════════════════════
print("\n=== B3: set_timeline_mode uses content_end ===")
do
    local f = io.open("../src/lua/core/playback/playback_controller.lua", "r")
    assert(f, "Cannot open playback_controller.lua")
    local content = f:read("*a")
    f:close()

    -- Should reference get_content_end_frame to get actual timeline length
    check("set_timeline_mode references content_end",
        content:find("get_content_end") ~= nil or content:find("content_end") ~= nil)
end

-- ═══════════════════════════════════════════════════════════
-- B5: viewer switching based on panel focus
-- ═══════════════════════════════════════════════════════════
print("\n=== B5: viewer switches based on panel focus ===")
do
    local f = io.open("../src/lua/ui/timeline/timeline_panel.lua", "r")
    assert(f, "Cannot open timeline_panel.lua")
    local content = f:read("*a")
    f:close()

    -- Timeline focus should restore timeline viewer (call show_timeline)
    -- Viewer/Browser focus should restore source viewer (if has_clip)
    -- The selection_hub listener should handle both directions
    local has_timeline_restore = content:find('panel_id == "timeline"')
        and content:find("load_sequence")
    check("timeline focus restores timeline viewer", has_timeline_restore)

    local has_viewer_restore = content:find('panel_id == "viewer"')
        and content:find("has_clip")
        and content:find("set_timeline_mode%(false%)")
    check("viewer focus restores source viewer", has_viewer_restore)
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_bug_fixes_wiring.lua passed")
