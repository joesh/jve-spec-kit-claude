require("test_env")
local media_status = require("core.media.media_status")
local database = require("core.database")

local function check(desc, cond)
    if not cond then error("FAIL: " .. desc) end
    print("  OK: " .. desc)
end

-- ============================================================
-- Regression: bg probe must re-validate persisted cache entries
--
-- Bug: start_background_probe skipped any path already in status_cache.
-- Since load_persisted fills status_cache from last session's DB, files
-- moved/deleted between sessions were never re-probed. The stale "online"
-- status persisted forever — files that should be offline appeared online.
--
-- This test verifies that ALL media paths are sent to the codec probe,
-- INCLUDING those already in the cache from load_persisted.
-- ============================================================

print("\n--- media_status: bg probe re-validates persisted cache ---")
do
    -- Set up test DB
    local TEST_DB = "/tmp/jve/test_bg_probe_revalidate.db"
    os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
    os.execute("mkdir -p /tmp/jve")
    assert(database.init(TEST_DB))
    local db = database.get_connection()
    db:exec(require("import_schema"))

    local now = os.time()
    -- Create project
    db:exec(string.format(
        "INSERT INTO projects (id, name, created_at, modified_at) VALUES ('proj1', 'Test', %d, %d)",
        now, now))

    -- Create media records: one for a file that exists, one for a file that doesn't
    local existing_file = "/tmp/jve/bg_probe_existing.txt"
    local moved_file = "/tmp/jve/bg_probe_moved_away.txt"

    local f = io.open(existing_file, "w"); f:write("x"); f:close()
    os.remove(moved_file)  -- ensure it doesn't exist

    db:exec(string.format([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
                          fps_numerator, fps_denominator, width, height, audio_channels,
                          created_at, modified_at)
        VALUES ('media_exists', 'proj1', 'existing', '%s', 100, 24, 1, 1920, 1080, 0, %d, %d)
    ]], existing_file, now, now))

    db:exec(string.format([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
                          fps_numerator, fps_denominator, width, height, audio_channels,
                          created_at, modified_at)
        VALUES ('media_moved', 'proj1', 'moved', '%s', 100, 24, 1, 1920, 1080, 0, %d, %d)
    ]], moved_file, now, now))

    -- Persist a cache that says BOTH files are online (from last session)
    local persist_map = {}
    persist_map[existing_file] = { offline = false, error_code = nil }
    persist_map[moved_file] = { offline = false, error_code = nil }
    database.set_project_setting("proj1", "media_error_cache", persist_map)

    -- Clear media_status and load persisted cache
    media_status.clear()
    media_status.load_persisted("proj1")

    -- Verify persisted cache loaded: both paths in status_cache as online
    check("existing file loaded as online from cache",
        media_status.get(existing_file) ~= nil and media_status.get(existing_file).offline == false)
    check("moved file loaded as online from cache (stale!)",
        media_status.get(moved_file) ~= nil and media_status.get(moved_file).offline == false)

    -- Mock qt_constants.EMP to capture which paths the bg probe sends
    local captured_paths = nil
    _G.qt_constants = {
        EMP = {
            CODEC_PROBE_START = function(paths, callback)
                captured_paths = paths
                -- Simulate immediate completion with correct results
                local results = {}
                for _, p in ipairs(paths) do
                    local fh = io.open(p, "r")
                    if fh then
                        fh:close()
                        results[p] = { offline = false, error_code = nil }
                    else
                        results[p] = { offline = true, error_code = "FileNotFound" }
                    end
                end
                callback(results, true)
            end,
            CODEC_PROBE_CANCEL = function() end,
        },
        FS = nil,  -- no filesystem watcher in tests
    }

    -- Run bg probe — this is the critical test
    media_status.start_background_probe(nil)

    -- REGRESSION CHECK: both paths must be in the probe list
    -- (previously, cached paths were skipped)
    check("probe was called", captured_paths ~= nil)

    local found_existing = false
    local found_moved = false
    for _, p in ipairs(captured_paths or {}) do
        if p == existing_file then found_existing = true end
        if p == moved_file then found_moved = true end
    end

    check("existing file included in probe (not skipped due to cache)",
        found_existing == true)
    check("moved file included in probe (not skipped due to cache)",
        found_moved == true)

    -- After probe completes: moved file must now be offline
    local moved_status = media_status.get(moved_file)
    check("moved file now offline after probe",
        moved_status ~= nil and moved_status.offline == true)
    check("moved file error_code is FileNotFound",
        moved_status ~= nil and moved_status.error_code == "FileNotFound")

    -- Existing file should still be online
    local exists_status = media_status.get(existing_file)
    check("existing file still online after probe",
        exists_status ~= nil and exists_status.offline == false)

    -- Cleanup
    _G.qt_constants = nil
    os.remove(existing_file)
    os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
    media_status.clear()
