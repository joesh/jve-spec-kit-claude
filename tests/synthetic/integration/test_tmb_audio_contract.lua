-- Integration test: TMB audio contract — mix resolution, format binding, speed guard.
--
-- REPLACES:
--   tests/synthetic/lua/test_audio_decimate.lua
--   tests/synthetic/lua/test_audio_mix_tmb.lua
--   tests/synthetic/lua/test_tmb_audio_format_uses_sequence_rate.lua
--
-- DROPPED (stub-call-sequence only, no domain content):
--   test_audio_mix_tmb: SSE.RESET count on cold/hot swap (tests SSE internals, not
--     audio domain behavior; C++ AudioPump owns that path in Phase 3).
--   test_audio_mix_tmb: AOP.STOP/START counts (internal transport plumbing, not
--     observable domain output).
--   test_audio_mix_tmb: PCM push verification via mock sse_push_calls (C++ AudioPump
--     owns push in Phase 3; the Lua layer has no push path to observe).
--   test_audio_mix_tmb: "dedup" (F11) — OPEN QUESTION: relies on observing that
--     TMB_SET_AUDIO_MIX_PARAMS is NOT called. With a pass-through wrapper on the
--     real EMP binding, the dedup rule is observable. Kept below with instrumentation.
--   test_audio_decimate: §2 sample-rate mismatch — requires a device that opens
--     at a different rate than requested; real AOP on macOS honours the request,
--     so this guard cannot be triggered with real bindings. DROPPED.
--
-- DOMAIN RULES PINNED:
--   DA-1  Speed > MAX_SPEED_DECIMATE asserts loud (NSF-F4 boundary guard).
--   DA-2  Solo resolution: when ≥1 track is soloed, non-soloed tracks get
--         volume=0; soloed track keeps its declared volume.
--   DA-3  Mute resolution: muted track gets volume=0; others keep declared vol.
--   DA-4  Empty mix_params → has_audio=false.
--   DA-5  TMB audio format is the sequence's audio_sample_rate (44.1kHz sequence
--         → TMB output 44100, NOT hardcoded 48000). Mismatch forces SSE to
--         resample every buffer: latency, CPU waste, correctness risk.
--   DA-6  Missing/zero audio_sample_rate → fail-fast assert (rule 1.14).
--   DA-7  Identical resolved params → TMB_SET_AUDIO_MIX_PARAMS NOT called again
--         (prevents mix-cache nuke at clip boundaries where only clip_id changed).
--
-- OPEN QUESTIONS:
--   None.
--
-- Runs via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_tmb_audio_contract.lua

local ienv = require("synthetic.integration.integration_test_env")
local EMP  = ienv.require_emp()

print("=== test_tmb_audio_contract.lua ===")

-- ── Minimal DB required by PlaybackEngine:_create_tmb → Media.find_tc_override_media
-- DA-5/DA-6 call _create_tmb directly; without an active DB that query asserts.
local database = require("core.database")
local DB_PATH  = "/tmp/jve/test_tmb_audio_contract.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB_PATH); os.remove(DB_PATH.."-wal"); os.remove(DB_PATH.."-shm")
assert(database.set_path(DB_PATH), "set_path must succeed")
local db = database.get_connection()
db:exec(require("import_schema"))
local _now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p_test', 'AudioContractTest', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], _now, _now)), "project insert must succeed")

-- ── Observe TMB_SET_AUDIO_FORMAT calls via pass-through wrapper ──────────────
-- Wraps the real binding so we can count/verify without replacing it.
-- The real binding still executes; we just record the arguments.
local tmb_audio_format_calls = {}
do
    local real_set_audio_format = EMP.TMB_SET_AUDIO_FORMAT
    assert(type(real_set_audio_format) == "function",
        "precondition: EMP.TMB_SET_AUDIO_FORMAT must be a real function")
    EMP.TMB_SET_AUDIO_FORMAT = function(tmb, sample_rate, channels)
        tmb_audio_format_calls[#tmb_audio_format_calls + 1] = {
            sample_rate = sample_rate, channels = channels,
        }
        return real_set_audio_format(tmb, sample_rate, channels)
    end
