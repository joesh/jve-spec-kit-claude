#!/usr/bin/env luajit

-- 015 — movement commands (SetMarkIn, SetMarkOut, SetPlayhead) issued
-- from the timeline panel must target the *displayed* tab, not the
-- active record sequence. The split between active and displayed is by
-- design: edits go to active; mark / playhead are MOVEMENT, not edits,
-- and they belong to whatever the user is looking at.
--
-- Reported by user 2026-05-12: with source tab displayed in the timeline
-- panel, pressing I / O / clicking the ruler writes mark_in / mark_out /
-- playhead onto the active record sequence. The marks panel shows the
-- record's marks while the user is staring at the source.
--
-- This test drives the timeline_state pointer split (FR-005) and
-- asserts that movement-class commands fired with sequence_id resolved
-- from the timeline panel land on the displayed sequence.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Sequence        = require("models.sequence")
local timeline_state  = require("ui.timeline.timeline_state")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== test_movement_targets_displayed_tab.lua ===")

local DB = "/tmp/jve/test_movement_targets_displayed_tab.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, start_timecode_frame, playhead_frame,
        view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES
      ('rec', 'proj', 'Record', 'sequence', 25, 1, 48000, 1920, 1080,
            0, 100, 0, 1500, %d, %d),
      ('src', 'proj', 'A023', 'master', 24, 1, NULL, 1920, 1080,
            0, 0, 0, 2784, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('rv1', 'rec', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now, now, now))

command_manager.init('rec', 'proj')

-- Mirror the UI: timeline_state holds the displayed/active split.
-- Switch the timeline panel's displayed tab to the source master, leaving
-- the active record sequence untouched (FR-005).
timeline_state.switch_to_record_tab('rec')
assert(timeline_state.get_active_sequence_id() == 'rec',
    "fixture: active should be rec")
assert(timeline_state.get_displayed_tab_id() == 'rec',
    "fixture: displayed should be rec before switch")

timeline_state.switch_to_source_tab('src')
assert(timeline_state.get_active_sequence_id() == 'rec',
    "FR-005: switching displayed must NOT change active")
assert(timeline_state.get_displayed_tab_id() == 'src',
    "FR-005: displayed must follow switch_to_source_tab")

-- ── Test 1: SetPlayhead from timeline panel (no explicit sequence_id) ──
-- The ruler at timeline_ruler.lua dispatches SetPlayhead with the panel's
-- sequence_id. When the displayed tab is the source, that must be the
-- source — otherwise the playhead lands on the record while the user is
-- looking at the source.
print("\nTest 1: SetPlayhead from timeline panel targets displayed tab")
local PH_FRAME = 42
do
    local target = timeline_state.get_movement_target_sequence_id
        and timeline_state.get_movement_target_sequence_id()
    assert(target == 'src',
        string.format("get_movement_target_sequence_id must return displayed "
            .. "tab ('src') when source is displayed; got %s", tostring(target)))

    local result = command_manager.execute("SetPlayhead", {
        project_id  = "proj",
        sequence_id = target,
        playhead_position = PH_FRAME,
    })
    assert(result and result.success,
        "SetPlayhead must succeed: " .. tostring(result and result.error_message))
end

local src_after = Sequence.load('src')
local rec_after = Sequence.load('rec')
assert(src_after.playhead_position == PH_FRAME, string.format(
    "source playhead must advance to %d; got %s",
    PH_FRAME, tostring(src_after.playhead_position)))
assert(rec_after.playhead_position == 100, string.format(
    "record playhead must NOT change; expected 100, got %s",
    tostring(rec_after.playhead_position)))
print("  ✓ playhead lands on displayed (source), not active (record)")

-- ── Test 2: SetMarkIn / SetMarkOut from timeline panel ──
print("\nTest 2: SetMarkIn / SetMarkOut from timeline panel target displayed")
do
    local target = timeline_state.get_movement_target_sequence_id()
    local r1 = command_manager.execute("SetMarkIn",
        { project_id = "proj", sequence_id = target, frame = 10 })
    assert(r1 and r1.success, "SetMarkIn must succeed")
    local r2 = command_manager.execute("SetMarkOut",
        { project_id = "proj", sequence_id = target, frame = 50 })
    assert(r2 and r2.success, "SetMarkOut must succeed")
end

