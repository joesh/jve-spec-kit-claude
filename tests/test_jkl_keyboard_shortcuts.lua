require('test_env')

-- JKL keyboard shortcut dispatch test.
-- Verifies that literal Qt key codes J/K/L dispatch correct shuttle commands.
-- Uses LITERAL Qt key codes (not keyboard_constants) to catch wrong-constant bugs.
-- Uses REAL timeline_state — no mock.
-- command_manager mock is justified: test tracks dispatched command names, not execution.

print("=== Test JKL Keyboard Shortcuts ===")

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Mock panel_manager (Qt dependency)
package.loaded["ui.panel_manager"] = {
    toggle_active_panel = function() end,
    get_active_sequence_monitor = function() return nil end,
}

-- Set up database for real timeline_state
local database = require("core.database")
local command_manager = require("core.command_manager")

local TEST_DB = "/tmp/jve/test_jkl_keyboard.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")
assert(database.init(TEST_DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (
        id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'seq1', 'proj1', 'Seq', 'timeline', 24, 1, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d
    );
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

-- Init real timeline_state from database
command_manager.init('seq1', 'proj1')

-- Load real modules
local keyboard_shortcuts = require("core.keyboard_shortcuts")
local focus_manager = require("ui.focus_manager")
local timeline_state = require("ui.timeline.timeline_state")

-- ── Literal Qt key codes ──
local QT_KEY_J = 74
local QT_KEY_K = 75
local QT_KEY_L = 76

-- Mock command_manager for dispatch tracking (justified: testing routing, not execution)
local dispatched = {}
local mock_cm = {
    execute_ui = function(cmd)
        dispatched[#dispatched + 1] = cmd
        return { success = true }
    end,
    get_executor = function() return function() end end,
    peek_command_event_origin = function() return nil end,
    begin_command_event = function() end,
    end_command_event = function() end,
}

local function reset()
    dispatched = {}
    focus_manager.set_focused_panel("timeline")
    keyboard_shortcuts.init(timeline_state, mock_cm,
        { add_selected_to_timeline = function() end },
        { is_dragging = function() return false end })
end

local function find_cmd(name)
    for _, cmd in ipairs(dispatched) do
        if cmd == name then return true end
    end
    return false
end

print("\nTest 1: J dispatches ShuttleReverse")
reset()
keyboard_shortcuts.handle_key({ key = QT_KEY_J, modifiers = 0, text = "j", focus_widget_is_text_input = 0 })
assert(find_cmd("ShuttleReverse"), "J should dispatch ShuttleReverse, got: " .. table.concat(dispatched, ", "))
print("  ✓ J → ShuttleReverse")

print("\nTest 2: K dispatches ShuttleStop")
reset()
keyboard_shortcuts.handle_key({ key = QT_KEY_K, modifiers = 0, text = "k", focus_widget_is_text_input = 0 })
assert(find_cmd("ShuttleStop"), "K should dispatch ShuttleStop, got: " .. table.concat(dispatched, ", "))
print("  ✓ K → ShuttleStop")

print("\nTest 3: L dispatches ShuttleForward")
reset()
keyboard_shortcuts.handle_key({ key = QT_KEY_L, modifiers = 0, text = "l", focus_widget_is_text_input = 0 })
assert(find_cmd("ShuttleForward"), "L should dispatch ShuttleForward, got: " .. table.concat(dispatched, ", "))
print("  ✓ L → ShuttleForward")

print("\nTest 4: J in text field does not dispatch")
reset()
keyboard_shortcuts.handle_key({ key = QT_KEY_J, modifiers = 0, text = "j", focus_widget_is_text_input = true })
assert(not find_cmd("ShuttleReverse"), "J should not dispatch in text field")
print("  ✓ J in text field passes through")

print("\nTest 5: handle_key_release exists and returns false")
assert(type(keyboard_shortcuts.handle_key_release) == "function", "handle_key_release should exist")
local result = keyboard_shortcuts.handle_key_release({ key = QT_KEY_K })
assert(result == false, "handle_key_release should return false")
print("  ✓ handle_key_release(K) returns false")

print("\n✅ test_jkl_keyboard_shortcuts.lua passed")
