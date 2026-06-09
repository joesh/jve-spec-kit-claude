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
print("\n--- media_status: ensure_clip_status (pure reader) ---")
do
    media_status.clear()
    os.execute("mkdir -p /tmp/jve")

    -- ensure_clip_status is a pure reader: stamps from cache, never writes.

    -- Cache hit: stamps clip from cached status
    media_status._set_cache("/tmp/jve/online.mov", { offline = false })
    local c1 = { id = "c1", media_path = "/tmp/jve/online.mov" }
    media_status.ensure_clip_status(c1)
    check("c1 online from cache", c1.offline == false)

    -- Cache hit with error
    media_status._set_cache("/tmp/jve/bad.braw", { offline = true, error_code = "Unsupported" })
    local c2 = { id = "c2", media_path = "/tmp/jve/bad.braw" }
    media_status.ensure_clip_status(c2)
    check("c2 offline from cache", c2.offline == true)
    check("c2 Unsupported from cache", c2.error_code == "Unsupported")

    -- Cache miss: no-op (clip keeps existing state)
    local c3 = { id = "c3", media_path = "/tmp/jve/unknown.mov" }
    media_status.ensure_clip_status(c3)
    check("c3 unchanged (cache miss)", c3.offline == nil)

    -- Empty/nil path: no-op
    local c4 = { id = "c4", media_path = "" }
    media_status.ensure_clip_status(c4)
    check("c4 unchanged (empty path)", c4.offline == nil)

    local c5 = { id = "c5" }
    media_status.ensure_clip_status(c5)
    check("c5 unchanged (nil path)", c5.offline == nil)

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

    os.remove(tmp)
    local parent = tmp:match("^(.+)/[^/]+$")
    media_status._on_dir_changed(parent)

    check("signal emitted on disappear", signal_received == true)
    check("now offline", media_status.get(tmp).offline == true)
    check("error is FileNotFound", media_status.get(tmp).error_code == "FileNotFound")

    Signals.disconnect(conn_id)
    media_status.clear()
end

-- ============================================================
print("\n--- media_status: in-place rewrite fires media_content_changed ---")
do
    media_status.clear()

    local tmp = "/tmp/jve/test_media_rewrite.txt"
    os.execute("mkdir -p /tmp/jve")
    local f = io.open(tmp, "w"); f:write("initial"); f:close()

    local status = media_status.register(tmp)
    check("initially online", status.offline == false)

    local status_fired, content_fired = false, false
    local c1 = Signals.connect("media_status_changed", function() status_fired = true end)
    local c2 = Signals.connect("media_content_changed", function() content_fired = true end)

    -- Advance mtime deterministically — filesystem granularity is ~1s.
    os.execute(string.format("touch -t 202601010000 %q", tmp))

    local parent = tmp:match("^(.+)/[^/]+$")
    media_status._on_dir_changed(parent)

    check("status_changed NOT emitted (file still online)", status_fired == false)
    check("content_changed emitted for in-place rewrite", content_fired == true)

    -- Negative case: dir_changed fires again but file wasn't touched —
    -- no spurious content_changed.
    content_fired = false
    media_status._on_dir_changed(parent)
    check("no spurious content_changed when mtime unchanged", content_fired == false)

    Signals.disconnect(c1)
    Signals.disconnect(c2)
    os.remove(tmp)
    media_status.clear()
end

