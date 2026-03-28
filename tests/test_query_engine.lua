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
-- Test data: clips with varied attributes
-- ============================================================================

local clips = {
    {
        id = "clip_int_scene1",
        name = "INT_SCENE1_wide",
        codec = "ProRes",
        fps = 24,
        duration = 150,
        enabled = true,
        offline = false,
        volume = 0.8,
        width = 1920,
        height = 1080,
        audio_channels = 2,
        audio_sample_rate = 48000,
        properties = { scene = "42", take = "3", comments = "Good performance" },
    },
    {
        id = "clip_ext_scene2",
        name = "EXT_SCENE2_close",
        codec = "ProRes",
        fps = 24,
        duration = 200,
        enabled = true,
        offline = false,
        volume = 1.0,
        width = 1920,
        height = 1080,
        audio_channels = 2,
        audio_sample_rate = 48000,
        properties = { scene = "7", take = "1", comments = "" },
    },
    {
        id = "clip_interview_a",
        name = "Interview_CamA",
        codec = "DNxHD",
        fps = 25,
        duration = 3000,
        enabled = false,
        offline = false,
        volume = 1.0,
        width = 3840,
        height = 2160,
        audio_channels = 4,
        audio_sample_rate = 48000,
        properties = { scene = "INT42", take = "7", comments = "Select" },
    },
    {
        id = "clip_painting",
        name = "PAINTING_insert",
        codec = "H264",
        fps = 30,
        duration = 75,
        enabled = true,
        offline = true,
        volume = 0.0,
        width = 1280,
        height = 720,
        audio_channels = 0,
        audio_sample_rate = 0,
        properties = { scene = "12", take = "2" },
    },
    {
        id = "clip_a001_01",
        name = "A001_01_take3",
        codec = "ProRes",
        fps = 24,
        duration = 480,
        enabled = true,
        offline = false,
        volume = 1.0,
        width = 1920,
        height = 1080,
        audio_channels = 2,
        audio_sample_rate = 48000,
        properties = { scene = "1", take = "3" },
    },
    {
        id = "clip_xa001",
        name = "XA001_broll",
        codec = "ProRes",
        fps = 24,
        duration = 120,
        enabled = true,
        offline = false,
        volume = 0.5,
        width = 1920,
        height = 1080,
        audio_channels = 2,
        audio_sample_rate = 44100,
        properties = { scene = "42B", take = "1" },
    },
    {
        id = "clip_ba001",
        name = "BA001_sfx",
        codec = "WAV",
        fps = 48000,
        duration = 96000,
        enabled = true,
        offline = false,
        volume = 0.9,
        width = 0,
        height = 0,
        audio_channels = 1,
        audio_sample_rate = 48000,
        properties = {},
    },
}

local query_engine = require("core.query_engine")

-- ============================================================================
-- match() — text operators
-- ============================================================================
print("--- match: text operators ---")

-- Contains
check("contains matches substring",
    query_engine.match(clips[1], {column = "name", operator = "contains", value = "INT"}))
check("contains matches substring (interview)",
    query_engine.match(clips[3], {column = "name", operator = "contains", value = "INT"}))
check("contains rejects non-match",
    not query_engine.match(clips[2], {column = "name", operator = "contains", value = "INT"}))
check("contains case-insensitive",
    query_engine.match(clips[1], {column = "name", operator = "contains", value = "int"}))
check("contains case-insensitive (painting)",
    query_engine.match(clips[4], {column = "name", operator = "contains", value = "paint"}))

-- Begins With
check("begins_with matches prefix",
    query_engine.match(clips[5], {column = "name", operator = "begins_with", value = "A001"}))
check("begins_with rejects non-prefix (XA001)",
    not query_engine.match(clips[6], {column = "name", operator = "begins_with", value = "A001"}))
check("begins_with rejects non-prefix (BA001)",
    not query_engine.match(clips[7], {column = "name", operator = "begins_with", value = "A001"}))
check("begins_with case-insensitive",
    query_engine.match(clips[5], {column = "name", operator = "begins_with", value = "a001"}))

