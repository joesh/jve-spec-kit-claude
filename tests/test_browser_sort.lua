--- Test: browser_sort — key extractors, type grouping, primary+secondary comparator
require("test_env")

local browser_sort = require("ui.browser_sort")

print("Testing browser_sort...")

-- Helper: make item tables for sorting
local function make_clip(name, duration, width, height, fps, codec, date)
    return {
        type = "master_clip",
        name = name,
        duration = duration or 0,
        width = width or 0,
        height = height or 0,
        fps_float = fps or 0,
        codec = codec or "",
        modified_at = date or "",
    }
end

local function make_timeline(name, duration, width, height, fps)
    return {
        type = "timeline",
        name = name,
        duration = duration or 0,
        width = width or 0,
        height = height or 0,
        fps_float = fps or 0,
        codec = "Timeline",
        modified_at = "",
    }
end

local function make_bin(name)
    return {
        type = "bin",
        name = name,
        duration = 0,
        width = 0,
        height = 0,
        fps_float = 0,
        codec = "",
        modified_at = "",
    }
end

-- 1. Type grouping invariant: bins < timelines < clips
print("  type grouping...")
do
    local items = {
        make_clip("Clip A", 100),
        make_bin("Bin X"),
        make_timeline("Seq 1", 200),
        make_clip("Clip B", 50),
        make_bin("Bin Y"),
        make_timeline("Seq 2", 100),
    }
    browser_sort.sort_items(items, browser_sort.COL_NAME, "asc")
    -- Bins first, then timelines, then clips
    assert(items[1].type == "bin", "first should be bin, got " .. items[1].type)
    assert(items[2].type == "bin", "second should be bin, got " .. items[2].type)
    assert(items[3].type == "timeline", "third should be timeline, got " .. items[3].type)
    assert(items[4].type == "timeline", "fourth should be timeline, got " .. items[4].type)
    assert(items[5].type == "master_clip", "fifth should be clip, got " .. items[5].type)
    assert(items[6].type == "master_clip", "sixth should be clip, got " .. items[6].type)
    -- Within bins: alphabetical
    assert(items[1].name == "Bin X", "bins sorted by name asc")
    assert(items[2].name == "Bin Y")
end

-- 2. Sort by name ascending
print("  sort by name asc...")
do
    local items = {
        make_clip("Zebra"),
        make_clip("Alpha"),
        make_clip("Mango"),
    }
    browser_sort.sort_items(items, browser_sort.COL_NAME, "asc")
    assert(items[1].name == "Alpha")
    assert(items[2].name == "Mango")
    assert(items[3].name == "Zebra")
end

-- 3. Sort by name descending
print("  sort by name desc...")
do
    local items = {
        make_clip("Zebra"),
        make_clip("Alpha"),
        make_clip("Mango"),
    }
    browser_sort.sort_items(items, browser_sort.COL_NAME, "desc")
    assert(items[1].name == "Zebra")
    assert(items[2].name == "Mango")
    assert(items[3].name == "Alpha")
end

-- 4. Sort by duration
print("  sort by duration...")
do
    local items = {
        make_clip("C", 300),
        make_clip("A", 100),
        make_clip("B", 200),
    }
    browser_sort.sort_items(items, browser_sort.COL_DURATION, "asc")
    assert(items[1].duration == 100)
    assert(items[2].duration == 200)
    assert(items[3].duration == 300)

    browser_sort.sort_items(items, browser_sort.COL_DURATION, "desc")
    assert(items[1].duration == 300)
    assert(items[2].duration == 200)
    assert(items[3].duration == 100)
end

-- 5. Sort by resolution (area)
print("  sort by resolution...")
do
    local items = {
        make_clip("4K",  0, 3840, 2160),
        make_clip("HD",  0, 1920, 1080),
        make_clip("SD",  0, 720,  480),
    }
    browser_sort.sort_items(items, browser_sort.COL_RESOLUTION, "asc")
    assert(items[1].name == "SD")
    assert(items[2].name == "HD")
    assert(items[3].name == "4K")