end

-- ── Observe TMB_SET_AUDIO_MIX_PARAMS calls via pass-through wrapper ──────────
local mix_params_calls = {}
do
    local real_set_mix = EMP.TMB_SET_AUDIO_MIX_PARAMS
    assert(type(real_set_mix) == "function",
        "precondition: EMP.TMB_SET_AUDIO_MIX_PARAMS must be a real function")
    EMP.TMB_SET_AUDIO_MIX_PARAMS = function(tmb, params, sr, ch)
        mix_params_calls[#mix_params_calls + 1] = {
            params = params, sample_rate = sr, channels = ch,
        }
        return real_set_mix(tmb, params, sr, ch)
    end
end

local audio_playback = require("core.media.audio_playback")

-- ────────────────────────────────────────────────────────────────────────────
-- Session lifecycle helpers
-- ────────────────────────────────────────────────────────────────────────────

local function init_session()
    if not audio_playback.session_initialized then
        audio_playback.init_session(48000, 2)
    end
end

local function teardown_session()
    if audio_playback.session_initialized then
        audio_playback.shutdown_session()
    end
    -- Force fresh module state for next sub-test.
    package.loaded["core.media.audio_playback"] = nil
    audio_playback = require("core.media.audio_playback")
    mix_params_calls = {}
end

-- A minimal real TMB used as the mix target. We don't decode audio from it;
-- it only serves as the handle that TMB_SET_AUDIO_MIX_PARAMS receives.
local function make_tmb()
    local tmb = EMP.TMB_CREATE(0)
    assert(tmb, "make_tmb: TMB_CREATE returned nil")
    EMP.TMB_SET_SEQUENCE_RATE(tmb, 48000, 1)
    return tmb
end

-- ────────────────────────────────────────────────────────────────────────────
-- DA-1  Speed > MAX_SPEED_DECIMATE asserts
-- ────────────────────────────────────────────────────────────────────────────
print("\n-- (DA-1) speed > MAX_SPEED_DECIMATE asserts --")
do
    teardown_session()
    init_session()
    local tmb = make_tmb()
    audio_playback.apply_mix(tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)

    local ok, err = pcall(function() audio_playback.set_speed(20.0) end)
    assert(not ok, "speed 20× must assert")
    assert(tostring(err):find("MAX_SPEED_DECIMATE") or tostring(err):find("16"),
        "assert message must mention MAX_SPEED_DECIMATE limit; got: " .. tostring(err))

    audio_playback.stop()
    EMP.TMB_CLOSE(tmb)
    print("  PASS: speed 20× asserts MAX_SPEED_DECIMATE")
end

