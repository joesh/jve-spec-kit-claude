#!/usr/bin/env luajit

-- Regression: apply_mutations must not double-apply bulk_shift when mutations already
-- contain clip_ids (e.g. reloaded command / redo). It should either reuse or replace
-- the list, but never append and update twice.

require("test_env")

local database = require("core.database")
local command_helper = require("core.command_helper")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_command_helper_bulk_shift_does_not_double_apply.db"
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
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 25, 1, 48000, 1920, 1080, 0, 600, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 10000, 25, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, offline,
                       created_at, modified_at)
    VALUES ('clip_a', 'default_project', 'timeline', 'A', 'track_v1', 'media1', 'default_sequence',
            0, 100, 0, 100, 25, 1, 1, 0, %d, %d),
           ('clip_b', 'default_project', 'timeline', 'B', 'track_v1', 'media1', 'default_sequence',
            200, 100, 0, 100, 25, 1, 1, 0, %d, %d),
           ('clip_c', 'default_project', 'timeline', 'C', 'track_v1', 'media1', 'default_sequence',
            400, 100, 0, 100, 25, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now, now, now)))

local function get_start(clip_id)
    local stmt = assert(db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?"))
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "missing clip row for " .. tostring(clip_id))
    local value = tonumber(stmt:value(0))
    stmt:finalize()
    return value
end

-- This mutation simulates a replayed command: clip_ids already populated.
local mutations = {
    {
        type = "bulk_shift",
        track_id = "track_v1",
        anchor_start_frame = 200,
        shift_frames = 50,
        clip_ids = {"clip_b", "clip_c"},
    }
}

local ok_apply, apply_err = command_helper.apply_mutations(db, mutations)
assert(ok_apply, apply_err or "apply_mutations failed")

-- If bulk_shift is double-applied, clip_b would end up at 300 and clip_c at 500.
assert(get_start("clip_a") == 0, "bulk_shift should not move clip_a")
assert(get_start("clip_b") == 250, "bulk_shift should move clip_b exactly once")
assert(get_start("clip_c") == 450, "bulk_shift should move clip_c exactly once")

os.remove(TEST_DB)
print("✅ apply_mutations bulk_shift does not double-apply clip_ids")
