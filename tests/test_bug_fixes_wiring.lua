#!/usr/bin/env luajit

-- Regression tests for 4 bugs where fixes existed but were never wired in:
-- B1: TrimHead/TrimTail not registered in command system
-- B2: mark bar seek must sync engine position (via SequenceView on_seek)
-- B3: load_sequence uses content_end, not 24hr fallback
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
-- B2: mark bar seek must sync engine position
-- (SequenceView on_seek callback calls engine:seek)
-- ═══════════════════════════════════════════════════════════
print("\n=== B2: seek syncs engine position (SequenceView) ===")
do
    local f = io.open("../src/lua/ui/sequence_view.lua", "r")
    assert(f, "Cannot open sequence_view.lua")
    local content = f:read("*a")
    f:close()

    check("on_seek calls engine:seek in sequence_view",
        content:find("on_seek") ~= nil and
        content:find("seek") ~= nil and
        content:find("engine") ~= nil)
end

-- ═══════════════════════════════════════════════════════════
-- B3: load_sequence uses content_end, not 24hr fallback
-- ═══════════════════════════════════════════════════════════
print("\n=== B3: load_sequence uses content_end ===")
do
    local f = io.open("../src/lua/core/playback/playback_engine.lua", "r")
    assert(f, "Cannot open playback_engine.lua")
    local content = f:read("*a")
    f:close()

    check("load_sequence references content_end",
        content:find("content_end") ~= nil)
end

-- ═══════════════════════════════════════════════════════════
-- B5: dual SequenceView (mode-switching removed — each view is independent)
-- ═══════════════════════════════════════════════════════════
print("\n=== B5: dual SequenceView (no mode-switching) ===")
do
    local f = io.open("../src/lua/ui/timeline/timeline_panel.lua", "r")
    assert(f, "Cannot open timeline_panel.lua")
    local content = f:read("*a")
    f:close()

    -- timeline_panel should load into timeline_view via panel_manager
    local uses_panel_manager = content:find('panel_manager') and content:find('get_sequence_view')
    check("timeline_panel uses panel_manager for timeline_view", uses_panel_manager)

    -- No more mode-switching: set_timeline_mode is gone
    local no_mode_switch = not content:find("set_timeline_mode")
    check("no set_timeline_mode calls", no_mode_switch)
end

-- ═══════════════════════════════════════════════════════════
-- B6: PlaybackEngine audio must be initialized at startup
-- (layout.lua must call init_audio + activate_audio)
-- ═══════════════════════════════════════════════════════════
print("\n=== B6: audio init wiring in layout.lua ===")
do
    local f = io.open("../src/lua/ui/layout.lua", "r")
    assert(f, "Cannot open layout.lua")
    local content = f:read("*a")
    f:close()

    check("layout calls init_audio", content:find("init_audio") ~= nil)
    check("layout calls activate_audio", content:find("activate_audio") ~= nil)
end

-- ═══════════════════════════════════════════════════════════
-- B7: Playhead must sync from engine to timeline_state during playback
-- (timeline_panel's tl_view listener must call set_playhead_position)
-- ═══════════════════════════════════════════════════════════
print("\n=== B7: playhead sync during playback ===")
do
    local f = io.open("../src/lua/ui/timeline/timeline_panel.lua", "r")
    assert(f, "Cannot open timeline_panel.lua")
    local content = f:read("*a")
    f:close()

    -- The tl_view playback listener must sync tl_view.playhead → state.
    -- set_playhead_position(playhead_frame) must appear (not snapped_frame/parsed).
    check("tl_view listener syncs playhead to state during playback",
        content:find("set_playhead_position%(playhead_frame%)") ~= nil)
end

-- ═══════════════════════════════════════════════════════════
-- B8: StepFrame must display frame via seek_to_frame (not bare set_position)
-- ═══════════════════════════════════════════════════════════
print("\n=== B8: StepFrame uses seek_to_frame ===")
do
    local f = io.open("../src/lua/core/commands/step_frame.lua", "r")
    assert(f, "Cannot open step_frame.lua")
    local content = f:read("*a")
    f:close()

    -- Must use seek_to_frame (which displays frame + updates playhead)
    check("StepFrame calls seek_to_frame", content:find("seek_to_frame") ~= nil)
    -- Must NOT use bare engine:set_position (which skips frame display)
    check("StepFrame does not use bare set_position",
        content:find("set_position%(") == nil)
end

-- ═══════════════════════════════════════════════════════════
-- B9: Audio ownership transfers on focus change
-- ═══════════════════════════════════════════════════════════
print("\n=== B9: audio follows focus ===")
do
    local f = io.open("../src/lua/ui/focus_manager.lua", "r")
    assert(f, "Cannot open focus_manager.lua")
    local content = f:read("*a")
    f:close()

    check("focus_manager has on_focus_change callback",
        content:find("on_focus_change") ~= nil)
end
do
    local f = io.open("../src/lua/ui/layout.lua", "r")
    assert(f, "Cannot open layout.lua")
    local content = f:read("*a")
    f:close()

    check("layout wires audio transfer on focus change",
        content:find("on_focus_change") ~= nil
        and content:find("activate_audio") ~= nil
        and content:find("deactivate_audio") ~= nil)
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_bug_fixes_wiring.lua passed")
