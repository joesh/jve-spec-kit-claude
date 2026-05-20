#!/usr/bin/env luajit
--- 019 T008b: SequenceMonitor playback-range diverges by source_viewer mode.
---
--- Per spec FR-016e: in live-bound source-viewer mode, the playback range
--- engine uses CONTENT bounds (`[start_frame, total_frames)`), ignoring
--- any marks. In staged mode, the existing mark-bounded behavior holds
--- (`[mark_in or start_frame, mark_out or total_frames)`).
---
--- Tested via the new `SequenceMonitor:get_playback_range()` accessor —
--- introduced by T020 — so the playback engine and any other consumer
--- read from a single source of truth, and the divergence is testable
--- without bootstrapping the Qt widget stack.
---
--- Black-box: stubs source_viewer to control `get_mode()`; constructs a
--- minimal monitor table with only the fields get_playback_range reads
--- (start_frame, total_frames, sequence.mark_in, sequence.mark_out).

require("test_env")

-- Stub source_viewer's mode oracle. The accessor reads this to branch.
local viewer_mode = "staged_sequence"
package.loaded["ui.source_viewer"] = {
    get_mode = function() return viewer_mode end,
    load_sequence = function() end, load_clip = function() end,
    load_master_clip = function() end, unload = function() end,
}

-- Pull in SequenceMonitor solely to access the get_playback_range method
-- as a class method. Avoid `SequenceMonitor.new()` which requires Qt.
local SequenceMonitor = require("ui.sequence_monitor")

print("=== test_live_bound_play_ignores_marks.lua ===")

assert(type(SequenceMonitor.get_playback_range) == "function", string.format(
    "SequenceMonitor must expose a `get_playback_range` method returning "
    .. "(start, end) per FR-016e; got %s",
    type(SequenceMonitor.get_playback_range)))

-- Minimal self-table — only the fields get_playback_range can legitimately
-- read. Anything else accessed by the method is a contract violation.
local function make_self(start_frame, total_frames, mark_in, mark_out)
    return {
        start_frame  = start_frame,
        total_frames = total_frames,
        sequence     = {
            mark_in  = mark_in,
            mark_out = mark_out,
        },
    }
end

-- ── Scenario 1: staged mode + both marks → mark range ────────────────────────
do
    viewer_mode = "staged_sequence"
    local self_ = make_self(0, 1000, 100, 300)
    local rstart, rend = SequenceMonitor.get_playback_range(self_)
    assert(rstart == 100 and rend == 300, string.format(
        "staged + marks set: range = (100, 300); got (%s, %s)",
        tostring(rstart), tostring(rend)))
    print("  ✓ staged mode + marks: range = (mark_in, mark_out)")
end

-- ── Scenario 2: staged mode + no marks → content range ───────────────────────
-- Reaffirms existing staged-mode behavior: nil marks fall back to start+total.
do
    viewer_mode = "staged_sequence"
    local self_ = make_self(0, 1000, nil, nil)
    local rstart, rend = SequenceMonitor.get_playback_range(self_)
    assert(rstart == 0 and rend == 1000, string.format(
        "staged + no marks: range = (start_frame, total_frames); got (%s, %s)",
        tostring(rstart), tostring(rend)))
    print("  ✓ staged mode + no marks: range = (start_frame, total_frames)")
end

-- ── Scenario 3: live-bound mode IGNORES marks → content range ────────────────
do
    viewer_mode = "live_bound_clip"
    -- Same marks as scenario 1, but live-bound mode must ignore them.
    local self_ = make_self(0, 1000, 100, 300)
    local rstart, rend = SequenceMonitor.get_playback_range(self_)
    assert(rstart == 0 and rend == 1000, string.format(
        "live-bound mode: range MUST ignore marks and use (start_frame, "
        .. "total_frames) = (0, 1000); got (%s, %s)",
        tostring(rstart), tostring(rend)))
    print("  ✓ live-bound mode: range = content bounds (marks ignored)")
end

-- ── Scenario 4: non-zero start_frame respected in both modes ─────────────────
-- Pins that the accessor uses start_frame (not literal 0) so masters with
-- non-zero start_timecode_frame work correctly.
do
    viewer_mode = "live_bound_clip"
    local self_ = make_self(720, 1720, 800, 900)  -- live-bound ignores 800/900
    local rstart, rend = SequenceMonitor.get_playback_range(self_)
    assert(rstart == 720 and rend == 1720, string.format(
        "live-bound + non-zero start_frame: (720, 1720); got (%s, %s)",
        tostring(rstart), tostring(rend)))

    viewer_mode = "staged_sequence"
    rstart, rend = SequenceMonitor.get_playback_range(self_)
    assert(rstart == 800 and rend == 900, string.format(
        "staged + non-zero start_frame + marks: marks win; got (%s, %s)",
        tostring(rstart), tostring(rend)))
    print("  ✓ non-zero start_frame honored in both modes")
end

print("\n✅ test_live_bound_play_ignores_marks.lua passed")
