-- FR-002: ±nnn timecode offset entry (spec 025).
--
-- TWO surfaces under test:
--
--  1. timecode_entry.compute_action(prefix, value_frames, has_selection, current)
--     — the PURE dispatch decision (decision B: panel pre-parses, this does
--     no parsing). "=" navigates the playhead (SetPlayhead). "+"/"-" with a
--     selection delegates to NudgeSelection (direction + magnitude — the same
--     selection-aware dispatcher comma/period use, which ripples edges and
--     owns undo); "+"/"-" with no selection nudges the playhead. Expected
--     values come from FR-002 semantics + TC math (30fps: 1 second = 30
--     frames), never from tracing.
--
--  2. IncrementTimecode / DecrementTimecode / GoToTimecode — activation
--     commands that (a) ask playback to stop and (b) ask the view to open the
--     TC field, both via signals. They perform NO move themselves.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local command_manager = require("core.command_manager")
local Signals         = require("core.signals")
local timecode_entry  = require("core.commands.timecode_entry")
local ripple_layout   = require("synthetic.helpers.ripple_layout")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_timecode_entry_commands.lua ===")

-- ── compute_action: absolute go-to ("=") ─────────────────────────────────
-- 1 minute at 30fps = 60 × 30 = 1800 frames. Absolute mode navigates the
-- playhead regardless of selection.
do
    local FRAMES_PER_MIN = 60 * 30                       -- TC math, not code
    local action = timecode_entry.compute_action("=", FRAMES_PER_MIN, true, 99)
    assert(action.command == "SetPlayhead", "= → SetPlayhead, got " .. tostring(action.command))
    assert(action.args.playhead_position == 1800,
        "= 0:01:00:00 @30fps → playhead_position 1800, got " .. tostring(action.args.playhead_position))
    assert(action.args.frame == nil, "arg must be playhead_position, NOT frame")
    print("  PASS: '=' navigates playhead to absolute frame (ignores selection)")
end

-- ── compute_action: relative with NO selection → move the playhead ───────
do
    local action = timecode_entry.compute_action("+", 10, false, 500)
    assert(action.command == "SetPlayhead", "+ no selection → SetPlayhead")
    assert(action.args.playhead_position == 510,
        "playhead 500 + 10 = 510, got " .. tostring(action.args.playhead_position))
    print("  PASS: '+10' with no selection nudges playhead 500→510")
end

-- ── compute_action: relative WITH selection → NudgeSelection ─────────────
-- Forward by 10 frames: direction +1, magnitude 10. NudgeSelection reads the
-- live selection itself and ripples edges / nudges clips — we pass only the
-- direction + magnitude (no clip ids or edges here).
do
    local action = timecode_entry.compute_action("+", 10, true, 500)
    assert(action.command == "NudgeSelection", "+ with selection → NudgeSelection, got " .. tostring(action.command))
    assert(action.args.direction == 1, "forward → direction +1, got " .. tostring(action.args.direction))
    assert(action.args.magnitude == 10, "magnitude 10, got " .. tostring(action.args.magnitude))
    print("  PASS: '+10' with a selection → NudgeSelection(dir +1, mag 10)")
end

-- ── compute_action: +00:00:01:00 (=30f) with selection → magnitude 30 ────
do
    local action = timecode_entry.compute_action("+", 30, true, 500)
    assert(action.command == "NudgeSelection" and action.args.magnitude == 30 and action.args.direction == 1,
        "'+00:00:01:00'(=30f) with selection → NudgeSelection(dir +1, mag 30)")
    print("  PASS: '+00:00:01:00'(=30f) with a selection → NudgeSelection(+1, 30)")
end

-- ── compute_action: negative offset → direction -1 / playhead back ───────
do
    local with_sel = timecode_entry.compute_action("-", -5, true, 500)
    assert(with_sel.command == "NudgeSelection" and with_sel.args.direction == -1 and with_sel.args.magnitude == 5,
        "'-5' with selection → NudgeSelection(dir -1, mag 5)")
    local no_sel = timecode_entry.compute_action("-", -5, false, 500)
    assert(no_sel.command == "SetPlayhead" and no_sel.args.playhead_position == 495,
        "'-5' no selection → playhead 500→495")
    print("  PASS: negative offset → NudgeSelection(-1,5) with selection / playhead 500→495 without")
