require('test_env')

-- Behavior under test: after a track is renamed, the timeline's cached view of
-- that track must reflect the new name immediately — without the tab being
-- closed and reopened (which is the only thing that re-reads the DB today).
-- The strip owns the per-tab track cache, so it is the strip's job to reconcile
-- a rename into the cache that the header view rebuilds from.

local TimelineTabStrip = require("ui.timeline.timeline_tab_strip")

-- Build a strip with two tabs, each holding its own (separate) track cache.
-- A renamed track lives in exactly one tab's cache (tracks belong to one
-- sequence); the other tab must be untouched.
local strip = TimelineTabStrip.new()
strip.tabs = {
    { cache = { tracks = {
        { id = "trkA1", name = "Dialogue" },
        { id = "trkA2", name = nil },        -- derived label (no override)
    } } },
    { cache = { tracks = {
        { id = "trkV1", name = "Cam A" },
    } } },
}

-- Rename a track that has an existing name.
assert(strip:refresh_track_name("trkA1", "Boom"),
    "refresh_track_name should report it found+updated the track")
assert(strip.tabs[1].cache.tracks[1].name == "Boom",
    "renamed track's cached name must update in place")

-- Untouched tracks stay as they were.
assert(strip.tabs[1].cache.tracks[2].name == nil, "sibling track name untouched")
assert(strip.tabs[2].cache.tracks[1].name == "Cam A", "other-tab track untouched")

-- Clearing the override (empty rename → nil stored name) reconciles to nil so
-- the derived label returns.
assert(strip:refresh_track_name("trkA1", nil), "clearing the name is still a hit")
assert(strip.tabs[1].cache.tracks[1].name == nil,
    "cleared override must store nil so the derived label returns")

-- A track that lives in no open tab's cache: report miss, mutate nothing.
assert(not strip:refresh_track_name("ghost", "X"),
    "renaming a track absent from every cache reports a miss")

-- Failure path (rule 1.14): a bad track_id must assert loudly.
local ok, err = pcall(function() strip:refresh_track_name("", "X") end)
assert(not ok, "empty track_id must assert")
assert(err:find("track_id"), "wrong error: " .. tostring(err))

print("✅ test_tab_strip_refresh_track_name.lua passed")
