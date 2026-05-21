#!/usr/bin/env luajit
--- Regression: in source-viewer live-bound mode, the I/O keys must trim
--- the loaded clip's source_in/source_out — NOT mutate sequence marks.
---
--- 019 architecture: the keymap routes I/O in @source_monitor scope to
--- the SetMarkAndTrimIfClip command (a sibling of SetMark, NOT a hidden
--- branch inside it). In live_bound_clip mode it dispatches the active
--- trim command (Overwrite or Ripple per edit_mode.get_trim_mode()).
--- In staged_sequence mode it sets the staged sequence's mark.

require("test_env")

_G.qt_create_single_shot_timer = function() end

-- Stub focus_manager + transport so the source-viewer flow runs without
-- real Qt focus / playback wiring.
package.loaded["ui.focus_manager"] = { focus_panel = function(_) end }
package.loaded["core.playback.transport"] = {
    bind_role_to_sequence = function(_, _) end,
    is_bootstrapped       = function() return false end,
}

-- Stub a source monitor that source_viewer.load_clip can ask panel_manager
-- for. The monitor exposes a real-ish engine with get_position() returning
-- the test-controlled playhead.
local source_monitor_playhead = 150  -- frame in source sequence's space
local fake_source_monitor = {
    sequence_id = nil,
    sequence    = nil,
    engine      = { get_position = function() return source_monitor_playhead end },
}
function fake_source_monitor:load_sequence(seq_id)
    self.sequence_id = seq_id
    local Sequence = require("models.sequence")
    self.sequence = Sequence.load(seq_id)
end
function fake_source_monitor:unload()
    self.sequence_id = nil
    self.sequence = nil
end
function fake_source_monitor:_set_title(_) end
function fake_source_monitor:seek_to_frame(_) end  -- load_clip parks engine at clip.source_in (FR-003)
function fake_source_monitor:get_loaded_master_seq_id() return self.sequence_id end

package.loaded["ui.panel_manager"] = {
    get_sequence_monitor        = function(view_id)
        if view_id == "source_monitor" then return fake_source_monitor end
        return nil
    end,
    -- get_active_sequence_monitor is what the command's playhead-default
    -- branch queries; with the source_monitor focused, it returns ours.
    get_active_sequence_monitor = function() return fake_source_monitor end,
}

-- ── Build the DB ─────────────────────────────────────────────────────────────

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Clip            = require("models.clip")
local Sequence        = require("models.sequence")

local TEST_DB = "/tmp/jve/test_set_mark_and_trim_if_clip_routes_to_trim.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);

    -- rec: timeline that owns the clip. msa: source sequence the clip
    -- references (kind=master so source_viewer.load_clip's owner-check
    -- doesn't trip).
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames,
        playhead_frame, mark_in_frame, mark_out_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES
      ('rec', 'proj', 'Rec',     'sequence', 24, 1, 48000, 1920, 1080,
       0, 1000, 0, NULL, NULL, '[]', '[]', '[]', 0, 0, 0),
      ('msa', 'proj', 'Source',  'master',   24, 1, NULL,  1920, 1080,
       0, 300,  0, NULL, NULL, '[]', '[]', '[]', 0, 0, 0);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('rv1', 'rec', 'V1', 'VIDEO', 1, 1);

    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
        track_id, source_in_frame, source_out_frame, sequence_start_frame,
        duration_frames, fps_mismatch_policy, name, enabled, volume,
        playhead_frame, created_at, modified_at)
    VALUES ('c1', 'proj', 'rec', 'msa', 'rv1', 100, 300, 0, 200,
            'resample', 'AlphaClip', 1, 1.0, 0, 0, 0);
]])

command_manager.init("rec", "proj")

-- Force fresh load of source_viewer so it picks up our panel_manager stub.
package.loaded["ui.source_viewer"] = nil
local source_viewer = require("ui.source_viewer")
local edit_mode     = require("core.edit_mode")
edit_mode.set_trim_mode("overwrite")  -- default; explicit for the test

print("=== test_set_mark_and_trim_if_clip_routes_to_trim.lua ===")

-- ── Enter live-bound mode ────────────────────────────────────────────────────
source_viewer.load_clip("c1", { skip_focus = true })
assert(source_viewer.get_mode() == "live_bound_clip",
    "fixture: source_viewer must be in live_bound_clip mode")

-- Snapshot what should NOT change.
local rec_before = Sequence.load("rec")
local msa_before = Sequence.load("msa")
assert(rec_before.mark_in == nil, "fixture: rec.mark_in starts nil")
assert(msa_before.mark_in == nil, "fixture: msa.mark_in starts nil")

local c1_before = Clip.load("c1")
assert(c1_before.source_in == 100, "fixture: c1.source_in starts 100")
assert(c1_before.source_out == 300, "fixture: c1.source_out starts 300")

-- ── Dispatch the same way the I-key keymap does ─────────────────────────────
-- Keymap (019): `"I" = "SetMarkAndTrimIfClip in @source_monitor"`. Source
-- monitor focused → command_manager auto-injects sequence_id from the
-- active scope. We omit `frame` so the command falls back to the active
-- monitor's engine playhead (150).
local result = command_manager.execute_interactive("SetMarkAndTrimIfClip", {
    _positional = { "in" },
})
assert(result and result.success,
    "SetMarkAndTrimIfClip dispatch must succeed; got " .. tostring(result and result.success))

-- ── Assertions: clip's source_in moved to playhead; sequence marks untouched ─