end

-- 6. Sort by FPS
print("  sort by fps...")
do
    local items = {
        make_clip("60fps", 0, 0, 0, 60),
        make_clip("24fps", 0, 0, 0, 23.976),
        make_clip("30fps", 0, 0, 0, 29.97),
    }
    browser_sort.sort_items(items, browser_sort.COL_FPS, "asc")
    assert(items[1].name == "24fps")
    assert(items[2].name == "30fps")
    assert(items[3].name == "60fps")
end

-- 7. Sort by codec
print("  sort by codec...")
do
    local items = {
        make_clip("Z", 0, 0, 0, 0, "ProRes"),
        make_clip("A", 0, 0, 0, 0, "H264"),
        make_clip("B", 0, 0, 0, 0, "DNxHD"),
    }
    browser_sort.sort_items(items, browser_sort.COL_CODEC, "asc")
    assert(items[1].codec == "DNxHD", "first codec: " .. items[1].codec)
    assert(items[2].codec == "H264")
    assert(items[3].codec == "ProRes")
end

-- 8. Sort by date
print("  sort by date...")
do
    local items = {
        make_clip("C", 0, 0, 0, 0, "", "2024-03-01"),
        make_clip("A", 0, 0, 0, 0, "", "2024-01-01"),
        make_clip("B", 0, 0, 0, 0, "", "2024-02-01"),
    }
    browser_sort.sort_items(items, browser_sort.COL_DATE, "asc")
    assert(items[1].modified_at == "2024-01-01")
    assert(items[2].modified_at == "2024-02-01")
    assert(items[3].modified_at == "2024-03-01")
end

-- 9. Primary + secondary sort
print("  primary + secondary sort...")
do
    local items = {
        make_clip("B", 100, 0, 0, 0, "ProRes"),
        make_clip("A", 100, 0, 0, 0, "H264"),
        make_clip("C", 200, 0, 0, 0, "ProRes"),
        make_clip("D", 200, 0, 0, 0, "H264"),
    }
    -- Primary: duration asc, Secondary: codec asc
    browser_sort.sort_items(items, browser_sort.COL_DURATION, "asc",
        browser_sort.COL_CODEC, "asc")
    assert(items[1].name == "A", "dur=100, codec=H264 first")
    assert(items[2].name == "B", "dur=100, codec=ProRes second")
    assert(items[3].name == "D", "dur=200, codec=H264 third")
    assert(items[4].name == "C", "dur=200, codec=ProRes fourth")
end

-- 10. Name tiebreaker when primary + secondary tie
print("  name tiebreaker...")
do
    local items = {
        make_clip("Zebra", 100, 0, 0, 0, "H264"),
        make_clip("Alpha", 100, 0, 0, 0, "H264"),
    }
    browser_sort.sort_items(items, browser_sort.COL_DURATION, "asc",
        browser_sort.COL_CODEC, "asc")
    assert(items[1].name == "Alpha", "alpha before zebra on tie")
    assert(items[2].name == "Zebra")
end

