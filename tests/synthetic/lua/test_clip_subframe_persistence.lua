-- T013 (018): clip subframe persistence round-trip (FR-005, FR-020).
-- Writes an audio clip via clip_position.write_audio_source, reloads from DB,
-- asserts subframes round-trip exactly. Mirror video case checks NULL preserved.

require("test_env")
local database = require("core.database")
local clip_position = require("core.clip_position")

local DB_PATH = "/tmp/jve/test_clip_subframe_persistence.db"
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")
assert(database.init(DB_PATH))
local db = database.get_connection()

-- Seed minimal: project (settings.master_clock_hz = 192000), master, sequence,
-- VIDEO + AUDIO track on the sequence.
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'p', 'passthrough', '%s', 0, 0);
]], '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}')))
assert(db:exec([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('m', 'p', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0),
           ('s', 'p', 's', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('s-v', 's', 'V1', 'VIDEO', 1),
           ('s-a', 's', 'A1', 'AUDIO', 1);
]]))

-- INSERT one VIDEO clip + one AUDIO clip via raw SQL (clip_position is for
-- reads + mutation-through-existing-rows; T019 wires writes through it for
-- new clips). For now: validate the persistence round-trip end-to-end.
-- VIDEO clip with NULL subframes.
assert(db:exec([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        sequence_start_frame, duration_frames,
        fps_mismatch_policy, name, enabled, volume, playhead_frame,
        created_at, modified_at)
    VALUES ('v1', 'p', 's', 's-v', 'm', 10, 50, NULL, NULL, 0, 40,
            'passthrough', 'v', 1, 1.0, 0, 0, 0);
]]))
-- AUDIO clip with non-zero subframes.
assert(db:exec([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        sequence_start_frame, duration_frames,
        fps_mismatch_policy, name, enabled, volume, playhead_frame,
        created_at, modified_at)
    VALUES ('a1', 'p', 's', 's-a', 'm', 10, 50, 1234, 5678, 0, 40,
            'passthrough', 'a', 1, 1.0, 0, 0, 0);
]]))

-- Build in-memory clip tables the way database.load_clips would (T018 will
-- formalize this in production code; the test uses a minimal proxy here).
local function load_one(id)
    local stmt = db:prepare([[
        SELECT c.source_in_frame, c.source_out_frame,
               c.source_in_subframe, c.source_out_subframe,
               t.track_type
        FROM clips c
        JOIN tracks t ON t.id = c.track_id
        WHERE c.id = ?
    ]])
    assert(stmt, "prepare failed")
    stmt:bind_value(1, id)
    assert(stmt:exec())
    assert(stmt:next())
    local row = {
        id = id,
        source_in_frame    = stmt:value(0),
        source_out_frame   = stmt:value(1),
        source_in_subframe = stmt:value(2),
        source_out_subframe= stmt:value(3),
        track_type         = stmt:value(4),
    }
    stmt:finalize()
    return row
end

local v = load_one("v1")
assert(v.source_in_subframe == nil, "VIDEO clip should have NULL source_in_subframe")
assert(v.source_out_subframe == nil, "VIDEO clip should have NULL source_out_subframe")
local vf_in, vf_out = clip_position.read_video_source(v)
assert(vf_in == 10 and vf_out == 50,
    string.format("VIDEO read_video_source expected (10,50), got (%s,%s)", tostring(vf_in), tostring(vf_out)))

local a = load_one("a1")
assert(a.source_in_subframe == 1234, "AUDIO subframe_in lost: " .. tostring(a.source_in_subframe))
assert(a.source_out_subframe == 5678, "AUDIO subframe_out lost: " .. tostring(a.source_out_subframe))
local af_in, as_in, af_out, as_out = clip_position.read_audio_source(a)
assert(af_in == 10 and as_in == 1234 and af_out == 50 and as_out == 5678,
    string.format("AUDIO read_audio_source expected (10,1234,50,5678), got (%s,%s,%s,%s)",
        tostring(af_in), tostring(as_in), tostring(af_out), tostring(as_out)))

-- Cross-misuse: read_audio_source on a video clip MUST assert.
local ok = pcall(function() clip_position.read_audio_source(v) end)
assert(not ok, "read_audio_source on VIDEO clip should assert")
local ok2 = pcall(function() clip_position.read_video_source(a) end)
assert(not ok2, "read_video_source on AUDIO clip should assert")

print("✅ test_clip_subframe_persistence.lua passed")