src_after = Sequence.load('src')
rec_after = Sequence.load('rec')
assert(src_after.mark_in == 10,
    string.format("source mark_in must be 10; got %s",
        tostring(src_after.mark_in)))
-- mark_out is stored as frame+1 (exclusive) per set_marks contract
assert(src_after.mark_out == 51,
    string.format("source mark_out must be 51 (exclusive); got %s",
        tostring(src_after.mark_out)))
assert(rec_after.mark_in == nil,
    string.format("record mark_in must remain unset; got %s",
        tostring(rec_after.mark_in)))
assert(rec_after.mark_out == nil,
    string.format("record mark_out must remain unset; got %s",
        tostring(rec_after.mark_out)))
print("  ✓ marks land on displayed (source), not active (record)")

-- ── Test 3: When displayed switches back to record, target is record ──
print("\nTest 3: switching displayed back to record routes movement to rec")
timeline_state.switch_to_record_tab('rec')
do
    local target = timeline_state.get_movement_target_sequence_id()
    assert(target == 'rec', string.format(
        "after switch back, movement target should be rec; got %s",
        tostring(target)))
end

-- ── Test 4: focus-driven injection: SetPlayhead with NO sequence_id arg
-- and timeline-panel focus + source displayed → command lands on source.
-- This exercises the command_manager.execute_interactive injection that
-- backs keyboard shortcuts (I / O / J / etc.) — they go through TOML
-- dispatch with no explicit sequence_id and rely on focus to resolve.
print("\nTest 4: execute_interactive injects displayed for movement commands")
timeline_state.switch_to_source_tab('src')

-- Stub focus_manager to claim the timeline panel is focused.
local fm = require("ui.focus_manager")
local saved_get = fm.get_focused_panel
fm.get_focused_panel = function() return "timeline" end

local ok, err = pcall(function()
    local r = command_manager.execute_interactive("SetPlayhead", {
        playhead_position = 77,
    })
    assert(r and r.success,
        "SetPlayhead via execute_interactive must succeed: "
        .. tostring(r and r.error_message))
end)

fm.get_focused_panel = saved_get  -- restore even on failure
assert(ok, "Test 4 inner block raised: " .. tostring(err))

src_after = Sequence.load('src')
rec_after = Sequence.load('rec')
assert(src_after.playhead_position == 77, string.format(
    "source playhead must be 77 (focus=timeline + displayed=src); got %s",
    tostring(src_after.playhead_position)))
-- The record's playhead before Test 4 was set to 42 in Test 1, then
-- changed back to 42 when we switched displayed to rec in Test 3 (the
-- switch doesn't move playheads). It must NOT have advanced to 77.
assert(rec_after.playhead_position ~= 77, string.format(
    "record playhead must NOT be 77; got %s",
    tostring(rec_after.playhead_position)))
print("  ✓ keyboard-style dispatch routes movement to displayed")

-- ── Test 5: edit commands from timeline-panel focus stay on active record
-- even when source tab is displayed. This is the architectural invariant:
-- edits target active_sequence_id (FR-005); movement targets displayed.
print("\nTest 5: edit commands stay on active even when source displayed")
-- ClearMarks is undoable but mutates_clips=false (movement). Try an
-- explicit non-movement, undoable command. SetSelectedClips is a
-- selection write — let's use ClearMarks anyway and rely on the
-- mutates_clips=true classifier-driven path via Insert? Insert needs
-- a source_sequence_id which would be itself when displayed=src. So we
-- instead use a synthetic check: assert command_manager classifies
-- Insert/Overwrite as NOT movement and would NOT inject from
-- timeline_state. (Verifies the spec.mutates_clips gate works.)
local registry = require("core.command_registry")
local insert_spec = registry.get_spec("Insert")
assert(insert_spec, "Insert spec must be registered")
assert(insert_spec.mutates_clips ~= false, string.format(
    "Insert.mutates_clips must NOT be false — edits must NOT be routed to "
    .. "displayed via get_movement_target_sequence_id. Spec says: %s",
    tostring(insert_spec.mutates_clips)))
local overwrite_spec = registry.get_spec("Overwrite")
assert(overwrite_spec.mutates_clips ~= false,
    "Overwrite.mutates_clips must NOT be false (same rationale)")
print("  ✓ Insert / Overwrite specs are not classified as movement")

print("\n✅ test_movement_targets_displayed_tab.lua passed")
