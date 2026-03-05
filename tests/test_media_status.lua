require("test_env")
local media_status = require("core.media.media_status")
local Signals = require("core.signals")

local function check(desc, cond)
    if not cond then error("FAIL: " .. desc) end
    print("  OK: " .. desc)
end

-- ============================================================
print("\n--- media_status: probe existing file ---")
do
    media_status.clear()

    -- Create a temp file
    local tmp = "/tmp/jve/test_media_status_exists.txt"
    os.execute("mkdir -p /tmp/jve")
    local f = io.open(tmp, "w")
    f:write("test")
    f:close()

    local status = media_status.register(tmp)
    check("existing file is not offline", status.offline == false)
    check("existing file has no error_code", status.error_code == nil)

    -- Cached get returns same
    local cached = media_status.get(tmp)
    check("cached status matches", cached.offline == false)
    check("cached error_code matches", cached.error_code == nil)

    os.remove(tmp)
    media_status.clear()
end

-- ============================================================
print("\n--- media_status: probe missing file ---")
do
    media_status.clear()

    local status = media_status.register("/tmp/jve/nonexistent_media_file_12345.mov")
    check("missing file is offline", status.offline == true)
    check("missing file error_code is FileNotFound", status.error_code == "FileNotFound")

    media_status.clear()
end

-- ============================================================
print("\n--- media_status: unregister clears cache ---")
do
    media_status.clear()

    media_status.register("/tmp/jve/nonexistent_file_unreg.mov")
    check("registered", media_status.get("/tmp/jve/nonexistent_file_unreg.mov") ~= nil)

    media_status.unregister("/tmp/jve/nonexistent_file_unreg.mov")
    check("unregistered", media_status.get("/tmp/jve/nonexistent_file_unreg.mov") == nil)

    media_status.clear()
end

-- ============================================================
print("\n--- media_status: ensure_clip_status (lazy eval) ---")
do
    media_status.clear()

    -- Create a temp file so this one is online
    local tmp = "/tmp/jve/test_media_apply.txt"
    os.execute("mkdir -p /tmp/jve")
    local f = io.open(tmp, "w")
    f:write("test")
    f:close()

    -- Test with media_path (timeline clips)
    local c1 = { id = "c1", media_path = tmp }
    media_status.ensure_clip_status(c1)
    check("c1 is online", c1.offline == false)
    check("c1 no error", c1.error_code == nil)

    local c2 = { id = "c2", media_path = "/tmp/jve/does_not_exist_apply.mov" }
    media_status.ensure_clip_status(c2)
    check("c2 is offline", c2.offline == true)
    check("c2 error is FileNotFound", c2.error_code == "FileNotFound")

    -- Test with file_path (browser clips)
    local c5 = { id = "c5", file_path = tmp }
    media_status.ensure_clip_status(c5)
    check("c5 online via file_path", c5.offline == false)

    -- Empty/nil path: no-op
    local c3 = { id = "c3", media_path = "" }
    media_status.ensure_clip_status(c3)
    check("c3 unchanged (empty media_path)", c3.offline == nil)

    local c4 = { id = "c4" }
    media_status.ensure_clip_status(c4)
    check("c4 unchanged (nil media_path)", c4.offline == nil)

    -- Cache hit: second call is instant, doesn't re-probe
    local c1b = { id = "c1b", media_path = tmp }
    os.remove(tmp)  -- delete file AFTER initial probe cached it
    media_status.ensure_clip_status(c1b)
    check("c1b uses cache (still online despite file deleted)", c1b.offline == false)

    media_status.clear()
end

-- ============================================================
print("\n--- media_status: ensure_clip_status with check_codec ---")
do
    media_status.clear()

    -- Create a temp file
    local tmp = "/tmp/jve/test_media_codec_check.txt"
    os.execute("mkdir -p /tmp/jve")
    local f = io.open(tmp, "w")
    f:write("test data")
    f:close()

    -- Without check_codec: file existence only
    local c1 = { id = "c1", media_path = tmp }
    media_status.ensure_clip_status(c1)
    check("without codec check: online", c1.offline == false)

    -- With check_codec=true: queues async codec probe (timer-based).
    -- In tests (no qt_create_single_shot_timer), drain is a no-op.
    -- File appears online immediately; codec check would run async.
    media_status.clear()
    local c2 = { id = "c2", media_path = tmp }
    media_status.ensure_clip_status(c2, true)
    check("with codec check (no EMP): still online", c2.offline == false)

    -- For missing files, check_codec doesn't matter (file doesn't exist)
    media_status.clear()
    local c3 = { id = "c3", media_path = "/tmp/jve/does_not_exist_codec.mov" }
    media_status.ensure_clip_status(c3, true)
    check("missing file with codec check: offline", c3.offline == true)
    check("missing file error: FileNotFound", c3.error_code == "FileNotFound")

    os.remove(tmp)
    media_status.clear()
end

-- ============================================================
print("\n--- media_status: clear resets everything ---")
do
    media_status.register("/tmp/jve/clear_test.mov")
    check("registered", media_status.get("/tmp/jve/clear_test.mov") ~= nil)

    media_status.clear()
    check("cleared", media_status.get("/tmp/jve/clear_test.mov") == nil)
