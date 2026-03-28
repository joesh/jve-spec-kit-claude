require("test_env")

local find_state = require("core.find_state")

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

-- Test data: 10 clips with varied names, codecs, fps
local function make_clips()
    return {
        {id = "c1",  name = "INT_Scene1_Take3",  codec = "ProRes",  fps = 24, duration = 120, enabled = true},
        {id = "c2",  name = "EXT_Scene2_Take1",  codec = "ProRes",  fps = 24, duration = 240, enabled = true},
        {id = "c3",  name = "INT_Scene3_Take2",  codec = "DNxHD",   fps = 25, duration = 180, enabled = true},
        {id = "c4",  name = "EXT_Scene4_Take1",  codec = "DNxHD",   fps = 25, duration = 300, enabled = false},
        {id = "c5",  name = "INT_Hallway_Take5",  codec = "ProRes",  fps = 24, duration = 90,  enabled = true},
        {id = "c6",  name = "EXT_Park_Take1",    codec = "H264",    fps = 30, duration = 450, enabled = true},
        {id = "c7",  name = "INT_Kitchen_Take2", codec = "ProRes",  fps = 24, duration = 200, enabled = true},
        {id = "c8",  name = "TITLE_Card",         codec = "PNG",     fps = 24, duration = 48,  enabled = true},
        {id = "c9",  name = "EXT_Beach_Take3",   codec = "H264",    fps = 30, duration = 360, enabled = false},
        {id = "c10", name = "INT_Bedroom_Take1", codec = "DNxHD",   fps = 25, duration = 150, enabled = true},
    }
end

print("\n=== Find Commands Tests ===")

