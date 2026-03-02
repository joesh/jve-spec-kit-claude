--- End-to-end test: verify application layout is sane after startup.
--
-- Catches regressions like:
--   - Project browser taking over the entire window (22300px wide CAMetalLayer)
--   - Panels with zero width/height (squeezed out by layout)
--   - Wrong number of splitter panes
--   - Wrong sequence loaded at startup
--   - All sequences loaded instead of just the active one
--
-- Run: ./build/bin/JVEEditor --test tests/integration/test_layout_sanity.lua

local ui = require("integration.ui_test_env")

print("=== test_layout_sanity ===")

-- Launch with a known 3-sequence project, active on #2
local app, info = ui.launch({
    project_name = "Layout Sanity Test",
    num_sequences = 3,
    sequence_names = {"Reel A", "Reel B", "Reel C"},
    active_sequence = 2,
})

-- 1. Main window has reasonable dimensions
print("  Checking main window size...")
local win_w, win_h = ui.assert_size_in_range(
    app.main_window, "main_window",
    400, 5000,   -- width: sane range for any display
    300, 3000    -- height: sane range for any display
)
print(string.format("    main_window: %dx%d", win_w, win_h))

-- 2. Top splitter: exactly 4 panels (browser, source, timeline monitor, inspector)
print("  Checking top splitter...")
local top_sizes = ui.assert_splitter_count(app.top_splitter, "top_splitter", 4)
print(string.format("    top panels: [%s]", table.concat(top_sizes, ", ")))

-- 3. Main splitter: exactly 2 panels (top row + timeline)
print("  Checking main splitter...")
local main_sizes = ui.assert_splitter_count(app.main_splitter, "main_splitter", 2)
print(string.format("    main panels: [%s]", table.concat(main_sizes, ", ")))

-- 4. No panel dominates (regression: project_browser at 22300px)
print("  Checking panel proportions...")
ui.assert_no_panel_dominates(app, 0.6)
print("    no panel > 60% width")

-- 5. All panels have non-trivial size
print("  Checking minimum panel sizes...")
for i, s in ipairs(top_sizes) do
    assert(s > 10,
        string.format("top panel %d has tiny size: %dpx", i, s))
end
for i, s in ipairs(main_sizes) do
    assert(s > 50,
        string.format("main panel %d has tiny size: %dpx", i, s))
end
print("    all panels above minimum")

-- 6. Correct sequence loaded (should be #2 "Reel B", not #1 or all)
print("  Checking active sequence...")
ui.assert_eq(app.active_sequence_id, info.sequences[2].id, "active_sequence_id")
print(string.format("    active: %s (Reel B)", app.active_sequence_id))

-- 7. Project ID is set
print("  Checking project ID...")
ui.assert_eq(app.active_project_id, info.project.id, "active_project_id")
print(string.format("    project: %s", app.active_project_id))

ui.cleanup()
print("✅ test_layout_sanity.lua passed")