-- ============================================================
print("\n--- media_status: FS watches dirs, never files ---")
do
    -- Architectural guarantee: media_status must never install per-file
    -- watches. Per-file kqueue FDs exhaust RLIMIT_NOFILE on large
    -- projects. Stub qt_constants.FS and count calls by kind.
    media_status.clear()

    -- Stub FS: WATCH_FILE aborts the test if ever called (binary
    -- invariant, no need to count — a single call is already a bug).
    local dir_watch_calls = 0
    local saved_qt = rawget(_G, "qt_constants")
    _G.qt_constants = {
        FS = {
            WATCH_FILE = function()
                error("media_status must not install per-file watches")
            end,
            WATCH_DIR = function()
                dir_watch_calls = dir_watch_calls + 1
                return true
            end,
            UNWATCH_DIR = function() return true end,
            SET_DIR_CHANGED_CB = function() end,
            CLEAR_ALL = function() end,
        },
    }

    -- Force re-init: media_status caches fs_available. The test env
    -- above left it false; now with qt_constants set the next
    -- watch_path call will flip it.
    local paths = {
        "/tmp/jve/fs_watch_test_a.txt",
        "/tmp/jve/fs_watch_test_b.txt",
        "/tmp/jve/fs_watch_test_c.txt",
    }
    os.execute("mkdir -p /tmp/jve")
    for _, p in ipairs(paths) do
        local f = io.open(p, "w"); f:write("x"); f:close()
        media_status.register(p)
    end

    -- If WATCH_FILE had been called, the stub would have raised and
    -- the register() above would have propagated the error. Reaching
    -- here means the binary invariant held.
    check("at least one dir watch installed", dir_watch_calls >= 1)

    for _, p in ipairs(paths) do os.remove(p) end
    _G.qt_constants = saved_qt
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
print("\n--- media_status: persistence round-trip ---")
do
    -- Set up a test DB so project_settings work
    local database = require("core.database")
    local TEST_DB = "/tmp/jve/test_media_persist.db"
    os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
    os.execute("mkdir -p /tmp/jve")
    assert(database.init(TEST_DB))
    local db = database.get_connection()
    db:exec(require("import_schema"))
    local now = os.time()
    db:exec(string.format(
        "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) VALUES ('p1', 'Test', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', %d, %d)",
        now, now))

    media_status.clear()

    -- Simulate TMB discovering errors for 2 paths
    media_status.register("/tmp/jve/existing_file_persist.txt")
    local f = io.open("/tmp/jve/existing_file_persist.txt", "w"); f:write("x"); f:close()
    media_status.register("/tmp/jve/existing_file_persist.txt")
    media_status.update_from_tmb("/tmp/jve/existing_file_persist.txt", true, "Unsupported")
    media_status.register("/tmp/jve/missing_persist.mov")

    -- Load persisted sets project_id for persist_now
    media_status.load_persisted("p1")

    -- Force flush
    media_status.persist_now()

    -- Verify DB has the data
    local map = database.get_project_setting("p1", "media_error_cache")
    check("persisted map is table", type(map) == "table")
    check("existing file persisted as Unsupported",
        map["/tmp/jve/existing_file_persist.txt"] ~= nil
        and map["/tmp/jve/existing_file_persist.txt"].error_code == "Unsupported")
    check("missing file persisted as FileNotFound",
        map["/tmp/jve/missing_persist.mov"] ~= nil
        and map["/tmp/jve/missing_persist.mov"].error_code == "FileNotFound")

    -- Clear and reload — should pre-populate cache
    media_status.clear()
    check("cache empty after clear", media_status.get("/tmp/jve/existing_file_persist.txt") == nil)

    media_status.load_persisted("p1")
    local cached = media_status.get("/tmp/jve/existing_file_persist.txt")
    -- "Unsupported" entries are intentionally cleared on load (stale codec errors
    -- from prior builds get re-probed). Only "FileNotFound" persists across loads.
    check("Unsupported cleared on reload (re-probe needed)", cached == nil)
    local cached2 = media_status.get("/tmp/jve/missing_persist.mov")
    check("FileNotFound restored from DB", cached2 ~= nil and cached2.error_code == "FileNotFound")

    os.remove("/tmp/jve/existing_file_persist.txt")
    os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
    media_status.clear()
end

-- ============================================================
print("\n--- media_status: ensure_clip_status is pure reader (no cache writes) ---")
do
    -- Architecture: ensure_clip_status ONLY reads from cache, never writes.
    -- This prevents preliminary file-existence results from overwriting
    -- authoritative codec error discoveries.
    media_status.clear()
    os.execute("mkdir -p /tmp/jve")

    local braw_path = "/tmp/jve/test_pure_reader.braw"
    local f = io.open(braw_path, "w"); f:write("fake braw"); f:close()

    -- Cache has Unsupported error (from bg probe or load_persisted)
    media_status._set_cache(braw_path, { offline = true, error_code = "Unsupported" })

    -- ensure_clip_status reads from cache — doesn't probe or overwrite
    local clip = { id = "pure_reader", media_path = braw_path }
    media_status.ensure_clip_status(clip)
    check("reads Unsupported from cache", clip.offline == true)
    check("error_code preserved", clip.error_code == "Unsupported")

    -- Cache unchanged
    local post = media_status.get(braw_path)
    check("cache unchanged after ensure", post.error_code == "Unsupported")

    -- Cache miss: clip not stamped (no writing to cache)
    local unknown = { id = "unknown", media_path = "/tmp/jve/not_cached.mov" }
    media_status.ensure_clip_status(unknown)
    check("cache miss: clip.offline is nil", unknown.offline == nil)
    check("cache miss: no entry created", media_status.get("/tmp/jve/not_cached.mov") == nil)

    os.remove(braw_path)
    media_status.clear()
end

print("\n✅ test_media_status.lua passed")
