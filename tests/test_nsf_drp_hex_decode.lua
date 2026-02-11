#!/usr/bin/env luajit
-- NSF Test: DRP hex decode must produce valid fps values
--
-- DRP stores fps as hex-encoded IEEE 754 double:
-- "00000000000038400000000000000000" = 24.0 fps
-- "00000000008041400000000000000000" = ~30.0 fps (29.97)

require("test_env")

print("=== test_nsf_drp_hex_decode.lua ===")

local drp_importer = require("importers.drp_importer")

--------------------------------------------------------------------------------
-- Test 1: Parsed fps values must be in valid range (1-120)
--------------------------------------------------------------------------------

print("\n--- Test 1: Timeline fps must be valid (1-120) ---")

local DRP_PATH = "fixtures/resolve/sample_project.drp"
local f = io.open(DRP_PATH, "r")
if not f then
    print("  (skipping - fixture not available)")
    print("\n✅ test_nsf_drp_hex_decode.lua passed (no fixture)")
    os.exit(0)
end
f:close()

local result = drp_importer.parse_drp_file(DRP_PATH)
assert(result.success, "parse_drp_file failed: " .. tostring(result.error))

local invalid_fps = {}
for i, timeline in ipairs(result.timelines or {}) do
    local fps = timeline.fps
    if not fps or fps < 1 or fps > 120 then
        table.insert(invalid_fps, {
            name = timeline.name or "unnamed",
            fps = fps
        })
    end
end

if #invalid_fps > 0 then
    print("INVALID FPS VALUES (must be 1-120):")
    for _, t in ipairs(invalid_fps) do
        print(string.format("  ✗ Timeline '%s': fps=%s", t.name, tostring(t.fps)))
    end
    error(string.format("Found %d timelines with invalid fps - hex decode bug", #invalid_fps))
end

for _, timeline in ipairs(result.timelines or {}) do
    print(string.format("  ✓ Timeline '%s': fps=%.2f", timeline.name, timeline.fps))
end

print("✓ All timelines have valid fps in range 1-120")

print("\n✅ test_nsf_drp_hex_decode.lua passed")