end

-- ============================================================
print("\n--- media_status: re-probe detects file appearance ---")
do
    media_status.clear()

    local tmp = "/tmp/jve/test_media_reprobe.txt"
    os.remove(tmp)  -- ensure it doesn't exist

    -- Register as missing
    local status = media_status.register(tmp)
    check("initially offline", status.offline == true)

    -- Track signal emissions
    local signal_received = false
    local signal_path, signal_status
    local conn_id = Signals.connect("media_status_changed", function(path, st)
        signal_received = true
        signal_path = path
        signal_status = st
    end)

    -- Create the file
    local f = io.open(tmp, "w")
    f:write("test")
    f:close()

    -- Simulate dir change callback (in real app, QFileSystemWatcher fires this)
    media_status._on_dir_changed("/tmp/jve")

    check("signal emitted", signal_received == true)
    check("signal path correct", signal_path == tmp)
    check("now online", signal_status.offline == false)
    check("cache updated", media_status.get(tmp).offline == false)

    Signals.disconnect(conn_id)
    os.remove(tmp)
    media_status.clear()
end

-- ============================================================
print("\n--- media_status: re-probe detects file disappearance ---")
do
    media_status.clear()

    local tmp = "/tmp/jve/test_media_disappear.txt"
    local f = io.open(tmp, "w")
    f:write("test")
    f:close()

    -- Register as online
    local status = media_status.register(tmp)
    check("initially online", status.offline == false)

    local signal_received = false
    local conn_id = Signals.connect("media_status_changed", function(path, st)
        signal_received = true
    end)

    -- Delete the file
    os.remove(tmp)

    -- Simulate file change callback
    media_status._on_file_changed(tmp)

    check("signal emitted on disappear", signal_received == true)
    check("now offline", media_status.get(tmp).offline == true)
    check("error is FileNotFound", media_status.get(tmp).error_code == "FileNotFound")

    Signals.disconnect(conn_id)
    media_status.clear()
end

-- ============================================================
print("\n--- media_status: project_changed clears state ---")
do
    media_status.register("/tmp/jve/project_change_test.mov")
    check("registered before project_changed", media_status.get("/tmp/jve/project_change_test.mov") ~= nil)

    Signals.emit("project_changed", "new_project_id")
    check("cleared after project_changed", media_status.get("/tmp/jve/project_change_test.mov") == nil)
end

-- ============================================================
print("\n--- media_status: NSF — register(nil) asserts ---")
do
    local ok, err = pcall(function() media_status.register(nil) end)
    check("register(nil) asserts", ok == false)
    check("assert message mentions media_path", err:find("media_path") ~= nil)
end

-- ============================================================
print("\n--- media_status: NSF — register('') asserts ---")
do
    local ok, err = pcall(function() media_status.register("") end)
    check("register('') asserts", ok == false)
    check("assert message mentions media_path", err:find("media_path") ~= nil)
end

-- ============================================================
print("\n--- media_status: NSF — ensure_clip_status(nil) is no-op ---")
do
    -- nil clip fields: ensure_clip_status should not crash
    local clip = {}
    media_status.ensure_clip_status(clip)
    check("ensure_clip_status({}) is safe", clip.offline == nil)
end

-- ============================================================
print("\n--- media_status: NSF — _on_file_changed(nil) asserts ---")
do
    local ok, err = pcall(function() media_status._on_file_changed(nil) end)
    check("_on_file_changed(nil) asserts", ok == false)
    check("assert message mentions path", err:find("path") ~= nil)
end

-- ============================================================
print("\n--- media_status: NSF — _on_dir_changed(nil) asserts ---")
do
    local ok, err = pcall(function() media_status._on_dir_changed(nil) end)
    check("_on_dir_changed(nil) asserts", ok == false)
    check("assert message mentions dir", err:find("dir") ~= nil)
end

-- ============================================================
print("\n--- media_status: NSF — clear + re-register works (callback survival) ---")
do
    media_status.clear()

    local tmp = "/tmp/jve/test_media_callback_survival.txt"
    os.remove(tmp)

    -- Register as missing
    media_status.register(tmp)
    check("initially offline", media_status.get(tmp).offline == true)

    -- Simulate project change (clears all state)
    media_status.clear()
    check("cache cleared after clear()", media_status.get(tmp) == nil)

    -- Re-register same path (new project has same media)
    media_status.register(tmp)
    check("re-registered as offline", media_status.get(tmp).offline == true)

    -- Create the file and simulate dir change — callbacks should still work
    local signal_received = false
    local conn_id = Signals.connect("media_status_changed", function()
        signal_received = true
    end)

    local f = io.open(tmp, "w")
    f:write("test")
    f:close()

    media_status._on_dir_changed("/tmp/jve")
    check("signal still fires after clear+re-register", signal_received == true)
    check("now online after re-probe", media_status.get(tmp).offline == false)

    Signals.disconnect(conn_id)
    os.remove(tmp)
    media_status.clear()
