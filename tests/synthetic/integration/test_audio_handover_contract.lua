-- Integration: audio device handover contract (017 audio_handover.md).
--
-- REPLACES (from tests/synthetic/lua/):
--   test_contract_audio_handover.lua
--
-- Honest conversion. The rejected original faked qt_constants wholesale and
-- replaced AOP.START/STOP and PLAYBACK.(DE)ACTIVATE_AUDIO with log-appending
-- fakes, then asserted on the fake call log — verifying Lua→stub routing, not
-- the device-ownership contract. This version runs inside JVEEditor (--test)
-- with the REAL audio_playback module and REAL PlaybackEngines bound to REAL
-- DB sequences. It observes the contract's actual surface — the single audio
-- owner (audio_playback.current_owner()) — which is the observable the
-- contract defines (FR-011/FR-012 I1: at most one engine owns the device at
-- any instant). No FFI function is faked.
--
-- DOMAIN RULES PINNED (017 contracts/audio_handover.md):
--   AH-1  Required public surface present: current_owner, is_owner,
--         halt_current, acquire_for.
--   AH-2  Idle device: current_owner() == nil before any acquire_for.
--   AH-3  halt_current() with no owner is a clean no-op (owner stays nil).
--   AH-4  acquire_for(engine) makes that engine the sole owner; is_owner
--         reports true for it and false for the other engine.
--   AH-5  acquire_for while another engine owns the device asserts — the
--         caller must halt_current() first (this IS invariant I1: you cannot
--         acquire over a live owner).
--   AH-6  halt_current() → acquire_for(other) is the legal handover: after
--         halt the owner is nil (prior side fully released), and the new
--         engine then becomes sole owner. No instant has two owners.
--   AH-7  acquire_for(nil) and acquire_for({}) assert (bad engine shape).
--
-- WHY OWNER-STATE, NOT FFI ORDER: the no-overlap invariant I1 is defined on
-- ownership ("at most one engine sources the stream"). current_owner()
-- transitions are the black-box projection of that invariant. The lower-level
-- AOP.STOP-before-AOP.START ordering is exercised through real play() in
-- test_audio_no_dropout_on_side_switch.lua.
--
-- OPEN QUESTIONS: none.
--
-- Runs via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_audio_handover_contract.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_audio_handover_contract.lua (integration) ===")

require("test_env")
local database       = require("core.database")
local transport      = require("core.playback.transport")
local audio_playback = require("core.media.audio_playback")

-- ── AH-1  public surface ─────────────────────────────────────────────────
print("\n-- (AH-1) audio handover surface present --")
do
    for _, name in ipairs({ "current_owner", "is_owner", "halt_current", "acquire_for" }) do
        assert(type(audio_playback[name]) == "function", string.format(
            "audio_playback.%s must be a function", name))
    end
    print("  PASS: current_owner/is_owner/halt_current/acquire_for present")
end

-- ── DB bootstrap: a record timeline (with audio) + a master ──────────────
local DB = "/tmp/jve/test_audio_handover_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
local media_path = ienv.test_media_path(ienv.STANDARD_MEDIA)
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('proj', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO media (id, project_id, file_path, name, duration_frames,
        fps_numerator, fps_denominator, width, height,
        audio_channels, audio_sample_rate, created_at, modified_at)
      VALUES ('media_a', 'proj', %q, 'A', 108, 24000, 1001, 640, 360, 2, 48000, %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, start_timecode_frame, created_at, modified_at)
      VALUES ('tl', 'proj', 'Timeline', 'sequence', 24000, 1001, 48000, 640, 360,
              0, 300, 0, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('tl_v1', 'tl', 'V1', 'VIDEO', 1, 1),
             ('tl_a1', 'tl', 'A1', 'AUDIO', 1, 1);
]], now, now, media_path, now, now, now, now)))
local master_id = require("test_env").create_test_masterclip_sequence(
    "proj", "A", 24000, 1001, 108, "media_a")

