-- Test offline_frame_cache module
-- Tests cache behavior: hit/miss, clear, and line composition.
-- EMP.COMPOSE_OFFLINE_FRAME is mocked since tests run without Qt context.
require('test_env')

print("Testing offline frame cache...")

-- ============================================================================
-- Setup: mock EMP.COMPOSE_OFFLINE_FRAME and path_utils
-- ============================================================================

-- Track compose calls for verification
local compose_calls = {}
local next_handle_id = 1

-- Mock qt_constants with COMPOSE_OFFLINE_FRAME
local mock_qt = {
    EMP = {
        COMPOSE_OFFLINE_FRAME = function(png_path, lines)
            local handle = { id = next_handle_id, png_path = png_path, lines = lines }
            next_handle_id = next_handle_id + 1
            compose_calls[#compose_calls + 1] = handle
            return handle
        end,
    },
}
package.loaded["core.qt_constants"] = mock_qt

-- Mock path_utils so resolve_repo_path returns a fixed string
package.loaded["core.path_utils"] = {
    resolve_repo_path = function(rel)
        return "/mock/repo/" .. rel
    end,
}

-- Mock logger (tests use print)
package.loaded["core.logger"] = {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
}

-- Mock signals (prevent side effects)
package.loaded["core.signals"] = {
    connect = function() return 1 end,
    disconnect = function() end,
    emit = function() end,
}

-- Now require the module under test
local offline_frame_cache = require("core.media.offline_frame_cache")

-- ============================================================================
-- Test: get_frame returns composited frame handle
-- ============================================================================

print("  Testing: get_frame composes frame on cache miss")
compose_calls = {}
next_handle_id = 1

local metadata = {
    media_path = "/path/to/missing_file.mov",
    error_code = "FileNotFound",
    error_msg = "File not found: /path/to/missing_file.mov",
}

local frame1 = offline_frame_cache.get_frame(metadata)
assert(frame1, "get_frame should return a frame handle")
assert(frame1.id == 1, "First frame should have id=1")
assert(#compose_calls == 1, "Should have called COMPOSE_OFFLINE_FRAME once")

-- Verify PNG path
assert(compose_calls[1].png_path == "/mock/repo/resources/offline_frame.png",
    "Should use offline_frame.png from resources")

-- Verify lines content: 4 lines (title, filename, path, error with path stripped)
local lines = compose_calls[1].lines
assert(#lines == 4, "Should produce 4 lines, got " .. #lines)
assert(lines[1].text == "Media Offline", "Line 1 should be 'MEDIA OFFLINE'")
assert(lines[1].bold == true, "Line 1 should be bold")
assert(lines[1].color == "#ffffff", "Line 1 should be white")
assert(lines[1].height_pct == 12, "Line 1 height_pct should be 12")
assert(lines[1].gap_after_pct == 5, "Line 1 should have gap_after_pct=5")
assert(lines[2].text == "missing_file.mov", "Line 2 should be filename")
assert(lines[2].height_pct == 5, "Line 2 height_pct should be 5")
assert(lines[3].text == "/path/to/missing_file.mov", "Line 3 should be full path")
assert(lines[4].text == "File not found", "Line 4 should be error_msg with path stripped")
print("    ✓ Frame composed with correct text lines")

-- ============================================================================
-- Test: get_frame returns cached handle on second call (cache hit)
-- ============================================================================

print("  Testing: get_frame returns cached handle on repeat call")
local frame2 = offline_frame_cache.get_frame(metadata)
assert(frame2 == frame1, "Second call should return same handle (cache hit)")
assert(#compose_calls == 1, "Should NOT call COMPOSE_OFFLINE_FRAME again")
print("    ✓ Cache hit returns same handle")

-- ============================================================================
-- Test: different media_path gets different frame
-- ============================================================================

print("  Testing: different media_path gets new frame")
local metadata2 = {
    media_path = "/path/to/another_file.wav",
    error_code = "FileNotFound",
    error_msg = "File not found: /path/to/another_file.wav",
}

local frame3 = offline_frame_cache.get_frame(metadata2)
assert(frame3 ~= frame1, "Different path should get different frame")
assert(frame3.id == 2, "Second path should have id=2")
assert(#compose_calls == 2, "Should have called COMPOSE_OFFLINE_FRAME twice total")
print("    ✓ Different path gets new frame")

-- ============================================================================
-- Test: clear() invalidates cache
-- ============================================================================

print("  Testing: clear() invalidates cache")
offline_frame_cache.clear()

local frame4 = offline_frame_cache.get_frame(metadata)
assert(frame4 ~= frame1, "After clear, should compose new frame")
assert(frame4.id == 3, "After clear, new frame should have id=3")
assert(#compose_calls == 3, "Should have called COMPOSE_OFFLINE_FRAME 3 times total")
print("    ✓ clear() forces recomposition")

-- ============================================================================
-- Test: metadata without error fields produces fewer lines
-- ============================================================================

print("  Testing: metadata without error fields")
compose_calls = {}
next_handle_id = 10
offline_frame_cache.clear()

local sparse_meta = {
    media_path = "/just/path.mp4",
}

local frame5 = offline_frame_cache.get_frame(sparse_meta)
assert(frame5, "Should compose frame with sparse metadata")
local sparse_lines = compose_calls[1].lines
assert(#sparse_lines == 3, "Without error fields, should produce 3 lines, got " .. #sparse_lines)
assert(sparse_lines[1].text == "Media Offline", "Line 1 should still be title")
assert(sparse_lines[2].text == "path.mp4", "Line 2 should be filename")
assert(sparse_lines[3].text == "/just/path.mp4", "Line 3 should be full path")
print("    ✓ Sparse metadata produces correct lines")

-- ============================================================================
-- Test: non-FileNotFound error IS shown
-- ============================================================================

print("  Testing: non-FileNotFound error shown")
compose_calls = {}
next_handle_id = 20
offline_frame_cache.clear()

local perm_meta = {
    media_path = "/restricted/file.mov",
    error_code = "PermissionDenied",
    error_msg = "Permission denied",
}

local frame_perm = offline_frame_cache.get_frame(perm_meta)
assert(frame_perm, "Should compose frame for PermissionDenied")
local perm_lines = compose_calls[1].lines
assert(#perm_lines == 4, "PermissionDenied should produce 4 lines, got " .. #perm_lines)
assert(perm_lines[4].text == "Permission denied", "Line 4 should be error_msg only")
print("    ✓ Non-FileNotFound error shown")

-- ============================================================================
-- Test: assert on nil metadata
-- ============================================================================

print("  Testing: assert on nil metadata")
local ok, err = pcall(offline_frame_cache.get_frame, nil)
assert(not ok, "Should error on nil metadata")
assert(tostring(err):match("metadata is nil"), "Error should mention nil metadata")
print("    ✓ Asserts on nil metadata")

-- ============================================================================
-- Test: assert on missing media_path
-- ============================================================================

print("  Testing: assert on missing media_path")
local ok2, err2 = pcall(offline_frame_cache.get_frame, {})
assert(not ok2, "Should error on missing media_path")
assert(tostring(err2):match("media_path is nil"), "Error should mention media_path")
print("    ✓ Asserts on missing media_path")

print("✅ test_offline_frame_composite.lua passed")
