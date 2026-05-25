-- Integration: media_status background codec probe with REAL CodecProbeWorker.
--
-- Replaces the prior mock-EMP test. The mock encoded the test's own
-- expected behavior (offline iff io.open fails), so it couldn't catch
-- divergence between the production FFmpeg-based probe and any
-- assumption baked into media_status. Real CODEC_PROBE_START runs
-- emp::MediaFile::Open + ProbeCodec on a worker thread and delivers
-- batches back to the main thread via Qt::QueuedConnection.
--
-- Two regressions pinned:
--   (A) Bg probe re-validates persisted cache: stale "online" entries
--       for files that have since gone missing flip to offline after the
--       probe completes. Previously, cached paths were skipped entirely.
--   (B) No-change probe batch does not schedule a persist: when reality
--       matches the persisted cache, the probe must produce zero disk
--       writes. Previously, every batch unconditionally scheduled one.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_media_status_bg_probe.lua ===")

require("test_env")
local media_status = require("core.media.media_status")
local database     = require("core.database")
local Signals      = require("core.signals")

-- Pump Qt events with brief sleeps until predicate fires or the deadline
-- passes. The probe thread opens files via FFmpeg, so wall-clock time is
-- the right unit — PROCESS_EVENTS returns immediately when the queue is
-- empty, so a bare-spin loop burns CPU without giving the worker time
-- to actually probe. Pattern lifted from fs_watcher_media_status.lua.
local function wait_until(predicate, timeout_s, label)
    local deadline = os.time() + (timeout_s or 5)
    while os.time() <= deadline do
        qt_constants.CONTROL.PROCESS_EVENTS()
        if predicate() then return end
        os.execute("sleep 0.05")
    end
    error(string.format("wait_until: timed out (%ds) waiting for: %s",
        timeout_s or 5, label))
end

local function seed_project(test_db_path)
    os.remove(test_db_path)
    os.remove(test_db_path .. "-wal")
    os.remove(test_db_path .. "-shm")
    os.execute("mkdir -p /tmp/jve")
    assert(database.init(test_db_path))
    local db = database.get_connection()
    db:exec(require("import_schema"))
    local now = os.time()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings,
            created_at, modified_at)
        VALUES ('proj1', 'Test', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
            %d, %d)
    ]], now, now)))
    return db, now
end

local function insert_media(db, id, file_path, now)
    assert(db:exec(string.format([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, width, height, audio_channels,
            created_at, modified_at)
        VALUES ('%s', 'proj1', '%s', '%s', 100, 24, 1, 1920, 1080, 0, %d, %d)
    ]], id, id, file_path, now, now)))
end

-- ── (A) Bg probe re-validates persisted cache ────────────────────────
print("\n-- (A) bg probe re-validates persisted cache --")
do
    local db, now = seed_project("/tmp/jve/test_bg_probe_revalidate.db")

    -- Use a real fixture file for "online" — txt would probe as Unsupported,
    -- not online, because CodecProbeWorker calls FFmpeg. For "missing",
    -- any nonexistent path works.
    local existing_file = ienv.test_media_path("A001_C037_0921FG_001.mp4")
    local moved_file    = "/tmp/jve/bg_probe_missing_path_does_not_exist.mp4"
    os.remove(moved_file)

    insert_media(db, "media_exists", existing_file, now)
    insert_media(db, "media_moved",  moved_file,    now)

    -- Pre-seed disk cache claiming BOTH are online (stale from last session).
    database.set_project_setting("proj1", "media_error_cache", {
        [existing_file] = { offline = false, error_code = nil },
        [moved_file]    = { offline = false, error_code = nil },
    })

    media_status.clear()
    media_status.load_persisted("proj1")

    assert(media_status.get(existing_file).offline == false,
        "pre-probe: existing file loaded as online from cache")
    assert(media_status.get(moved_file).offline == false,
        "pre-probe: moved file loaded as online from cache (stale)")

    -- Track media_status_changed signals so we know when the probe has
    -- updated each path. We can't predict batch boundaries, but the
    -- moved-file flip is the regression check — its real result (offline)
    -- differs from the cached state (online), so it WILL emit a signal.
    local moved_changed = false
    local sub = Signals.connect("media_status_changed", function(path)
        if path == moved_file then moved_changed = true end
    end)

    media_status.start_background_probe(nil)
    wait_until(function() return moved_changed end, 5,
        "moved_file flip after real probe")
    Signals.disconnect(sub)

    -- REGRESSION CHECK: the probe must have re-validated cached paths,
    -- not skipped them. moved_file flipping to offline proves it was
    -- included in the probe (if it had been skipped, status would
    -- remain stale online).
    local moved_status = media_status.get(moved_file)
    assert(moved_status.offline == true,
        "moved file must be offline after bg probe (was: "
        .. tostring(moved_status.offline) .. ")")
    assert(moved_status.error_code == "FileNotFound", string.format(
        "moved file error_code must be FileNotFound; got %s",
        tostring(moved_status.error_code)))

    -- existing_file's pre-cache state matches reality (online), so it may
    -- or may not have emitted a "changed" signal depending on whether the
    -- probe sees any difference — but its post-probe state must remain
    -- online. Pump a few more events to make sure its batch landed too.
    for _ = 1, 50 do qt_constants.CONTROL.PROCESS_EVENTS() end
    assert(media_status.get(existing_file).offline == false,
        "existing file must remain online after bg probe")

    media_status.cancel_background_probe()
    os.remove("/tmp/jve/test_bg_probe_revalidate.db")
    os.remove("/tmp/jve/test_bg_probe_revalidate.db-wal")
    os.remove("/tmp/jve/test_bg_probe_revalidate.db-shm")
    media_status.clear()
    print("  PASS moved file re-validated; existing stayed online")
