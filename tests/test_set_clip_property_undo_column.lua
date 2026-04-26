#!/usr/bin/env luajit
-- Regression: undoing SetClipProperty on a top-level clip column
-- (duration, timeline_start, source_in, source_out) must restore the
-- clip's previous column value — not nil.
--
-- Before the fix: the executor snapshotted `previous_value` from the
-- `properties` table (generic key/value). When the Inspector uses
-- SetClipProperty for a clip column that has no corresponding
-- properties-table row, previous_value was nil, and the undoer's
-- `clip:set_property(name, nil) + clip:save()` hit the integer-check
-- assert at models/clip.lua:436. See TSO 2026-04-21 00:28:50 — user
-- edited clip duration to 156, hit Cmd-Z, crashed with
-- "Clip.save: duration must be integer (got nil)".
--
-- Domain behavior (not implementation):
--   Setting then undoing a column edit returns the clip to its original
--   value. The undo operation itself must not error.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

print("=== SetClipProperty → undo on top-level column ===")

local db_path = "/tmp/jve/test_set_clip_property_undo_column.db"
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
    VALUES ('p1', 'Undo Column Test', 'resample', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'p1', 'Seq1', 'nested', 24000, 1001, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    -- V13 placeholder master sequence for clip's nested_sequence_id FK.
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        created_at, modified_at)
    VALUES ('mc_media', 'p1', 'mc', '/tmp/mc.mov', 1000, 24000, 1001,
        1920, 1080, 0, 'raw', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, created_at, modified_at)
    VALUES ('mc_seq', 'p1', 'MC', 'master', 24000, 1001, 48000, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('mc_seq_v', 'mc_seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    UPDATE sequences SET default_video_layer_track_id = 'mc_seq_v' WHERE id = 'mc_seq';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, timeline_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mc_seq_mr', 'p1', 'mc_seq', 'mc_seq_v', 'mc_media',
        0, 1000, 0, 1000, 1, 1.0, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now))

do
    local stmt = db:prepare([[
        INSERT INTO clips (id, project_id, owner_sequence_id, nested_sequence_id,
            track_id, name,
            timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 'resample', ?, ?, ?, ?, ?)
    ]])
    assert(stmt, "clip insert prepare failed")
    stmt:bind_value(1, "c1"); stmt:bind_value(2, "p1")
    stmt:bind_value(3, "seq1"); stmt:bind_value(4, "mc_seq")
    stmt:bind_value(5, "t1")
    stmt:bind_value(6, "Original")
    stmt:bind_value(7, 0); stmt:bind_value(8, 120)
    stmt:bind_value(9, 0); stmt:bind_value(10, 120)
    stmt:bind_value(11, 1); stmt:bind_value(12, 1.0); stmt:bind_value(13, 0)
    stmt:bind_value(14, now); stmt:bind_value(15, now)
    assert(stmt:exec(), "clip insert failed")
    stmt:finalize()
end

timeline_state.init("seq1", "p1")
command_manager.init("seq1", "p1")

-- Sanity: clip starts with duration 120.
local function get_cached_duration()
    for _, c in ipairs(timeline_state.get_clips()) do
        if c.id == "c1" then return c.duration end
    end
    return nil
end
assert(get_cached_duration() == 120,
    "precondition: initial duration should be 120, got " .. tostring(get_cached_duration()))

-- ----------------------------------------------------------------------
-- Check 1: edit duration via SetClipProperty.
-- ----------------------------------------------------------------------
print("Check 1: SetClipProperty sets duration to 156")
local cmd = Command.create("SetClipProperty", "p1")
cmd:set_parameter("clip_id", "c1")
cmd:set_parameter("property_name", "duration")
cmd:set_parameter("value", 156)
cmd:set_parameter("property_type", "NUMBER")
local result = command_manager.execute(cmd)
assert(result.success,
    "SetClipProperty execute failed: " .. tostring(result.error_message))
assert(get_cached_duration() == 156,
    "after execute: expected duration=156, got " .. tostring(get_cached_duration()))

