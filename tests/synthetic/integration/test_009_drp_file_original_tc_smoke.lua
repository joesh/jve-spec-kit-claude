-- 009 smoke: schema carries file_original_timecode independent of start_tc_value.
--
-- The full importer path is exercised by tests/test_drp_dual_tc.lua and
-- tests/test_relink_file_original_tc.lua. This smoke pins the integration-
-- tier guarantee from FR-001 / FR-005: the column exists on the media row
-- and accepts a value independent of start_tc_value, so an importer that
-- writes both never collides.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_009_drp_file_original_tc_smoke.lua ===")

require("test_env")
local database = require("core.database")

local DB = "/tmp/jve/test_009_drp_tc.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(DB); os.remove(DB..".wal"); os.remove(DB..".shm")
assert(database.init(DB))
local db = database.get_connection()

-- file_original_timecode lives in media.metadata JSON (FR-001 stores it on
-- the same row as start_tc_value, not in a separate top-level column). The
-- model exposes it via Media:get_file_original_timecode(); we verify the
-- round-trip end-to-end through the accessor (FR-005 independence).
local Media = require("models.media")

local now = os.time()
local _json = require("dkjson")
-- Both start_tc_value (override) and file_original_timecode (on-disk) are
-- stored inside media.metadata JSON. The model exposes them via accessors;
-- the schema invariant is that they are independent fields, not derived.
local meta = _json.encode({
    start_tc_value               = 1146141,
    start_tc_rate                = 24,
    file_original_timecode       = 654128,
    file_original_timecode_audio = math.floor(654128 * 48000 / 24 + 0.5),
    start_tc_audio_rate          = 48000,
})
local meta_sql = meta:gsub("'", "''")
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p','P','passthrough','{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',%d,%d);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
        metadata, created_at, modified_at)
      VALUES ('m-ovr','p','ovr.mov','/tmp/ovr.mov',100,24,1,0,NULL,
              '%s', %d, %d);
]], now, now, meta_sql, now, now)))

local m = assert(Media.load("m-ovr"), "Media.load('m-ovr') failed")
local original_tc, original_rate = m:get_file_original_timecode()
assert(original_tc == 654128 and original_rate == 24, string.format(
    "FR-005: file_original_timecode round-trip mismatch — got %s @ %s",
    tostring(original_tc), tostring(original_rate)))
local override_tc, override_rate = m:get_start_tc()
assert(override_tc == 1146141 and override_rate == 24, string.format(
    "FR-005: start_tc_value must round-trip independently of file_original_timecode "
    .. "— got override=%s @ %s",
    tostring(override_tc), tostring(override_rate)))
assert(override_tc ~= original_tc,
    "FR-005 needs override ≠ original to exercise independence")
print("  PASS: start_tc_value (override) and file_original_timecode round-trip independently")

print("\n✅ test_009_drp_file_original_tc_smoke.lua passed")
