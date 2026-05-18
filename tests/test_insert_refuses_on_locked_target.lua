#!/usr/bin/env luajit

-- Insert with a patch routing to a LOCKED existing record track must refuse.
-- Auto-create handles missing intermediate tracks; the actual write happens
-- on the patch's target. The track_lock_guard at the Clip-model boundary
-- refuses, command_manager rolls the BEGIN..COMMIT envelope back, and no
-- side-effect tracks leak from the auto-create phase.

require("test_env")
local database        = require("core.database")
local command_manager = require("core.command_manager")

print("=== test_insert_refuses_on_locked_target.lua ===")

local DB = "/tmp/jve/test_insert_refuses_on_locked_target.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
assert(database.init(DB), "init failed")
local db = database.get_connection()

-- Master with V1 + A1. Rec with V1+V2 (V2 LOCKED) and A1 (unlocked) +
-- A3 unlocked at sparse idx 3. Patch routes source V1 → rec V2 (locked).
assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p','P','resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0,0);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('m','p','M','master',  24,1,NULL,1920,1080,0,0),
           ('r','p','R','sequence',24,1,48000,1920,1080,0,0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect)
    VALUES
      ('m-v1','m','V1','VIDEO',1,1,0,0,0,1.0,0.0,'off',1),
      ('r-v1','r','V1','VIDEO',1,1,0,0,0,1.0,0.0,'off',1),
      ('r-v2','r','V2','VIDEO',2,1,1,0,0,1.0,0.0,'off',1),  -- LOCKED target
      ('r-a1','r','A1','AUDIO',1,1,0,0,0,1.0,0.0,'off',1),
      ('r-a3','r','A3','AUDIO',3,1,0,0,0,1.0,0.0,'off',1);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, created_at, modified_at)
    VALUES ('me','p','m.mov','/tmp/m.mov',240,24,1,1920,1080,0,0);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr','p','m','m-v1','me',0,240,0,240, 48000,1,1.0,0,0,0);
    -- Patch: src V1 → rec V2 (locked).
    INSERT INTO patches (id, sequence_id, track_type, source_shape,
        source_track_index, record_track_index, enabled, created_at)
    VALUES ('p-v','r','VIDEO',1,1,2,1,0);
]]))
require("test_env").touch_media_fixtures()

command_manager.init("r", "p")

local function track_count()
    local s = db:prepare("SELECT COUNT(*) FROM tracks WHERE sequence_id='r'")
    assert(s:exec() and s:next())
    local n = s:value(0); s:finalize()
    return n
end

local function clip_count()
    local s = db:prepare(
        "SELECT COUNT(*) FROM clips WHERE owner_sequence_id='r'")
    assert(s:exec() and s:next())
    local n = s:value(0); s:finalize()
    return n
end

local tracks_before = track_count()
local clips_before  = clip_count()

local r = command_manager.execute("Insert", {
    sequence_id          = "r",
    source_sequence_id   = "m",
    sequence_start_frame = 0,
    project_id           = "p",
})
assert(r and r.success == false,
    "FAIL: Insert into locked-target sequence must refuse; got "
    .. tostring(r and r.error_message))
assert(tostring(r.error_message):match("[Ll]ocked"),
    "FAIL: error must mention 'locked'; got: "..tostring(r.error_message))

-- ROLLBACK invariants: no clips created, no orphan auto-tracks.
assert(clip_count() == clips_before,
    string.format("FAIL: clips leaked through rollback: %d → %d",
        clips_before, clip_count()))
assert(track_count() == tracks_before,
    string.format("FAIL: auto-created tracks leaked through rollback: %d → %d",
        tracks_before, track_count()))
print("  refused + clean rollback (no leaked tracks/clips) — OK")

print("\n✅ test_insert_refuses_on_locked_target.lua passed")
