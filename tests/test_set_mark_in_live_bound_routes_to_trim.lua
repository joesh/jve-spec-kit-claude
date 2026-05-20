#!/usr/bin/env luajit
--- Regression: I/O keys in source viewer's live-bound mode must trim the
--- loaded clip's source_in/source_out — NOT mutate sequence marks.
---
--- The bug shipped on master (2026-05-20, commit 6b86c7bd): live-bound
--- mode's mark-dispatch path (source_viewer.handle_mark_key) was
--- defined but never wired to any key. The keymap routes "I" to the
--- SetMark command, which mutates the sequence row's mark_in/mark_out
--- column directly. In live-bound mode that's wrong — the user expects
--- the clip's source range to shrink/grow.
---
--- TDD: this test MUST fail on the buggy code (current master). Then
--- patch SetMark to detect live-bound mode and delegate to
--- source_viewer.handle_mark_key (which dispatches the proper
--- OverwriteTrimEdge / RippleTrimEdge per edit_mode.get_trim_mode()).

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
function fake_source_monitor:get_loaded_master_seq_id() return self.sequence_id end

package.loaded["ui.panel_manager"] = {
    get_sequence_monitor        = function(view_id)
        if view_id == "source_monitor" then return fake_source_monitor end
        return nil
    end,
    -- get_active_sequence_monitor is what SetMark's playhead-default branch
    -- queries; with the source_monitor focused, it returns ours.
    get_active_sequence_monitor = function() return fake_source_monitor end,
}

-- ── Build the DB ─────────────────────────────────────────────────────────────

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Clip            = require("models.clip")
local Sequence        = require("models.sequence")

local TEST_DB = "/tmp/jve/test_set_mark_in_live_bound_routes_to_trim.db"
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

print("=== test_set_mark_in_live_bound_routes_to_trim.lua ===")

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

-- ── Dispatch the same way the I-key keymap does: SetMark "in" ────────────────
-- The keymap is `"I" = "SetMark in @timeline @source_monitor @timeline_monitor"`.
-- Source monitor focused → command_manager auto-injects sequence_id from
-- the active scope. We omit `frame` so SetMark falls back to the active
-- monitor's engine playhead (150).
local result = command_manager.execute_interactive("SetMark", {
    _positional = { "in" },
})
assert(result and result.success,
    "SetMark dispatch must succeed; got " .. tostring(result and result.success))

-- ── Assertions: clip's source_in moved to playhead; sequence marks untouched ─

local c1_after = Clip.load("c1")
assert(c1_after.source_in == 150, string.format(
    "BUG: live-bound SetMark 'in' must move clip's source_in to the playhead "
    .. "(150) via OverwriteTrimEdge; got %s",
    tostring(c1_after.source_in)))
assert(c1_after.source_out == 300, string.format(
    "BUG: live-bound SetMark 'in' must leave clip's source_out alone; got %s",
    tostring(c1_after.source_out)))
print("  ✓ live-bound SetMark 'in' moves clip.source_in to the playhead")

local rec_after = Sequence.load("rec")
local msa_after = Sequence.load("msa")
assert(rec_after.mark_in == nil, string.format(
    "BUG: live-bound SetMark must NOT mutate the rec timeline's mark_in; got %s",
    tostring(rec_after.mark_in)))
assert(msa_after.mark_in == nil, string.format(
    "BUG: live-bound SetMark must NOT mutate the source sequence's mark_in; got %s",
    tostring(msa_after.mark_in)))
print("  ✓ no sequence marks were touched")

-- ── Bonus: same flow for OUT key, with a non-zero baseline ────────────────────
source_monitor_playhead = 280

local result2 = command_manager.execute_interactive("SetMark", {
    _positional = { "out" },
})
assert(result2 and result2.success,
    "SetMark 'out' dispatch must succeed; got " .. tostring(result2 and result2.success))

-- After previous trim, c1.source_in was 150, source_out 300. Now setting
-- source_out to 280 should shrink the tail.
local c1_after2 = Clip.load("c1")
assert(c1_after2.source_out == 280, string.format(
    "live-bound SetMark 'out' must move clip's source_out to the playhead "
    .. "(280); got %s", tostring(c1_after2.source_out)))
assert(c1_after2.source_in == 150,
    "source_in must remain unchanged on OUT trim")
print("  ✓ live-bound SetMark 'out' moves clip.source_out to the playhead")

print("\n✅ test_set_mark_in_live_bound_routes_to_trim.lua passed")
