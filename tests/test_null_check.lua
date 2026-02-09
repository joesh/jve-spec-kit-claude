require('test_env')
local database = require('core.database')

local DB_PATH = '/tmp/jve/test_null_clip.db'
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(require('import_schema')))

db:exec([[
    INSERT INTO projects VALUES ('proj', 'P', 0, 0, '{}');
    INSERT INTO sequences VALUES ('seq', 'proj', 'S', 'timeline', 25, 1, 48000, 1920, 1080, 0, 250, 0, '[]', '[]', '[]', 0, 0, 0);
    INSERT INTO tracks VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('clip1', 'proj', 'clip', 'OK', 'v1', 'seq', 100, 50, 0, 50, 1, 0, 30, 1, 0, 0);
]])

-- Now insert a clip with NULL timeline_start
db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('clip_null', 'proj', 'clip', 'NULL', 'v1', 'seq', NULL, 50, 0, 50, 1, 0, 30, 1, 0, 0);
]])

local clips = database.load_clips('seq')
for _, c in ipairs(clips) do
    print('Clip:', c.id, 'timeline_start:', type(c.timeline_start), tostring(c.timeline_start))
end
