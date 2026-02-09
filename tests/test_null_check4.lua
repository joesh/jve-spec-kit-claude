require('test_env')
local database = require('core.database')
local DB_PATH = '/tmp/jve/test_null_clip4.db'
os.remove(DB_PATH)
database.init(DB_PATH)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Verify we have the right columns
local pragma = db:prepare("PRAGMA table_info(clips)")
io.stdout:write("Clips columns:\n")
assert(pragma:exec(), "PRAGMA exec failed")
while pragma:next() do
    io.stdout:write("  " .. tostring(pragma:value(1)) .. "\n")
end
pragma:finalize()

db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('proj', 'P', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at) VALUES ('seq', 'proj', 'S', 'timeline', 25, 1, 48000, 1920, 1080, 0, 250, 0, '[]', '[]', 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);
]])

-- Use proper column names from schema
db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('clip_ok', 'proj', 'timeline', 'OK', 'v1', 'seq', 100, 50, 0, 50, 1, 0, 30, 1, 0, 0)
]])

local clips = database.load_clips('seq')
io.stdout:write("Got clips: " .. #clips .. "\n")
for _, c in ipairs(clips) do
    io.stdout:write("  " .. c.id .. ": timeline_start = " .. tostring(c.timeline_start) .. "\n")
end
