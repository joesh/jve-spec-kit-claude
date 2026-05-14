#!/usr/bin/env luajit

-- 015 — Canonical command pattern: executor must NOT wrap M.execute in
-- pcall + set_last_error. Doing so swallows the assertion's traceback
-- and surfaces a click as silently no-op (rule 2.32).
--
-- Each 015 command's executor must call M.execute directly so that
-- assertions raised inside propagate to command_manager.lua:1007's
-- xpcall, which logs `[commands] ERROR: Executor failed (X):
-- <traceback>` and returns the traceback as result.error_message.
--
-- Test mechanism: dispatch each command with bad args that will hit an
-- internal assert inside M.execute. The result.error_message MUST contain
-- "stack traceback" (the canonical xpcall path) — proving the assertion's
-- diagnostic context surfaced. With the swallow-pcall pattern the inner
-- pcall captures only the assertion message text (no traceback), so the
-- test would fail.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== test_015_command_pattern_no_swallowed_asserts.lua ===")

-- ── DB setup ─────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_015_command_pattern.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, sync_mode)
    VALUES ('trk_v1', 'seq', 'V1', 'VIDEO', 1, 1, 'ripple');
]], now, now, now, now))

command_manager.init("seq", "proj")

-- Each case dispatches with args designed to fail an internal assertion
-- inside M.execute. The assertion's text and traceback MUST surface in
-- result.error_message. The signature `stack traceback:` is the
-- xpcall+debug.traceback marker — present only on the canonical path.

local cases = {
    {
        name = "ToggleTrackPreference",
        params = {
            track_id   = "trk_v1",
            property   = "not_a_real_property",   -- triggers ALLOWED-set assert
            project_id = "proj",
        },
        expected_assert_substring = "muted/soloed/locked/enabled",
    },
    {
        name = "SetSyncMode",
        params = {
            track_id   = "trk_v1",
            sync_mode  = "not_a_real_mode",       -- triggers VALID_MODES assert
            project_id = "proj",
        },
        expected_assert_substring = "sync_mode must be",
    },
    {
        name = "SetPatch",
        params = {
            sequence_id        = "seq",
            track_type         = "INVALID",       -- triggers VIDEO/AUDIO assert
            source_shape       = 1,
            source_track_index = 0,
            record_track_index = 0,
            project_id         = "proj",
            enabled            = 1,
        },
        expected_assert_substring = "VIDEO",
    },
    {
        name = "SetTrackMixValue",
        params = {
            track_id   = "trk_v1",
            property   = "not_volume_or_pan",     -- triggers ALLOWED assert
            value      = 0.5,
            project_id = "proj",
        },
        expected_assert_substring = "volume",
    },
}

for _, case in ipairs(cases) do
    print(string.format("-- %s --", case.name))
    local r = command_manager.execute(case.name, case.params)
    assert(r and r.success == false, string.format(
        "FAIL: %s with bad args should report success=false (got %s)",
        case.name, tostring(r and r.success)))
    local em = r.error_message or ""
    -- Canonical path surfaces the assertion text from M.execute …
    assert(em:find(case.expected_assert_substring, 1, true), string.format(
        "FAIL: %s error_message missing expected assertion substring '%s'.\n"
        .. "Got: %s",
        case.name, case.expected_assert_substring, em))
    -- … AND the traceback marker proving xpcall (canonical path) caught
    -- it. The swallow-pcall pattern would NOT include this — its inner
    -- pcall captures only the bare error text, no traceback.
    assert(em:find("stack traceback", 1, true), string.format(
        "FAIL: %s error_message missing 'stack traceback' — executor is "
        .. "still wrapping M.execute in pcall and swallowing the diagnostic "
        .. "context (rule 2.32). Convert to canonical pattern: executor "
        .. "calls M.execute directly so command_manager's xpcall captures "
        .. "the traceback.\nGot: %s",
        case.name, em))
    print(string.format("  %s surfaces traceback — OK", case.name))
end

print("\n✅ test_015_command_pattern_no_swallowed_asserts.lua passed")
