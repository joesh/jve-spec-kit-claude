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

-- ============================================================================
-- Test data: 12 clips with varied codecs, fps, names
-- ============================================================================

local function make_clips()
    return {
        {id = "pr24_wide", name = "INT_Scene1_wide", codec = "ProRes", fps = 24,
         duration = 150, enabled = true, offline = false, volume = 0.8,
         properties = {scene = "42", take = "3"}},

        {id = "pr24_close", name = "EXT_Scene2_close", codec = "ProRes", fps = 24,
         duration = 200, enabled = true, offline = false, volume = 1.0,
         properties = {scene = "7", take = "1"}},

        {id = "dnx25_cam", name = "Interview_CamA", codec = "DNxHD", fps = 25,
         duration = 3000, enabled = false, offline = false, volume = 1.0,
         properties = {scene = "INT42", take = "7"}},

        {id = "h264_30", name = "PAINTING_insert", codec = "H264", fps = 30,
         duration = 75, enabled = true, offline = true, volume = 0.0,
         properties = {scene = "12", take = "2"}},

        {id = "pr24_take3", name = "A001_01_take3", codec = "ProRes", fps = 24,
         duration = 480, enabled = true, offline = false, volume = 1.0,
         properties = {scene = "1", take = "3"}},

        {id = "pr24_broll", name = "XA001_broll", codec = "ProRes", fps = 24,
         duration = 120, enabled = true, offline = false, volume = 0.5,
         properties = {scene = "42B", take = "1"}},

        {id = "wav_sfx", name = "BA001_sfx", codec = "WAV", fps = 48000,
         duration = 96000, enabled = true, offline = false, volume = 0.9,
         properties = {}},

        {id = "dnx25_b", name = "Interview_CamB", codec = "DNxHD", fps = 25,
         duration = 2800, enabled = true, offline = false, volume = 1.0,
         properties = {scene = "INT42", take = "8"}},

        {id = "h264_24", name = "Drone_flyover", codec = "H264", fps = 24,
         duration = 360, enabled = true, offline = false, volume = 0.0,
         properties = {scene = "EXT1"}},

        {id = "pr25_pickup", name = "Pickup_shot", codec = "ProRes", fps = 25,
         duration = 90, enabled = true, offline = false, volume = 1.0,
         properties = {scene = "9", take = "5"}},

        {id = "wav_atmos", name = "Atmos_forest", codec = "WAV", fps = 48000,
         duration = 240000, enabled = true, offline = false, volume = 0.7,
         properties = {}},

        {id = "dnx30_test", name = "TestChart_bars", codec = "DNxHD", fps = 30,
         duration = 150, enabled = false, offline = false, volume = 1.0,
         properties = {scene = "CAL"}},
    }
end

local dkjson = require("dkjson")
local sift_state = require("core.sift_state")

-- Helper: build id set from evaluate result
local function id_set(id_list)
    local s = {}
    for _, id in ipairs(id_list) do s[id] = true end
    return s
end

