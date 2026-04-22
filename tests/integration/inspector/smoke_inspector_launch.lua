-- Integration smoke test: Inspector mounts inside a fresh Qt container
-- and its public API is reachable. Run via:
--   ./build/bin/JVEEditor --test tests/integration/inspector/smoke_inspector_launch.lua
--
-- --test mode boots C++ Qt bindings but does NOT run layout.lua (that
-- only runs in full GUI mode). Each integration test owns its container.

local qt_constants = require("core.qt_constants")

-- Create a throwaway top-level widget.
local container = qt_constants.WIDGET.CREATE()
assert(container, "smoke: could not create container widget")

local inspector = require("ui.inspector")

-- Facade shape — exactly three exports.
assert(type(inspector.mount)            == "function", "facade missing mount")
assert(type(inspector.update_selection) == "function", "facade missing update_selection")
assert(type(inspector.get_focus_widgets)== "function", "facade missing get_focus_widgets")

local export_count = 0
for _ in pairs(inspector) do export_count = export_count + 1 end
assert(export_count == 3,
    string.format("facade must export exactly 3 functions, got %d", export_count))

-- Mount.
inspector.mount(container)

-- Focus widgets.
local focus = inspector.get_focus_widgets()
assert(type(focus) == "table" and #focus >= 1,
    "get_focus_widgets returned empty / non-table")

-- update_selection must ignore "inspector" source (FR-003).
inspector.update_selection({ { item_type = "timeline_clip", clip_id = "ignored" } }, "inspector")

-- update_selection with empty items → empty mode, no crash.
inspector.update_selection({}, "timeline")

print("✅ smoke_inspector_launch.lua passed")
os.exit(0)
