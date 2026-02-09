require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local asserts_module = require("core.asserts")

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

local function expect_error(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
    return err
end

print("\n=== CommandManager Error Path Tests ===")

local db_path = "/tmp/jve/test_command_manager_error_paths.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now, now, now))

-- Stub timeline_state so commands can capture playhead/selection
local timeline_state = require("ui.timeline.timeline_state")
timeline_state.capture_viewport = function()
    return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 1000}
end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end
timeline_state.get_selected_clips = function() return {} end
timeline_state.set_edge_selection = function(_) end
timeline_state.get_selected_edges = function() return {} end
timeline_state.set_playhead_position = function(_) end
timeline_state.get_playhead_position = function() return 0 end
timeline_state.reload_clips = function() end
timeline_state.get_sequence_frame_rate = function() return {fps_numerator = 24000, fps_denominator = 1001} end
timeline_state.get_sequence_audio_sample_rate = function() return 48000 end
timeline_state.clear_edge_selection = function() end
timeline_state.clear_gap_selection = function() end
timeline_state.apply_mutations = function() return false end

command_manager.init("seq1", "proj1")

-- ═══════════════════════════════════════════════════════════════
-- Tests 1-4: normalize_command failures (bug_result path).
-- Disable asserts so bug_result returns {success=false} instead of
-- throwing — which would leak execution_depth (no cleanup block).
-- ═══════════════════════════════════════════════════════════════

asserts_module._set_enabled_for_tests(false)

print("\n--- unknown command type (string) → bug_result ---")
do
    local result = command_manager.execute("NonexistentCommand", { project_id = "proj1" })
    check("unregistered string → success=false", result.success == false)
    check("is_bug flag set", result.is_bug == true)
    check("error mentions 'No executor'", result.error_message and result.error_message:find("No executor") ~= nil)
end

print("--- unknown command type (Command object) → bug_result ---")
do
    local cmd = Command.create("GhostCommand", "proj1")
    local result = command_manager.execute(cmd)
    check("unregistered Command → success=false", result.success == false)
    check("error mentions 'No executor'", result.error_message and result.error_message:find("No executor") ~= nil)
end

print("--- unsupported argument type → bug_result ---")
do
    local result = command_manager.execute(42)
    check("number arg → success=false", result.success == false)
    check("error mentions 'Unsupported'", result.error_message and result.error_message:find("Unsupported") ~= nil)
end

print("\n--- no active command event → auto-wraps ---")
do
    command_manager.end_command_event()
    command_manager.register_executor("EventTestCmd", function() return true end, function() return true end, {
        args = { project_id = { required = true } }
    })

    -- execute() should auto-wrap in command event when none is active
    local result = command_manager.execute("EventTestCmd", { project_id = "proj1" })
    check("no event → auto-wraps, success=true", result.success == true)

    command_manager.begin_command_event("script")
    command_manager.unregister_executor("EventTestCmd")
end

asserts_module._set_enabled_for_tests(true)

-- ═══════════════════════════════════════════════════════════════
-- 5. Executor returns nil — treated as failure
-- ═══════════════════════════════════════════════════════════════

print("\n--- executor returns nil → failure ---")
do
    command_manager.register_executor("NilResult", function()
        return nil
    end, function() return true end, {
        args = { project_id = { required = true } }
    })

    local cmd = Command.create("NilResult", "proj1")
    local result = command_manager.execute(cmd)
    check("nil result → success=false", result.success == false)

    command_manager.unregister_executor("NilResult")
end

-- ═══════════════════════════════════════════════════════════════
-- 6. Executor throws error — pcall catches
-- ═══════════════════════════════════════════════════════════════

print("--- executor throws error → caught, returns failure ---")
do
    command_manager.register_executor("CrashingCmd", function()
        error("BOOM: intentional test crash")
    end, function() return true end, {
        args = { project_id = { required = true } }
    })

    local cmd = Command.create("CrashingCmd", "proj1")
    local result = command_manager.execute(cmd)
    check("crashing executor → success=false", result.success == false)
    check("error message includes crash text", result.error_message and result.error_message:find("BOOM") ~= nil)

    command_manager.unregister_executor("CrashingCmd")
end

-- ═══════════════════════════════════════════════════════════════
-- 7. execute_undo when undoer auto-load fails
-- ═══════════════════════════════════════════════════════════════

print("\n--- undo without undoer (auto-load fails) ---")
do
    command_manager.register_executor("NoUndoerCmd", function()
        return true
    end, nil, {
        args = { project_id = { required = true } }
    })

    local cmd = Command.create("NoUndoerCmd", "proj1")
    local exec_result = command_manager.execute(cmd)
    check("execute succeeds", exec_result.success == true)

    local undo_result = command_manager.undo()
    check("undo fails", undo_result.success == false)
    check("mentions 'No undoer'", undo_result.error_message and undo_result.error_message:find("No undoer") ~= nil)

    command_manager.unregister_executor("NoUndoerCmd")
end

-- ═══════════════════════════════════════════════════════════════
-- 8. Undoer throws error — pcall catches
-- ═══════════════════════════════════════════════════════════════

print("--- undoer throws error → caught ---")
do
    command_manager.register_executor("CrashUndoCmd", function()
        return true
    end, function()
        error("UNDO_BOOM: intentional undo crash")
    end, {
        args = { project_id = { required = true } }
    })

    local cmd = Command.create("CrashUndoCmd", "proj1")
    local exec_result = command_manager.execute(cmd)
    check("execute succeeds", exec_result.success == true)

    local undo_result = command_manager.undo()
    check("crashing undoer → success=false", undo_result.success == false)
    check("error includes crash text", undo_result.error_message and undo_result.error_message:find("UNDO_BOOM") ~= nil)

    command_manager.unregister_executor("CrashUndoCmd")