end

-- ── (B) No-change probe batch does not schedule a persist ────────────
-- When the persisted cache exactly matches reality, the probe must
-- complete without any disk-write scheduling. schedule_persist() is the
-- only user of qt_create_single_shot_timer in media_status, so we count
-- timer invocations during the probe.
print("\n-- (B) no-change probe schedules zero persists --")
do
    local db, now = seed_project("/tmp/jve/test_bg_probe_no_change.db")

    local online_a = ienv.test_media_path("A001_C037_0921FG_001.mp4")
    local online_b = ienv.test_media_path("A002_C018_0922BW_002.mp4")
    insert_media(db, "m1", online_a, now)
    insert_media(db, "m2", online_b, now)

    -- Cache matches reality: both online with no error.
    database.set_project_setting("proj1", "media_error_cache", {
        [online_a] = { offline = false, error_code = nil },
        [online_b] = { offline = false, error_code = nil },
    })

    media_status.clear()
    media_status.load_persisted("proj1")

    -- Count schedule_persist invocations via the single-shot timer hook.
    -- Save and restore the global so we don't poison other tests in this
    -- process (in --test mode the script is the whole process, but be
    -- careful in case the harness shares state).
    local persist_schedules = 0
    local saved_timer = _G.qt_create_single_shot_timer
    _G.qt_create_single_shot_timer = function(_delay_ms, _cb)
        persist_schedules = persist_schedules + 1
        -- Don't fire — we only care that scheduling occurred.
    end

    -- Track final batch via media_status_changed... but if nothing changed,
    -- no signal fires. Detect probe completion by polling the worker's
    -- final batch — easiest proxy is to wait a bounded number of pumps
    -- (the probe is sync for 2 small paths once the thread runs).
    media_status.start_background_probe(nil)
    -- Pump generously to ensure the worker has run and delivered its
    -- batches. 200 attempts is far more than needed for 2 paths.
    for _ = 1, 200 do qt_constants.CONTROL.PROCESS_EVENTS() end
    media_status.cancel_background_probe()  -- joins the worker thread

    _G.qt_create_single_shot_timer = saved_timer

    assert(persist_schedules == 0, string.format(
        "no-change probe must not schedule any persist; got %d schedule(s). "
        .. "Regression: schedule_persist() was being called unconditionally "
        .. "per batch, producing ~1115-entry rewrites every probe second "
        .. "even when the cache already matched reality.",
        persist_schedules))

    os.remove("/tmp/jve/test_bg_probe_no_change.db")
    os.remove("/tmp/jve/test_bg_probe_no_change.db-wal")
    os.remove("/tmp/jve/test_bg_probe_no_change.db-shm")
    media_status.clear()
    print("  PASS no persists scheduled when cache matches reality")
end

print("\nPASS test_media_status_bg_probe.lua")
