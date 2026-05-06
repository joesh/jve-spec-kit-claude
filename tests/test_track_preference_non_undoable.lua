#!/usr/bin/env luajit

-- T006 (015) — FR-040a regression.
--
-- Domain rule: track preferences (muted, soloed, locked, enabled) are
-- session-monitoring state, not mix decisions. Toggling them must NOT
-- land on the per-sequence undo stack. After the user toggles muted,
-- pressing Cmd-Z should NOT unmute the track.
--
-- This test MUST FAIL on the current codebase — the failure is the proof
-- that FR-040a (pre-existing bug) exists. It will be turned green by T027
-- (ToggleTrackPreference command split).
--
-- Expected failure today: "unknown command: ToggleTrackPreference"

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_track_preference_non_undoable.lua ===")

-- ── Fixture ──────────────────────────────────────────────────────────────
local DB_PATH = "/tmp/jve/test_track_preference_non_undoable.db"
os.remove(DB_PATH)
os.execute("mkdir -p /tmp/jve")
database.init(DB_PATH)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'Seq', 'nested', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('trk', 'seq', 'A1', 'AUDIO', 1, 1);
]])

command_manager.init("seq", "proj")

-- ── Helper ────────────────────────────────────────────────────────────────
local function get_track_field(field)
    local stmt = db:prepare("SELECT " .. field .. " FROM tracks WHERE id = 'trk'")
    assert(stmt)
    stmt:exec(); stmt:next()
    local v = stmt:value(0)
    stmt:finalize()
    return v
end

-- ── Test each boolean preference ─────────────────────────────────────────
local PROPERTIES = {"muted", "soloed", "locked", "enabled"}

for _, prop in ipairs(PROPERTIES) do
    print(string.format("-- %s: toggle must not be undoable --", prop))

    -- Reset to known baseline: set property to 0 via raw SQL (not the
    -- command under test, so it doesn't pollute the undo stack).
    db:exec(string.format("UPDATE tracks SET %s = 0 WHERE id = 'trk'", prop))

    -- Toggle via ToggleTrackPreference (the command introduced by T027).
    local r = command_manager.execute("ToggleTrackPreference", {
        track_id   = "trk",
        property   = prop,
        value      = true,
        project_id = "proj",
    })
    assert(r and r.success, string.format(
        "ToggleTrackPreference(%s=true) must succeed; got: %s",
        prop, tostring(r and r.error_message)))

    -- Assert the DB value was set.
    local after_exec = get_track_field(prop)
    assert(after_exec == 1, string.format(
        "%s must be 1 after toggle; got %s", prop, tostring(after_exec)))

    -- Undo must NOT revert a preference toggle.
    command_manager.undo()

    local after_undo = get_track_field(prop)
    assert(after_undo == 1, string.format(
        "DOMAIN VIOLATION: %s reverted to %s after undo — preference "
        .. "toggles must NOT land on the undo stack (FR-040a)",
        prop, tostring(after_undo)))

    print(string.format("  %s: toggle persists across undo — OK", prop))
end

print("\n✅ test_track_preference_non_undoable.lua passed")
