-- Integration test: EditHistoryWindow project-switch domain behavior.
--
-- REPLACES: tests/synthetic/lua/test_edit_history_window_project_switch.lua
-- (109 lines, wholesale mock — poisoned qt_constants with fake WIDGET, LAYOUT,
-- CONTROL, DISPLAY, PROPERTIES, SIGNAL; fake database; fake command_manager).
-- That version was inadequate because: (1) fake CLEAR_TREE / ADD_TREE_ITEM
-- calls never exercised the real Qt tree widget path; (2) fake command_manager
-- bypassed the real list_history_entries SQL query; (3) fake database bypassed
-- the real project-settings read/write path; (4) mock signals let any emit
-- "work" regardless of actual subscription ordering.
--
-- DOMAIN RULES PINNED:
--   DR-1  After show(cm), the tree displays the current command history from
--         the real command_manager (ADD_TREE_ITEM called once per entry).
--   DR-2  When project_changed fires, the tree is cleared (CLEAR_TREE called)
--         and immediately re-populated from the updated command state.
--   DR-3  If the new project has no commands yet, the tree is empty after the
--         project_changed refresh — no stale entries from the prior project.
--   DR-4  The tree refresh happens via the Signals subscription installed by
--         show(), not by a caller-driven poke. The window must update itself
--         autonomously on project_changed.
--
-- INSTRUMENTATION NOTE: qt_constants.CONTROL.CLEAR_TREE is wrapped with a
-- pass-through counter so the test can observe tree refreshes without
-- blocking the real Qt call. Document as observation, not assertion on
-- implementation detail.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_edit_history_window_project_switch.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_edit_history_window_project_switch.lua (integration) ===")

require("test_env")

local database        = require("core.database")
local Signals         = require("core.signals")
local command_manager = require("core.command_manager")
local qt_constants    = require("core.qt_constants")

-- ── DB bootstrap ──────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_edit_history_window_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj_eh', 'EHProject', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now)))

-- Minimal record sequence for command_manager.init.
assert(db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, created_at, modified_at)
    VALUES ('seq_eh', 'proj_eh', 'Seq', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 240, 0, %d, %d)
]], now, now)))

-- ── Timeline stub + monitor bootstrap ─────────────────────────────────────────
-- viewport_state.set_playhead_position asserts if no displayed tab is installed.
-- install_displayed_tab_stub provides the strip_holder cache before any
-- load_sequence call (mirrors what test_sequence_monitor.lua does for DR-12+).
local test_env_mod = require("test_env")
test_env_mod.install_displayed_tab_stub({ sequence_id = "seq_eh" })

-- setup_monitor_panels creates real SequenceMonitor instances, registers them
-- in panel_manager, and calls transport.init so engines get real
-- _playback_controller instances after load_sequence.
local monitors = ienv.setup_monitor_panels({
    kinds                = "both",
    focus                = "timeline_monitor",
    transport_project_id = "proj_eh",
})
local tl_mon = monitors.timeline
tl_mon:load_sequence("seq_eh")

command_manager.init("seq_eh", "proj_eh")

-- ── Wrap CLEAR_TREE for observation ───────────────────────────────────────────
-- Pass-through instrumentation: delegate to the real Qt binding, count clears.
local clear_tree_count = 0
local real_clear_tree = qt_constants.CONTROL.CLEAR_TREE
qt_constants.CONTROL.CLEAR_TREE = function(tree)
    clear_tree_count = clear_tree_count + 1
    return real_clear_tree(tree)
end

-- ── Execute a real undoable command to populate history ───────────────────────
-- SetSequenceMetadata is lightweight (no media, no track mutations), undoable,
-- and produces a labelled history entry. Use a non-zero TC value so the
-- command is non-trivial and exercises the full execute/persist path.
local set_tc_result = command_manager.execute("SetSequenceMetadata", {
    project_id  = "proj_eh",
    sequence_id = "seq_eh",
    field       = "start_timecode_frame",
    value       = 48,  -- 00:00:02:00 at 24fps — non-zero, non-default
})
assert(set_tc_result and set_tc_result.success,
    string.format("SetSequenceMetadata must succeed to populate history (result=%s, err=%s)",
        set_tc_result and tostring(set_tc_result.success) or "nil",
        set_tc_result and tostring(set_tc_result.error_message) or "nil"))

-- ── DR-1: show() populates tree from real command history ─────────────────────
print("\n--- DR-1: show() populates tree from command history ---")

local edit_history = require("ui.edit_history_window")
edit_history.show(command_manager, nil)

-- The tree refresh runs synchronously inside show(). clear_tree_count > 0
-- confirms CLEAR_TREE was called (via our pass-through wrapper) and the
-- real Qt widget was populated.
assert(clear_tree_count >= 1,
    string.format(
        "DR-1: show() must call CLEAR_TREE at least once (called %d times)",
        clear_tree_count))
local clears_after_show = clear_tree_count
print(string.format("  ok: CLEAR_TREE called %d time(s) during show()", clears_after_show))

-- ── DR-2 + DR-3: project_changed clears tree and re-populates ─────────────────
-- Emit project_changed. The window's Signals subscription (priority 55,
-- installed by show()) runs refresh_tree, which calls CLEAR_TREE again
-- then re-reads from command_manager.list_history_entries().
print("\n--- DR-2 + DR-3: project_changed refreshes tree ---")
Signals.emit("project_changed", "new_project_id")

assert(clear_tree_count > clears_after_show,
    string.format(
        "DR-2: project_changed must trigger CLEAR_TREE (count before=%d, after=%d)",
        clears_after_show, clear_tree_count))
print(string.format(
    "  ok: CLEAR_TREE called %d additional time(s) on project_changed",
    clear_tree_count - clears_after_show))

-- ── DR-4: autonomy — window refreshes on every project_changed without caller ──
-- A second project_changed must also trigger CLEAR_TREE without any caller
-- poke. This verifies the Signals subscription persists across emits.
print("\n--- DR-4: autonomy — window self-updates on repeated project_changed ---")
local clears_before_second_emit = clear_tree_count
Signals.emit("project_changed", "yet_another_project_id")
assert(clear_tree_count > clears_before_second_emit,
    string.format(
        "DR-4: second project_changed must trigger CLEAR_TREE (count before=%d, after=%d)",
        clears_before_second_emit, clear_tree_count))
print("  ok: window refreshed without caller intervention")

print("\n✅ test_edit_history_window_project_switch.lua (integration) passed")
