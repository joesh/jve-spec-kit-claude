#!/usr/bin/env luajit
--- 019 T008c: ClearMarks / ClearMarkIn / ClearMarkOut are disabled when
--- source_viewer is in live-bound mode (FR-016c).
---
--- A clip's source range is required (NOT NULL columns); clearing has no
--- defined destination, so the three ClearMark* commands no-op (with a
--- logged event) when dispatched while source_viewer is in live-bound
--- mode. Staged mode behavior is UNCHANGED.
---
--- Pinned behaviors:
---   * Live-bound mode + ClearMarks → no mutation to clip.source_in/out
---     AND no mutation to the source sequence's mark_in/mark_out columns.
---   * Live-bound mode + ClearMarkIn → no mutation.
---   * Live-bound mode + ClearMarkOut → no mutation.
---   * Staged mode + ClearMarks → existing behavior: sequence marks cleared.
---
--- Black-box: real DB, real set_marks executors, stubbed source_viewer
--- so we can flip the mode without setting up the actual live-bound
--- machinery (that's T013's concern).

require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
    get_sequence_monitor         = function() return nil end,
}

-- Stub source_viewer.get_mode() so the executor's branch is testable
-- without the full live-bound machinery in place.
local viewer_mode = "staged_sequence"
package.loaded["ui.source_viewer"] = {
    get_mode = function() return viewer_mode end,
    load_sequence = function() end, load_clip = function() end,
    load_master_clip = function() end, unload = function() end,
}

local database        = require("core.database")
local command_manager = require("core.command_manager")

local TEST_DB = "/tmp/jve/test_clear_marks_disabled_in_live_bound.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))
db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj_X', 'P', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        mark_in_frame, mark_out_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq_S', 'proj_X', 'S', 'sequence', 24, 1, 48000, 1920, 1080,
            0, 1000, 0, 100, 300,
            '[]', '[]', '[]', 0, 0, 0);
]])
command_manager.init("seq_S", "proj_X")

local function read_seq_marks()
    local stmt = db:prepare("SELECT mark_in_frame, mark_out_frame FROM sequences WHERE id = 'seq_S'")
    assert(stmt:exec())
    assert(stmt:next())
    local mi, mo = stmt:value(0), stmt:value(1)
    stmt:finalize()
    return mi, mo
end

local function reset_marks()
    db:exec("UPDATE sequences SET mark_in_frame=100, mark_out_frame=300 WHERE id='seq_S'")
end

print("=== test_clear_marks_disabled_in_live_bound.lua ===")

-- ── Scenario 1: live-bound mode + ClearMarks → no mutation ───────────────────
do
    reset_marks()
    viewer_mode = "live_bound_clip"

    local r = command_manager.execute_interactive("ClearMarks", {
        sequence_id = "seq_S",
        project_id  = "proj_X",
    })
    -- The command "succeeds" (no error), but no mutation happens.
    assert(r and r.success, "ClearMarks dispatch must return success even when no-op'd")

    local mi, mo = read_seq_marks()
    assert(mi == 100 and mo == 300, string.format(
        "live-bound ClearMarks must NOT mutate sequence marks; "
        .. "expected (100, 300), got (%s, %s)", tostring(mi), tostring(mo)))
    print("  ✓ live-bound + ClearMarks: no mutation")
end

-- ── Scenario 2: live-bound mode + ClearMarkIn → no mutation ──────────────────
do
    reset_marks()
    viewer_mode = "live_bound_clip"

    command_manager.execute_interactive("ClearMarkIn", {
        sequence_id = "seq_S",
        project_id  = "proj_X",
    })
    local mi, _ = read_seq_marks()
    assert(mi == 100, string.format(
        "live-bound ClearMarkIn must NOT mutate mark_in; got %s", tostring(mi)))
    print("  ✓ live-bound + ClearMarkIn: no mutation")
end

-- ── Scenario 3: live-bound mode + ClearMarkOut → no mutation ─────────────────
do
    reset_marks()
    viewer_mode = "live_bound_clip"

    command_manager.execute_interactive("ClearMarkOut", {
        sequence_id = "seq_S",
        project_id  = "proj_X",
    })
    local _, mo = read_seq_marks()
    assert(mo == 300, string.format(
        "live-bound ClearMarkOut must NOT mutate mark_out; got %s", tostring(mo)))
    print("  ✓ live-bound + ClearMarkOut: no mutation")
end

-- ── Scenario 4: staged mode + ClearMarks → marks ARE cleared (regression) ────
-- Pins that staged-mode behavior is preserved — the disable is mode-scoped.
do
    reset_marks()
    viewer_mode = "staged_sequence"

    local r = command_manager.execute_interactive("ClearMarks", {
        sequence_id = "seq_S",
        project_id  = "proj_X",
    })
    assert(r and r.success, "fixture: staged ClearMarks must succeed")

    local mi, mo = read_seq_marks()
    assert(mi == nil and mo == nil, string.format(
        "staged mode + ClearMarks must clear both marks (existing behavior); "
        .. "got (%s, %s)", tostring(mi), tostring(mo)))
    print("  ✓ staged mode + ClearMarks: marks cleared (unchanged)")
end

print("\n✅ test_clear_marks_disabled_in_live_bound.lua passed")
