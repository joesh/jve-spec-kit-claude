-- Integration test: real QFileSystemWatcher → media_status reacts to
-- genuine filesystem events (delete, rename, create, rewrite).
--
-- Runs inside JVEEditor via:
--   ./build/bin/JVEEditor --test tests/integration/fs_watcher_media_status.lua
--
-- Domain behaviors under test:
--   * Real delete of a registered file flips cache to offline + emits signal.
--   * Real creation of a previously-missing registered file flips the
--     cache to online + emits signal (dir-watch path).
--   * Real rename of a registered file flips the OLD path to offline +
--     emits signal (the only path the watcher knew about).
--   * Real in-place content rewrite emits a signal so downstream caches
--     (decoders, peaks, preview) can invalidate. File remains "online"
--     because existence-only probe still succeeds — the signal is a
--     "file contents changed" notification, not a state flip.
--
-- Anti-pattern avoided: this test MUST NOT call media_status.init_watcher()
-- or any other one-shot wiring that isn't also performed at production app
-- startup. If production forgets to wire FS callbacks, this test must fail.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

local media_status = require("core.media.media_status")
local Signals      = require("core.signals")
local wait_until   = ienv.wait_until

print("=== integration: fs watcher → media_status ===")

-- Signal capture. media_status_changed = status flips; media_content_changed
-- = in-place byte rewrite of an online file (status unchanged). Keep them
-- separate so each case below asserts the right signal fired.
local status_events  = {}
local content_events = {}
local status_listener  = Signals.connect("media_status_changed", function(path, status)
    status_events[#status_events + 1] = { path = path, status = status }
end, 50)
local content_listener = Signals.connect("media_content_changed", function(path)
    content_events[#content_events + 1] = { path = path }
end, 50)
local function saw_status(path, expected_offline)
    for _, ev in ipairs(status_events) do
        if ev.path == path and ev.status.offline == expected_offline then
            return true
        end
    end
    return false
end
local function saw_content(path)
    for _, ev in ipairs(content_events) do
        if ev.path == path then return true end
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

-- Fresh state. DELIBERATELY NO init_watcher() — production must wire it.
media_status.clear()
status_events, content_events = {}, {}

-- --------------------------------------------------------------------
-- 1. Delete: file exists at registration → delete on disk → watcher
--    fires → cache flips to offline + FileNotFound.
-- --------------------------------------------------------------------
do
    local p = path("delete_me.mov")
    touch(p)
    media_status.register(p)
    assert(media_status.get(p).offline == false, "precondition: registered file online")
    status_events, content_events = {}, {}

    os.remove(p)

    wait_until(
        function() return media_status.get(p).offline == true end,
        3, "delete_me.mov: cache flips offline after os.remove")
    assert(media_status.get(p).error_code == "FileNotFound",
        "real delete must produce FileNotFound error code")
    assert(saw_status(p, true),
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
    status_events, content_events = {}, {}

    touch(p)

    wait_until(
        function() return media_status.get(p).offline == false end,
        3, "appears_later.mov: cache flips online after file creation")
    assert(saw_status(p, false),
        "media_status_changed must fire on real file creation")
    print("  OK: real create → cache online + signal")
end

-- --------------------------------------------------------------------
-- 3. Rename: registered file is renamed on disk. From the watcher's
--    POV the old path is gone. Qt fires a change on the old path;
--    cache must flip offline.
-- --------------------------------------------------------------------
do
    local old_p = path("rename_from.mov")
    local new_p = path("rename_to.mov")
    touch(old_p)
    media_status.register(old_p)
    assert(media_status.get(old_p).offline == false, "precondition: old path online")
    status_events, content_events = {}, {}

    os.rename(old_p, new_p)

    wait_until(
        function() return media_status.get(old_p).offline == true end,
        3, "rename_from.mov: cache flips offline after rename")
    assert(media_status.get(old_p).error_code == "FileNotFound",
        "renamed-away path reports FileNotFound at its OLD path")
    assert(saw_status(old_p, true),
        "media_status_changed must fire on real rename (old path)")
    os.remove(new_p)
    print("  OK: real rename → old path offline + signal")
end

-- --------------------------------------------------------------------
-- 4. In-place content rewrite: same path, new bytes. File still exists
--    so offline-status stays online, BUT downstream caches (decoder
--    readers, peak cache, preview thumbnails) need to know the bytes
--    changed. A DEDICATED signal — media_content_changed — fires so
--    only the path-keyed-cache consumers pay the cost; status-flip
--    consumers (offline icons, clip.offline flags) aren't bothered.
-- --------------------------------------------------------------------
do
    local p = path("update_in_place.mov")
    touch(p, "initial")
    media_status.register(p)
    assert(media_status.get(p).offline == false, "precondition: online")
    status_events, content_events = {}, {}

    touch(p, "updated content larger than initial")

    wait_until(
        function() return saw_content(p) end,
        3, "update_in_place.mov: media_content_changed fires on content rewrite")
    assert(media_status.get(p).offline == false,
        "in-place rewrite: file still exists, cache stays online")
    -- Status didn't flip — media_status_changed must NOT fire for this path.
    for _, ev in ipairs(status_events) do
        assert(ev.path ~= p, string.format(
            "media_status_changed must NOT fire on pure content rewrite; "
            .. "saw offline=%s", tostring(ev.status.offline)))
    end
    print("  OK: real content rewrite → media_content_changed fires, status_changed does not")
end

Signals.disconnect(status_listener)
Signals.disconnect(content_listener)
os.execute("rm -rf " .. DIR)

print("✅ integration/fs_watcher_media_status.lua passed")
os.exit(0)
