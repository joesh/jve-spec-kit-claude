-- Integration test: real QFileSystemWatcher → media_status reacts to
-- genuine filesystem events (delete, rename, create, update).
--
-- Runs inside JVEEditor via:
--   ./build/bin/JVEEditor --test tests/integration/fs_watcher_media_status.lua
--
-- The pure-Lua companion test exercises the _on_file_changed /
-- _on_dir_changed callbacks directly; this test covers the full
-- path Qt → C++ FS bridge → callback → cache mutation that the
-- app experiences at runtime.
--
-- Domain behaviors under test:
--   * Real delete of a registered file flips cache to offline and
--     emits media_status_changed.
--   * Real rename of a registered file (new path isn't registered)
--     flips the OLD path to offline (the only path the watcher
--     knew about).
--   * Real creation of a previously-missing registered file flips
--     the cache to online (via the dir-watch path).
--   * Real in-place file update (content change, same path) is a
--     no-op on the offline status cache (file still exists) but
--     IS observed by the watcher (peak_cache invalidation path).
--
-- Timing: QFileSystemWatcher delivers events asynchronously through
-- the Qt event loop. After each FS operation we pump events and poll
-- the cache with a bounded timeout. A real OS-level coalesce or a
-- ~100 ms watcher delay is accommodated; a genuine regression
-- (callback never fires, cache never flips) trips the timeout.

local qt_constants = require("core.qt_constants")
local media_status = require("core.media.media_status")
local Signals      = require("core.signals")

assert(type(qt_constants) == "table" and type(qt_constants.CONTROL) == "table"
    and type(qt_constants.CONTROL.PROCESS_EVENTS) == "function",
    "must run via JVEEditor --test (qt_constants not available)")

print("=== integration: fs watcher → media_status ===")

-- Pump Qt events until a predicate succeeds or a deadline passes.
-- Returns true if the predicate was satisfied. Qt's watcher fires on
-- the main event loop; PROCESS_EVENTS drains its queue. Small sleep
-- between polls to let the OS coalesce batches.
local function wait_until(predicate, timeout_s, label)
    local deadline = os.time() + (timeout_s or 2)
    while os.time() <= deadline do
        qt_constants.CONTROL.PROCESS_EVENTS()
        if predicate() then return true end
        os.execute("sleep 0.05")
    end
    error(string.format("timed out waiting for: %s", label or "predicate"))
end

-- Signal capture — any fire of media_status_changed for paths we care about.
local signal_events = {}
local listener_id = Signals.connect("media_status_changed", function(path, status)
    signal_events[#signal_events + 1] = { path = path, status = status, t = os.clock() }
end, 50)
local function saw_signal(path, expected_offline)
    for _, ev in ipairs(signal_events) do
        if ev.path == path and ev.status.offline == expected_offline then
            return true
        end
    end
    return false
end

-- Unique test dir so parallel runs don't collide.
local DIR = "/tmp/jve/fs_watcher_integration_" .. os.time() .. "_" .. math.random(100000)
os.execute("mkdir -p " .. DIR)
local function path(name) return DIR .. "/" .. name end
local function touch(p, content)
    local f = assert(io.open(p, "w"))
    f:write(content or "initial content")
    f:close()
end

-- Fresh state.
media_status.clear()
media_status.init_watcher()
signal_events = {}

-- --------------------------------------------------------------------
-- 1. Delete: file exists at registration → delete on disk → watcher
--    fires → cache flips to offline + FileNotFound.
-- --------------------------------------------------------------------
do
    local p = path("delete_me.mov")
    touch(p)
    media_status.register(p)
    assert(media_status.get(p).offline == false, "precondition: registered file online")
    signal_events = {}

    os.remove(p)

    wait_until(
        function() return media_status.get(p).offline == true end,
        3, "delete_me.mov: cache flips offline after os.remove")
    assert(media_status.get(p).error_code == "FileNotFound",
        "real delete must produce FileNotFound error code")
    assert(saw_signal(p, true),
        "media_status_changed must fire on real delete")
    print("  OK: real delete → cache offline + signal")
end

-- --------------------------------------------------------------------
-- 2. Create (dir-watch path): file missing at registration → watcher
--    watches the parent dir → create the file on disk → watcher fires
--    the dir-changed callback → cache flips online.
-- --------------------------------------------------------------------
do
    local p = path("appears_later.mov")
    assert(not io.open(p, "r"), "precondition: file must be absent")
    media_status.register(p)
    assert(media_status.get(p).offline == true, "precondition: absent file registers offline")
    signal_events = {}

    touch(p)

    wait_until(
        function() return media_status.get(p).offline == false end,
        3, "appears_later.mov: cache flips online after file creation")
    assert(saw_signal(p, false),
        "media_status_changed must fire on real file creation")
    print("  OK: real create → cache online + signal")
end

-- --------------------------------------------------------------------
-- 3. Rename: registered file is renamed on disk. From the watcher's
--    POV the old path is gone. Qt fires a change on the old path;
--    cache must flip offline. (The new path is unwatched — we aren't
--    testing that it's auto-picked up.)
-- --------------------------------------------------------------------
do
    local old_p = path("rename_from.mov")
    local new_p = path("rename_to.mov")
    touch(old_p)
    media_status.register(old_p)
    assert(media_status.get(old_p).offline == false, "precondition: old path online")
    signal_events = {}

    os.rename(old_p, new_p)

    wait_until(
        function() return media_status.get(old_p).offline == true end,
        3, "rename_from.mov: cache flips offline after rename")
    assert(media_status.get(old_p).error_code == "FileNotFound",
        "renamed-away path reports FileNotFound at its OLD path")
    assert(saw_signal(old_p, true),
        "media_status_changed must fire on real rename (old path)")
    -- Clean up the destination.
    os.remove(new_p)
    print("  OK: real rename → old path offline + signal")
end

-- --------------------------------------------------------------------
-- 4. In-place update: content change, same path. File still exists
--    → cache offline-status stays online (probe is existence-only).
--    The watcher DOES fire, but no media_status_changed is emitted
--    because the status didn't change (reprobe_and_notify's
--    change-detection suppresses). This pins the "no signal storm
--    on every save" behavior.
-- --------------------------------------------------------------------
do
    local p = path("update_in_place.mov")
    touch(p, "initial")
    media_status.register(p)
    assert(media_status.get(p).offline == false, "precondition: online")
    signal_events = {}

    touch(p, "updated content larger than initial")
    -- Pump events for a reasonable window, then check no signal fired
    -- for this path with a status change.
    local deadline = os.time() + 1
    while os.time() <= deadline do
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.05")
    end
    assert(media_status.get(p).offline == false,
        "in-place update must keep file online in the cache")
    for _, ev in ipairs(signal_events) do
        if ev.path == p then
            -- Any emit would need a state change; if we see one, the
            -- change-detection suppression regressed.
            error(string.format(
                "in-place update must not emit media_status_changed; " ..
                "saw offline=%s", tostring(ev.status.offline)))
        end
    end
    print("  OK: real in-place update → no state change + no signal storm")
end

Signals.disconnect(listener_id)
os.execute("rm -rf " .. DIR)

print("✅ integration/fs_watcher_media_status.lua passed")
os.exit(0)
