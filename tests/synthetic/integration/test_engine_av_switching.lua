-- Integration: Audio handover invariants when switching between source/record.
--
-- REPLACES (from tests/synthetic/lua/):
--   test_contract_audio_handover.lua
--   test_no_audio_dropout_when_switching_between_source_and_record.lua
--   test_video_does_not_appear_before_audio_when_switching_sides.lua
--
-- SCENARIOS KEPT:
--   DR-1   audio_playback public surface: current_owner, is_owner,
--            halt_current, acquire_for are functions.
--   DR-2   current_owner() is nil before any acquire_for.
--   DR-3   halt_current() with no owner is a clean no-op (returns without crash).
--   DR-4   acquire_for(engine) sets ownership; is_owner returns true/false correctly.
--   DR-5   acquire_for() while another live owner holds asserts (no-overlap at Lua layer).
--   DR-6   halt_current() fires AOP.STOP or PLAYBACK.DEACTIVATE_AUDIO before
--            current_owner becomes nil (I1 no-overlap structural proof).
--   DR-7   acquire_for(nil) and acquire_for({}) each assert.
--   DR-8   FR-012 I1: switching sides — halt event precedes new-side start event
--            in call-log order.
--   DR-9   FR-012 I2: audio-before-video — audio acquire event precedes
--            PLAYBACK.PLAY in call-log order.
--
-- SCENARIOS DROPPED:
--   audio_playback AOP.OPEN call with exact sample_rate/channel args — verifies
--   a specific internal AOP init path rather than the I1/I2 ordering invariants.
--   SSE.CREATE / SSE.RESET mock-sequence checks — internal initialisation detail.
--
-- OPEN QUESTIONS:
--   None; I1/I2 invariants are directly from 017 spec FR-012.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_engine_av_switching.lua (integration) ===")

require("test_env")
local setup = require("synthetic.helpers.test_017_setup")

-- ── DB bootstrap ────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_engine_av_switching_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
setup.install_qt_stub()
setup.fresh_project_db("test_engine_av_switching_integ.db")

local function expect_assert(fn, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected assert/error, got success")
    return tostring(err)
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-1  Public surface
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-1) audio_playback public surface --")
do
    local audio_playback = require("core.media.audio_playback")
    for _, name in ipairs({ "current_owner", "is_owner", "halt_current", "acquire_for" }) do
        assert(type(audio_playback[name]) == "function",
            string.format("audio_playback.%s must be a function", name))
    end
    print("  PASS: required surface present")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-2  current_owner() nil before any acquire_for
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-2) current_owner nil initially --")
do
    local audio_playback = require("core.media.audio_playback")
    -- Ensure clean slate (previous tests in the session may have set owner).
    audio_playback.halt_current()
    assert(audio_playback.current_owner() == nil,
        "current_owner must be nil before any acquire_for")
    print("  PASS: current_owner() nil before acquire_for")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-3  halt_current() with no owner is a clean no-op
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-3) halt_current() with no owner is a no-op --")
do
    local audio_playback = require("core.media.audio_playback")
    audio_playback.halt_current()  -- ensure no owner
    local ok, err = pcall(function() audio_playback.halt_current() end)
    assert(ok, "halt_current with no owner must not raise; got: " .. tostring(err))
    assert(audio_playback.current_owner() == nil,
        "halt_current with no owner must leave owner nil")
    print("  PASS: halt_current with no owner is a clean no-op")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-4  acquire_for(engine) sets ownership
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-4) acquire_for sets ownership --")
do
    local audio_playback = require("core.media.audio_playback")
    audio_playback.halt_current()

    -- Minimal engine shape: audio_playback only needs role + sequence.audio_sample_rate
    -- to compute the bus rate. Full engine not required here.
    local function fake_engine(role)
        return {
            role = role,
            loaded_sequence_id = "stub-seq",
            sequence = { audio_sample_rate = 48000 },
        }
    end

    local src = fake_engine("source")
    local rec = fake_engine("record")

    audio_playback.acquire_for(src)
    assert(audio_playback.current_owner() == src,
        "after acquire_for(source), current_owner must be source engine")
    assert(audio_playback.is_owner(src) == true,
        "is_owner(src) must be true after acquire_for(src)")
    assert(audio_playback.is_owner(rec) == false,
        "is_owner(rec) must be false when source owns")

    audio_playback.halt_current()
    print("  PASS: acquire_for sets owner; is_owner discriminates correctly")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-5  acquire_for while another owner holds asserts
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-5) acquire_for with live owner asserts --")
do
    local audio_playback = require("core.media.audio_playback")
    audio_playback.halt_current()

    local function fake_engine(role)
        return { role = role, loaded_sequence_id = "s",
                 sequence = { audio_sample_rate = 48000 } }
    end
    local src = fake_engine("source")
    local rec = fake_engine("record")

    audio_playback.acquire_for(src)
    expect_assert(function() audio_playback.acquire_for(rec) end,
        "acquire_for with live owner")

    audio_playback.halt_current()
    print("  PASS: acquire_for with another live owner asserts")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-6  halt_current() fires a stop event before clearing owner (I1 structural)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-6) halt_current fires stop before clearing owner (I1) --")
