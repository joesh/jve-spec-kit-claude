-- Integration: the timeline video/audio split is ONE model value projected
-- onto BOTH the lanes splitter and the headers splitter (run via `jve --test`).
--
-- Regression: the track-header column and the clip-lane column each carry the
-- video/audio boundary in a separate QSplitter. They must always agree. The
-- old code reset only the headers splitter to {1,1} (= 0.5) on every tab
-- rebuild and never re-applied the persisted ratio, so any non-0.5 split left
-- the V/A headers floating at the midline while the clips collapsed to the top
-- (the visible misalignment). apply_video_audio_split is the single projection
-- both splitters now go through; this pins that they end at the SAME ratio.
--
-- Real QSplitters (not mocks): Qt scales setSizes to each splitter's own
-- height, so equality of the resulting RATIO — not the raw px — is the invariant.

print("=== test_video_audio_split_projection.lua ===")

require("test_env")
local timeline_panel = require("ui.timeline.timeline_panel")

local function make_widget()
    local w = qt_constants.WIDGET.CREATE()
    assert(w, "WIDGET.CREATE returned nil")
    return w
end

-- Two independent vertical splitters, each video-over-audio, hosted + shown so
-- Qt assigns real geometry (GET_SPLITTER_SIZES returns zeros without a parent).
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_SIZE(main_window, 600, 800)

local lanes_split   = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
local headers_split = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")

qt_constants.LAYOUT.ADD_WIDGET(lanes_split, make_widget())   -- video lanes
qt_constants.LAYOUT.ADD_WIDGET(lanes_split, make_widget())   -- audio lanes
qt_constants.LAYOUT.ADD_WIDGET(headers_split, make_widget()) -- video headers
qt_constants.LAYOUT.ADD_WIDGET(headers_split, make_widget()) -- audio headers

-- Host both in a horizontal splitter so they get a real height side by side.
local host = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")
qt_constants.LAYOUT.ADD_WIDGET(host, headers_split)
qt_constants.LAYOUT.ADD_WIDGET(host, lanes_split)
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, host)
qt_constants.DISPLAY.SHOW(main_window)

-- Wire the two splitters as the panel's projection targets.
timeline_panel.vertical_splitter = lanes_split
timeline_panel.headers_main_splitter = headers_split

local function ratio_of(splitter)
    local s = qt_constants.LAYOUT.GET_SPLITTER_SIZES(splitter)
    assert(s and #s == 2, "splitter must report 2 sections")
    local total = s[1] + s[2]
    assert(total > 0, "splitter total height must be > 0 (window shown?)")
    return s[1] / total
end

local function assert_close(actual, expected, label)
    assert(math.abs(actual - expected) < 0.03, string.format(
        "%s: expected ~%.3f, got %.3f", label, expected, actual))
end

-- ── (1) A non-0.5 ratio projects onto BOTH splitters equally ──────────
print("-- (1) project 0.70 --")
timeline_panel.apply_video_audio_split(0.70)
local lanes_r = ratio_of(lanes_split)
local headers_r = ratio_of(headers_split)
assert_close(lanes_r, 0.70, "lanes ratio")
assert_close(headers_r, 0.70, "headers ratio")
assert(math.abs(lanes_r - headers_r) < 0.02,
    string.format("lanes and headers must agree: %.3f vs %.3f", lanes_r, headers_r))
print("  PASS both splitters at 0.70")

-- ── (2) The rebuild-desync regression: a {1,1} reset of ONLY the headers
-- splitter (what the old code did) is re-corrected by projecting the model
-- ratio to both — they end equal, NOT one-at-0.5-one-at-0.18. ───────────
print("-- (2) re-sync after a headers-only reset --")
qt_constants.LAYOUT.SET_SPLITTER_SIZES(headers_split, {1, 1})  -- simulate old reset → 0.5
assert(math.abs(ratio_of(headers_split) - 0.5) < 0.05, "headers reset to ~0.5")
assert(math.abs(ratio_of(lanes_split) - 0.70) < 0.05, "lanes still ~0.70 → DESYNCED")

timeline_panel.apply_video_audio_split(0.18)  -- what rebuild_for_displayed_tab now does
lanes_r = ratio_of(lanes_split)
headers_r = ratio_of(headers_split)
assert_close(lanes_r, 0.18, "lanes after rebuild")
assert_close(headers_r, 0.18, "headers after rebuild")
assert(math.abs(lanes_r - headers_r) < 0.02,
    string.format("rebuild must re-sync both: %.3f vs %.3f", lanes_r, headers_r))
print("  PASS rebuild re-syncs both to 0.18")

-- ── (3) nil ratio (no displayed tab) is a no-op, not a crash ──────────
print("-- (3) nil ratio is a no-op --")
local before = ratio_of(lanes_split)
timeline_panel.apply_video_audio_split(nil)
assert_close(ratio_of(lanes_split), before, "nil ratio leaves sizes unchanged")
print("  PASS nil ratio no-op")

print("\nPASS test_video_audio_split_projection.lua")
