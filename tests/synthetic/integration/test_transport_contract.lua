-- Integration: core.playback.transport public contract (017).
--
-- REPLACES (from tests/synthetic/lua/):
--   test_contract_transport.lua
--
-- Honest conversion of the rejected stub: the original poisoned
-- package.loaded["core.qt_constants"] with a wholesale fake and drove the
-- target via the transport_target_sim stub (which replaced focus_manager
-- and timeline_state with fakes). This version runs inside JVEEditor
-- (--test) with the REAL qt_constants / EMP / PlaybackEngine, builds real
-- DB sequences, and derives the target from REAL UI state: a real
-- focus_manager panel focus and a real displayed source tab.
--
-- DOMAIN RULES PINNED (017 contracts/transport.md):
--   TC-1  Required public surface present: init, shutdown, get_target,
--         engine_for_role, engine_for_target.
--   TC-2  Removed setter/persister surface absent (derived-target redesign):
--         set_user_transport, persist_target must not exist.
--   TC-3  get_target() before init asserts (names "init"/"not initialized").
--   TC-4  init(nil) and init("") assert.
--   TC-5  init succeeds; with no source-side UI state the target derives to
--         "record" (FR-008a default-to-record).
--   TC-6  engine_for_role("source"/"record") return distinct engines whose
--         role field matches; engine_for_role("garbage") asserts.
--   TC-7  Focusing the source monitor derives the target to "source" and
--         engine_for_target() == the source engine; defocusing back to the
--         timeline monitor derives "record".
--   TC-8  get_target() is a stable, side-effect-free projection: repeated
--         calls under one UI state return the same value.
--   TC-9  After shutdown, get_target() asserts again (gated by init).
--
-- DROPPED:
--   The transport_target_sim-driven cases (original Case 6) are folded into
--   TC-7, driven by real focus_manager state instead of the stub.
--
-- OPEN QUESTIONS: none.
--
-- Runs via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_transport_contract.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_transport_contract.lua (integration) ===")

require("test_env")
local database      = require("core.database")
local focus_manager = require("ui.focus_manager")
local transport     = require("core.playback.transport")

local function expect_assert(fn, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected assert/error, got success")
    return tostring(err)
end

-- ── TC-1 / TC-2  public + forbidden surface (no init needed) ─────────────
print("\n-- (TC-1) required public surface --")
do
    for _, name in ipairs({
        "init", "shutdown", "get_target", "engine_for_role", "engine_for_target",
    }) do
        assert(type(transport[name]) == "function", string.format(
            "transport.%s must be a function", name))
    end
    print("  PASS: init/shutdown/get_target/engine_for_role/engine_for_target present")
end

print("\n-- (TC-2) removed setter/persister absent --")
do
    assert(transport.set_user_transport == nil,
        "transport.set_user_transport must not exist (derived-target redesign)")
    assert(transport.persist_target == nil,
        "transport.persist_target must not exist (target is derived, not stored)")
    print("  PASS: set_user_transport / persist_target absent")
end

-- ── TC-3  get_target before init asserts ─────────────────────────────────
print("\n-- (TC-3) get_target before init asserts --")
do
    -- Guard: a sibling test in the same process may have left transport up.
    if transport.is_bootstrapped() then transport.shutdown() end
    local err = expect_assert(transport.get_target, "get_target pre-init")
    assert(err:match("init") or err:match("not initialized"), string.format(
        "pre-init error must name 'init'/'not initialized'; got: %s", err))
    print("  PASS: get_target() pre-init asserts naming init")
end

-- ── TC-4  init bad args assert ───────────────────────────────────────────
print("\n-- (TC-4) init(nil) / init('') assert --")
do
    expect_assert(function() transport.init(nil) end, "init(nil)")
    expect_assert(function() transport.init("") end, "init('')")
    print("  PASS: init(nil) and init('') both assert")
end

-- ── DB bootstrap: project + a timeline (record) + a master (source) ───────
local DB = "/tmp/jve/test_transport_contract_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('proj', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO media (id, project_id, file_path, name, duration_frames,
        fps_numerator, fps_denominator, width, height,
        audio_channels, audio_sample_rate, created_at, modified_at)
      VALUES ('media_tc', 'proj', '/test/tc_clip.mov', 'TCClip', 300, 24, 1,
              1920, 1080, 2, 48000, %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, start_timecode_frame, created_at, modified_at)
      VALUES ('timeline_seq', 'proj', 'Timeline', 'sequence', 30, 1, 48000, 1920, 1080,
              0, 300, 0, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('tl_v1', 'timeline_seq', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now, now, now)))