end

-- ============================================================
-- Regression: bg probe batch with no changes must not schedule a persist
--
-- Bug: start_background_probe called schedule_persist() unconditionally on
-- every batch callback, regardless of whether any entry actually changed.
-- During a large probe this triggered a full-cache rewrite (~1115 entries)
-- roughly once per second, producing wasted disk I/O and DB churn whenever
-- the persisted cache already matched reality.
--
-- Domain contract: persisting status to disk is only warranted when cached
-- state actually changed. A probe that confirms the existing cache should
-- perform no persistence work.
-- ============================================================

print("\n--- media_status: no-change probe batch does not schedule persist ---")
do
    local TEST_DB = "/tmp/jve/test_bg_probe_no_change.db"
    os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
    os.execute("mkdir -p /tmp/jve")
    assert(database.init(TEST_DB))
    local db = database.get_connection()
    db:exec(require("import_schema"))

    local now = os.time()
    db:exec(string.format(
        "INSERT INTO projects (id, name, created_at, modified_at) VALUES ('proj1', 'Test', %d, %d)",
        now, now))

    local file_a = "/tmp/jve/bg_probe_nochange_a.txt"
    local file_b = "/tmp/jve/bg_probe_nochange_b.txt"
    local fa = io.open(file_a, "w"); fa:write("x"); fa:close()
    local fb = io.open(file_b, "w"); fb:write("x"); fb:close()

    for i, p in ipairs({file_a, file_b}) do
        db:exec(string.format([[
            INSERT INTO media (id, project_id, name, file_path, duration_frames,
                              fps_numerator, fps_denominator, width, height, audio_channels,
                              created_at, modified_at)
            VALUES ('m%d', 'proj1', 'n%d', '%s', 100, 24, 1, 1920, 1080, 0, %d, %d)
        ]], i, i, p, now, now))
    end

    -- Persist cache that matches reality: both files online
    local persist_map = {
        [file_a] = { offline = false, error_code = nil },
        [file_b] = { offline = false, error_code = nil },
    }
    database.set_project_setting("proj1", "media_error_cache", persist_map)

    media_status.clear()
    media_status.load_persisted("proj1")

    -- Count persist-timer schedulings via the qt single-shot timer hook
    -- (schedule_persist is the only user of qt_create_single_shot_timer in
    -- media_status.lua; a scheduling => a pending disk write).
    local persist_schedules = 0
    _G.qt_create_single_shot_timer = function(_delay_ms, cb)
        persist_schedules = persist_schedules + 1
        -- Don't fire cb — we only care that a persist was scheduled.
    end

    -- Mock probe: emit a non-final batch that matches the cache exactly
    -- (no changes), then a final batch that also matches.
    _G.qt_constants = {
        EMP = {
            CODEC_PROBE_START = function(paths, callback)
                local results = {}
                for _, p in ipairs(paths) do
                    results[p] = { offline = false, error_code = nil }
                end
                -- Non-final batch: this is the path that previously leaked a persist
                callback(results, false)
                -- Final batch: persist_now fires directly (not via schedule_persist)
                callback({}, true)
            end,
            CODEC_PROBE_CANCEL = function() end,
        },
        FS = nil,
    }

    media_status.start_background_probe(nil)

    check("no-change probe batch did not schedule a persist (got "
        .. tostring(persist_schedules) .. ")", persist_schedules == 0)

    _G.qt_constants = nil
    _G.qt_create_single_shot_timer = nil
    os.remove(file_a); os.remove(file_b)
    os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
    media_status.clear()
end

print("\n✅ test_media_status_bg_probe.lua passed")