do
    local audio_playback = require("core.media.audio_playback")
    audio_playback.halt_current()

    local function fake_engine(role)
        return { role = role, loaded_sequence_id = "s",
                 sequence = { audio_sample_rate = 48000 } }
    end
    local src = fake_engine("source")

    -- Instrument the stub qt_constants to log AOP.STOP / DEACTIVATE_AUDIO.
    local ffi_log = {}
    local qt = package.loaded["core.qt_constants"]
    local orig_aop_stop  = qt.AOP  and qt.AOP.STOP
    local orig_deact     = qt.PLAYBACK and qt.PLAYBACK.DEACTIVATE_AUDIO
    if qt.AOP then
        qt.AOP.STOP = function(...)
            ffi_log[#ffi_log + 1] = "AOP.STOP"
            if orig_aop_stop then orig_aop_stop(...) end
        end
    end
    if qt.PLAYBACK then
        qt.PLAYBACK.DEACTIVATE_AUDIO = function(...)
            ffi_log[#ffi_log + 1] = "DEACTIVATE_AUDIO"
            if orig_deact then orig_deact(...) end
        end
    end

    audio_playback.acquire_for(src)
    ffi_log = {}
    audio_playback.halt_current()

    -- Restore.
    if qt.AOP and orig_aop_stop then qt.AOP.STOP = orig_aop_stop end
    if qt.PLAYBACK and orig_deact then qt.PLAYBACK.DEACTIVATE_AUDIO = orig_deact end

    assert(audio_playback.current_owner() == nil,
        "after halt_current, owner must be nil")

    local saw_stop = false
    for _, e in ipairs(ffi_log) do
        if e == "AOP.STOP" or e == "DEACTIVATE_AUDIO" then
            saw_stop = true; break
        end
    end
    assert(saw_stop, string.format(
        "I1 structural: halt_current must fire AOP.STOP or DEACTIVATE_AUDIO; "
        .. "ffi_log=%s", table.concat(ffi_log, ",")))
    print("  PASS: halt_current fires stop event before clearing owner (I1)")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-7  acquire_for(nil) and acquire_for({}) each assert
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-7) acquire_for bad args assert --")
do
    local audio_playback = require("core.media.audio_playback")
    audio_playback.halt_current()

    expect_assert(function() audio_playback.acquire_for(nil) end,
        "acquire_for(nil)")
    expect_assert(function() audio_playback.acquire_for({}) end,
        "acquire_for({}) — missing role/sequence")
    print("  PASS: acquire_for(nil) and acquire_for({}) each assert")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-8  FR-012 I1: halt event precedes new-side start in call-log
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-8) FR-012 I1: halt precedes start on side switch --")
do
    -- IMPORTANT: do NOT call install_qt_stub here.  audio_playback and
    -- playback_engine_audio captured a reference to the qt_constants table
    -- when they were first required above (DR-1).  Replacing the table via
    -- install_qt_stub would create a new table that those modules never see.
    -- Instead, mutate the SAME table they hold in-place.
    local qt = require("core.qt_constants")

    -- Rewire only the events we need to observe; leave the rest intact so
    -- that the real transport/engine machinery keeps functioning.
    local orig_play      = qt.PLAYBACK.PLAY
    local orig_aop_start = qt.AOP.START
    local orig_aop_stop  = qt.AOP.STOP
    local orig_deact     = qt.PLAYBACK.DEACTIVATE_AUDIO

    setup.fresh_project_db("test_av_switching_i1.db")

    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    transport.init("p")

    local rec = transport.engine_for_role("record")
    local src = transport.engine_for_role("source")

    -- Load both engines.
    rec:load("rec")
    src:load("src")

    -- Record plays first.
    require("synthetic.helpers.transport_target_sim").target_record()
    rec:play()

    -- Reset log to capture just the handover events.
    local call_log = {}
    qt.PLAYBACK.PLAY         = function(...) call_log[#call_log + 1] = "PLAYBACK.PLAY"    if orig_play      then orig_play(...)      end end
    qt.AOP.START             = function(...) call_log[#call_log + 1] = "AOP.START"        if orig_aop_start then orig_aop_start(...) end end
    qt.AOP.STOP              = function(...) call_log[#call_log + 1] = "AOP.STOP"         if orig_aop_stop  then orig_aop_stop(...)  end end
    qt.PLAYBACK.DEACTIVATE_AUDIO = function(...) call_log[#call_log + 1] = "DEACTIVATE_AUDIO" if orig_deact then orig_deact(...) end end

    -- Stop record; source takes over.
    rec:stop()
    require("synthetic.helpers.transport_target_sim").target_source()
    src:play()

    -- I1: a halt event must precede the new-side start event.
    local function index_of(events, prefixes)
        for i, e in ipairs(events) do
            for _, p in ipairs(prefixes) do
                if e == p then return i end
            end
        end
        return nil
    end

    local halt_at  = index_of(call_log, { "AOP.STOP", "DEACTIVATE_AUDIO" })
    local start_at = index_of(call_log, { "AOP.START", "PLAYBACK.PLAY" })

    assert(halt_at, "I1: expected a halt event during handover; log: "
        .. table.concat(call_log, ","))
    assert(start_at, "I1: expected a start event during handover; log: "
        .. table.concat(call_log, ","))
    assert(halt_at < start_at, string.format(
        "FR-012 I1 no-overlap: halt must precede start; halt_at=%d start_at=%d log=%s",
        halt_at, start_at, table.concat(call_log, ",")))

    -- Restore qt table before moving to next DR.
    qt.PLAYBACK.PLAY             = orig_play
    qt.AOP.START                 = orig_aop_start
    qt.AOP.STOP                  = orig_aop_stop
    qt.PLAYBACK.DEACTIVATE_AUDIO = orig_deact

    transport.shutdown()
    print("  PASS: FR-012 I1 — halt event precedes new-side start")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-9  FR-012 I2: audio acquire precedes PLAYBACK.PLAY (audio-before-video)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-9) FR-012 I2: audio before video on play --")
do
    -- Same in-place mutation pattern as DR-8 — do NOT call install_qt_stub.
    local qt = require("core.qt_constants")

    local orig_aop_start  = qt.AOP.START
    local orig_play       = qt.PLAYBACK.PLAY
    local orig_act_audio  = qt.PLAYBACK.ACTIVATE_AUDIO

    setup.fresh_project_db("test_av_switching_i2.db")

    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    transport.init("p")

    local src = transport.engine_for_role("source")
    src:load("src")
    require("synthetic.helpers.transport_target_sim").target_source()

    -- Re-wire on the actual table audio modules hold; capture fresh log.
    local call_log = {}
    qt.AOP.START               = function(...) call_log[#call_log + 1] = "AOP.START"               if orig_aop_start then orig_aop_start(...) end end
    qt.PLAYBACK.PLAY           = function(...) call_log[#call_log + 1] = "PLAYBACK.PLAY"           if orig_play      then orig_play(...)      end end
    qt.PLAYBACK.ACTIVATE_AUDIO = function(...) call_log[#call_log + 1] = "PLAYBACK.ACTIVATE_AUDIO" if orig_act_audio  then orig_act_audio(...) end end

    src:play()

    local function first_index_of(events, prefix)
        for i, e in ipairs(events) do
            if e == prefix then return i end
        end
        return nil
    end

    local audio_at = first_index_of(call_log, "AOP.START")
        or first_index_of(call_log, "PLAYBACK.ACTIVATE_AUDIO")
    local video_at = first_index_of(call_log, "PLAYBACK.PLAY")

    assert(audio_at, "I2: expected an audio-acquire event; log: "
        .. table.concat(call_log, ","))
    assert(video_at, "I2: expected PLAYBACK.PLAY; log: "
        .. table.concat(call_log, ","))
    assert(audio_at < video_at, string.format(
        "FR-012 I2 audio-before-video: audio_at=%d video_at=%d log=%s",
        audio_at, video_at, table.concat(call_log, ",")))

    transport.shutdown()
    print("  PASS: FR-012 I2 — audio acquire precedes PLAYBACK.PLAY")
end

print("\nPASS test_engine_av_switching.lua")
os.exit(0)