-- ============================================================================
-- 1. apply() sets active, computes hidden_ids correctly
-- ============================================================================
print("--- apply ---")
do
    sift_state.clear()
    local clips = make_clips()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "ProRes"})

    check("apply: is_active after apply", sift_state.is_active())

    local result = sift_state.evaluate(clips)
    local vis = id_set(result.visible_ids)
    local hid = id_set(result.hidden_ids)

    -- ProRes clips: pr24_wide, pr24_close, pr24_take3, pr24_broll, pr25_pickup
    check("apply: pr24_wide visible", vis["pr24_wide"] == true)
    check("apply: pr24_close visible", vis["pr24_close"] == true)
    check("apply: pr24_take3 visible", vis["pr24_take3"] == true)
    check("apply: pr24_broll visible", vis["pr24_broll"] == true)
    check("apply: pr25_pickup visible", vis["pr25_pickup"] == true)

    -- Non-ProRes clips hidden
    check("apply: dnx25_cam hidden", hid["dnx25_cam"] == true)
    check("apply: h264_30 hidden", hid["h264_30"] == true)
    check("apply: wav_sfx hidden", hid["wav_sfx"] == true)
    check("apply: dnx25_b hidden", hid["dnx25_b"] == true)
    check("apply: h264_24 hidden", hid["h264_24"] == true)
    check("apply: wav_atmos hidden", hid["wav_atmos"] == true)
    check("apply: dnx30_test hidden", hid["dnx30_test"] == true)

    check("apply: visible + hidden = total",
        #result.visible_ids + #result.hidden_ids == #clips)
end

-- ============================================================================
-- 2. expand() adds OR — previously hidden clips matching new criteria visible
-- ============================================================================
print("--- expand ---")
do
    sift_state.clear()
    local clips = make_clips()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "ProRes"})
    sift_state.expand(clips, {column = "codec", operator = "contains", value = "DNxHD"})

    local result = sift_state.evaluate(clips)
    local vis = id_set(result.visible_ids)

    -- ProRes + DNxHD should all be visible
    check("expand: pr24_wide visible", vis["pr24_wide"] == true)
    check("expand: dnx25_cam now visible", vis["dnx25_cam"] == true)
    check("expand: dnx25_b now visible", vis["dnx25_b"] == true)
    check("expand: dnx30_test now visible", vis["dnx30_test"] == true)

    -- H264 and WAV still hidden
    local hid = id_set(result.hidden_ids)
    check("expand: h264_30 still hidden", hid["h264_30"] == true)
    check("expand: wav_sfx still hidden", hid["wav_sfx"] == true)
    check("expand: h264_24 still hidden", hid["h264_24"] == true)

    check("expand: visible + hidden = total",
        #result.visible_ids + #result.hidden_ids == #clips)
end

-- ============================================================================
-- 3. narrow() adds AND — visible clips not matching new criteria become hidden
-- ============================================================================
print("--- narrow ---")
do
    sift_state.clear()
    local clips = make_clips()
    -- Start with ProRes (5 clips visible)
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "ProRes"})
    -- Narrow to 24fps only
    sift_state.narrow(clips, {column = "fps", operator = "equals", value = "24"})

    local result = sift_state.evaluate(clips)
    local vis = id_set(result.visible_ids)
    local hid = id_set(result.hidden_ids)

    -- ProRes + 24fps: pr24_wide, pr24_close, pr24_take3, pr24_broll
    check("narrow: pr24_wide visible", vis["pr24_wide"] == true)
    check("narrow: pr24_close visible", vis["pr24_close"] == true)
    check("narrow: pr24_take3 visible", vis["pr24_take3"] == true)
    check("narrow: pr24_broll visible", vis["pr24_broll"] == true)

    -- pr25_pickup is ProRes but 25fps — should be hidden now
    check("narrow: pr25_pickup hidden (25fps)", hid["pr25_pickup"] == true)

    -- Non-ProRes still hidden
    check("narrow: h264_30 hidden", hid["h264_30"] == true)
    check("narrow: dnx25_cam hidden", hid["dnx25_cam"] == true)

    check("narrow: visible + hidden = total",
        #result.visible_ids + #result.hidden_ids == #clips)
end

-- ============================================================================
-- 4. clear() resets everything
-- ============================================================================
print("--- clear ---")
do
    sift_state.clear()
    local clips = make_clips()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "ProRes"})
    check("clear: active before clear", sift_state.is_active())

    sift_state.clear()
    check("clear: not active after clear", not sift_state.is_active())

    local criteria = sift_state.get_criteria()
    check("clear: criteria empty", #criteria == 0)
end

-- ============================================================================
-- 5. is_active() returns correct state
-- ============================================================================
print("--- is_active ---")
do
    sift_state.clear()
    check("is_active: false initially", not sift_state.is_active())

    local clips = make_clips()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "H264"})
    check("is_active: true after apply", sift_state.is_active())

    sift_state.clear()
    check("is_active: false after clear", not sift_state.is_active())
end

