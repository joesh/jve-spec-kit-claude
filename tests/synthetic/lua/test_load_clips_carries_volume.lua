-- Regression: a clip loaded from the project DB must carry its volume.
--
-- Domain behavior: a clip's volume (mix gain, default unity 1.0) is part of
-- the clip's persisted state. Anything that reads clips back from the DB —
-- the timeline cache, and the Find/Sift snapshot (timeline_panel:get_clips,
-- which asserts numeric volume) — needs it present.
--
-- Pre-fix bug: the timeline clip loader (db.load_clips / load_clip_entry)
-- never SELECTed the volume column, so every freshly-loaded clip had
-- volume = nil. Find/Sift over a timeline view then asserted "missing
-- volume" on the first clip. Re-inserted clips (duplicate/move/paste)
-- masked it for themselves by hand-adding volume; fresh clips crashed.
--
-- Black-box: load a clip with a NON-unity volume and assert it round-trips
-- as that number. Non-trivial value (0.5) so a hardcoded 1.0 default would
-- be caught.

require("test_env")

local database = require("core.database")

print("=== test_load_clips_carries_volume.lua ===")

local DB = "/tmp/jve/test_load_clips_carries_volume.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

db:exec([[
    INSERT INTO projects (id,name,fps_mismatch_policy,settings,created_at,modified_at)
    VALUES ('p','p','passthrough','{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',0,0);
    INSERT INTO sequences (id,project_id,name,kind,fps_numerator,fps_denominator,audio_sample_rate,width,height,created_at,modified_at)
    VALUES ('e','p','e','sequence',24,1,48000,1920,1080,0,0),('m','p','m','master',24,1,NULL,1920,1080,0,0);
    INSERT INTO tracks (id,sequence_id,name,track_type,track_index) VALUES ('e-v1','e','V1','VIDEO',1),('m-v1','m','V1','VIDEO',1);
    UPDATE sequences SET default_video_layer_track_id='m-v1' WHERE id='m';
    INSERT INTO clips (id,project_id,owner_sequence_id,track_id,sequence_id,name,
        sequence_start_frame,duration_frames,source_in_frame,source_out_frame,
        source_in_subframe,source_out_subframe,fps_mismatch_policy,enabled,volume,
        playhead_frame,created_at,modified_at)
    VALUES ('c1','p','e','e-v1','m','c1',0,100,0,100,NULL,NULL,'passthrough',1,0.5,0,0,0);
]])

-- Bulk load path (timeline cache).
local clips = database.load_clips("e")
assert(#clips >= 1, "expected the seeded clip")
local c
for _, cl in ipairs(clips) do if cl.id == "c1" then c = cl end end
assert(c, "clip c1 must load")
assert(type(c.volume) == "number", string.format(
    "load_clips: clip volume must be a number, got %s", type(c.volume)))
assert(math.abs(c.volume - 0.5) < 1e-9, string.format(
    "load_clips: clip volume must round-trip as 0.5, got %s", tostring(c.volume)))
print("  ✓ db.load_clips carries volume (0.5)")

-- Single-clip load path (used to rebuild cache entries on insert/undo).
local entry = database.load_clip_entry("c1")
assert(entry and type(entry.volume) == "number", string.format(
    "load_clip_entry: clip volume must be a number, got %s",
    entry and type(entry.volume) or "nil"))
assert(math.abs(entry.volume - 0.5) < 1e-9, string.format(
    "load_clip_entry: clip volume must round-trip as 0.5, got %s", tostring(entry.volume)))
print("  ✓ db.load_clip_entry carries volume (0.5)")

print("\n✅ test_load_clips_carries_volume.lua passed")
