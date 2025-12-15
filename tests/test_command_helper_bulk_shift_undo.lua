#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_helper = require("core.command_helper")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_command_helper_bulk_shift_undo.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()
assert(db:exec(SCHEMA_SQL))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30, 1, 48000, 1920, 1080, 0, 600, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 10000, 30, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, offline,
                       created_at, modified_at)
    VALUES ('clip_a', 'default_project', 'timeline', 'A', 'track_v1', 'media1', 'default_sequence',
            0, 100, 0, 100, 30, 1, 1, 0, %d, %d),
           ('clip_b', 'default_project', 'timeline', 'B', 'track_v1', 'media1', 'default_sequence',
            1000, 100, 0, 100, 30, 1, 1, 0, %d, %d),
           ('clip_c', 'default_project', 'timeline', 'C', 'track_v1', 'media1', 'default_sequence',
            2000, 100, 0, 100, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now, now, now)))

local function get_start(clip_id)
    local stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    assert(stmt, "failed to prepare start query")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "missing clip row for " .. tostring(clip_id))
    local value = stmt:value(0)
    stmt:finalize()
    return value
end

local mutations = {
    {
        type = "bulk_shift",
        track_id = "track_v1",
        shift_frames = 100,
        first_clip_id = "clip_b",
    }
}

local ok, err = command_helper.apply_mutations(db, mutations)
assert(ok, err or "apply_mutations failed")
assert(get_start("clip_a") == 0, "bulk_shift should not move clips before anchor")
assert(get_start("clip_b") == 1100, "bulk_shift should move anchor clip")
assert(get_start("clip_c") == 2100, "bulk_shift should move downstream clip")

local ok_undo, undo_err = command_helper.revert_mutations(db, mutations, nil, nil)
assert(ok_undo, undo_err or "revert_mutations failed")
assert(get_start("clip_a") == 0, "undo should restore clip_a")
assert(get_start("clip_b") == 1000, "undo should restore clip_b")
assert(get_start("clip_c") == 2000, "undo should restore clip_c")

-- Legacy format: bulk_shift recorded explicit clip_ids.
assert(db:exec("UPDATE clips SET timeline_start_frame = timeline_start_frame + 50 WHERE id IN ('clip_b','clip_c')"))
local legacy = {
    {
        type = "bulk_shift",
        track_id = "track_v1",
        shift_frames = 50,
        clip_ids = {"clip_b", "clip_c"},
    }
}
local ok_legacy, legacy_err = command_helper.revert_mutations(db, legacy, nil, nil)
assert(ok_legacy, legacy_err or "legacy bulk_shift undo failed")
assert(get_start("clip_b") == 1000, "legacy undo should restore clip_b")
assert(get_start("clip_c") == 2000, "legacy undo should restore clip_c")

os.remove(TEST_DB)
print("✅ command_helper bulk_shift applies and undoes correctly")
