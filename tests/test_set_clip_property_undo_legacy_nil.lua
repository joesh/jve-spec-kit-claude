#!/usr/bin/env luajit
-- Regression: undoing a SetClipProperty command that was persisted
-- BEFORE the 2026-04-21 snapshot fix (when `previous_value` came from
-- an empty properties-table row = nil) must NOT crash. The fix going
-- forward snapshots `clip[property_name]` into `previous_value`, but
-- existing .jvp project files carry undo records with nil in that
-- slot. Those records can't be data-migrated without guessing a
-- "correct" previous value we don't have — so the undoer needs a
-- defense: skip the clip:save step when restoring nil into a
-- NOT-NULL clip column, log, and let the cursor advance so the rest
-- of the undo stack remains usable.
--
-- Domain behavior (not implementation):
--   Undoing a legacy bad SetClipProperty record does not raise. The
--   clip's current value is retained. Subsequent undo of an older,
--   healthy record still works.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

print("=== Undo of legacy SetClipProperty record with nil previous_value ===")

local db_path = "/tmp/jve/test_set_clip_property_undo_legacy_nil.db"
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
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p1', 'Legacy Nil Undo Test', 'resample', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'p1', 'Seq1', 'sequence', 24000, 1001, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

-- V13 placeholder master sequence + media_ref for the clip below.
db:exec([[
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'p1', 'placeholder', '_placeholder', 1000, 24, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'p1', 'placeholder_master', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'p1', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 1000, 0, 1000, 1, 1.0, 0, 0, 0);
]])

do
    local stmt = db:prepare([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES (?, ?, ?, ?, '_v13_placeholder_master', ?, ?, ?, ?, ?, NULL, NULL, 'resample', ?, 1.0, 0, ?, ?)
    ]])
    stmt:bind_value(1, "c1")
    stmt:bind_value(2, "p1")
    stmt:bind_value(3, "seq1")
    stmt:bind_value(4, "t1")
    stmt:bind_value(5, "Original")
    stmt:bind_value(6, 0)
    stmt:bind_value(7, 120)
    stmt:bind_value(8, 0)
    stmt:bind_value(9, 120)
    stmt:bind_value(10, 1)
    stmt:bind_value(11, now)
    stmt:bind_value(12, now)
    assert(stmt:exec(), "clip insert failed: " .. tostring(db:last_error()))
    stmt:finalize()
end

timeline_state.init("seq1", "p1")
command_manager.init("seq1", "p1")

-- Execute a real SetClipProperty so we get a valid command row. This
-- produces the POST-fix snapshot automatically; we then simulate the
-- legacy bug by wiping `previous_value` in the persisted command row
-- to reproduce what pre-fix `.jvp` files contain.
local cmd = Command.create("SetClipProperty", "p1")
cmd:set_parameter("clip_id", "c1")
cmd:set_parameter("property_name", "duration")
cmd:set_parameter("value", 156)
cmd:set_parameter("property_type", "NUMBER")
assert(command_manager.execute(cmd).success, "precondition: execute failed")

-- Simulate legacy row: rewrite the command's serialized parameters to
-- remove previous_value (making it effectively nil on re-read). The
-- parameters column is JSON-encoded.
local target_seq = cmd.sequence_number
assert(target_seq, "precondition: command missing sequence_number after execute")

do
    local q = db:prepare("SELECT command_args FROM commands WHERE sequence_number = ?")
    assert(q, "prepare fetch command_args failed")
    q:bind_value(1, target_seq)
    assert(q:exec() and q:next(), "fetch command_args failed")
    local raw = q:value(0)
    q:finalize()

    local json = require("dkjson")
    local params = json.decode(raw)
    -- Pre-fix: previous_value was nil because the properties-table row
    -- didn't exist yet. Simulate exactly that shape. dkjson drops nil
    -- keys on encode, which matches the legacy serialization.
    params.previous_value = nil
    local rewritten = json.encode(params)

    local u = db:prepare("UPDATE commands SET command_args = ? WHERE sequence_number = ?")
    u:bind_value(1, rewritten); u:bind_value(2, target_seq)
    assert(u:exec(), "rewrite command_args failed")
    u:finalize()
end

-- ----------------------------------------------------------------------
-- Check 1: undo does not crash on the legacy record.
-- Before the defense: Clip.save asserts on nil duration, error
-- propagates, cursor does not advance → user is stuck.
-- After the defense: undoer detects nil-into-NOT-NULL-column, logs,
-- skips the save, returns success. Cursor advances.
-- ----------------------------------------------------------------------
print("Check 1: undo of legacy-nil record succeeds (defensive skip)")
local undo_result = command_manager.undo()
assert(undo_result.success, string.format(
    "undo crashed on legacy record: %s — the undoer must defend " ..
    "against nil previous_value for NOT-NULL clip columns",
    tostring(undo_result.error_message)))

-- ----------------------------------------------------------------------
-- Check 2: clip duration retained its current value (156). We can't
-- recover the true previous value from a legacy record — skipping
-- the save is strictly better than crashing, and it keeps the DB
-- consistent.
-- ----------------------------------------------------------------------
print("Check 2: clip.duration remains 156 (current value retained)")
local function get_cached_duration()
    for _, c in ipairs(timeline_state.get_clips()) do
        if c.id == "c1" then return c.duration end
    end
    return nil
end
assert(get_cached_duration() == 156, string.format(
    "duration should remain 156 (defensive skip), got %s",
    tostring(get_cached_duration())))

print("✅ test_set_clip_property_undo_legacy_nil.lua passed")
