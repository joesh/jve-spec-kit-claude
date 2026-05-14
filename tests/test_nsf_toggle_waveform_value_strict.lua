#!/usr/bin/env luajit

-- NSF: ToggleTrackWaveformDisplay's `value` arg must be strictly boolean.
-- The original implementation used `args.value and true or false` to
-- coerce, which silently mistakes Lua-truthy non-booleans (integer 0,
-- string "false", etc.) for `true`. NSF half-1 requires that bad input
-- surface a loud failure, not silently produce a wrong output.

require("test_env")

print("=== test_nsf_toggle_waveform_value_strict.lua ===")

local database        = require("core.database")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_nsf_toggle_waveform_value.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)

local db = database.get_connection()
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect)
    VALUES ('a1', 's', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0, 'off', 1);
]], now, now, now, now))
command_manager.init("s", "p")

-- command_manager.execute wraps the executor in xpcall and converts asserts
-- to {success=false, error_message=…}. So "loud failure" here means
-- result.success == false (not a thrown Lua error).
local function succeeded(v)
    local r = command_manager.execute("ToggleTrackWaveformDisplay",
        { track_id = "a1", project_id = "p", value = v })
    return r == true or (type(r) == "table" and r.success == true)
end

-- ── Strictly-boolean inputs pass ─────────────────────────────────────────
assert(succeeded(true),  "value=true must be accepted")
assert(succeeded(false), "value=false must be accepted")

-- ── Truthy non-boolean inputs MUST be rejected ───────────────────────────
local truthy_non_bools = { 0, 1, "", "false", "true", {}, "yes" }
for _, v in ipairs(truthy_non_bools) do
    assert(not succeeded(v), string.format(
        "FAIL: value=%s (type %s) must produce a loud failure; pre-NSF "
        .. "code silently coerced it via `args.value and true or false`, "
        .. "treating Lua-truthy values as true and string \"false\" as true.",
        tostring(v), type(v)))
end

print("  strict boolean value enforced — OK")
print("\n✅ test_nsf_toggle_waveform_value_strict.lua passed")
