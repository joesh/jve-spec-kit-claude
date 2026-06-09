require("test_env")

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

-- ============================================================================
-- Test data: timeline clips with positions across 3 tracks
-- Sorted by sequence_start for expected find order
-- ============================================================================

local clips = {
    {id = "v1_1", name = "INT_Scene1",     track_id = "V1", sequence_start_frame = 0,    duration_frames = 100, codec = "ProRes", fps = 24, enabled = true, properties = {}},
    {id = "v2_1", name = "GFX_Lower",      track_id = "V2", sequence_start_frame = 10,   duration_frames = 50,  codec = "ProRes", fps = 24, enabled = true, properties = {}},
    {id = "v1_2", name = "EXT_Scene2",     track_id = "V1", sequence_start_frame = 100,  duration_frames = 150, codec = "ProRes", fps = 24, enabled = true, properties = {}},
    {id = "a1_1", name = "INT_Dialogue_1", track_id = "A1", sequence_start_frame = 0,    duration_frames = 250, codec = "WAV",    fps = 48000, enabled = true, properties = {}},
    {id = "v1_3", name = "INT_Scene3",     track_id = "V1", sequence_start_frame = 250,  duration_frames = 200, codec = "ProRes", fps = 24, enabled = true, properties = {}},
    {id = "v2_2", name = "Interview_B",    track_id = "V2", sequence_start_frame = 300,  duration_frames = 100, codec = "DNxHD",  fps = 25, enabled = true, properties = {}},
    {id = "v1_4", name = "EXT_Scene4",     track_id = "V1", sequence_start_frame = 450,  duration_frames = 100, codec = "ProRes", fps = 24, enabled = true, properties = {}},
    {id = "a1_2", name = "INT_Dialogue_2", track_id = "A1", sequence_start_frame = 250,  duration_frames = 300, codec = "WAV",    fps = 48000, enabled = true, properties = {}},
    {id = "v1_5", name = "INT_Closing",    track_id = "V1", sequence_start_frame = 550,  duration_frames = 50,  codec = "ProRes", fps = 24, enabled = false, properties = {}},
}

local find_state = require("core.find_state")

-- ============================================================================
-- Timeline find: matches sorted by sequence_start
-- ============================================================================
print("--- timeline find: INT clips ---")
find_state.clear()

-- Sort clips by sequence_start for timeline context
local sorted = {}
for _, c in ipairs(clips) do sorted[#sorted + 1] = c end
table.sort(sorted, function(a, b) return a.sequence_start_frame < b.sequence_start_frame end)

find_state.execute(sorted, {column = "name", operator = "contains", value = "INT"})

-- INT clips: INT_Scene1(0), INT_Dialogue_1(0), Interview_B(300), INT_Scene3(250), INT_Dialogue_2(250), INT_Closing(550) = 6
-- Note: "Interview" contains "INT" (case-insensitive)
check("timeline INT: 6 matches", find_state.get_match_count() == 6)
check("timeline INT: active", find_state.is_active())

-- First match should be earliest by sequence_start
local first = find_state.get_current_match()
check("timeline INT: first match is earliest",
    first == "v1_1" or first == "a1_1")  -- both at frame 0

-- Cycling visits all matches
local visited = {}
for _ = 1, 6 do
    visited[find_state.get_current_match()] = true
    find_state.next()
end
local visited_count = 0
for _ in pairs(visited) do visited_count = visited_count + 1 end
check("timeline INT: 6 unique matches visited", visited_count == 6)

-- ============================================================================
-- Timeline find: cross-track ordering
-- ============================================================================
print("--- timeline find: cross-track ---")
find_state.clear()
find_state.execute(sorted, {column = "name", operator = "contains", value = "Scene"})

-- Scene clips: INT_Scene1(0), EXT_Scene2(100), INT_Scene3(250), EXT_Scene4(450) = 4
check("cross-track: 4 Scene matches", find_state.get_match_count() == 4)

-- Verify order is by sequence_start
local order = {}
for _ = 1, 4 do
    order[#order + 1] = find_state.get_current_match()
    find_state.next()
end
check("cross-track: first is INT_Scene1", order[1] == "v1_1")
check("cross-track: second is EXT_Scene2", order[2] == "v1_2")
check("cross-track: third is INT_Scene3", order[3] == "v1_3")
check("cross-track: fourth is EXT_Scene4", order[4] == "v1_4")

-- ============================================================================
-- Timeline find: wrap around
-- ============================================================================
print("--- timeline find: wrap ---")
-- Continue from current position (after 4 nexts, we're back at 1)
check("wrap: back to first after full cycle", find_state.get_current_match() == "v1_1")

-- Previous wraps to last
find_state.previous()
check("wrap: previous from first goes to last", find_state.get_current_match() == "v1_4")

-- ============================================================================
-- Timeline find: no matches
-- ============================================================================
print("--- timeline find: no matches ---")
find_state.clear()
find_state.execute(sorted, {column = "name", operator = "contains", value = "XYZZY"})
check("no match: count = 0", find_state.get_match_count() == 0)
check("no match: current = nil", find_state.get_current_match() == nil)
check("no match: still active", find_state.is_active())

-- next/previous on empty set should not crash
find_state.next()
find_state.previous()
check("no match: next/prev no crash", true)

-- ============================================================================
-- Timeline find: search by codec (non-name attribute)
-- ============================================================================
print("--- timeline find: by codec ---")
find_state.clear()
find_state.execute(sorted, {column = "codec", operator = "contains", value = "DNxHD"})
check("codec search: 1 match", find_state.get_match_count() == 1)
check("codec search: Interview_B", find_state.get_current_match() == "v2_2")

find_state.clear()

-- ============================================================================
-- Summary
-- ============================================================================
print("")
if fail_count > 0 then
    print(string.format("❌ test_timeline_find.lua: %d passed, %d FAILED", pass_count, fail_count))
    os.exit(1)
end
print(string.format("✅ test_timeline_find.lua passed (%d assertions)", pass_count))
