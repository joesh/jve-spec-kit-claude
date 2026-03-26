require("test_env")

local query_engine = require("core.query_engine")
local sift_state = require("core.sift_state")
local smart_bin = require("core.smart_bin")
local json = require("dkjson")

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

-- ============================================================================
-- Generate 1500 clips with varied attributes
-- ============================================================================
print("--- generating 1500 test clips ---")

local codecs = {"ProRes", "DNxHD", "H264", "XDCAM", "CineForm", "WAV", "AIFF", "FLAC"}
local fps_values = {24, 25, 30, 48, 60}
local scenes = {}
for i = 1, 50 do scenes[i] = tostring(i) end

local clips = {}
for i = 1, 1500 do
    local codec_idx = ((i - 1) % #codecs) + 1
    local fps_idx = ((i - 1) % #fps_values) + 1
    local scene_idx = ((i - 1) % #scenes) + 1
    clips[i] = {
        id = string.format("clip_%04d", i),
        name = string.format("Clip_%s_Scene%s_Take%d", codecs[codec_idx], scenes[scene_idx], (i % 7) + 1),
        codec = codecs[codec_idx],
        fps = fps_values[fps_idx],
        duration = 50 + (i * 7) % 500,
        enabled = (i % 10) ~= 0,  -- 10% disabled
        offline = (i % 50) == 0,   -- 2% offline
        volume = 0.5 + (i % 10) * 0.05,
        width = (i % 3 == 0) and 3840 or 1920,
        height = (i % 3 == 0) and 2160 or 1080,
        audio_channels = (codec_idx <= 5) and 2 or ((i % 2 == 0) and 1 or 4),
        audio_sample_rate = 48000,
        timeline_start_frame = i * 100,
        properties = {
            scene = scenes[scene_idx],
            take = tostring((i % 7) + 1),
            comments = (i % 20 == 0) and "Selected take" or "",
        },
    }
end

print(string.format("Generated %d clips", #clips))

-- ============================================================================
-- Performance: query_engine.filter with single text criterion
-- ============================================================================
print("--- perf: single text filter ---")

local t0 = os.clock()
local iterations = 100
for _ = 1, iterations do
    query_engine.filter(clips, {{column = "codec", operator = "contains", value = "ProRes"}})
end
local elapsed = os.clock() - t0
local per_call_ms = (elapsed / iterations) * 1000

print(string.format("  filter (1500 clips, 1 criterion): %.2f ms/call (%d iterations)", per_call_ms, iterations))
check("single filter < 10ms", per_call_ms < 10)

-- ============================================================================
-- Performance: query_engine.filter with 3 criteria (AND)
-- ============================================================================
print("--- perf: multi-criteria filter ---")

t0 = os.clock()
for _ = 1, iterations do
    query_engine.filter(clips, {
        {column = "codec", operator = "contains", value = "ProRes"},
        {column = "fps", operator = "equals", value = "24"},
        {column = "scene", operator = "contains", value = "1"},
    })
end
elapsed = os.clock() - t0
per_call_ms = (elapsed / iterations) * 1000

print(string.format("  filter (1500 clips, 3 criteria): %.2f ms/call", per_call_ms))
check("multi filter < 20ms", per_call_ms < 20)

-- ============================================================================
-- Performance: sift_state.apply + evaluate
-- ============================================================================
print("--- perf: sift apply + evaluate ---")

t0 = os.clock()
for _ = 1, iterations do
    sift_state.clear()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "ProRes"})
    sift_state.evaluate(clips)
end
elapsed = os.clock() - t0
per_call_ms = (elapsed / iterations) * 1000

print(string.format("  sift apply+evaluate (1500 clips): %.2f ms/call", per_call_ms))
check("sift apply+evaluate < 20ms", per_call_ms < 20)
sift_state.clear()

-- ============================================================================
-- Performance: sift compose (apply + expand + narrow + evaluate)
-- ============================================================================
print("--- perf: sift compose ---")

t0 = os.clock()
for _ = 1, iterations do
    sift_state.clear()
    sift_state.apply(clips, {column = "codec", operator = "contains", value = "ProRes"})
    sift_state.expand(clips, {column = "codec", operator = "contains", value = "DNxHD"})
    sift_state.narrow(clips, {column = "fps", operator = "equals", value = "24"})
    sift_state.evaluate(clips)
end
elapsed = os.clock() - t0
per_call_ms = (elapsed / iterations) * 1000

print(string.format("  sift compose (1500 clips, 3 ops): %.2f ms/call", per_call_ms))
check("sift compose < 30ms", per_call_ms < 30)
sift_state.clear()

-- ============================================================================
-- Performance: smart_bin evaluate (no DB, just criteria matching)
-- ============================================================================
print("--- perf: smart bin evaluate ---")

local sb_record = {
    criteria_json = json.encode({
        {column = "codec", operator = "contains", value = "ProRes"},
        {column = "fps", operator = "equals", value = "24"},
    }),
}

t0 = os.clock()
for _ = 1, iterations do
    smart_bin.evaluate(sb_record, clips)
end
elapsed = os.clock() - t0
per_call_ms = (elapsed / iterations) * 1000

print(string.format("  smart_bin evaluate (1500 clips): %.2f ms/call", per_call_ms))
check("smart_bin evaluate < 20ms", per_call_ms < 20)

-- ============================================================================
-- Performance: find_state with 1500 clips
-- ============================================================================
print("--- perf: find_state ---")
local find_state = require("core.find_state")

t0 = os.clock()
for _ = 1, iterations do
    find_state.execute(clips, {column = "name", operator = "contains", value = "Scene1"})
end
elapsed = os.clock() - t0
per_call_ms = (elapsed / iterations) * 1000

print(string.format("  find_state execute (1500 clips): %.2f ms/call", per_call_ms))
check("find_state execute < 10ms", per_call_ms < 10)
find_state.clear()

-- ============================================================================
-- Summary
-- ============================================================================
print("")
if fail_count > 0 then
    print(string.format("❌ test_query_engine_performance.lua: %d passed, %d FAILED", pass_count, fail_count))
    os.exit(1)
end
print(string.format("✅ test_query_engine_performance.lua passed (%d assertions)", pass_count))