end

-- ============================================================
print("\n--- media_status: update_from_tmb sets codec error ---")
do
    media_status.clear()

    -- Register an existing file (online)
    local tmp = "/tmp/jve/test_media_tmb_update.txt"
    os.execute("mkdir -p /tmp/jve")
    local f = io.open(tmp, "w")
    f:write("test")
    f:close()

    media_status.register(tmp)
    check("initially online", media_status.get(tmp).offline == false)
    check("initially no error_code", media_status.get(tmp).error_code == nil)

    -- Simulate TMB discovering a codec error
    local signal_received = false
    local received_status
    local conn_id = Signals.connect("media_status_changed", function(_, st)
        signal_received = true
        received_status = st
    end)

    media_status.update_from_tmb(tmp, true, "Unsupported")
    check("signal emitted on TMB update", signal_received == true)
    check("signal payload offline", received_status.offline == true)
    check("signal payload error_code", received_status.error_code == "Unsupported")
    check("now offline", media_status.get(tmp).offline == true)
    check("error_code is Unsupported", media_status.get(tmp).error_code == "Unsupported")

    -- Calling again with same status should NOT emit signal
    signal_received = false
    media_status.update_from_tmb(tmp, true, "Unsupported")
    check("no duplicate signal for same status", signal_received == false)

    Signals.disconnect(conn_id)
    os.remove(tmp)
    media_status.clear()
end

-- ============================================================
print("\n--- media_status: NSF — update_from_tmb(nil) asserts ---")
do
    local ok, err = pcall(function() media_status.update_from_tmb(nil, true, "X") end)
    check("update_from_tmb(nil) asserts", ok == false)
    check("assert message mentions media_path", err:find("media_path") ~= nil)
end

-- ============================================================
print("\n--- media_status: NSF — ensure_clip_status(nil) asserts ---")
do
    local ok, err = pcall(function() media_status.ensure_clip_status(nil) end)
    check("ensure_clip_status(nil) asserts", ok == false)
    check("assert message mentions clip", err:find("clip") ~= nil)
end

-- ============================================================
print("\n--- media_status: NSF — update_from_tmb offline must be boolean ---")
do
    media_status.clear()
    local tmp = "/tmp/jve/test_tmb_offline_type.txt"
    os.execute("mkdir -p /tmp/jve")
    local f = io.open(tmp, "w"); f:write("x"); f:close()
    media_status.register(tmp)

    -- offline=nil should assert
    local ok, err = pcall(function() media_status.update_from_tmb(tmp, nil, "X") end)
    check("update_from_tmb(offline=nil) asserts", ok == false)
    check("assert message mentions offline", err:find("offline") ~= nil)

    os.remove(tmp)
    media_status.clear()
end

-- ============================================================
print("\n--- media_status: NSF — drain_one_codec_probe processes queued path ---")
do
    media_status.clear()

    local tmp = "/tmp/jve/test_drain_codec.txt"
    os.execute("mkdir -p /tmp/jve")
    local f = io.open(tmp, "w"); f:write("test"); f:close()

    -- Register path (online via file existence)
    media_status.register(tmp)
    check("initially online", media_status.get(tmp).offline == false)

    -- Simulate queueing a codec check (what ensure_clip_status does)
    local clip = { id = "drain_test", media_path = tmp }
    media_status.ensure_clip_status(clip, true)
    check("clip shows online before drain", clip.offline == false)

    -- In tests, no timer exists, so drain never fires automatically.
    -- Call drain directly to test the mechanism.
    media_status._drain_one_codec_probe()

    -- In tests, no EMP → probe_codec returns nil → path stays online
    check("after drain (no EMP): still online", media_status.get(tmp).offline == false)

    -- Verify path was marked as probed (won't be re-queued)
    local clip2 = { id = "drain_test2", media_path = tmp }
    media_status.ensure_clip_status(clip2, true)
    check("not re-queued after drain", clip2.offline == false)

    os.remove(tmp)
    media_status.clear()
end

-- ============================================================
print("\n--- media_status: NSF — drain skips path already offline ---")
do
    media_status.clear()

    local tmp = "/tmp/jve/test_drain_skip.txt"
    os.execute("mkdir -p /tmp/jve")
    local f = io.open(tmp, "w"); f:write("test"); f:close()

    -- Register as online, queue codec check
    media_status.register(tmp)
    local clip = { id = "skip_test", media_path = tmp }
    media_status.ensure_clip_status(clip, true)

    -- Before drain fires, TMB discovers it's offline
    media_status.update_from_tmb(tmp, true, "Unsupported")
    check("now offline via TMB", media_status.get(tmp).offline == true)

    -- Track signals
    local signal_count = 0
    local conn = Signals.connect("media_status_changed", function()
        signal_count = signal_count + 1
    end)

    -- Drain should skip this path (already offline)
    media_status._drain_one_codec_probe()
    check("no signal from drain (path already offline)", signal_count == 0)

    Signals.disconnect(conn)
    os.remove(tmp)
    media_status.clear()
end

print("\n✅ test_media_status.lua passed")