-- ============================================================================
-- 6. evaluate() after clip list changes
-- ============================================================================
print("--- evaluate with changed clips ---")
do
    sift_state.clear()
    local clips = make_clips()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "ProRes"})

    -- Add a new ProRes clip
    clips[#clips + 1] = {id = "pr24_new", name = "NewShot", codec = "ProRes", fps = 24,
        duration = 50, enabled = true, offline = false, volume = 1.0, properties = {}}

    local result = sift_state.evaluate(clips)
    local vis = id_set(result.visible_ids)
    check("evaluate: new ProRes clip visible", vis["pr24_new"] == true)
    check("evaluate: visible + hidden = new total",
        #result.visible_ids + #result.hidden_ids == #clips)

    -- Add a non-matching clip
    clips[#clips + 1] = {id = "h264_extra", name = "Extra", codec = "H264", fps = 30,
        duration = 100, enabled = true, offline = false, volume = 1.0, properties = {}}

    local result2 = sift_state.evaluate(clips)
    local hid2 = id_set(result2.hidden_ids)
    check("evaluate: new H264 clip hidden", hid2["h264_extra"] == true)
    check("evaluate: visible + hidden = updated total",
        #result2.visible_ids + #result2.hidden_ids == #clips)
end

-- ============================================================================
-- 7. to_json()/from_json() round-trip preserves criteria
-- ============================================================================
print("--- json round-trip ---")
do
    sift_state.clear()
    local clips = make_clips()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "ProRes"})
    sift_state.narrow(clips, {column = "fps", operator = "equals", value = "24"})

    local json_str = sift_state.to_json()
    check("to_json: returns string", type(json_str) == "string")

    -- Verify JSON is valid
    local decoded = dkjson.decode(json_str)
    check("to_json: valid JSON", decoded ~= nil)

    -- Restore into fresh state
    sift_state.clear()
    check("round-trip: clear before from_json", not sift_state.is_active())

    sift_state.from_json(json_str)
    check("round-trip: active after from_json", sift_state.is_active())

    local criteria = sift_state.get_criteria()
    check("round-trip: criteria count preserved", #criteria == 2)

    -- First criterion: apply ProRes
    check("round-trip: first query column", criteria[1].query.column == "codec")
    check("round-trip: first query operator", criteria[1].query.operator == "contains")
    check("round-trip: first query value", criteria[1].query.value == "ProRes")
    check("round-trip: first mode is apply", criteria[1].mode == "fresh")

    -- Second criterion: narrow fps=24
    check("round-trip: second query column", criteria[2].query.column == "fps")
    check("round-trip: second query operator", criteria[2].query.operator == "equals")
    check("round-trip: second query value", criteria[2].query.value == "24")
    check("round-trip: second mode is narrow", criteria[2].mode == "narrow")
end

-- ============================================================================
-- 8. from_json() then evaluate() reproduces same visible/hidden sets
-- ============================================================================
print("--- from_json + evaluate ---")
do
    sift_state.clear()
    local clips = make_clips()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "ProRes"})
    sift_state.expand(clips, {column = "codec", operator = "contains", value = "DNxHD"})

    local result_before = sift_state.evaluate(clips)
    local json_str = sift_state.to_json()

    sift_state.clear()
    sift_state.from_json(json_str)

    local result_after = sift_state.evaluate(clips)

    check("from_json+eval: same visible count",
        #result_before.visible_ids == #result_after.visible_ids)
    check("from_json+eval: same hidden count",
        #result_before.hidden_ids == #result_after.hidden_ids)

    -- Verify exact same IDs visible
    local vis_before = id_set(result_before.visible_ids)
    local vis_after = id_set(result_after.visible_ids)
    local all_match = true
    for _, vid in ipairs(result_before.visible_ids) do
        if not vis_after[vid] then all_match = false end
    end
    for _, vid in ipairs(result_after.visible_ids) do
        if not vis_before[vid] then all_match = false end
    end
    check("from_json+eval: identical visible sets", all_match)
end

-- ============================================================================
-- 9. Edge: sift where all clips match (all visible, still active)
-- ============================================================================
print("--- edge: all match ---")
do
    sift_state.clear()
    local clips = make_clips()
    -- All clips have duration > 0
    sift_state.apply(clips, {column = "duration", operator = "greater_than", value = "0"})

    check("all-match: still active", sift_state.is_active())

    local result = sift_state.evaluate(clips)
    check("all-match: all visible", #result.visible_ids == #clips)
    check("all-match: none hidden", #result.hidden_ids == 0)
end

-- ============================================================================
-- 10. Edge: sift where no clips match (all hidden, still active)
-- ============================================================================
print("--- edge: none match ---")
do
    sift_state.clear()
    local clips = make_clips()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "XDCAM"})

    check("none-match: still active", sift_state.is_active())

    local result = sift_state.evaluate(clips)
    check("none-match: none visible", #result.visible_ids == 0)
    check("none-match: all hidden", #result.hidden_ids == #clips)
end

-- ============================================================================
-- 11. Edge: expand after clear (should work like fresh apply)
-- ============================================================================
print("--- edge: expand after clear ---")
do
    sift_state.clear()
    local clips = make_clips()

    -- expand on cleared state should behave like apply
    sift_state.expand(clips, {column = "codec", operator = "contains", value = "WAV"})

    check("expand-after-clear: is active", sift_state.is_active())

    local result = sift_state.evaluate(clips)
    local vis = id_set(result.visible_ids)

    check("expand-after-clear: wav_sfx visible", vis["wav_sfx"] == true)
    check("expand-after-clear: wav_atmos visible", vis["wav_atmos"] == true)
    check("expand-after-clear: visible count = 2", #result.visible_ids == 2)
    check("expand-after-clear: hidden count = 10", #result.hidden_ids == 10)
end

-- ============================================================================
-- 12. get_criteria() tracks modes correctly through apply/expand/narrow
-- ============================================================================
print("--- get_criteria ---")
do
    sift_state.clear()
    local clips = make_clips()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "ProRes"})
    sift_state.expand(clips, {column = "codec", operator = "contains", value = "DNxHD"})
    sift_state.narrow(clips, {column = "fps", operator = "equals", value = "25"})

    local criteria = sift_state.get_criteria()
    check("get_criteria: count is 3", #criteria == 3)
    check("get_criteria: first mode = apply", criteria[1].mode == "fresh")
    check("get_criteria: second mode = expand", criteria[2].mode == "expand")
    check("get_criteria: third mode = narrow", criteria[3].mode == "narrow")
end

-- ============================================================================
-- 13. apply() replaces existing sift
-- ============================================================================
print("--- apply replaces ---")
do
    sift_state.clear()
    local clips = make_clips()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "ProRes"})
    sift_state.narrow(clips, {column = "fps", operator = "equals", value = "24"})

    -- Second apply should replace, not accumulate
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "H264"})

    local criteria = sift_state.get_criteria()
    check("apply-replaces: criteria count = 1", #criteria == 1)
    check("apply-replaces: criterion is H264",
        criteria[1].query.value == "H264")

    local result = sift_state.evaluate(clips)
    local vis = id_set(result.visible_ids)
    check("apply-replaces: h264_30 visible", vis["h264_30"] == true)
    check("apply-replaces: h264_24 visible", vis["h264_24"] == true)
    check("apply-replaces: visible count = 2", #result.visible_ids == 2)
end

-- ============================================================================
-- 14. Error: evaluate without clips
-- ============================================================================
print("--- error cases ---")
do
    sift_state.clear()

    expect_error("evaluate with nil clips",
        function() sift_state.evaluate(nil) end)

    expect_error("apply with nil clips",
        function() sift_state.apply(nil, {column = "name", operator = "contains", value = "x"}) end)

    expect_error("apply with nil query",
        function() sift_state.apply(make_clips(), nil) end)
end

-- ============================================================================
-- Summary
-- ============================================================================
print("")
if fail_count > 0 then
    print(string.format("❌ test_sift_state.lua: %d passed, %d FAILED", pass_count, fail_count))
    os.exit(1)
end
print(string.format("✅ test_sift_state.lua passed (%d assertions)", pass_count))
