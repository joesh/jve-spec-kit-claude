#!/usr/bin/env luajit

-- Spec 022 Phase 1.4 — signal handlers dispatch to all open tabs.
--
-- track_preference_changed, playhead_changed, and media_status_changed
-- update EVERY open tab's cache, not just data.state. data.state still
-- mirrors the displayed tab until 1.3b/c land — the new path keeps
-- non-displayed tabs current so when the user switches between tabs
-- they don't see stale state from before the signal fired.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local Signals = require("core.signals")
local timeline_state = require("ui.timeline.timeline_state")

print("=== test_timeline_signal_handlers_per_tab.lua ===")

local DB = "/tmp/jve/test_timeline_signal_handlers_per_tab.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('seqA', 'proj', 'A', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 2000, %d, %d),
           ('seqB', 'proj', 'B', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 2000, %d, %d)
]], now, now, now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, track_type, track_index, name, muted)
    VALUES ('tA', 'seqA', 'VIDEO', 1, 'V1', 0),
           ('tB', 'seqB', 'VIDEO', 1, 'V1', 0)
]])

timeline_state.init("seqA", "proj")
local strip = timeline_state.get_tab_strip()
local tabA = strip:find_record_tab_by_sequence_id("seqA")
local tabB = strip:open_record_tab("seqB")

-- ── playhead_changed dispatches per-tab ───────────────────────────────────
assert(tabA.cache.playhead_position == 0, "fixture: tabA playhead starts 0")
assert(tabB.cache.playhead_position == 0, "fixture: tabB playhead starts 0")

Signals.emit("playhead_changed", "seqB", 5000)
assert(tabB.cache.playhead_position == 5000,
    string.format("seqB tab cache updated by playhead_changed (got %s)",
        tostring(tabB.cache.playhead_position)))
assert(tabA.cache.playhead_position == 0,
    "seqA tab cache untouched by seqB-targeted playhead signal")
print("✓ playhead_changed updates the matching tab's cache only")

Signals.emit("playhead_changed", "seqA", 1234)
assert(tabA.cache.playhead_position == 1234, "seqA tab cache updated")
-- H1 (#28): displayed-target playhead is read straight from the tab's
-- cache (no data.state mirror). The handler still triggers notify_listeners
-- for the displayed case — the assertion below is the visible behavior.
assert(timeline_state.get_playhead_position() == 1234,
    "displayed seqA playhead readable via timeline_state getter")
print("✓ displayed-target playhead readable via getter (tab cache)")

-- ── track_preference_changed walks all tabs ───────────────────────────────
-- tA on seqA tab and tB on seqB tab. Toggle tB's muted; only seqB tab
-- should reflect (and data.state if displayed; here displayed is seqA so
-- data.state.tracks doesn't have tB).
Signals.emit("track_preference_changed", "tB", "muted", 1)
local found_tB_muted = false
for _, t in ipairs(tabB.cache.tracks) do
    if t.id == "tB" then
        assert(t.muted == true,
            "seqB tab cache: tB.muted flipped to true")
        found_tB_muted = true
    end
end
assert(found_tB_muted, "tB exists in seqB tab cache")
for _, t in ipairs(tabA.cache.tracks) do
    assert(t.id ~= "tB", "seqA tab cache has no tB track (untouched)")
end
print("✓ track_preference_changed dispatches to the right tab cache")

-- ── media_status_changed walks every tab's clips ──────────────────────────
-- Inject synthetic clip rows onto both tab caches with a shared media_path.
-- The handler walks all tabs and sets offline + error_code on matching
-- clips. We're testing the dispatch fan-out, not gap recompute or any
-- other side effect.
table.insert(tabA.cache.clips, {id = "clA", media_path = "/m1.mov",
    sequence_start = 0, duration = 100, track_id = "tA"})
table.insert(tabB.cache.clips, {id = "clB", media_path = "/m1.mov",
    sequence_start = 0, duration = 100, track_id = "tB"})
tabA:invalidate_indexes()
tabB:invalidate_indexes()

Signals.emit("media_status_changed", "/m1.mov",
    {offline = true, error_code = 42})

local function find_clip(list, id)
    for _, c in ipairs(list) do if c.id == id then return c end end
    return nil
end
local clA = find_clip(tabA.cache.clips, "clA")
local clB = find_clip(tabB.cache.clips, "clB")
assert(clA and clA.offline == true and clA.error_code == 42,
    "media_status_changed updated seqA tab's matching clip")
assert(clB and clB.offline == true and clB.error_code == 42,
    "media_status_changed updated seqB tab's matching clip")
print("✓ media_status_changed walks every tab's clips")

print("✅ test_timeline_signal_handlers_per_tab.lua passed")
