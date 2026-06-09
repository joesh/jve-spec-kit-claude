#!/usr/bin/env luajit

-- Regression: cinema-camera and BWF sequences carry a non-zero TC origin
-- (e.g., 01:00:00:00 at 24fps = 86400 frames). Loading such a sequence
-- must surface that origin into the timeline state cache so the viewport
-- positions clips correctly. A defensive `or 0` here used to silently
-- substitute zero whenever a future caller produced a sparse row.

require("test_env")

local database        = require("core.database")
local Sequence        = require("models.sequence")
local command_manager = require("core.command_manager")

print("=== test_nsf_timecode_start_no_fallback.lua ===")

local DB = "/tmp/jve/test_nsf_tc_start.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))

local TC_ORIGIN = 86400  -- 01:00:00:00 @ 24fps

local seq = Sequence.create("S", "p",
    { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080,
    { kind = "sequence", id = "s", audio_sample_rate = 48000,
      start_timecode_frame = TC_ORIGIN })
assert(seq:save(), "test setup: save sequence")
db:exec(string.format([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect)
    VALUES ('v1', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0, 'off', 1);
]]))

command_manager.init("s", "p")
local timeline_state = require("ui.timeline.timeline_state")  -- triggers load_displayed_sequence

-- H1 (#28): per-sequence TC origin now lives on the displayed tab's cache,
-- not on the data.state singleton mirror. Read through the public getter,
-- which routes via strip_holder.displayed_cache().
local cached = timeline_state.get_start_timecode_frame()
assert(cached == TC_ORIGIN, string.format(
    "FAIL: TC origin must round-trip from sequence row into the displayed "
    .. "tab cache. Expected %d (01:00:00:00 @ 24fps), got %s. If this "
    .. "regresses, every viewport-fit and ruler computation on cinema / "
    .. "BWF sequences silently misaligns by the missing frame count.",
    TC_ORIGIN, tostring(cached)))
print("  TC origin round-trips through tab cache — OK")

print("\n✅ test_nsf_timecode_start_no_fallback.lua passed")
