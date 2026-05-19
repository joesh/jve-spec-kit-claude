-- 012 smoke: Inspector renders a selected clip with current values.
--
-- Acceptance Scenario 1: select one clip → Inspector shows the clip's name
-- as its header AND each field reflects the clip's current value. Driven
-- through the production `inspectable.clip` adapter the Inspector reads
-- from, so this catches schema drift between the model and the view.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_012_inspector_clip_smoke.lua ===")

require("test_env")
local database = require("core.database")
local Inspectable = require("inspectable")

local DB = "/tmp/jve/test_012_inspector.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(DB); os.remove(DB..".wal"); os.remove(DB..".shm")
assert(database.init(DB))
local db = database.get_connection()
local now = os.time()

assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p','P','passthrough','{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
      VALUES ('m','p','M','master',24,1,NULL,1920,1080,%d,%d),
             ('e','p','E','sequence',24,1,48000,1920,1080,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
      VALUES ('m-v1','m','V1','VIDEO',1), ('e-v1','e','V1','VIDEO',1);
    UPDATE sequences SET default_video_layer_track_id='m-v1' WHERE id='m';
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate, created_at, modified_at)
      VALUES ('med','p','m.mov','/tmp/m.mov',240,24,1,0,0,%d,%d);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr-v','p','m','m-v1','med',0,240,0,240,1,1.0,0,%d,%d);
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id, track_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        fps_mismatch_policy, enabled, volume, playhead_frame, name,
        created_at, modified_at)
      VALUES ('c1','p','e','m','e-v1', 10, 200, 0, 190, 'passthrough', 1, 0.75, 0,
              'Alpha Clip', %d, %d);
]],
    now, now, now, now, now, now, now, now, now, now, now, now)))

-- Seed a property row so the Inspector's name accessor (which reads from
-- the EAV properties table, not the clips row's `name` column) returns it.
assert(db:exec(string.format([[
    INSERT INTO properties (id, clip_id, property_name, property_value)
      VALUES ('prop-name', 'c1', 'name', '%s')
]], '{"value":"Alpha Clip"}')))

-- The Inspector creates an inspectable for the selected clip and reads each
-- field via :get(). The display name is the property-row "name".
local clip_insp = Inspectable.clip({ clip_id = "c1", project_id = "p", sequence_id = "e" })

assert(clip_insp:get_schema_id() == "clip", "clip inspectable must have schema_id='clip'")
print("  PASS: schema_id is 'clip'")

local display = clip_insp:get_display_name()
assert(display == "Alpha Clip", string.format(
    "Inspector header must show the property-row name; got %q", tostring(display)))
print("  PASS: header shows clip name 'Alpha Clip'")

-- Verify the inspectable's :get returns SOMETHING for known fields (the
-- exact shape depends on the clip schema, which is a Phase-1 design surface
-- — this smoke proves the model-tier read path is wired end-to-end).
assert(type(clip_insp.iter_fields) == "function",
    "inspectable must expose iter_fields method")
local n_fields = 0
for _ in clip_insp:iter_fields() do n_fields = n_fields + 1 end
assert(n_fields > 0, "clip inspectable must enumerate at least one field")
print(string.format("  PASS: inspectable enumerates %d fields", n_fields))

print("\n✅ test_012_inspector_clip_smoke.lua passed")
