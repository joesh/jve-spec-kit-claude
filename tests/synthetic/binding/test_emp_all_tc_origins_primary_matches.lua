-- test_emp_all_tc_origins_primary_matches.lua
--
-- Contract: when MediaFileInfo reports an authoritative TC origin, the
-- corresponding `all_*_tc_origins` vector must be non-empty AND its first
-- entry must equal the primary TC. Consumers (media_relinker, matchers)
-- depend on this so they can treat [1] as the primary and walk the rest
-- as alternatives.
--
-- Two probe paths that the 0dcd908b "surface all TC origins" change missed
-- and which this test pins:
--   1. Broadcast MXF where TC is derived from stream start_time (no
--      "timecode" metadata tag) — collect_all_video_tc_origins() only
--      walks metadata tags and returns empty, but first_frame_tc is set
--      from the PTS path.
--   2. BRAW container — first_frame_tc comes from the BRAW SDK
--      (build_braw_info) which never populates all_video_tc_origins.
-- Both produce the relink dialog crash:
--   probe_result_from_emp_info: all_video_tc_origins[1] must equal
--   first_frame_tc (primary)
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        tests/synthetic/binding/test_emp_all_tc_origins_primary_matches.lua
local test_env = require("test_env")

local EMP = qt_constants and qt_constants.EMP
assert(EMP, "EMP bindings not available — run via: jve --test this_script.lua")

print("=== test_emp_all_tc_origins_primary_matches.lua ===")

-- Returns the probed info, or nil if MEDIA_FILE_OPEN failed (e.g. BRAW SDK
-- not loadable in the make-VM sandbox). Caller decides whether absent
-- coverage is fatal: MOV/MXF must succeed, BRAW skips with a loud warning.
local function probe(path)
    local mf = EMP.MEDIA_FILE_OPEN(path)
    if not mf then return nil end
    local info = EMP.MEDIA_FILE_INFO(mf)
    assert(info, "MEDIA_FILE_INFO returned nil: " .. path)
    EMP.MEDIA_FILE_CLOSE(mf)
    return info
end

local function check_video_contract(label, info)
    print(string.format("  %s: has_video_tc_origin=%s first_frame_tc=%s #all=%d",
        label, tostring(info.has_video_tc_origin),
        tostring(info.first_frame_tc),
        info.all_video_tc_origins and #info.all_video_tc_origins or -1))
    if not info.has_video_tc_origin then
        return  -- contract only applies when an authoritative TC was found
    end
    assert(info.all_video_tc_origins,
        label .. ": all_video_tc_origins nil but has_video_tc_origin=true")
    assert(#info.all_video_tc_origins > 0,
        label .. ": all_video_tc_origins empty but has_video_tc_origin=true")
    assert(info.all_video_tc_origins[1] == info.first_frame_tc, string.format(
        "%s: all_video_tc_origins[1]=%s must equal first_frame_tc=%s",
        label, tostring(info.all_video_tc_origins[1]),
        tostring(info.first_frame_tc)))
end

local function check_audio_contract(label, info)
    print(string.format("  %s: has_audio_tc_origin=%s first_sample_tc=%s #all=%d",
        label, tostring(info.has_audio_tc_origin),
        tostring(info.first_sample_tc),
        info.all_audio_tc_origins and #info.all_audio_tc_origins or -1))
    if not info.has_audio_tc_origin then
        return
    end
    assert(info.all_audio_tc_origins,
        label .. ": all_audio_tc_origins nil but has_audio_tc_origin=true")
    assert(#info.all_audio_tc_origins > 0,
        label .. ": all_audio_tc_origins empty but has_audio_tc_origin=true")
    assert(info.all_audio_tc_origins[1] == info.first_sample_tc, string.format(
        "%s: all_audio_tc_origins[1]=%s must equal first_sample_tc=%s",
        label, tostring(info.all_audio_tc_origins[1]),
        tostring(info.first_sample_tc)))
end

-- ─────────────────────────────────────────────────────────────
-- Case 1: Broadcast MXF — TC derived from stream start_time path
-- ─────────────────────────────────────────────────────────────
print("\n--- Case 1: Broadcast MXF (start_time-derived TC) ---")
local mxf = test_env.require_fixture("tests/fixtures/media/B0002.MXF")
local mxf_info = probe(mxf)
assert(mxf_info, "MEDIA_FILE_OPEN failed on MXF fixture: " .. mxf)
check_video_contract("B0002.MXF", mxf_info)
check_audio_contract("B0002.MXF", mxf_info)

-- ─────────────────────────────────────────────────────────────
-- Case 2: BRAW — TC from BRAW SDK, separate build_braw_info path.
-- The make-VM binding sandbox may not load the BRAW SDK; the live
-- jve --test run against the editor binary always exercises this
-- path. Skip loudly here if the SDK is unavailable rather than
-- silently passing.
-- ─────────────────────────────────────────────────────────────
print("\n--- Case 2: BRAW (SDK-derived TC) ---")
local braw = test_env.require_fixture(
    "tests/fixtures/media/anamnesis-untrimmed/A001_07240010_C015.braw")
local braw_info = probe(braw)
if braw_info then
    check_video_contract("A001_07240010_C015.braw", braw_info)
    check_audio_contract("A001_07240010_C015.braw", braw_info)
else
    print("  ⚠ MEDIA_FILE_OPEN(braw) returned nil — BRAW SDK not loaded "
        .. "in this binding-test context. Verify BRAW path via:\n"
        .. "    ./build/bin/jve.app/Contents/MacOS/jve --test "
        .. "tests/synthetic/binding/test_emp_all_tc_origins_primary_matches.lua")
end

-- ─────────────────────────────────────────────────────────────
-- Case 3: Camera MOV with "timecode" metadata tag — control case,
-- should already pass since 0dcd908b walks metadata tags.
-- ─────────────────────────────────────────────────────────────
print("\n--- Case 3: Camera MOV (metadata-tag TC, control) ---")
local mov = test_env.require_fixture(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")
local mov_info = probe(mov)
assert(mov_info, "MEDIA_FILE_OPEN failed on MOV control fixture: " .. mov)
check_video_contract("A005_C052_0925BL_001_tc01.mp4", mov_info)
check_audio_contract("A005_C052_0925BL_001_tc01.mp4", mov_info)

print("\n✅ test_emp_all_tc_origins_primary_matches.lua passed")