end

-- ── compute_action: bare prefix (zero offset) over a selection → no-op ────
-- NudgeSelection requires a positive magnitude; a zero-frame nudge of a
-- selection moves nothing, so compute_action returns nil (no command).
do
    local action = timecode_entry.compute_action("+", 0, true, 500)
    assert(action == nil, "zero offset with a selection is a no-op (nil action)")
    -- But a zero offset with NO selection is a harmless playhead re-set.
    local no_sel = timecode_entry.compute_action("+", 0, false, 500)
    assert(no_sel.command == "SetPlayhead" and no_sel.args.playhead_position == 500,
        "zero offset, no selection → playhead stays at 500")
    print("  PASS: bare '+' (zero offset) is a no-op over a selection")
end

-- ── compute_action: assert paths ─────────────────────────────────────────
do
    local ok1, err1 = pcall(timecode_entry.compute_action, "*", 10, false, 0)
    assert(not ok1, "invalid prefix must assert")
    assert(tostring(err1):find("compute_action"), "error names the function: " .. tostring(err1))

    local ok2, err2 = pcall(timecode_entry.compute_action, "+", 10, false, nil)
    assert(not ok2, "relative move with no selection AND no current_frame must assert")
    assert(tostring(err2):find("current_frame"), "error names current_frame: " .. tostring(err2))

    local ok3 = pcall(timecode_entry.compute_action, "+", 10.5, false, 0)
    assert(not ok3, "non-integer value_frames must assert")

    local ok4 = pcall(timecode_entry.compute_action, "+", 10, nil, 0)
    assert(not ok4, "non-boolean has_selection must assert")
    print("  PASS: bad prefix / missing current_frame / non-integer frame / bad has_selection all assert")
end

-- ── Activation commands emit stop + activate signals with the right prefix ─
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_timecode_entry_commands.db",
        tracks = { order = {"v1"}, v1 = {id="trk_v1", name="V1", track_type="VIDEO", track_index=1, enabled=1} },
        clips = { order = {} },
    })
    local PROJECT, SEQ = layout.project_id, layout.sequence_id

    local function run_and_capture(command_name)
        local stop_count, activate_prefix = 0, nil
        local c1 = Signals.connect("request_stop_playback", function() stop_count = stop_count + 1 end)
        local c2 = Signals.connect("tc_entry_activate", function(prefix) activate_prefix = prefix end)
        local r = command_manager.execute(command_name, {project_id = PROJECT, sequence_id = SEQ})
        Signals.disconnect(c1)
        Signals.disconnect(c2)
        assert(r and r.success, command_name .. " failed: " .. tostring(r and r.error_message))
        assert(stop_count == 1, command_name .. " must request playback stop exactly once")
        return activate_prefix
    end

    assert(run_and_capture("IncrementTimecode") == "+", "IncrementTimecode activates with '+'")
    assert(run_and_capture("DecrementTimecode") == "-", "DecrementTimecode activates with '-'")
    assert(run_and_capture("GoToTimecode")      == "=", "GoToTimecode activates with '='")
    print("  PASS: Increment/Decrement/GoTo emit stop + activate('+'/'-'/'=')")

    -- ── Assert paths: the command's own context guard fires loudly ───────
    -- Tested at the executor function directly: command_manager.execute
    -- auto-injects the active sequence_id from context, so the guard is
    -- exercised by calling the module entrypoint with the arg absent.
    local ok_seq, err_seq = pcall(timecode_entry.increment, {project_id = PROJECT})
    assert(not ok_seq, "missing sequence_id must assert")
    assert(tostring(err_seq):find("IncrementTimecode"),
        "error message names the command: " .. tostring(err_seq))

    local ok_proj, err_proj = pcall(timecode_entry.go_to, {sequence_id = SEQ})
    assert(not ok_proj, "missing project_id must assert")
    assert(tostring(err_proj):find("GoToTimecode"),
        "error message names the command: " .. tostring(err_proj))
    print("  PASS: missing project_id / sequence_id assert loudly with the command name")

    layout:cleanup()
end

print("\n✅ test_timecode_entry_commands.lua passed")