-- Ends With
check("ends_with matches suffix",
    query_engine.match(clips[1], {column = "name", operator = "ends_with", value = "wide"}))
check("ends_with rejects non-suffix",
    not query_engine.match(clips[2], {column = "name", operator = "ends_with", value = "wide"}))
check("ends_with case-insensitive",
    query_engine.match(clips[1], {column = "name", operator = "ends_with", value = "WIDE"}))

-- Matches Exactly
check("matches_exactly full match",
    query_engine.match(clips[3], {column = "name", operator = "matches_exactly", value = "Interview_CamA"}))
check("matches_exactly rejects partial",
    not query_engine.match(clips[3], {column = "name", operator = "matches_exactly", value = "Interview"}))
check("matches_exactly case-insensitive",
    query_engine.match(clips[3], {column = "name", operator = "matches_exactly", value = "interview_cama"}))

-- ============================================================================
-- match() — numeric operators
-- ============================================================================
print("--- match: numeric operators ---")

check("equals matches exact fps",
    query_engine.match(clips[1], {column = "fps", operator = "equals", value = "24"}))
check("equals rejects different fps",
    not query_engine.match(clips[3], {column = "fps", operator = "equals", value = "24"}))
check("greater_than matches",
    query_engine.match(clips[3], {column = "duration", operator = "greater_than", value = "200"}))
check("greater_than rejects equal",
    not query_engine.match(clips[2], {column = "duration", operator = "greater_than", value = "200"}))
check("less_than matches",
    query_engine.match(clips[4], {column = "duration", operator = "less_than", value = "100"}))
check("less_than rejects equal",
    not query_engine.match(clips[1], {column = "duration", operator = "less_than", value = "150"}))

-- ============================================================================
-- match() — boolean fields
-- ============================================================================
print("--- match: boolean fields ---")

check("enabled equals true",
    query_engine.match(clips[1], {column = "enabled", operator = "equals", value = "true"}))
check("enabled equals false (disabled clip)",
    query_engine.match(clips[3], {column = "enabled", operator = "equals", value = "false"}))
check("offline equals true",
    query_engine.match(clips[4], {column = "offline", operator = "equals", value = "true"}))

-- ============================================================================
-- match() — codec and other media fields
-- ============================================================================
print("--- match: media fields ---")

check("codec contains ProRes",
    query_engine.match(clips[1], {column = "codec", operator = "contains", value = "ProRes"}))
check("codec contains dnxhd (case insensitive)",
    query_engine.match(clips[3], {column = "codec", operator = "contains", value = "dnxhd"}))
check("audio_channels equals 4",
    query_engine.match(clips[3], {column = "audio_channels", operator = "equals", value = "4"}))
check("audio_sample_rate equals 44100",
    query_engine.match(clips[6], {column = "audio_sample_rate", operator = "equals", value = "44100"}))

-- ============================================================================
-- match() — custom properties
-- ============================================================================
print("--- match: custom properties ---")

check("scene contains 42",
    query_engine.match(clips[1], {column = "scene", operator = "contains", value = "42"}))
check("scene contains 42 (INT42)",
    query_engine.match(clips[3], {column = "scene", operator = "contains", value = "42"}))
check("take equals 3",
    query_engine.match(clips[1], {column = "take", operator = "matches_exactly", value = "3"}))
check("comments contains Good",
    query_engine.match(clips[1], {column = "comments", operator = "contains", value = "Good"}))
check("missing property returns no match",
    not query_engine.match(clips[7], {column = "scene", operator = "contains", value = "42"}))

-- ============================================================================
-- match() — volume (numeric, fractional)
-- ============================================================================
print("--- match: volume ---")

check("volume less_than 1.0",
    query_engine.match(clips[1], {column = "volume", operator = "less_than", value = "1.0"}))
check("volume equals 0.0",
    query_engine.match(clips[4], {column = "volume", operator = "equals", value = "0"}))