local c1_after = Clip.load("c1")
assert(c1_after.source_in == 150, string.format(
    "BUG: live-bound 'in' must move clip's source_in to the playhead "
    .. "(150) via OverwriteTrimEdge; got %s",
    tostring(c1_after.source_in)))
assert(c1_after.source_out == 300, string.format(
    "BUG: live-bound 'in' must leave clip's source_out alone; got %s",
    tostring(c1_after.source_out)))
print("  ✓ live-bound 'in' moves clip.source_in to the playhead")

local rec_after = Sequence.load("rec")
local msa_after = Sequence.load("msa")
assert(rec_after.mark_in == nil, string.format(
    "BUG: live-bound dispatch must NOT mutate the rec timeline's mark_in; got %s",
    tostring(rec_after.mark_in)))
assert(msa_after.mark_in == nil, string.format(
    "BUG: live-bound dispatch must NOT mutate the source sequence's mark_in; got %s",
    tostring(msa_after.mark_in)))
print("  ✓ no sequence marks were touched")

-- ── Bonus: same flow for OUT key, with a non-zero baseline ────────────────────
source_monitor_playhead = 280

local result2 = command_manager.execute_interactive("SetMarkAndTrimIfClip", {
    _positional = { "out" },
})
assert(result2 and result2.success,
    "SetMarkAndTrimIfClip 'out' dispatch must succeed; got " .. tostring(result2 and result2.success))

-- After previous trim, c1.source_in was 150, source_out 300. Now setting
-- source_out to 280 should shrink the tail.
local c1_after2 = Clip.load("c1")
assert(c1_after2.source_out == 280, string.format(
    "live-bound 'out' must move clip's source_out to the playhead "
    .. "(280); got %s", tostring(c1_after2.source_out)))
assert(c1_after2.source_in == 150,
    "source_in must remain unchanged on OUT trim")
print("  ✓ live-bound 'out' moves clip.source_out to the playhead")

-- ── Plain SetMark stays pure: timeline scope, sets seq row marks ─────────────
-- Routed via the same command_manager surface to prove SetMark itself has
-- no hidden live-bound branch anymore.
source_monitor_playhead = 50
local result3 = command_manager.execute_interactive("SetMark", {
    _positional = { "in" },
    sequence_id = "rec",
    frame       = 50,
})
assert(result3 and result3.success, "plain SetMark dispatch must succeed")
local rec_final = Sequence.load("rec")
assert(rec_final.mark_in == 50,
    "plain SetMark must mutate the addressed sequence row's mark_in even while "
    .. "source_viewer is in live_bound_clip mode; got " .. tostring(rec_final.mark_in))
local c1_final = Clip.load("c1")
assert(c1_final.source_in == 150,
    "plain SetMark must NOT touch the live-bound clip; got source_in="
    .. tostring(c1_final.source_in))
print("  ✓ plain SetMark stays pure (no hidden trim branch)")

-- ── Collapse rejection: setting IN at-or-beyond OUT must NOT mutate ─────────
-- TSO 2026-05-20: SetMarkAndTrimIfClip used to forward bad deltas straight
-- to OverwriteTrimEdge / Clip.update, which then tripped the SQL
-- CHECK(duration_frames > 0) with an opaque message. The command-layer
-- precondition must catch this gracefully (log + return) without invoking
-- the trim command — wrong-key presses are UX, not invariant violations.
do
    local c_before = Clip.load("c1")
    assert(c_before.source_in == 150 and c_before.source_out == 280,
        "fixture: c1 should still be (150, 280) from prior scenarios")

    -- Set IN at exactly OUT → would collapse duration to 0.
    source_monitor_playhead = 280
    local r = command_manager.execute_interactive("SetMarkAndTrimIfClip",
        { _positional = { "in" } })
    assert(r and r.success,
        "SetMarkAndTrimIfClip must report success (UX no-op, not an error)")

    local c_after = Clip.load("c1")
    assert(c_after.source_in  == 150, string.format(
        "collapse-mark IN must NOT mutate source_in; got %s",
        tostring(c_after.source_in)))
    assert(c_after.source_out == 280, string.format(
        "collapse-mark IN must NOT mutate source_out; got %s",
        tostring(c_after.source_out)))
    assert(c_after.duration   == c_before.duration, string.format(
        "collapse-mark IN must NOT mutate duration; got %s",
        tostring(c_after.duration)))

    -- Set IN past OUT → would invert (negative duration).
    source_monitor_playhead = 281
    local r2 = command_manager.execute_interactive("SetMarkAndTrimIfClip",
        { _positional = { "in" } })
    assert(r2 and r2.success,
        "SetMarkAndTrimIfClip must report success for past-OUT IN press")
    local c_after2 = Clip.load("c1")
    assert(c_after2.source_in  == 150 and c_after2.source_out == 280,
        "past-OUT IN must NOT mutate the clip")

    -- Symmetric for OUT before IN.
    source_monitor_playhead = 150
    local r3 = command_manager.execute_interactive("SetMarkAndTrimIfClip",
        { _positional = { "out" } })
    assert(r3 and r3.success, "OUT at IN press must report success")
    local c_after3 = Clip.load("c1")
    assert(c_after3.source_in  == 150 and c_after3.source_out == 280,
        "OUT at IN must NOT mutate the clip")

    print("  ✓ collapse / inversion presses log + no-op (no model mutation)")
end

print("\n✅ test_set_mark_and_trim_if_clip_routes_to_trim.lua passed")