end

-- ═══════════════════════════════════════════════════════════════
-- 9. Undoer returns false — propagated as failure
-- ═══════════════════════════════════════════════════════════════

print("--- undoer returns false → failure ---")
do
    command_manager.register_executor("FailUndoCmd", function()
        return true
    end, function()
        return false, "undo_refused"
    end, {
        args = { project_id = { required = true } }
    })

    local cmd = Command.create("FailUndoCmd", "proj1")
    local exec_result = command_manager.execute(cmd)
    check("execute succeeds", exec_result.success == true)

    local undo_result = command_manager.undo()
    check("false undoer → success=false", undo_result.success == false)

    command_manager.unregister_executor("FailUndoCmd")
end

-- ═══════════════════════════════════════════════════════════════
-- 10. replay_events gracefully handles timeline_state
-- ═══════════════════════════════════════════════════════════════

print("\n--- replay_events returns boolean ---")
do
    local ok = command_manager.replay_events("seq1", 0)
    check("replay_events returns boolean", type(ok) == "boolean")
end

-- ═══════════════════════════════════════════════════════════════
-- 11. Nested command failure propagation
-- ═══════════════════════════════════════════════════════════════

print("\n--- nested command failure propagation ---")
do
    command_manager.register_executor("ChildFail", function()
        error("CHILD_FAIL: intentional")
    end, function() return true end, {
        args = { project_id = { required = true } }
    })

    command_manager.register_executor("ParentCmd", function(cmd)
        local child = Command.create("ChildFail", "proj1")
        local child_result = command_manager.execute(child)
        if not child_result.success then
            return false, "child failed: " .. (child_result.error_message or "")
        end
        return true
    end, function() return true end, {
        args = { project_id = { required = true } }
    })

    local cmd = Command.create("ParentCmd", "proj1")
    local result = command_manager.execute(cmd)
    check("parent fails when child fails", result.success == false)

    command_manager.unregister_executor("ChildFail")
    command_manager.unregister_executor("ParentCmd")
end

-- ═══════════════════════════════════════════════════════════════
-- 12. Listener error isolation (pcall in notify)
-- ═══════════════════════════════════════════════════════════════

print("\n--- listener error doesn't crash execute ---")
do
    local good_events = {}
    local crashing_listener = function()
        error("LISTENER_CRASH")
    end
    local good_listener = function(evt)
        table.insert(good_events, evt)
    end

    command_manager.add_listener(crashing_listener)
    command_manager.add_listener(good_listener)

    command_manager.register_executor("ListenerTestCmd", function()
        return true
    end, function() return true end, {
        args = { project_id = { required = true } }
    })

    local cmd = Command.create("ListenerTestCmd", "proj1")
    local result = command_manager.execute(cmd)
    check("execute succeeds despite crashing listener", result.success == true)
    check("good listener still received event", #good_events >= 1)

    command_manager.remove_listener(crashing_listener)
    command_manager.remove_listener(good_listener)
    command_manager.unregister_executor("ListenerTestCmd")
end

-- ═══════════════════════════════════════════════════════════════
-- 13. begin/end command_event depth tracking
-- ═══════════════════════════════════════════════════════════════

print("\n--- command event nesting depth ---")
do
    local ok1 = command_manager.begin_command_event("script")
    check("nested begin succeeds", ok1 == true)
    check("origin still 'script'", command_manager.peek_command_event_origin() == "script")

    local ok2 = command_manager.end_command_event()
    check("nested end succeeds", ok2 == true)
    check("origin still active (outer)", command_manager.peek_command_event_origin() == "script")
end

print("--- end_command_event without begin asserts ---")
do
    command_manager.end_command_event()
    local err = expect_error("end without begin", function()
        command_manager.end_command_event()
    end)
    check("error mentions 'No active command event'", err and err:find("No active command event") ~= nil)

    command_manager.begin_command_event("script")
end

-- ═══════════════════════════════════════════════════════════════
-- 14. Non-recording command (undoable=false) executor failure
-- ═══════════════════════════════════════════════════════════════

print("\n--- non-recording command failure ---")
do
    command_manager.register_executor("NonRecordFail", function()
        error("NON_RECORD_BOOM")
    end, nil, {
        undoable = false,
        args = { project_id = { required = true } }
    })

    local cmd = Command.create("NonRecordFail", "proj1")
    local result = command_manager.execute(cmd)
    check("non-recording failure → success=false", result.success == false)
    check("error includes crash text", result.error_message and result.error_message:find("NON_RECORD_BOOM") ~= nil)

    command_manager.unregister_executor("NonRecordFail")
end

-- ═══════════════════════════════════════════════════════════════
-- 15. Malformed executor result — MUST BE LAST
--     (assert at normalize_executor_result leaks execution_depth)
-- ═══════════════════════════════════════════════════════════════

print("\n--- malformed executor result (non-boolean .success) asserts ---")
do
    command_manager.register_executor("MalformedResult", function()
        return { success = "yes" }
    end, function() return true end, {
        args = { project_id = { required = true } }
    })

    local err = expect_error("non-boolean .success field", function()
        local cmd = Command.create("MalformedResult", "proj1")
        command_manager.execute(cmd)
    end)
    check("error mentions 'contract violated'", err and err:find("contract violated") ~= nil)

    command_manager.unregister_executor("MalformedResult")
end

-- ═══════════════════════════════════════════════════════════════
-- Summary
-- ═══════════════════════════════════════════════════════════════

print(string.format("\n%d passed, %d failed", pass_count, fail_count))

if fail_count > 0 then
    os.exit(1)
else
    print("✅ test_command_manager_error_paths.lua passed")
end
