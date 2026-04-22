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
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('p1', 'Undo Column Test', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'p1', 'Seq1', 'timeline', 24000, 1001, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

do
    local stmt = db:prepare([[
        INSERT INTO clips (id, project_id, clip_kind, owner_sequence_id,
            track_id, media_id, name,
            timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
            fps_numerator, fps_denominator, enabled, created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    assert(stmt, "clip insert prepare failed")
    stmt:bind_value(1, "c1"); stmt:bind_value(2, "p1")
    stmt:bind_value(3, "timeline"); stmt:bind_value(4, "seq1")
    stmt:bind_value(5, "t1"); stmt:bind_value(6, nil)
    stmt:bind_value(7, "Original")
    stmt:bind_value(8, 0); stmt:bind_value(9, 120)     -- duration starts at 120
    stmt:bind_value(10, 0); stmt:bind_value(11, 120)
    stmt:bind_value(12, 24000); stmt:bind_value(13, 1001)
    stmt:bind_value(14, 1)
    stmt:bind_value(15, now); stmt:bind_value(16, now)
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

print("✅ test_set_clip_property_undo_column.lua passed")
