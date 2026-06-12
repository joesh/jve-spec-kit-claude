-- Integration: SetTimelineDecodeMode command dispatch.
--
-- REPLACES (from tests/synthetic/lua/):
--   test_set_timeline_decode_mode_command.lua
--
-- SCENARIOS KEPT:
--   DR-1  SetTimelineDecodeMode("scrub") calls EMP.SET_DECODE_MODE("scrub").
--   DR-2  SetTimelineDecodeMode("park")  calls EMP.SET_DECODE_MODE("park").
--   DR-3  SetTimelineDecodeMode("play")  calls EMP.SET_DECODE_MODE("play").
--   DR-4  Unknown mode is rejected — EMP.SET_DECODE_MODE must NOT be called
--           with a bogus mode (no silent fallback).
--
-- SCENARIOS DROPPED:
--   None.
--
-- OPEN QUESTIONS:
--   None.
--
-- NOTE: This test wraps the real EMP.SET_DECODE_MODE binding as a
-- pass-through observer (wrap/unwrap) — it delegates to the original,
-- counting calls and the mode string passed. This is NOT a stub; the
-- real binding still executes. Observation-only instrumentation is
-- explicitly allowed per the task description.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_decode_mode_command.lua (integration) ===")

require("test_env")
local database        = require("core.database")
local command_manager = require("core.command_manager")

-- ── DB bootstrap ─────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_decode_mode_cmd_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
              %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
      VALUES ('seq1', 'p', 'Main', 'sequence', 30, 1, 48000, 1920, 1080,
              0, 0, 300, 0, %d, %d);
]], now, now, now, now)))

-- command_manager needs a sequence context + displayed-tab stub (post-H1).
require("test_env").install_displayed_tab_stub({ sequence_id = "seq1" })
command_manager.init("seq1", "p")
command_manager.activate_timeline_stack("seq1")
while pcall(command_manager.end_command_event) do end

-- ── Wrap EMP.SET_DECODE_MODE as a pass-through observer ──────────────────────
-- Counts invocations and records the mode string. Delegates to the real
-- binding so the C++ decoder state is actually updated. On unwrap the
-- original is restored, leaving the binding clean for subsequent tests.
local qt = require("core.qt_constants")
local set_mode_log = {}
local orig_set_decode_mode = qt.EMP.SET_DECODE_MODE
qt.EMP.SET_DECODE_MODE = function(mode)
    set_mode_log[#set_mode_log + 1] = mode
    if orig_set_decode_mode then orig_set_decode_mode(mode) end
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-1/2/3  Known modes are dispatched to EMP.SET_DECODE_MODE
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-1/2/3) known modes dispatched to EMP --")
for _, mode in ipairs({ "scrub", "park", "play" }) do
    set_mode_log = {}
    local result = command_manager.execute("SetTimelineDecodeMode", { mode = mode })
    assert(result and result.success, string.format(
        "SetTimelineDecodeMode('%s') must succeed; result=%s err=%s",
        mode, tostring(result and result.success),
        tostring(result and result.error_message)))
    assert(#set_mode_log == 1, string.format(
        "SetTimelineDecodeMode('%s') must call EMP.SET_DECODE_MODE exactly once; "
        .. "got %d calls", mode, #set_mode_log))
    assert(set_mode_log[1] == mode, string.format(
        "EMP.SET_DECODE_MODE called with '%s', expected '%s'",
        tostring(set_mode_log[1]), mode))
    print(string.format("  PASS DR-%d: mode '%s' dispatched to EMP",
        ({ scrub = 1, park = 2, play = 3 })[mode], mode))
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-4  Unknown mode is rejected — EMP must NOT be called
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-4) unknown mode rejected --")
do
    set_mode_log = {}
    -- command_manager wraps executor errors; observe the side-effect absence.
    pcall(command_manager.execute, "SetTimelineDecodeMode", { mode = "bogus" })
    assert(#set_mode_log == 0, string.format(
        "Unknown mode 'bogus' must NOT reach EMP.SET_DECODE_MODE (no silent fallback); "
        .. "got %d calls, last=%s",
        #set_mode_log, tostring(set_mode_log[#set_mode_log])))
    print("  PASS DR-4: unknown mode rejected — EMP not called")
end

-- ── Restore original binding ─────────────────────────────────────────────────
qt.EMP.SET_DECODE_MODE = orig_set_decode_mode

print("\nPASS test_decode_mode_command.lua")
os.exit(0)