-- ============================================================================
-- match_all() — AND logic
-- ============================================================================
print("--- match_all ---")

local and_queries = {
    {column = "codec", operator = "contains", value = "ProRes"},
    {column = "fps", operator = "equals", value = "24"},
}
check("match_all: ProRes AND 24fps matches clip 1",
    query_engine.match_all(clips[1], and_queries))
check("match_all: ProRes AND 24fps matches clip 5",
    query_engine.match_all(clips[5], and_queries))
check("match_all: DNxHD fails ProRes AND 24fps",
    not query_engine.match_all(clips[3], and_queries))
check("match_all: H264 fails ProRes AND 24fps",
    not query_engine.match_all(clips[4], and_queries))

check("match_all: empty queries matches everything",
    query_engine.match_all(clips[1], {}))

-- ============================================================================
-- filter() — splits clips into matching/non-matching
-- ============================================================================
print("--- filter ---")

local queries = {{column = "codec", operator = "contains", value = "ProRes"}}
local matching, non_matching = query_engine.filter(clips, queries)

check("filter: matching count for ProRes",
    #matching == 4)  -- clips 1, 2, 5, 6
check("filter: non_matching count",
    #non_matching == 3)  -- clips 3, 4, 7
check("filter: total equals input",
    #matching + #non_matching == #clips)

-- Verify specific clips in matching
local matching_ids = {}
for _, c in ipairs(matching) do matching_ids[c.id] = true end
check("filter: clip_int_scene1 is ProRes", matching_ids["clip_int_scene1"] == true)
check("filter: clip_interview_a is NOT ProRes", matching_ids["clip_interview_a"] == nil)

-- Multi-criteria filter
local matching2, _ = query_engine.filter(clips, and_queries)
check("filter: ProRes+24fps count", #matching2 == 4)  -- clips 1, 2, 5, 6

-- Empty criteria matches all
local all_match, none = query_engine.filter(clips, {})
check("filter: empty queries matches all", #all_match == #clips)
check("filter: empty queries non_matching is empty", #none == 0)

-- ============================================================================
-- get_searchable_fields()
-- ============================================================================
print("--- get_searchable_fields ---")

local fields = query_engine.get_searchable_fields()
check("searchable_fields returns table", type(fields) == "table")
check("searchable_fields is non-empty", #fields > 0)

-- Find specific fields and check properties
local field_by_name = {}
for _, f in ipairs(fields) do field_by_name[f.name] = f end

check("name field exists", field_by_name["name"] ~= nil)
check("name field is text type", field_by_name["name"].type == "text")
check("name field is editable", field_by_name["name"].editable == true)

check("codec field exists", field_by_name["codec"] ~= nil)
check("codec field is not editable", field_by_name["codec"].editable == false)

check("fps field exists", field_by_name["fps"] ~= nil)
check("fps field is numeric", field_by_name["fps"].type == "numeric")
check("fps field is not editable", field_by_name["fps"].editable == false)

check("duration field exists", field_by_name["duration"] ~= nil)
check("duration field is not editable", field_by_name["duration"].editable == false)

check("enabled field exists", field_by_name["enabled"] ~= nil)
check("volume field exists", field_by_name["volume"] ~= nil)

-- ============================================================================
-- Error cases
-- ============================================================================
print("--- error cases ---")

expect_error("invalid operator asserts",
    function() query_engine.match(clips[1], {column = "name", operator = "regex", value = "x"}) end,
    "operator")

expect_error("empty value asserts",
    function() query_engine.match(clips[1], {column = "name", operator = "contains", value = ""}) end,
    "value")

expect_error("nil column asserts",
    function() query_engine.match(clips[1], {column = nil, operator = "contains", value = "x"}) end,
    "column")

-- ============================================================================
-- Summary
-- ============================================================================
print("")
if fail_count > 0 then
    print(string.format("❌ test_query_engine.lua: %d passed, %d FAILED", pass_count, fail_count))
    os.exit(1)
end
print(string.format("✅ test_query_engine.lua passed (%d assertions)", pass_count))