-- 11. Edge case: empty list
print("  empty list...")
do
    local items = {}
    browser_sort.sort_items(items, browser_sort.COL_NAME, "asc")
    assert(#items == 0)
end

-- 12. Edge case: single item
print("  single item...")
do
    local items = { make_clip("Solo") }
    browser_sort.sort_items(items, browser_sort.COL_NAME, "asc")
    assert(#items == 1 and items[1].name == "Solo")
end

-- 13. Edge case: nil values in sort fields
print("  nil values...")
do
    local items = {
        { type = "master_clip", name = "B", duration = nil, width = nil, height = nil,
          fps_float = nil, codec = nil, modified_at = nil },
        { type = "master_clip", name = "A", duration = 100, width = 1920, height = 1080,
          fps_float = 24, codec = "H264", modified_at = "2024-01-01" },
    }
    browser_sort.sort_items(items, browser_sort.COL_DURATION, "asc")
    assert(items[1].name == "B", "nil duration=0, comes before 100")
    assert(items[2].name == "A")
end

-- 14. handle_header_click: plain click toggles direction
print("  header click: toggle direction...")
do
    local state = { primary_col = 0, primary_order = "asc", secondary_col = nil, secondary_order = nil }
    browser_sort.handle_header_click(state, 0, false)
    assert(state.primary_order == "desc", "toggle asc→desc")
    browser_sort.handle_header_click(state, 0, false)
    assert(state.primary_order == "asc", "toggle desc→asc")
end

-- 15. handle_header_click: plain click new column
print("  header click: new primary column...")
do
    local state = { primary_col = 0, primary_order = "desc", secondary_col = nil, secondary_order = nil }
    browser_sort.handle_header_click(state, 1, false)
    assert(state.primary_col == 1, "new primary col")
    assert(state.primary_order == "asc", "reset to asc")
end

-- 16. handle_header_click: plain click on secondary clears it
print("  header click: secondary becomes primary...")
do
    local state = { primary_col = 0, primary_order = "asc", secondary_col = 2, secondary_order = "desc" }
    browser_sort.handle_header_click(state, 2, false)
    assert(state.primary_col == 2, "secondary promoted to primary")
    assert(state.secondary_col == nil, "secondary cleared")
end

-- 17. handle_header_click: cmd+click sets secondary
print("  header click: cmd+click sets secondary...")
do
    local state = { primary_col = 0, primary_order = "asc", secondary_col = nil, secondary_order = nil }
    browser_sort.handle_header_click(state, 3, true)
    assert(state.secondary_col == 3, "secondary set")
    assert(state.secondary_order == "asc", "secondary starts asc")
end

-- 18. handle_header_click: cmd+click on primary ignored
print("  header click: cmd+click on primary ignored...")
do
    local state = { primary_col = 0, primary_order = "asc", secondary_col = nil, secondary_order = nil }
    browser_sort.handle_header_click(state, 0, true)
    assert(state.primary_col == 0)
    assert(state.secondary_col == nil, "secondary not set")
end

-- 19. handle_header_click: cmd+click toggles secondary direction
print("  header click: cmd+click toggle secondary...")
do
    local state = { primary_col = 0, primary_order = "asc", secondary_col = 3, secondary_order = "asc" }
    browser_sort.handle_header_click(state, 3, true)
    assert(state.secondary_order == "desc", "toggle secondary direction")
end

-- 20. build_header_labels
print("  build_header_labels...")
do
    local base = {"Name", "Duration", "Resolution", "FPS", "Codec", "Date"}
    local state = { primary_col = 1, primary_order = "asc", secondary_col = 3, secondary_order = "desc" }
    local labels = browser_sort.build_header_labels(base, state)
    assert(labels[1] == "Name", "no indicator")
    assert(labels[2]:find("\xe2\x96\xb2"), "primary asc arrow: " .. labels[2])
    assert(labels[3] == "Resolution", "no indicator")
    assert(labels[4]:find("\xe2\x96\xbd"), "secondary desc arrow: " .. labels[4])
    assert(labels[5] == "Codec", "no indicator")
    assert(labels[6] == "Date", "no indicator")
end

-- 21. All same type sort still works
print("  all same type...")
do
    local items = {
        make_bin("C"),
        make_bin("A"),
        make_bin("B"),
    }
    browser_sort.sort_items(items, browser_sort.COL_NAME, "asc")
    assert(items[1].name == "A")
    assert(items[2].name == "B")
    assert(items[3].name == "C")
end

-- 22. Case-insensitive name sort
print("  case-insensitive name sort...")
do
    local items = {
        make_clip("zebra"),
        make_clip("Alpha"),
        make_clip("MANGO"),
    }
    browser_sort.sort_items(items, browser_sort.COL_NAME, "asc")
    assert(items[1].name == "Alpha", "case-insensitive: " .. items[1].name)
    assert(items[2].name == "MANGO")
    assert(items[3].name == "zebra")
end

print("\xE2\x9C\x85 test_browser_sort.lua passed")