if transport.is_bootstrapped() then transport.shutdown() end
transport.init("proj")
transport.bind_role_to_sequence("source", master_id)
transport.bind_role_to_sequence("record", "tl")
local src = transport.engine_for_role("source")
local rec = transport.engine_for_role("record")

-- Start from a clean device. A sibling test in the same process may have
-- left an owner; release it (legal: halt_current on a live owner).
if audio_playback.current_owner() ~= nil then audio_playback.halt_current() end

-- ── AH-2  idle device ────────────────────────────────────────────────────
print("\n-- (AH-2) device idle before any acquire --")
do
    assert(audio_playback.current_owner() == nil,
        "current_owner() must be nil on an idle device")
    print("  PASS: current_owner() == nil when idle")
end

-- ── AH-3  halt_current with no owner is a no-op ──────────────────────────
print("\n-- (AH-3) halt_current with no owner is a no-op --")
do
    audio_playback.halt_current()
    assert(audio_playback.current_owner() == nil,
        "halt_current() with no owner must leave the device idle")
    print("  PASS: halt_current() with no owner left owner nil")
end

-- ── AH-4  acquire_for sets the sole owner ────────────────────────────────
print("\n-- (AH-4) acquire_for sets sole ownership --")
do
    audio_playback.acquire_for(rec)
    assert(audio_playback.current_owner() == rec,
        "after acquire_for(record), current_owner() must equal the record engine")
    assert(audio_playback.is_owner(rec) == true,
        "is_owner(record) must be true after it acquired")
    assert(audio_playback.is_owner(src) == false,
        "is_owner(source) must be false while record owns the device")
    print("  PASS: record is the sole owner after acquire_for")
end

-- ── AH-5  acquire over a live owner asserts (I1) ─────────────────────────
print("\n-- (AH-5) acquire over a live owner asserts (no-overlap I1) --")
do
    local ok = pcall(audio_playback.acquire_for, src)
    assert(not ok, string.format(
        "acquire_for(source) while record owns the device must assert "
        .. "(I1: caller must halt_current first); current_owner=%s",
        tostring(audio_playback.current_owner())))
    -- The failed acquire must not have changed ownership.
    assert(audio_playback.current_owner() == rec,
        "a rejected acquire_for must leave the prior owner intact")
    print("  PASS: acquiring over a live owner asserts; owner unchanged")
end

-- ── AH-6  halt → acquire is the legal handover ───────────────────────────
print("\n-- (AH-6) halt_current → acquire_for(other) handover --")
do
    audio_playback.halt_current()
    assert(audio_playback.current_owner() == nil, string.format(
        "after halt_current the prior owner must be released (I1: device idle "
        .. "before the new side acquires); current_owner=%s",
        tostring(audio_playback.current_owner())))

    audio_playback.acquire_for(src)
    assert(audio_playback.is_owner(src) == true,
        "after the handover, source must be the sole owner")
    assert(audio_playback.is_owner(rec) == false,
        "after the handover, record must no longer own the device")
    print("  PASS: halt then acquire transferred sole ownership cleanly")
end

-- ── AH-7  bad-shape acquire asserts ──────────────────────────────────────
print("\n-- (AH-7) acquire_for(nil) and acquire_for({}) assert --")
do
    audio_playback.halt_current()
    assert(not pcall(audio_playback.acquire_for, nil),
        "acquire_for(nil) must assert")
    assert(not pcall(audio_playback.acquire_for, {}),
        "acquire_for({}) must assert (no role / loaded_sequence_id)")
    print("  PASS: nil and empty-table engines both assert")
end

-- Leave the device idle for sibling tests.
if audio_playback.current_owner() ~= nil then audio_playback.halt_current() end
if transport.is_bootstrapped() then transport.shutdown() end
database.shutdown()
print("\nPASS test_audio_handover_contract.lua")
os.exit(0)
