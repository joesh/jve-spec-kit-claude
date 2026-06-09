-- Unit test for the NewBinHere keyboard/menu adapter
-- (see core/commands/new_bin_here.lua).
--
-- Black-box assertion: after dispatching NewBinHere, the project's
-- bin hierarchy gains exactly one new bin.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local tag_service = require("core.tag_service")

local db_path = "/tmp/jve/test_new_bin_here_adapter.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'sequence', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now, now, now))

command_manager.init("seq1", "proj1")

local bins_before = #tag_service.list("proj1")

local ok = command_manager.execute("NewBinHere", { project_id = "proj1" })
assert(ok, "NewBinHere dispatch should succeed")

local bins_after = #tag_service.list("proj1")
assert(bins_after == bins_before + 1, string.format(
    "NewBinHere should create exactly one bin: before=%d, after=%d",
    bins_before, bins_after))

print("✅ test_new_bin_here_adapter passed")