-- ============================================================
-- 1. execute() with "name contains INT" finds correct clips
-- ============================================================
print("\n--- execute: name contains INT ---")
do
    find_state.clear()
    local clips = make_clips()
    local query = {column = "name", operator = "contains", value = "INT"}
    find_state.execute(clips, query)

    local matched = find_state.get_matches()
    check("INT matches count = 5", #matched == 5)
    check("c1 matched", matched[1] == "c1")
    check("c3 matched", matched[2] == "c3")
    check("c5 matched", matched[3] == "c5")
    check("c7 matched", matched[4] == "c7")
    check("c10 matched", matched[5] == "c10")
end

-- ============================================================
-- 2. get_match_count() returns correct count
-- ============================================================
print("\n--- get_match_count ---")
do
    find_state.clear()
    local clips = make_clips()
    find_state.execute(clips, {column = "codec", operator = "contains", value = "ProRes"})
    check("ProRes match count = 4", find_state.get_match_count() == 4)
end

-- ============================================================
-- 3. get_current_index() starts at 1
-- ============================================================
print("\n--- get_current_index starts at 1 ---")
do
    find_state.clear()
    local clips = make_clips()
    find_state.execute(clips, {column = "name", operator = "contains", value = "EXT"})
    check("current index starts at 1", find_state.get_current_index() == 1)
end

-- ============================================================
-- 4. get_current_match() returns first match ID
-- ============================================================
print("\n--- get_current_match returns first ---")
do
    find_state.clear()
    local clips = make_clips()
    find_state.execute(clips, {column = "name", operator = "contains", value = "EXT"})
    check("current match is c2", find_state.get_current_match() == "c2")
end

-- ============================================================
-- 5. next() advances index
-- ============================================================
print("\n--- next advances ---")
do
    find_state.clear()
    local clips = make_clips()
    find_state.execute(clips, {column = "name", operator = "contains", value = "EXT"})
    -- EXT matches: c2, c4, c6, c9
    check("starts at c2", find_state.get_current_match() == "c2")
    find_state.next()
    check("next → c4", find_state.get_current_match() == "c4")
    check("index = 2", find_state.get_current_index() == 2)
    find_state.next()
    check("next → c6", find_state.get_current_match() == "c6")
    find_state.next()
    check("next → c9", find_state.get_current_match() == "c9")
end

-- ============================================================
-- 6. next() wraps from last to first
-- ============================================================
print("\n--- next wraps ---")
do
    find_state.clear()
    local clips = make_clips()
    find_state.execute(clips, {column = "name", operator = "contains", value = "EXT"})
    -- 4 matches, advance past last
    find_state.next()
    find_state.next()
    find_state.next()
    check("at last match c9", find_state.get_current_match() == "c9")
    find_state.next()
    check("wraps to c2", find_state.get_current_match() == "c2")
    check("index wraps to 1", find_state.get_current_index() == 1)
end

-- ============================================================
-- 7. previous() wraps from first to last
-- ============================================================
print("\n--- previous wraps ---")
do
    find_state.clear()
    local clips = make_clips()
    find_state.execute(clips, {column = "name", operator = "contains", value = "EXT"})
    -- At index 1 (c2), go back
    check("starts at c2", find_state.get_current_match() == "c2")
    find_state.previous()
    check("prev wraps to c9", find_state.get_current_match() == "c9")
    check("index = 4", find_state.get_current_index() == 4)
end

-- ============================================================
-- 8. execute() with no matches
-- ============================================================
print("\n--- no matches ---")
do
    find_state.clear()
    local clips = make_clips()
    find_state.execute(clips, {column = "name", operator = "contains", value = "NONEXISTENT"})
    check("count = 0", find_state.get_match_count() == 0)
    check("current match nil", find_state.get_current_match() == nil)
    check("current index = 0", find_state.get_current_index() == 0)
    -- next/previous on empty should not error
    find_state.next()
    find_state.previous()
    check("still nil after next/prev", find_state.get_current_match() == nil)
end

-- ============================================================
-- 9. scope="visible" with hidden_ids excludes hidden clips
-- ============================================================
print("\n--- scope visible ---")
do
    find_state.clear()
    local clips = make_clips()
    local hidden = {c3 = true, c7 = true}
    find_state.execute(clips,
        {column = "name", operator = "contains", value = "INT"},
        {scope = "visible", hidden_ids = hidden})
    -- INT clips: c1, c3, c5, c7, c10 minus hidden c3, c7 = c1, c5, c10
    check("visible INT count = 3", find_state.get_match_count() == 3)
    local matched = find_state.get_matches()
    check("c1 in visible", matched[1] == "c1")
    check("c5 in visible", matched[2] == "c5")
    check("c10 in visible", matched[3] == "c10")
end

-- ============================================================
-- 10. scope="all" ignores hidden_ids
-- ============================================================
print("\n--- scope all ignores hidden ---")
do
    find_state.clear()
    local clips = make_clips()
    local hidden = {c3 = true, c7 = true}
    find_state.execute(clips,
        {column = "name", operator = "contains", value = "INT"},
        {scope = "all", hidden_ids = hidden})
    check("all INT count = 5", find_state.get_match_count() == 5)
end

-- ============================================================
-- 11. clear() resets everything
-- ============================================================
print("\n--- clear resets ---")
do
    find_state.clear()
    local clips = make_clips()
    find_state.execute(clips, {column = "name", operator = "contains", value = "INT"})
    check("active before clear", find_state.is_active() == true)
    check("matches before clear", find_state.get_match_count() > 0)

    find_state.clear()
    check("not active after clear", find_state.is_active() == false)
    check("match count 0 after clear", find_state.get_match_count() == 0)
    check("current index 0 after clear", find_state.get_current_index() == 0)
    check("current match nil after clear", find_state.get_current_match() == nil)
    check("previous selection empty after clear", #find_state.get_previous_selection() == 0)
    check("query nil after clear", find_state.get_current_query() == nil)
end

-- ============================================================
-- 12. save_selection / get_previous_selection round-trip
-- ============================================================
print("\n--- save/get previous selection ---")
do
    find_state.clear()
    local sel = {"c2", "c5", "c8"}
    find_state.save_selection(sel)
    local restored = find_state.get_previous_selection()
    check("restored length = 3", #restored == 3)
    check("restored[1] = c2", restored[1] == "c2")
    check("restored[2] = c5", restored[2] == "c5")
    check("restored[3] = c8", restored[3] == "c8")
end

-- ============================================================
-- 13. is_active() true after execute, false after clear
-- ============================================================
print("\n--- is_active lifecycle ---")
do
    find_state.clear()
    check("initially not active", find_state.is_active() == false)
    local clips = make_clips()
    find_state.execute(clips, {column = "name", operator = "contains", value = "Scene"})
    check("active after execute", find_state.is_active() == true)
    -- Active even with zero matches
    find_state.execute(clips, {column = "name", operator = "contains", value = "ZZZZZ"})
    check("active even with 0 matches", find_state.is_active() == true)
    find_state.clear()
    check("not active after clear", find_state.is_active() == false)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
    print("❌ test_find_commands.lua FAILED")
    os.exit(1)
else
    print("✅ test_find_commands.lua passed")
end
