#!/usr/bin/env luajit

-- Regression: BatchRippleEdit undo must preserve strict reverse order so that
-- pre-bulk-shifts are undone after clip updates (otherwise VIDEO_OVERLAP can
-- trigger transiently).

require("test_env")

local database = require("core.database")
local command_helper = require("core.command_helper")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_batch_ripple_undo_respects_pre_bulk_shift_order.db"
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

    -- Post-apply state:
    -- clip_a duration expanded to 200 (ends at 200), clip_b shifted +100 to 250.
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, offline,
                       created_at, modified_at)
    VALUES ('clip_a', 'default_project', 'timeline', 'A', 'track_v1', 'media1', 'default_sequence',
            0, 200, 0, 200, 25, 1, 1, 0, %d, %d),
           ('clip_b', 'default_project', 'timeline', 'B', 'track_v1', 'media1', 'default_sequence',
            250, 100, 0, 100, 25, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now)))

local function get_row(clip_id)
    local stmt = db:prepare("SELECT timeline_start_frame, duration_frames FROM clips WHERE id = ?")
    assert(stmt, "failed to prepare row query")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "missing clip row for " .. tostring(clip_id))
    local start_frame = stmt:value(0)
    local dur = stmt:value(1)
    stmt:finalize()
    return start_frame, dur
end

local mutations = {
    -- Apply order: pre bulk shift first, then clip update.
    {
        type = "bulk_shift",
        track_id = "track_v1",
        shift_frames = 100,
        clip_ids = {"clip_b"},
    },
    {
        type = "update",
        previous = {
            id = "clip_a",
            project_id = "default_project",
            clip_kind = "timeline",
            name = "A",
            track_id = "track_v1",
            media_id = "media1",
            owner_sequence_id = "default_sequence",
            track_sequence_id = "default_sequence",
            timeline_start = { frames = 0 },
            duration = { frames = 100 },
            source_in = { frames = 0 },
            source_out = { frames = 100 },
            fps_numerator = 25,
            fps_denominator = 1,
            enabled = true,
            created_at = now,
            modified_at = now,
        },
    },
}

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("sequence_id", "default_sequence")

local ok, err = command_helper.revert_mutations(db, mutations, cmd, "default_sequence")
assert(ok, err or "revert_mutations failed")

local b_start, b_dur = get_row("clip_b")
assert(b_start == 150 and b_dur == 100, "expected clip_b restored to start=150 dur=100")

local a_start, a_dur = get_row("clip_a")
assert(a_start == 0 and a_dur == 100, "expected clip_a restored to start=0 dur=100")

os.remove(TEST_DB)
print("✅ BatchRippleEdit undo preserves strict ordering for bulk shifts")