-- ────────────────────────────────────────────────────────────────────────────
-- DA-2  Solo resolution: non-soloed tracks get volume=0
-- ────────────────────────────────────────────────────────────────────────────
print("\n-- (DA-2) solo resolution --")
do
    teardown_session()
    mix_params_calls = {}
    init_session()
    local tmb = make_tmb()

    audio_playback.apply_mix(tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = true  },
        { track_index = 2, volume = 0.8, muted = false, soloed = false },
    }, 0)

    assert(#mix_params_calls >= 1, "apply_mix must call TMB_SET_AUDIO_MIX_PARAMS")
    local last = mix_params_calls[#mix_params_calls]
    assert(#last.params == 2, "should have 2 param entries")

    -- Track 1 soloed → keeps its volume
    assert(math.abs(last.params[1].volume - 1.0) < 0.001, string.format(
        "soloed track must keep volume=1.0; got %.4f", last.params[1].volume))
    -- Track 2 not soloed → silenced
    assert(math.abs(last.params[2].volume - 0.0) < 0.001, string.format(
        "non-soloed track must get volume=0; got %.4f", last.params[2].volume))

    EMP.TMB_CLOSE(tmb)
    print("  PASS: solo reduces non-soloed tracks to volume=0")
end

-- ────────────────────────────────────────────────────────────────────────────
-- DA-3  Mute resolution: muted track gets volume=0
-- ────────────────────────────────────────────────────────────────────────────
print("\n-- (DA-3) mute resolution --")
do
    teardown_session()
    mix_params_calls = {}
    init_session()
    local tmb = make_tmb()

    audio_playback.apply_mix(tmb, {
        { track_index = 1, volume = 1.0, muted = true,  soloed = false },
        { track_index = 2, volume = 0.5, muted = false, soloed = false },
    }, 0)

    assert(#mix_params_calls >= 1, "apply_mix must call TMB_SET_AUDIO_MIX_PARAMS")
    local last = mix_params_calls[#mix_params_calls]

    assert(math.abs(last.params[1].volume - 0.0) < 0.001, string.format(
        "muted track must get volume=0; got %.4f", last.params[1].volume))
    assert(math.abs(last.params[2].volume - 0.5) < 0.001, string.format(
        "non-muted track must keep volume=0.5; got %.4f", last.params[2].volume))

    EMP.TMB_CLOSE(tmb)
    print("  PASS: muted track gets volume=0, others keep declared volume")
end

-- ────────────────────────────────────────────────────────────────────────────
-- DA-4  Empty mix_params → has_audio=false
-- ────────────────────────────────────────────────────────────────────────────
print("\n-- (DA-4) empty mix_params → has_audio=false --")
do
    teardown_session()
    init_session()
    local tmb = make_tmb()

    audio_playback.apply_mix(tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    assert(audio_playback.has_audio == true, "pre: has_audio must be true after 1-track apply_mix")

    audio_playback.apply_mix(tmb, {}, 1000000)
    assert(audio_playback.has_audio == false,
        "has_audio must be false after apply_mix with empty params")

    EMP.TMB_CLOSE(tmb)
    print("  PASS: empty params → has_audio=false")
end

-- ────────────────────────────────────────────────────────────────────────────
-- DA-5  TMB audio format uses sequence's audio_sample_rate (not hardcoded 48000)
-- ────────────────────────────────────────────────────────────────────────────
print("\n-- (DA-5) TMB audio format uses sequence's audio_sample_rate --")
do
    local PlaybackEngine = require("core.playback.playback_engine")
    tmb_audio_format_calls = {}

    -- Build a minimal engine in memory (without DB load — _create_tmb is callable
    -- directly because it only uses self.fps_num/fps_den/audio_sample_rate/sequence).
    local engine_44k = PlaybackEngine.new("source", {
        on_show_frame       = function() end,
        on_show_gap         = function() end,
        on_set_rotation     = function() end,
        on_set_par          = function() end,
        on_position_changed = function() end,
    })
    engine_44k.fps_num          = 24
    engine_44k.fps_den          = 1
    engine_44k.audio_sample_rate = 44100
    engine_44k.sequence          = { project_id = "p_test", width = 1920, height = 1080 }
    engine_44k:_create_tmb()

    assert(#tmb_audio_format_calls >= 1,
        "_create_tmb must call TMB_SET_AUDIO_FORMAT exactly once")
    local call_44k = tmb_audio_format_calls[#tmb_audio_format_calls]
    assert(call_44k.sample_rate == 44100, string.format(
        "44.1kHz sequence: TMB output rate must be 44100 (not hardcoded 48000); got %s. "
        .. "Mismatch forces SSE to resample every buffer: latency + CPU waste.",
        tostring(call_44k.sample_rate)))

    -- Sanity: 48kHz sequence still configures TMB at 48000.
    tmb_audio_format_calls = {}
    local engine_48k = PlaybackEngine.new("source", {
        on_show_frame       = function() end,
        on_show_gap         = function() end,
        on_set_rotation     = function() end,
        on_set_par          = function() end,
        on_position_changed = function() end,
    })
    engine_48k.fps_num          = 24
    engine_48k.fps_den          = 1
    engine_48k.audio_sample_rate = 48000
    engine_48k.sequence          = { project_id = "p_test", width = 1920, height = 1080 }
    engine_48k:_create_tmb()

    local call_48k = tmb_audio_format_calls[#tmb_audio_format_calls]
    assert(call_48k.sample_rate == 48000, string.format(
        "48kHz sequence must configure TMB at 48000; got %s", tostring(call_48k.sample_rate)))

    print("  PASS: 44.1kHz → TMB uses 44100, 48kHz → 48000 (not hardcoded)")
end

-- ────────────────────────────────────────────────────────────────────────────
-- DA-6  Missing/zero audio_sample_rate → fail-fast assert
-- ────────────────────────────────────────────────────────────────────────────
print("\n-- (DA-6) missing/zero audio_sample_rate asserts --")
do
    local PlaybackEngine = require("core.playback.playback_engine")

    local function make_engine_with_rate(rate)
        local e = PlaybackEngine.new("source", {
            on_show_frame       = function() end,
            on_show_gap         = function() end,
            on_set_rotation     = function() end,
            on_set_par          = function() end,
            on_position_changed = function() end,
        })
        e.fps_num          = 24
        e.fps_den          = 1
        e.audio_sample_rate = rate
        e.sequence          = { project_id = "p_test", width = 1920, height = 1080 }
        return e
    end

    local ok_nil, err_nil = pcall(function()
        local e = make_engine_with_rate(nil); e:_create_tmb()
    end)
    assert(not ok_nil, "nil audio_sample_rate must fail fast")
    assert(tostring(err_nil):find("audio_sample_rate"), string.format(
        "assert must mention audio_sample_rate; got: %s", tostring(err_nil)))

    local ok_zero, err_zero = pcall(function()
        local e = make_engine_with_rate(0); e:_create_tmb()
    end)
    assert(not ok_zero, "zero audio_sample_rate must fail fast")
    assert(tostring(err_zero):find("audio_sample_rate"), string.format(
        "assert must mention audio_sample_rate; got: %s", tostring(err_zero)))

    print("  PASS: nil and zero audio_sample_rate both fail fast with actionable message")
end

-- ────────────────────────────────────────────────────────────────────────────
-- DA-7  Identical resolved params → no redundant TMB_SET_AUDIO_MIX_PARAMS call
--
-- Domain: at audio clip boundaries, apply_mix fires even when track set and
-- volumes are unchanged (only clip_id changed). Redundant SetAudioMixParams
-- clears the C++ mixed-audio cache → next GetMixedAudio falls through to
-- sync decode on the main thread → AOP underrun.
-- ────────────────────────────────────────────────────────────────────────────
print("\n-- (DA-7) identical resolved params → no redundant TMB call --")
do
    teardown_session()
    mix_params_calls = {}
    init_session()
    local tmb = make_tmb()

    audio_playback.apply_mix(tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    local count_after_first = #mix_params_calls
    assert(count_after_first >= 1, "first apply_mix must call TMB_SET_AUDIO_MIX_PARAMS")

    -- Second apply_mix with IDENTICAL resolved params (same track, same volume).
    -- Simulates a clip boundary where only clip_id changed, not the track set.
    audio_playback.apply_mix(tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 1000000)

    assert(#mix_params_calls == count_after_first, string.format(
        "identical resolved params must NOT re-call TMB_SET_AUDIO_MIX_PARAMS "
        .. "(expected %d calls, got %d). Redundant call nukes C++ mix cache → "
        .. "sync decode on main thread → AOP underrun at clip boundaries.",
        count_after_first, #mix_params_calls))

    -- Sanity: a volume change DOES trigger the call.
    audio_playback.apply_mix(tmb, {
        { track_index = 1, volume = 0.5, muted = false, soloed = false },
    }, 2000000)
    assert(#mix_params_calls > count_after_first,
        "different volume must trigger TMB_SET_AUDIO_MIX_PARAMS")

    EMP.TMB_CLOSE(tmb)
    print("  PASS: identical params deduped; volume change triggers call")
end

teardown_session()

os.remove(DB_PATH); os.remove(DB_PATH.."-wal"); os.remove(DB_PATH.."-shm")

print("\n✅ test_tmb_audio_contract.lua passed")
os.exit(0)
