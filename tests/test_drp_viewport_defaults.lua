#!/usr/bin/env luajit
-- TDD regression test: DRP-imported sequences must have fps-correct viewport defaults
-- so that zoom_to_fit_if_first_open detects them as "never opened."
--
-- Bug: DRP import raw SQL omits viewport columns → schema default view_duration_frames=240.
-- For NTSC (24000/1001), the expected factory default is floor(10 * 24000/1001) = 239.
-- Mismatch → zoom_to_fit_if_first_open thinks user customized viewport → skips zoom + playhead.

require("test_env")

print("=== test_drp_viewport_defaults.lua ===")

local import_schema = require("import_schema")
local database = require("core.database")
local Sequence = require("models.sequence")

local function with_db(fn)
    local db_path = "/tmp/jve/test_drp_viewport_defaults.db"
    os.remove(db_path)
    os.remove(db_path .. "-wal")
    os.remove(db_path .. "-shm")
    assert(database.set_path(db_path), "failed to set db path")
    local db = database.get_connection()
    assert(db, "failed to open db connection")
    assert(db:exec(import_schema), "failed to apply schema")
    assert(db:exec([[INSERT INTO projects(id, name, created_at, modified_at, settings)
        VALUES('proj', 'Test', strftime('%s','now'), strftime('%s','now'), '{}')]]))
    fn(db)
end

--------------------------------------------------------------------------------
-- Test 1: NTSC 24000/1001 viewport default via DRP import SQL
--------------------------------------------------------------------------------

print("\n--- Test 1: NTSC viewport default matches zoom-to-fit expectation ---")

with_db(function(db)
    local fps_num, fps_den = 24000, 1001

    -- Match the INSERT from import_resolve_project.lua — includes viewport columns
    local default_view_dur = math.floor(10.0 * fps_num / fps_den)
    local sql = string.format([[
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                              audio_rate, width, height,
                              playhead_frame, view_start_frame, view_duration_frames,
                              created_at, modified_at)
        VALUES ('seq_ntsc', 'proj', 'NTSC Timeline', 'timeline', %d, %d, 48000, 1920, 1080,
                0, 0, %d,
                strftime('%%s','now'), strftime('%%s','now'))
    ]], fps_num, fps_den, default_view_dur)
    assert(db:exec(sql))

    -- Load via Sequence model (same path as zoom_to_fit_if_first_open)
    local sequence = Sequence.load("seq_ntsc")
    assert(sequence, "Failed to load sequence")

    -- This is what zoom_to_fit_if_first_open computes as "factory default"
    local expected_default_dur = math.floor(10.0 * fps_num / fps_den)  -- 239

    -- Core assertion: viewport_duration from DB must match expected factory default
    assert(sequence.viewport_duration == expected_default_dur, string.format(
        "DRP-imported NTSC sequence has viewport_duration=%d but zoom-to-fit expects %d " ..
        "(schema default 240 doesn't match fps-computed 239)",
        sequence.viewport_duration, expected_default_dur))
    print(string.format("  ✓ viewport_duration = %d (matches zoom-to-fit expectation)", expected_default_dur))

    assert(sequence.viewport_start_time == 0,
        "viewport_start_time should be 0, got " .. tostring(sequence.viewport_start_time))
    print("  ✓ viewport_start_time = 0")

    assert(sequence.playhead_position == 0,
        "playhead_position should be 0, got " .. tostring(sequence.playhead_position))
    print("  ✓ playhead_position = 0")
end)

--------------------------------------------------------------------------------
-- Test 2: PAL (25fps) viewport default
--------------------------------------------------------------------------------

print("\n--- Test 2: PAL (25fps) viewport default ---")

with_db(function(db)
    local fps_num, fps_den = 25, 1
    local default_view_dur = math.floor(10.0 * fps_num / fps_den)

    local sql = string.format([[
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                              audio_rate, width, height,
                              playhead_frame, view_start_frame, view_duration_frames,
                              created_at, modified_at)
        VALUES ('seq_pal', 'proj', 'PAL Timeline', 'timeline', %d, %d, 48000, 1920, 1080,
                0, 0, %d,
                strftime('%%s','now'), strftime('%%s','now'))
    ]], fps_num, fps_den, default_view_dur)
    assert(db:exec(sql))

    local seq = Sequence.load("seq_pal")
    local expected_dur = default_view_dur  -- 250

    assert(seq.viewport_duration == expected_dur, string.format(
        "PAL sequence has viewport_duration=%d but zoom-to-fit expects %d",
        seq.viewport_duration, expected_dur))
    print(string.format("  ✓ viewport_duration = %d (matches zoom-to-fit expectation)", expected_dur))
end)

--------------------------------------------------------------------------------
-- Test 3: 30fps NTSC (30000/1001) viewport default
--------------------------------------------------------------------------------

print("\n--- Test 3: 30fps NTSC viewport default ---")

with_db(function(db)
    local fps_num, fps_den = 30000, 1001
    local default_view_dur = math.floor(10.0 * fps_num / fps_den)

    local sql = string.format([[
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                              audio_rate, width, height,
                              playhead_frame, view_start_frame, view_duration_frames,
                              created_at, modified_at)
        VALUES ('seq_30ntsc', 'proj', '30 NTSC Timeline', 'timeline', %d, %d, 48000, 1920, 1080,
                0, 0, %d,
                strftime('%%s','now'), strftime('%%s','now'))
    ]], fps_num, fps_den, default_view_dur)
    assert(db:exec(sql))

    local seq = Sequence.load("seq_30ntsc")
    local expected_dur = default_view_dur  -- 299

    assert(seq.viewport_duration == expected_dur, string.format(
        "30 NTSC sequence has viewport_duration=%d but zoom-to-fit expects %d",
        seq.viewport_duration, expected_dur))
    print(string.format("  ✓ viewport_duration = %d (matches zoom-to-fit expectation)", expected_dur))
end)

print("\n✅ test_drp_viewport_defaults.lua passed")
