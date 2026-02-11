--- Test: media.lua rate_from_float and Media.load assert on nil/invalid fps
-- Regression: rate_from_float returned 30,1 for nil; Media.load used "or 30" for NULL columns
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end


-- Test 1: Media.load with NULL fps_numerator in DB should assert
-- Mock database to return a row with NULL fps columns
local mock_query_values = {
    [0] = "media_1",        -- id
    [1] = "proj1",          -- project_id
    [2] = "test.mov",       -- name
    [3] = "/path/test.mov", -- file_path
    [4] = 100,              -- duration_frames
    [5] = nil,              -- fps_numerator (NULL!)
    [6] = nil,              -- fps_denominator (NULL!)
    [7] = 1920, [8] = 1080,
    [9] = 2, [10] = "h264",
    [11] = os.time(), [12] = os.time(),
    [13] = "{}",
}

local mock_query = {
    bind_value = function() end,
    exec = function() return true end,
    next = function() return true end,
    value = function(_, idx) return mock_query_values[idx] end,
    finalize = function() end,
}

local mock_db = {
    prepare = function(_, sql) return mock_query end,
}

package.loaded["core.database"] = {
    get_connection = function() return mock_db end,
    init = function() return true end,
}

local Media = require("models.media")

local ok, err = pcall(function()
    Media.load("media_1")
end)

check("Media.load asserts on NULL fps_numerator", not ok)
check("error mentions fps_numerator",
    err and tostring(err):find("fps_numerator") ~= nil)

-- Test 2: Media.create with nil frame_rate should assert via rate_from_float
local ok2, err2 = pcall(function()
    Media.create({
        file_path = "/test.mov",
        name = "test",
        duration = 1000,
        frame_rate = nil,  -- no fps!
        project_id = "proj1",
    })
end)

check("Media.create asserts on nil frame_rate", not ok2)
check("error mentions fps or rate_from_float",
    err2 and (tostring(err2):find("fps") ~= nil or tostring(err2):find("rate_from_float") ~= nil))

-- Test 3: rate_from_float with 0 should assert
local ok3, err3 = pcall(function()
    Media.create({
        file_path = "/test.mov",
        name = "test",
        duration = 1000,
        frame_rate = 0,
        project_id = "proj1",
    })
end)

check("Media.create asserts on fps=0", not ok3)

-- Test 4: Valid fps should still work
local media = Media.create({
    file_path = "/test.mov",
    name = "test",
    duration = 1000,
    frame_rate = 24,
    project_id = "proj1",
})

check("valid fps creates media", media ~= nil)
check("valid fps num = 24", media.frame_rate.fps_numerator == 24)

if failed > 0 then
    print(string.format("❌ test_media_no_fps_fallback.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_media_no_fps_fallback.lua passed (%d assertions)", passed))
