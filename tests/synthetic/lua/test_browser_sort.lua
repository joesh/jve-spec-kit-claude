--- Test: browser_sort — header click state management and label building
-- (Sorting itself is now done by Qt's SORT_TREE)
require("test_env")

local browser_sort = require("ui.browser_sort")

print("Testing browser_sort...")

-- 1. handle_header_click: plain click toggles direction
print("  header click: toggle direction...")
do
    local state = { primary_col = 0, primary_order = "asc", secondary_col = nil, secondary_order = nil }
    browser_sort.handle_header_click(state, 0, false)
    assert(state.primary_order == "desc", "toggle asc→desc")
    browser_sort.handle_header_click(state, 0, false)
    assert(state.primary_order == "asc", "toggle desc→asc")
end

-- 2. handle_header_click: plain click new column
print("  header click: new primary column...")
do
    local state = { primary_col = 0, primary_order = "desc", secondary_col = nil, secondary_order = nil }
    browser_sort.handle_header_click(state, 1, false)
    assert(state.primary_col == 1, "new primary col")
    assert(state.primary_order == "asc", "reset to asc")
end

-- 3. handle_header_click: plain click on secondary clears it
print("  header click: secondary becomes primary...")
do
    local state = { primary_col = 0, primary_order = "asc", secondary_col = 2, secondary_order = "desc" }
    browser_sort.handle_header_click(state, 2, false)
    assert(state.primary_col == 2, "secondary promoted to primary")
    assert(state.secondary_col == nil, "secondary cleared")
end

-- 4. handle_header_click: cmd+click sets secondary
print("  header click: cmd+click sets secondary...")
do
    local state = { primary_col = 0, primary_order = "asc", secondary_col = nil, secondary_order = nil }
    browser_sort.handle_header_click(state, 3, true)
    assert(state.secondary_col == 3, "secondary set")
    assert(state.secondary_order == "asc", "secondary starts asc")
end

-- 5. handle_header_click: cmd+click on primary ignored
print("  header click: cmd+click on primary ignored...")
do
    local state = { primary_col = 0, primary_order = "asc", secondary_col = nil, secondary_order = nil }
    browser_sort.handle_header_click(state, 0, true)
    assert(state.primary_col == 0)
    assert(state.secondary_col == nil, "secondary not set")
end

-- 6. handle_header_click: cmd+click toggles secondary direction
print("  header click: cmd+click toggle secondary...")
do
    local state = { primary_col = 0, primary_order = "asc", secondary_col = 3, secondary_order = "asc" }
    browser_sort.handle_header_click(state, 3, true)
    assert(state.secondary_order == "desc", "toggle secondary direction")
end

-- 7. build_header_labels
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

print("\xE2\x9C\x85 test_browser_sort.lua passed")
