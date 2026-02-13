require('test_env')

-- Tests that JKL commands are registered with the shortcut registry
-- and dispatched via registry context matching (not hard-coded panel checks)

print("=== Test JKL Registry Integration ===")

-- Mock qt_create_single_shot_timer
_G.qt_create_single_shot_timer = function(interval, callback) end

-- Track registry registrations
local registered_commands = {}
local assigned_shortcuts = {}
local handled_events = {}

-- Mock keyboard_shortcut_registry with tracking
package.loaded["core.keyboard_shortcut_registry"] = {
    commands = registered_commands,
    register_command = function(cmd_def)
        registered_commands[cmd_def.id] = cmd_def
    end,
    assign_shortcut = function(cmd_id, shortcut)
        assigned_shortcuts[cmd_id] = assigned_shortcuts[cmd_id] or {}
        table.insert(assigned_shortcuts[cmd_id], shortcut)
        return true
    end,
    handle_key_event = function(key, modifiers, context)
        table.insert(handled_events, {key = key, modifiers = modifiers, context = context})
        -- Find matching command
        for id, cmd in pairs(registered_commands) do
            for _, sc in ipairs(cmd.default_shortcuts or {}) do
                if string.byte(sc) == key and cmd.handler then
                    -- Check context match
                    if cmd.context then
                        local contexts = type(cmd.context) == "table" and cmd.context or {cmd.context}
                        local matched = false
                        for _, ctx in ipairs(contexts) do
                            if ctx == context then matched = true; break end
                        end
                        if not matched then return false end
                    end
                    cmd.handler()
                    return true
                end
            end
        end
        return false
    end,
}

-- Track playback calls
local playback_calls = {}

-- Mock engine (used by SequenceMonitor)
local mock_engine = {
    total_frames = 100,
    fps_num = 24,
    fps_den = 1,
}
function mock_engine:is_playing() return false end
function mock_engine:has_source() return true end
function mock_engine:stop() table.insert(playback_calls, "stop") end
function mock_engine:shuttle(dir) table.insert(playback_calls, "shuttle:" .. tostring(dir)) end
function mock_engine:slow_play(dir) table.insert(playback_calls, "slow_play:" .. tostring(dir)) end
function mock_engine:play() table.insert(playback_calls, "play") end

-- Mock SequenceMonitor
local mock_sv = {
    sequence_id = "test_seq",
    total_frames = 100,
    engine = mock_engine,
}
function mock_sv:has_clip() return true end

-- Mock panel_manager with SequenceMonitor
local mock_pm = {
    toggle_active_panel = function() end,
    get_active_sequence_monitor = function() return mock_sv end,
    get_sequence_monitor = function() return mock_sv end,
}
package.loaded["ui.panel_manager"] = mock_pm

-- Mock focus_manager
local current_focus = "timeline_monitor"
package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return current_focus end,
}

-- Mock viewer_panel (still required by some paths)
package.loaded["ui.viewer_panel"] = {
    has_media = function() return true end,
    get_total_frames = function() return 100 end,
    get_fps = function() return 24 end,
    get_current_frame = function() return 0 end,
}

-- Load keyboard_shortcuts fresh
package.loaded["core.keyboard_shortcuts"] = nil
local keyboard_shortcuts = require("core.keyboard_shortcuts")

-- Initialize with mocks
keyboard_shortcuts.init(nil, nil, nil, nil)

print("\n--- Test JKL commands registered with registry ---")

print("\nTest 1: playback.forward command registered")
assert(registered_commands["playback.forward"], "playback.forward should be registered")
assert(registered_commands["playback.forward"].category == "Playback", "category should be Playback")
print("  ✓ playback.forward registered with category Playback")

print("\nTest 2: playback.reverse command registered")
assert(registered_commands["playback.reverse"], "playback.reverse should be registered")
print("  ✓ playback.reverse registered")

print("\nTest 3: playback.stop command registered")
assert(registered_commands["playback.stop"], "playback.stop should be registered")
print("  ✓ playback.stop registered")

print("\nTest 4: JKL commands have multi-context (timeline + viewer)")
local fwd_ctx = registered_commands["playback.forward"].context
assert(type(fwd_ctx) == "table", "context should be a table for multi-context")
local has_timeline, has_source, has_tl_view = false, false, false
for _, ctx in ipairs(fwd_ctx) do
    if ctx == "timeline" then has_timeline = true end
    if ctx == "source_monitor" then has_source = true end
    if ctx == "timeline_monitor" then has_tl_view = true end
end
assert(has_timeline and has_source and has_tl_view, "should have timeline, source_monitor, timeline_monitor contexts")
print("  ✓ playback.forward has contexts: timeline, source_monitor, timeline_monitor")

print("\n--- Test JKL shortcuts assigned ---")

print("\nTest 5: L shortcut assigned to playback.forward")
assert(assigned_shortcuts["playback.forward"], "playback.forward should have shortcuts")
local found_L = false
for _, sc in ipairs(assigned_shortcuts["playback.forward"]) do
    if sc == "L" then found_L = true end
end
assert(found_L, "L should be assigned to playback.forward")
print("  ✓ L assigned to playback.forward")

print("\nTest 6: J shortcut assigned to playback.reverse")
local found_J = false
for _, sc in ipairs(assigned_shortcuts["playback.reverse"] or {}) do
    if sc == "J" then found_J = true end
end
assert(found_J, "J should be assigned to playback.reverse")
print("  ✓ J assigned to playback.reverse")

print("\nTest 7: K shortcut assigned to playback.stop")
local found_K = false
for _, sc in ipairs(assigned_shortcuts["playback.stop"] or {}) do
    if sc == "K" then found_K = true end
end
assert(found_K, "K should be assigned to playback.stop")
print("  ✓ K assigned to playback.stop")

print("\n--- Test JKL handlers execute via registry ---")

-- Clear tracking
playback_calls = {}

print("\nTest 8: L key in timeline_monitor context triggers playback.forward handler")
current_focus = "timeline_monitor"
local handler = registered_commands["playback.forward"].handler
assert(handler, "playback.forward should have a handler")
handler()
assert(#playback_calls > 0, "handler should have called playback controller")
print("  ✓ playback.forward handler called playback controller: " .. playback_calls[#playback_calls])

-- Clear tracking
playback_calls = {}

print("\nTest 9: J key handler triggers reverse shuttle")
handler = registered_commands["playback.reverse"].handler
assert(handler, "playback.reverse should have a handler")
handler()
assert(#playback_calls > 0, "handler should have called playback controller")
print("  ✓ playback.reverse handler called: " .. playback_calls[#playback_calls])

-- Clear tracking
playback_calls = {}

print("\nTest 10: K key handler triggers stop")
handler = registered_commands["playback.stop"].handler
assert(handler, "playback.stop should have a handler")
handler()
local found_stop = false
for _, call in ipairs(playback_calls) do
    if call == "stop" then found_stop = true end
end
assert(found_stop, "K handler should call stop")
print("  ✓ playback.stop handler called stop")

print("\n✅ test_jkl_registry_integration.lua passed")
