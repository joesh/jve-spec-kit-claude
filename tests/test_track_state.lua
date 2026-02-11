require("test_env")

-- Stub ui_constants before timeline_state_data loads
package.loaded["core.ui_constants"] = {
    TIMELINE = {
        NOTIFY_DEBOUNCE_MS = 10,
        TRACK_HEIGHT = 50,
        TRACK_HEADER_WIDTH = 240,
        RULER_HEIGHT = 32,
    },
    LOGGING = { COMPONENT_NAMES = { UI = "ui" } },
}

-- timeline_state_data requires Rational — let it load naturally via test_env
local data = require("ui.timeline.state.timeline_state_data")
local track_state = require("ui.timeline.state.track_state")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

-- Helper: reset state and populate tracks
local function setup_tracks(tracks)
    data.reset()
    data.state.tracks = tracks or {}
end

print("\n=== Track State Tests (T26) ===")

-- ============================================================
-- get_all — returns tracks table
-- ============================================================
print("\n--- get_all ---")
do
    setup_tracks({
        {id = "v1", track_type = "VIDEO", name = "V1", height = 80},
        {id = "a1", track_type = "AUDIO", name = "A1", height = 40},
    })

    local all = track_state.get_all()
    check("get_all returns tracks", #all == 2)
    check("get_all first is V1", all[1].id == "v1")
    check("get_all second is A1", all[2].id == "a1")
end

do
    setup_tracks({})
    check("get_all empty", #track_state.get_all() == 0)
end

-- ============================================================
-- get_video_tracks / get_audio_tracks — filter by type
-- ============================================================
print("\n--- get_video/audio_tracks ---")
do
    setup_tracks({
        {id = "v1", track_type = "VIDEO", name = "V1"},
        {id = "v2", track_type = "VIDEO", name = "V2"},
        {id = "a1", track_type = "AUDIO", name = "A1"},
        {id = "a2", track_type = "AUDIO", name = "A2"},
        {id = "a3", track_type = "AUDIO", name = "A3"},
    })

    local video = track_state.get_video_tracks()
    check("video count", #video == 2)
    check("video[1].id", video[1].id == "v1")
    check("video[2].id", video[2].id == "v2")

    local audio = track_state.get_audio_tracks()
    check("audio count", #audio == 3)
    check("audio[1].id", audio[1].id == "a1")
end

do
    setup_tracks({
        {id = "v1", track_type = "VIDEO", name = "V1"},
    })
    check("no audio tracks", #track_state.get_audio_tracks() == 0)
    check("one video track", #track_state.get_video_tracks() == 1)
end

do
    setup_tracks({})
    check("empty video", #track_state.get_video_tracks() == 0)
    check("empty audio", #track_state.get_audio_tracks() == 0)
end

-- ============================================================
-- get_height — per-track height with default fallback
-- ============================================================
print("\n--- get_height ---")
do
    setup_tracks({
        {id = "v1", track_type = "VIDEO", height = 100},
        {id = "a1", track_type = "AUDIO"},  -- no height → default
    })

    check("explicit height", track_state.get_height("v1") == 100)
    check("default height", track_state.get_height("a1") == data.dimensions.default_track_height)
    check("nonexistent track", track_state.get_height("nope") == data.dimensions.default_track_height)
end

-- ============================================================
-- set_height — updates track, marks dirty, notifies
-- ============================================================
print("\n--- set_height ---")
do
    setup_tracks({
        {id = "v1", track_type = "VIDEO", height = 50},
    })
    track_state.clear_layout_dirty()
    check("initially clean", track_state.is_layout_dirty() == false)

    -- Track listener calls
    local notified = false
    data.add_listener(function() notified = true end)

    track_state.set_height("v1", 120)
    check("height updated", track_state.get_height("v1") == 120)
    check("layout dirty", track_state.is_layout_dirty() == true)
    check("listener notified", notified == true)

    -- Same height → no change
    track_state.clear_layout_dirty()
    notified = false  -- luacheck: ignore 311 (value assigned is overwritten)
    track_state.set_height("v1", 120)
    check("same height no-op dirty", track_state.is_layout_dirty() == false)

    -- Nonexistent track → no crash
    track_state.set_height("nope", 200)
    check("nonexistent set_height no crash", true)
end

do
    -- persist_callback called
    setup_tracks({
        {id = "v1", track_type = "VIDEO", height = 50},
    })
    local persisted = false
    track_state.set_height("v1", 99, function(force) persisted = force end)
    check("persist_callback called", persisted == true)
end

-- ============================================================
-- is_layout_dirty / clear_layout_dirty
-- ============================================================
print("\n--- layout dirty flag ---")
do
    setup_tracks({
        {id = "v1", track_type = "VIDEO", height = 50},
    })
    track_state.clear_layout_dirty()
    check("clean after clear", track_state.is_layout_dirty() == false)

    track_state.set_height("v1", 60)
    check("dirty after set_height", track_state.is_layout_dirty() == true)

    track_state.clear_layout_dirty()
    check("clean again", track_state.is_layout_dirty() == false)
end

-- ============================================================
-- get_primary_id — first track of given type
-- ============================================================
print("\n--- get_primary_id ---")
do
    setup_tracks({
        {id = "a1", track_type = "AUDIO"},
        {id = "v1", track_type = "VIDEO"},
        {id = "v2", track_type = "VIDEO"},
    })

    check("primary VIDEO", track_state.get_primary_id("VIDEO") == "v1")
    check("primary video lowercase", track_state.get_primary_id("video") == "v1")
    check("primary AUDIO", track_state.get_primary_id("AUDIO") == "a1")
    check("primary nonexistent type", track_state.get_primary_id("SUBTITLE") == nil)
end

do
    setup_tracks({})
    check("primary empty tracks", track_state.get_primary_id("VIDEO") == nil)
end

-- ============================================================
-- get_by_id — find track by id
-- ============================================================
print("\n--- get_by_id ---")
do
    setup_tracks({
        {id = "v1", track_type = "VIDEO", name = "V1"},
        {id = "a1", track_type = "AUDIO", name = "A1"},
    })

    local v1 = track_state.get_by_id("v1")
    check("get_by_id found", v1 ~= nil)
    check("get_by_id name", v1.name == "V1")
    check("get_by_id type", v1.track_type == "VIDEO")

    check("get_by_id nonexistent", track_state.get_by_id("nope") == nil)
    check("get_by_id nil", track_state.get_by_id(nil) == nil)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Track State: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_track_state.lua passed")