local master_id = require("test_env").create_test_masterclip_sequence(
    "proj", "TCClip", 24, 1, 300, "media_tc")

-- Real monitor panels + focus wiring, so get_target()'s focus_manager
-- projection has live panels to resolve against.
ienv.setup_monitor_panels({ kinds = "both", focus = "timeline_monitor" })

-- ── TC-5  init succeeds; default target is "record" ──────────────────────
print("\n-- (TC-5) init → default target 'record' (FR-008a) --")
do
    transport.init("proj")
    transport.bind_role_to_sequence("source", master_id)
    transport.bind_role_to_sequence("record", "timeline_seq")
    -- Timeline monitor is focused and no source tab is displayed → record.
    assert(transport.get_target() == "record", string.format(
        "FR-008a: fresh UI state must derive 'record'; got '%s'",
        tostring(transport.get_target())))
    print("  PASS: default derived target is 'record'")
end

-- ── TC-6  engine_for_role returns distinct role-bound engines ────────────
print("\n-- (TC-6) engine_for_role distinct + role-tagged --")
local src_engine, rec_engine
do
    src_engine = transport.engine_for_role("source")
    rec_engine = transport.engine_for_role("record")
    assert(src_engine and src_engine.role == "source",
        "engine_for_role('source') must return an engine with role='source'")
    assert(rec_engine and rec_engine.role == "record",
        "engine_for_role('record') must return an engine with role='record'")
    assert(src_engine ~= rec_engine,
        "source and record engines must be distinct objects")
    expect_assert(function() transport.engine_for_role("garbage") end,
        "engine_for_role('garbage')")
    print("  PASS: distinct source/record engines; garbage role asserts")
end

-- ── TC-7  real UI state drives the derived target ────────────────────────
print("\n-- (TC-7) focusing the source monitor → target 'source' --")
do
    focus_manager.set_focused_panel("source_monitor")
    assert(transport.get_target() == "source", string.format(
        "focused source monitor must derive 'source'; got '%s'",
        tostring(transport.get_target())))
    assert(transport.engine_for_target() == src_engine,
        "engine_for_target() must equal the source engine when target is 'source'")

    focus_manager.set_focused_panel("timeline_monitor")
    assert(transport.get_target() == "record", string.format(
        "focused timeline monitor must derive 'record'; got '%s'",
        tostring(transport.get_target())))
    assert(transport.engine_for_target() == rec_engine,
        "engine_for_target() must equal the record engine when target is 'record'")
    print("  PASS: focus switch flips derived target source↔record")
end

-- ── TC-8  derivation is stable / side-effect-free ────────────────────────
print("\n-- (TC-8) get_target() is a stable projection --")
do
    focus_manager.set_focused_panel("source_monitor")
    local first = transport.get_target()
    for _ = 1, 16 do
        assert(transport.get_target() == first,
            "get_target() must be stable under repeated calls with the same UI state")
    end
    assert(first == "source", "fixture: source monitor focused → 'source'")
    print("  PASS: 16 repeated get_target() calls returned the same value")
end

-- ── TC-9  shutdown re-gates access ───────────────────────────────────────
print("\n-- (TC-9) after shutdown get_target asserts --")
do
    transport.shutdown()
    expect_assert(transport.get_target, "get_target post-shutdown")
    print("  PASS: get_target() asserts again after shutdown")
end

database.shutdown()
print("\nPASS test_transport_contract.lua")
os.exit(0)
