-- Behavioral test: browser_state.normalize_selection handles timeline items correctly.
-- Complements test_browser_state_rational_duration.lua (code-inspection test)
-- which guards against Rational→integer refactor regressions.

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

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
end

print("\n=== browser_state normalize_timeline Behavioral Tests ===")

-- Stub Qt-dependent modules that browser_state's require chain needs
if not package.loaded["ui.selection_hub"] then
    package.loaded["ui.selection_hub"] = {
        set_selection = function() end,
        connect = function() end,
    }
end

local browser_state = require("ui.project_browser.browser_state")

-- 1. Standard sequence with integer duration
local items = {{
    type = "timeline",
    id = "seq1",
    kind = "sequence",
    name = "Main Timeline",
    duration = 2400,
    frame_rate = {fps_numerator = 24, fps_denominator = 1},
    width = 1920,
    height = 1080,
    project_id = "proj1",
}}
local result = browser_state.normalize_selection(items, {})
check("returns 1 entry", #result == 1)
if #result >= 1 then
    local e = result[1]
    check("id = seq1", e.id == "seq1")
    check("name = 'Main Timeline'", e.name == "Main Timeline")
    check("duration = 2400", e.duration == 2400)
    check("source_in = 0", e.source_in == 0)
    check("source_out = 2400", e.source_out == 2400)
    check("frame_rate preserved", e.frame_rate.fps_numerator == 24)
    check("width = 1920", e.width == 1920)
    check("height = 1080", e.height == 1080)
    check("item_type = 'timeline'", e.item_type == "timeline")
    check("project_id = proj1", e.project_id == "proj1")
end

-- 2. Empty duration (no clips in sequence)
local empty_items = {{
    type = "timeline",
    id = "seq_empty",
    kind = "sequence",
    name = "Empty",
    duration = 0,
    frame_rate = {fps_numerator = 25, fps_denominator = 1},
    width = 1920,
    height = 1080,
    project_id = "proj1",
}}
result = browser_state.normalize_selection(empty_items, {})
check("empty: returns 1 entry", #result == 1)
if #result >= 1 then
    check("empty: duration=0", result[1].duration == 0)
    check("empty: source_out=0", result[1].source_out == 0)
end

-- 3. NTSC frame rate (non-integer fps)
local ntsc_items = {{
    type = "timeline",
    id = "seq_ntsc",
    kind = "sequence",
    name = "NTSC",
    duration = 90000,
    frame_rate = {fps_numerator = 30000, fps_denominator = 1001},
    width = 1920,
    height = 1080,
    project_id = "proj1",
}}
result = browser_state.normalize_selection(ntsc_items, {})
check("ntsc: returns 1 entry", #result == 1)
if #result >= 1 then
    check("ntsc: frame_rate.fps_numerator=30000", result[1].frame_rate.fps_numerator == 30000)
    check("ntsc: frame_rate.fps_denominator=1001", result[1].frame_rate.fps_denominator == 1001)
end

-- 4. nil items returns empty
result = browser_state.normalize_selection(nil, {})
check("nil items: empty table", #result == 0)

-- 5. Non-timeline item type is ignored
result = browser_state.normalize_selection({{type = "bin", id = "bin1"}}, {})
check("bin type: ignored", #result == 0)

-- 6. String duration should fail (must be integer)
expect_error("string duration asserts",
    function()
        browser_state.normalize_selection({{
            type = "timeline",
            id = "bad",
            name = "Bad",
            duration = "100",
            frame_rate = {fps_numerator = 24, fps_denominator = 1},
            width = 1920,
            height = 1080,
            project_id = "proj1",
        }}, {})
    end,
    "duration must be integer")

-- 7. Missing frame_rate should fail
expect_error("missing frame_rate asserts",
    function()
        browser_state.normalize_selection({{
            type = "timeline",
            id = "bad2",
            name = "Bad",
            duration = 100,
            width = 1920,
            height = 1080,
            project_id = "proj1",
        }}, {})
    end,
    "missing frame_rate")

-- 8. project_id from context fallback
local ctx_items = {{
    type = "timeline",
    id = "seq_no_proj",
    kind = "sequence",
    name = "No Proj",
    duration = 100,
    frame_rate = {fps_numerator = 24, fps_denominator = 1},
    width = 1920,
    height = 1080,
}}
result = browser_state.normalize_selection(ctx_items, {project_id = "ctx_proj"})
check("project_id from context", #result == 1)
if #result >= 1 then
    check("context project_id = ctx_proj", result[1].project_id == "ctx_proj")
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_browser_state_normalize_timeline.lua passed")