-- ----------------------------------------------------------------------
-- Check 2: undo restores duration to 120 — this is the regression.
-- Before the fix: undo crashed because previous_value came from the
-- (non-existent) properties table row, so was nil, and nil duration
-- fails Clip.save's integer check.
-- ----------------------------------------------------------------------
print("Check 2: undo restores duration to 120 without crashing")
local undo_result = command_manager.undo()
assert(undo_result.success, string.format(
    "undo crashed: %s (bug: SetClipProperty executor snapshots " ..
    "previous_value from properties table, which is empty for " ..
    "column-backed properties)", tostring(undo_result.error_message)))
assert(get_cached_duration() == 120, string.format(
    "after undo: expected duration=120 (original), got %s",
    tostring(get_cached_duration())))

-- ----------------------------------------------------------------------
-- Check 3: redo re-applies the edit (round-trip symmetry).
-- ----------------------------------------------------------------------
print("Check 3: redo re-applies duration=156")
local redo_result = command_manager.redo()
assert(redo_result.success, "redo failed: " .. tostring(redo_result.error_message))
assert(get_cached_duration() == 156,
    "after redo: expected duration=156, got " .. tostring(get_cached_duration()))

-- ----------------------------------------------------------------------
-- Check 4: same cycle for `name` (which sometimes masked the bug
-- because names default to '' rather than error-on-nil).
-- ----------------------------------------------------------------------
print("Check 4: edit/undo/redo cycle for name")
local name_cmd = Command.create("SetClipProperty", "p1")
name_cmd:set_parameter("clip_id", "c1")
name_cmd:set_parameter("property_name", "name")
name_cmd:set_parameter("value", "Renamed")
name_cmd:set_parameter("property_type", "STRING")
assert(command_manager.execute(name_cmd).success, "name execute failed")

local function get_cached_name()
    for _, c in ipairs(timeline_state.get_clips()) do
        if c.id == "c1" then return c.name end
    end
    return nil
end

assert(get_cached_name() == "Renamed",
    "after name execute: expected 'Renamed', got " .. tostring(get_cached_name()))
assert(command_manager.undo().success, "name undo failed")
assert(get_cached_name() == "Original", string.format(
    "after name undo: expected 'Original', got %s", tostring(get_cached_name())))

-- ----------------------------------------------------------------------
-- Check 5: the full MUTATION_KEY set — timeline_start, source_in,
-- source_out, enabled. set_clip_property.lua maps each of these clip-
-- column property names onto a specific `_value`-suffixed key in the
-- __timeline_mutations payload; if ANY mapping regresses, the cache
-- won't track the DB edit for that column. Without these, a broken
-- key mapping for (say) source_in would sit undetected until a user
-- trimmed a clip from the Inspector.
-- ----------------------------------------------------------------------
print("Check 5: round-trip every column-backed field")

local function get_cached_field(field)
    for _, c in ipairs(timeline_state.get_clips()) do
        if c.id == "c1" then return c[field] end
    end
    return nil
end

local cases = {
    { field = "timeline_start", type = "NUMBER",  new = 42,    old = 0   },
    { field = "source_in",      type = "NUMBER",  new = 30,    old = 0   },
    { field = "source_out",     type = "NUMBER",  new = 200,   old = 120 },
    { field = "enabled",        type = "BOOLEAN", new = false, old = true},
}

for _, c in ipairs(cases) do
    assert(get_cached_field(c.field) == c.old, string.format(
        "precondition: initial %s should be %s, got %s",
        c.field, tostring(c.old), tostring(get_cached_field(c.field))))

    local cmd2 = Command.create("SetClipProperty", "p1")
    cmd2:set_parameter("clip_id", "c1")
    cmd2:set_parameter("property_name", c.field)
    cmd2:set_parameter("value", c.new)
    cmd2:set_parameter("property_type", c.type)
    local r = command_manager.execute(cmd2)
    assert(r.success, c.field .. " execute: " .. tostring(r.error_message))
    assert(get_cached_field(c.field) == c.new, string.format(
        "after execute, cached %s = %s (want %s) — MUTATION_KEY[%s] probably wrong",
        c.field, tostring(get_cached_field(c.field)), tostring(c.new), c.field))

    assert(command_manager.undo().success, c.field .. " undo failed")
    assert(get_cached_field(c.field) == c.old, string.format(
        "after undo, cached %s = %s (want %s) — undoer's mutation emission wrong",
        c.field, tostring(get_cached_field(c.field)), tostring(c.old)))
end

print("✅ test_set_clip_property_undo_column.lua passed")
