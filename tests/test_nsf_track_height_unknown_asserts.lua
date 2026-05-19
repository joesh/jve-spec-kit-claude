#!/usr/bin/env luajit

-- NSF: track_state.get_height silently returned DEFAULT_TRACK_HEIGHT for
-- a track_id that doesn't exist in state. A caller asking for the height
-- of an unknown track is a bug — it must surface, not silently produce
-- a plausible-looking number.

require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")

print("=== test_nsf_track_height_unknown_asserts.lua ===")

local DB = "/tmp/jve/test_nsf_track_height_unknown.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)

local db = database.get_connection()
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect)
    VALUES ('v1', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0, 'off', 1);
]], now, now, now, now))
command_manager.init("s", "p")

local timeline_state = require("ui.timeline.timeline_state")

-- ── Happy path: known track returns a number ─────────────────────────────
local h = timeline_state.get_track_height("v1")
assert(type(h) == "number" and h > 0, string.format(
    "known track must produce a positive numeric height; got %s", tostring(h)))

-- ── Unknown track must surface, not return DEFAULT silently ──────────────
local ok, err = pcall(timeline_state.get_track_height, "no_such_track")
assert(not ok, "FAIL: get_track_height on unknown track must assert (not silently "
    .. "return DEFAULT). The caller is asking about a track that does not exist; "
    .. "that is a bug at the call site, not a render-time fallback.")
assert(type(err) == "string" and err:find("no_such_track"),
    "FAIL: assert message must include the offending track_id; got: " .. tostring(err))

-- ── set on unknown track must also assert ────────────────────────────────
local ok2, err2 = pcall(timeline_state.set_track_height, "no_such_track", 80)
assert(not ok2, "FAIL: set_track_height on unknown track must assert (not silently "
    .. "no-op).")
assert(type(err2) == "string" and err2:find("no_such_track"),
    "FAIL: set assert message must include the offending track_id; got: " .. tostring(err2))

-- ── set with bad height type must assert (NSF half-1) ────────────────────
-- ipairs stops at the first nil, so nil cases are spelled out explicitly
-- to avoid silently skipping coverage.
local bad_cases = {
    { label = "string",  value = "80"  },
    { label = "boolean", value = true  },
    { label = "table",   value = {}    },
    { label = "nil",     value = nil   },  -- explicit field; never iterated by ipairs
}
local function check_bad(label, value)
    local ok_bad = pcall(timeline_state.set_track_height, "v1", value)
    assert(not ok_bad, string.format(
        "FAIL: set_track_height(\"v1\", <%s>) must assert. A non-number "
        .. "silently written into track.height corrupts every downstream "
        .. "layout call.", label))
end
for _, case in ipairs(bad_cases) do check_bad(case.label, case.value) end
-- ipairs above iterates 4 entries (each is a non-nil table); the nil
-- VALUE field inside the case=4 table still reaches the function.

print("  unknown tracks surface as assert; known tracks unaffected — OK")
print("\n✅ test_nsf_track_height_unknown_asserts.lua passed")
