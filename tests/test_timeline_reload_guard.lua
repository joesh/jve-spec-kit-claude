#!/usr/bin/env luajit

package.path = package.path
    .. ";./tests/?.lua"
    .. ";./src/lua/?.lua"
    .. ";./src/lua/core/?.lua"
    .. ";./src/lua/models/?.lua"
    .. ";./src/lua/ui/?.lua"
    .. ";./src/lua/ui/timeline/?.lua"

require("test_env")

local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

local SCHEMA_SQL = require("import_schema")

local DATA_SQL = [[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (
        id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES
        ('seq_a', 'default_project', 'Active Seq', 'timeline', 30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, strftime('%s','now'), strftime('%s','now')),
        ('seq_b', 'default_project', 'Background Seq', 'timeline', 30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, strftime('%s','now'), strftime('%s','now'));
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES
        ('seq_a_v1', 'seq_a', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
        ('seq_b_v1', 'seq_b', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]]

local tmp_db = os.tmpname() .. ".db"
os.remove(tmp_db)
assert(database.init(tmp_db))
local conn = database.get_connection()
assert(conn:exec(SCHEMA_SQL))
assert(conn:exec(DATA_SQL))

assert(timeline_state.init("seq_a"))
assert(timeline_state.get_sequence_id() == "seq_a", "expected active sequence to remain seq_a after init")

local reload_result = timeline_state.reload_clips("seq_b")
assert(reload_result == false, "reload_clips should skip when sequence_id differs")
assert(timeline_state.get_sequence_id() == "seq_a", "reload_clips should not switch active sequence")

local same_result = timeline_state.reload_clips("seq_a")
assert(same_result == true, "reload_clips should succeed for active sequence")
assert(timeline_state.get_sequence_id() == "seq_a", "active sequence should remain seq_a after valid reload")

os.remove(tmp_db)
print("✅ timeline reload guard test passed")
