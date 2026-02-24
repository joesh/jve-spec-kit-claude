-- Integration test environment for tests running inside JVEEditor (--test mode).
-- Extends test_env with real C++ EMP bindings and test media helpers.

local test_env = require("test_env")
local M = {}

-- Re-export test_env utilities
M.repo_root = test_env.repo_root
M.resolve_repo_path = test_env.resolve_repo_path
M.expect_error = test_env.expect_error
M.assert_type = test_env.assert_type

-- Standard test media (640x360 24000/1001 fps, has video + audio)
M.STANDARD_MEDIA = "A001_C037_0921FG_001.mp4"

--- Assert we're running inside JVEEditor with real C++ bindings.
-- Fails immediately if qt_constants.EMP is missing or TMB_CREATE isn't a function.
function M.require_emp()
    assert(type(qt_constants) == "table",
        "integration_test_env: qt_constants not found — must run via JVEEditor --test")
    assert(type(qt_constants.EMP) == "table",
        "integration_test_env: qt_constants.EMP not found — must run via JVEEditor --test")
    assert(type(qt_constants.EMP.TMB_CREATE) == "function",
        "integration_test_env: qt_constants.EMP.TMB_CREATE is not a function — stale build?")
    return qt_constants.EMP
end

--- Resolve a path under tests/fixtures/media/, assert file exists.
-- @param relative string: filename relative to tests/fixtures/media/
-- @return string: absolute path to the media file
function M.test_media_path(relative)
    assert(type(relative) == "string" and relative ~= "",
        "test_media_path: relative must be a non-empty string")
    local path = test_env.resolve_repo_path("tests/fixtures/media/" .. relative)
    local f = io.open(path, "r")
    assert(f, "test_media_path: file not found: " .. path)
    f:close()
    return path
end

--- Create a TMB with a single video clip from test media.
-- @param opts table: { pool_threads=N, media=filename, duration=N, source_in=N, rate_num=N, rate_den=N }
--   All fields optional. Defaults: pool_threads=0 (sync), media=STANDARD_MEDIA,
--   duration=50 frames, source_in=0, rate_num=24000, rate_den=1001
-- @return tmb handle, clip_info table, EMP reference
function M.create_single_clip_tmb(opts)
    opts = opts or {}
    local EMP = M.require_emp()

    local pool_threads = opts.pool_threads or 0
    local media = opts.media or M.STANDARD_MEDIA
    local media_path = M.test_media_path(media)
    local duration = opts.duration or 50
    local source_in = opts.source_in or 0
    local rate_num = opts.rate_num or 24000
    local rate_den = opts.rate_den or 1001

    local tmb = EMP.TMB_CREATE(pool_threads)
    assert(tmb, "create_single_clip_tmb: TMB_CREATE returned nil")

    EMP.TMB_SET_SEQUENCE_RATE(tmb, rate_num, rate_den)

    local clip_info = {
        clip_id = "test-clip-001",
        media_path = media_path,
        timeline_start = 0,
        duration = duration,
        source_in = source_in,
        rate_num = rate_num,
        rate_den = rate_den,
        speed_ratio = 1.0,
    }

    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, { clip_info })

    return tmb, clip_info, EMP
end

--- Create a TMB with two consecutive video clips (for boundary crossing tests).
-- @param opts table: { pool_threads=N, media=filename, clip_a_duration=N, clip_b_duration=N, rate_num=N, rate_den=N }
-- @return tmb handle, clip_a info, clip_b info, EMP reference
function M.create_two_clip_tmb(opts)
    opts = opts or {}
    local EMP = M.require_emp()

    local pool_threads = opts.pool_threads or 0
    local media = opts.media or M.STANDARD_MEDIA
    local media_path = M.test_media_path(media)
    local clip_a_dur = opts.clip_a_duration or 50
    local clip_b_dur = opts.clip_b_duration or 50
    local rate_num = opts.rate_num or 24000
    local rate_den = opts.rate_den or 1001

    local tmb = EMP.TMB_CREATE(pool_threads)
    assert(tmb, "create_two_clip_tmb: TMB_CREATE returned nil")

    EMP.TMB_SET_SEQUENCE_RATE(tmb, rate_num, rate_den)

    local clip_a = {
        clip_id = "clip-A",
        media_path = media_path,
        timeline_start = 0,
        duration = clip_a_dur,
        source_in = 0,
        rate_num = rate_num,
        rate_den = rate_den,
        speed_ratio = 1.0,
    }

    local clip_b = {
        clip_id = "clip-B",
        media_path = media_path,
        timeline_start = clip_a_dur,
        duration = clip_b_dur,
        source_in = clip_a_dur, -- different source region
        rate_num = rate_num,
        rate_den = rate_den,
        speed_ratio = 1.0,
    }

    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, { clip_a, clip_b })

    return tmb, clip_a, clip_b, EMP
end

--- Try to open audio output (AOP + SSE).
-- Returns (aop, sse) if audio device available, (nil, nil) otherwise.
-- Non-fatal: CI/headless environments may lack audio devices.
function M.try_open_audio(sample_rate, channels)
    sample_rate = sample_rate or 48000
    channels = channels or 2
    local AOP = qt_constants.AOP
    local SSE = qt_constants.SSE
    if not AOP or not SSE then
        print("  (audio unavailable: AOP/SSE bindings not found)")
        return nil, nil
    end
    local ok, aop_or_err = pcall(AOP.OPEN, sample_rate, channels, 100)
    if not ok then
        print("  (audio unavailable: AOP.OPEN threw: " .. tostring(aop_or_err) .. ")")
        return nil, nil
    end
    if not aop_or_err then
        print("  (audio unavailable: AOP.OPEN returned nil)")
        return nil, nil
    end
    local aop = aop_or_err
    local sse = SSE.CREATE({
        sample_rate = sample_rate, channels = channels, block_frames = 512,
    })
    assert(sse, "try_open_audio: SSE.CREATE failed after AOP succeeded")
    return aop, sse
end

return M
