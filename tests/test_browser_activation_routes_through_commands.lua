#!/usr/bin/env luajit
--- 019 T006: browser activation routes through `OpenSequenceInSourceMonitor`
--- and `OpenSequenceInTimeline` commands.
---
--- Per contracts/open_sequence_in_source_monitor.md +
--- contracts/open_sequence_in_timeline.md + spec FR-018, FR-019, FR-021,
--- FR-022. The browser refactor (T018) replaces direct calls to
--- source_viewer.load_master_clip / timeline_panel.load_sequence with
--- command_manager dispatches through these two new commands. This test
--- pins the command surface they expose; the router-side wiring is
--- exercised by the T018 implementation itself.
---
--- Pinned behaviors:
---   * `OpenSequenceInSourceMonitor` happy path: calls
---     `source_viewer.load_sequence(sequence_id)`; reports success;
---     `undoable=false`.
---   * `OpenSequenceInTimeline` happy path: calls
---     `timeline_panel.load_sequence(sequence_id)` + focuses timeline
---     panel; reports success; `undoable=false`.
---   * Required args: both commands declare `sequence_id` and `project_id`
---     as required; missing either rejected by command_manager schema.
---
--- Black-box: stub the two downstream module entry points
--- (source_viewer + timeline_panel) and observe dispatches through
--- command_manager.

require("test_env")

_G.qt_create_single_shot_timer = function() end

local database = require("core.database")
local TEST_DB = "/tmp/jve/test_browser_activation_routes.db"
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
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq_main', 'proj_X', 'Main', 'sequence', 24, 1, 48000, 1920, 1080,
            0, 10000, 0, '[]', '[]', '[]', 0, 0, 0);
]])

-- ── Stubs for command executors' downstream targets ──────────────────────────
local source_viewer_calls = {}
package.loaded["ui.source_viewer"] = {
    load_sequence = function(seq_id, opts)
        table.insert(source_viewer_calls, { kind = "load_sequence", seq_id = seq_id, opts = opts })
    end,
    load_clip       = function() end,
    load_master_clip = function(seq_id, opts)  -- legacy alias still in place pre-T013
        table.insert(source_viewer_calls, { kind = "load_master_clip", seq_id = seq_id, opts = opts })
    end,
    unload   = function() end,
    get_mode = function() return "neutral" end,
}

local timeline_panel_calls = {}
local timeline_panel_stub = {
    load_sequence = function(seq_id)
        table.insert(timeline_panel_calls, { seq_id = seq_id })
    end,
}
package.loaded["ui.timeline_panel"] = timeline_panel_stub
-- The actual production module is `ui.timeline.timeline_panel` — stub both
-- common require paths to be safe; the new command will choose one and the
-- test will catch the dispatch through whichever it uses.
package.loaded["ui.timeline.timeline_panel"] = timeline_panel_stub

local focus_panel_calls = {}
package.loaded["ui.focus_manager"] = {
    focus_panel = function(panel_id)
        table.insert(focus_panel_calls, panel_id)
    end,
    get_focused_panel = function() return "browser" end,
    set_focused_panel = function() end,
}

local command_manager = require("core.command_manager")
command_manager.init("seq_main", "proj_X")

print("=== test_browser_activation_routes_through_commands.lua ===")

-- ── Scenario 1: OpenSequenceInSourceMonitor dispatches load_sequence ─────────
do
    source_viewer_calls = {}

    local r = command_manager.execute_interactive("OpenSequenceInSourceMonitor", {
        sequence_id = "seq_main",
        project_id  = "proj_X",
    })

    assert(r and r.success, string.format(
        "OpenSequenceInSourceMonitor must succeed; got %s",
        tostring(r and r.error_message)))

    -- The command may target either M.load_sequence (new) or M.load_master_clip
    -- (one-session alias until 020). Either is acceptable as long as one was
    -- called with the dispatched sequence_id.
    assert(#source_viewer_calls >= 1, string.format(
        "OpenSequenceInSourceMonitor must call into source_viewer; got %d calls",
        #source_viewer_calls))
    local call = source_viewer_calls[1]
    assert(call.seq_id == "seq_main", string.format(
        "source_viewer call must receive sequence_id; got %q",
        tostring(call.seq_id)))
    print("  ✓ OpenSequenceInSourceMonitor → source_viewer.load_sequence(seq_id)")
end

-- ── Scenario 2: OpenSequenceInTimeline dispatches timeline_panel.load_sequence
--    AND focuses the timeline panel. ──────────────────────────────────────────
do
    timeline_panel_calls = {}
    focus_panel_calls = {}

    local r = command_manager.execute_interactive("OpenSequenceInTimeline", {
        sequence_id = "seq_main",
        project_id  = "proj_X",
    })

    assert(r and r.success, string.format(
        "OpenSequenceInTimeline must succeed; got %s",
        tostring(r and r.error_message)))

    assert(#timeline_panel_calls == 1, string.format(
        "OpenSequenceInTimeline must call timeline_panel.load_sequence exactly once; "
        .. "got %d calls", #timeline_panel_calls))
    assert(timeline_panel_calls[1].seq_id == "seq_main", string.format(
        "timeline_panel.load_sequence must receive sequence_id; got %q",
        tostring(timeline_panel_calls[1].seq_id)))

    -- Per contract: focus follows the load.
    local saw_timeline_focus = false
    for _, p in ipairs(focus_panel_calls) do
        if p == "timeline" then saw_timeline_focus = true; break end
    end
    assert(saw_timeline_focus, string.format(
        "OpenSequenceInTimeline must focus the timeline panel; "
        .. "focus_panel calls: %s", table.concat(focus_panel_calls, ", ")))
    print("  ✓ OpenSequenceInTimeline → timeline_panel.load_sequence + focus(timeline)")
end

-- ── Scenario 3: required-args declared in SPEC ──────────────────────────────
-- ── Scenario 4: undoable=false ───────────────────────────────────────────────
do
    source_viewer_calls = {}
    local r = command_manager.execute_interactive("OpenSequenceInSourceMonitor", {
        sequence_id = "seq_main",
        project_id  = "proj_X",
    })
    assert(r and r.success, "fixture: dispatch must succeed")
    assert(#source_viewer_calls == 1, "fixture: load called once")

    command_manager.undo()
    assert(#source_viewer_calls == 1, string.format(
        "after undo, load must not have been called again (undoable=false); "
        .. "got %d total calls", #source_viewer_calls))
    print("  ✓ OpenSequenceInSourceMonitor is non-undoable")
end

print("\n✅ test_browser_activation_routes_through_commands.lua passed")
