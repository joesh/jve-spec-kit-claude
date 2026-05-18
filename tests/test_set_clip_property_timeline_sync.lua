#!/usr/bin/env luajit
-- Regression: SetClipProperty must keep the timeline's in-memory clip
-- cache in sync with the DB. Before this fix, the executor called
-- clip:save() (DB row updates) but emitted no __timeline_mutations, so
-- apply_command_mutations couldn't patch the timeline's cached clip. The
-- Inspector showed the new name (pulls via content_changed) but the
-- timeline's clip label stayed stale.
--
-- Domain behavior being verified (not implementation):
--   After SetClipProperty("name", "asdf") on a timeline clip, the
--   in-memory clip object exposed by timeline_state reflects name="asdf"
--   without any reload.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")
local Clip = require("models.clip")

print("=== SetClipProperty → timeline cache sync ===")

local db_path = "/tmp/jve/test_set_clip_property_timeline_sync.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require('import_schema'))
db:exec([[
    CREATE TABLE IF NOT EXISTS properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT,
        property_type TEXT,
        default_value TEXT
    );
]])

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p1', 'TL Sync Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'p1', 'Seq1', 'sequence', 24000, 1001, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    -- V13 placeholder master sequence for clip's sequence_id FK.
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        created_at, modified_at)
    VALUES ('mc_media', 'p1', 'mc', '/tmp/mc.mov', 1000, 24000, 1001,
        1920, 1080, 0, 'raw', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('mc_seq', 'p1', 'MC', 'master', 24000, 1001, NULL, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('mc_seq_v', 'mc_seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    UPDATE sequences SET default_video_layer_track_id = 'mc_seq_v' WHERE id = 'mc_seq';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mc_seq_mr', 'p1', 'mc_seq', 'mc_seq_v', 'mc_media',
        0, 1000, 0, 1000, 48000, 1, 1.0, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now))

-- Clip insert via prepared statement. The `db:exec` multi-statement path
-- silently swallows errors on some rows; use prepare/bind to catch FK or
-- CHECK violations as loud failures.
do
    local stmt = db:prepare([[
        INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
            track_id, name,
            sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 'resample', ?, ?, ?, ?, ?)
    ]])
    assert(stmt, "failed to prepare clip insert")
    stmt:bind_value(1, "c1")
    stmt:bind_value(2, "p1")
    stmt:bind_value(3, "seq1")
    stmt:bind_value(4, "mc_seq")
    stmt:bind_value(5, "t1")
    stmt:bind_value(6, "Original")
    stmt:bind_value(7, 0)
    stmt:bind_value(8, 120)
    stmt:bind_value(9, 0)
    stmt:bind_value(10, 120)
    stmt:bind_value(11, 1)
    stmt:bind_value(12, 1.0)
    stmt:bind_value(13, 0)
    stmt:bind_value(14, now)
    stmt:bind_value(15, now)
    local ok = stmt:exec()
    if not ok then
        local err = stmt.last_error and stmt:last_error() or "?"
        error("clip insert failed: " .. tostring(err))
    end
    stmt:finalize()
end

timeline_state.init("seq1", "p1")

-- Sanity: timeline_state should now cache the clip with name="Original".
local cached = nil
for _, c in ipairs(timeline_state.get_clips()) do
    if c.id == "c1" then cached = c end
end
assert(cached, "setup: expected timeline_state to cache clip c1")
assert(cached.name == "Original",
    "setup: expected cached name='Original', got " .. tostring(cached.name))

command_manager.init("seq1", "p1")

-- Precondition: the clip already knows its sequence via track lookup. The
-- executor derives __timeline_mutations.sequence_id from this, not from a
-- caller-passed param, so the caller doesn't need to duplicate the arg.
assert(Clip.get_sequence_id("c1") == "seq1",
    "precondition: Clip.get_sequence_id(c1) should return seq1")

local cmd = Command.create("SetClipProperty", "p1")
cmd:set_parameter("clip_id", "c1")
cmd:set_parameter("property_name", "name")
cmd:set_parameter("value", "asdf")
cmd:set_parameter("property_type", "STRING")

local result = command_manager.execute(cmd)
assert(result.success,
    "SetClipProperty execute failed: " .. tostring(result.error_message))

-- ----------------------------------------------------------------------
-- Check 1: DB reflects the new name (sanity; this already worked).
-- ----------------------------------------------------------------------
print("Check 1: DB row has new name")
local row_stmt = db:prepare("SELECT name FROM clips WHERE id = 'c1'")
assert(row_stmt and row_stmt:exec() and row_stmt:next(),
    "could not read clips.name")
local db_name = row_stmt:value(0)
row_stmt:finalize()
assert(db_name == "asdf", "DB name mismatch: " .. tostring(db_name))

-- ----------------------------------------------------------------------
-- Check 2: timeline_state's cached clip reflects the new name WITHOUT
-- a manual reload. This is the user-visible bug — the timeline's clip
-- label stays stale after the edit commits.
-- ----------------------------------------------------------------------
print("Check 2: timeline_state cache reflects new name")
local patched = nil
for _, c in ipairs(timeline_state.get_clips()) do
    if c.id == "c1" then patched = c end
end
assert(patched, "timeline_state should still cache clip c1")
assert(patched.name == "asdf", string.format(
    "timeline cache stale: expected name='asdf', got %s (bug: executor " ..
    "produced no __timeline_mutations for the name change)",
    tostring(patched.name)))

print("✅ test_set_clip_property_timeline_sync.lua passed")
