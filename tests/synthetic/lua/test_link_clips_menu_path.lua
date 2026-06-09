-- Regression: the "Link Clips" MENU command (menus.xml → command="LinkClips",
-- dispatched directly by menu_system with gathered selection context) must
-- succeed. The menu supplies only the clips to link; it has no link group id
-- to hand over — LinkClips MINTS the group.
--
-- Pre-fix bug (seen in the field, TSO 2026-05-28):
--   "Command 'LinkClips' missing required param 'link_group_id'"
-- LINK_SPEC wrongly declared link_group_id as a REQUIRED INPUT, but the
-- executor never reads it as input — it generates the id and persists it for
-- undo. Cmd+L only worked because its adapter passed a dummy uuid (ignored).
-- The menu path passed none and crashed at validation.
--
-- Black-box: drives LinkClips via command_manager exactly as the menu does
-- (clips + project_id, NO link_group_id) and inspects the model.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local ClipLink = require("models.clip_link")

print("=== test_link_clips_menu_path.lua ===")

local db_path = "/tmp/jve/test_link_clips_menu_path.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'Seq', 'sequence', 24000, 1001, 48000, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_v', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_a', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('master', 'proj', 'm', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('master_v', 'master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, enabled, created_at, modified_at, fps_mismatch_policy, volume, playhead_frame)
    VALUES ('clip_v', 'proj', 'V', 'trk_v', 'seq', 'master', 0, 100, 0, 100, NULL, NULL, 1, %d, %d, 'resample', 1.0, 0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, enabled, created_at, modified_at, fps_mismatch_policy, volume, playhead_frame)
    VALUES ('clip_a', 'proj', 'A', 'trk_a', 'seq', 'master', 0, 100, 0, 100, 0, 0, 1, %d, %d, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now))

command_manager.init("seq", "proj")

assert(ClipLink.get_link_group_id("clip_v", db) == nil, "precondition: clip_v unlinked")

-- Exactly what the menu dispatches: clips + project_id, NO link_group_id.
local ok, result = command_manager.execute("LinkClips", {
    project_id = "proj",
    clips = {
        { clip_id = "clip_v", role = "video", time_offset = 0 },
        { clip_id = "clip_a", role = "audio", time_offset = 0 },
    },
})
local res = ok or result
assert(type(res) == "table" and res.success, string.format(
    "LinkClips (menu path, no link_group_id) must succeed: %s",
    type(res) == "table" and tostring(res.error_message) or tostring(res)))

local gv = ClipLink.get_link_group_id("clip_v", db)
local ga = ClipLink.get_link_group_id("clip_a", db)
assert(gv and ga and gv == ga, string.format(
    "both clips must share one minted link group; got %s vs %s", tostring(gv), tostring(ga)))
print("  ✓ menu-path LinkClips mints a group and links both clips")

-- Undo removes the minted group.
command_manager.begin_command_event("script")
local undo_res = command_manager.undo()
command_manager.end_command_event()
assert((undo_res and undo_res.success), "undo should succeed")
assert(ClipLink.get_link_group_id("clip_v", db) == nil,
    "undo must remove the minted link group")
print("  ✓ undo removes the minted group")

print("\n✅ test_link_clips_menu_path.lua passed")
