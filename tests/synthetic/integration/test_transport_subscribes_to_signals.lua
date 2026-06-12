-- Integration: transport owns the UI→engine cross-domain subscriptions (017).
--
-- REPLACES (from tests/synthetic/lua/):
--   test_transport_subscribes_to_signals.lua
--
-- Honest conversion. The rejected original faked qt_constants AND replaced
-- package.loaded["core.playback.playback_engine"] with a stub whose
-- teardown_engine / stop merely incremented counters — it verified that
-- transport CALLS those functions, not that the engines actually change
-- state. This version runs inside JVEEditor (--test) with REAL engines
-- bound to REAL DB sequences and a REAL GPU surface, and observes the
-- engines' OBSERVABLE post-signal state (playing→stopped, loaded→nil)
-- rather than counting calls into a fake module.
--
-- DOMAIN RULES PINNED (017 contracts/transport.md §Signal subscriptions):
--   SS-1  displayed_tab_cleared(seq) stops the role-bound engine that holds
--         `seq` — and ONLY that one. The other role's engine, holding a
--         different sequence, keeps playing.
--   SS-2  displayed_tab_cleared(seq) with no role-bound engine holding `seq`
--         is a no-op: neither engine is disturbed.
--   SS-3  displayed_tab_changed parks BOTH engines when they are playing
--         (the user changed what they're looking at; continuing to play the
--         prior side is surprising).
--   SS-4  displayed_tab_changed is a no-op for already-parked engines
--         (idempotent; no spurious work on stopped engines).
--   SS-5  project_changed tears down BOTH role engines: after the signal
--         each engine is back to the unloaded state (loaded_sequence_id nil,
--         no playback controller) — the same observable state as a
--         freshly-constructed engine.
--
-- The engine module is NOT stubbed; teardown is observed through the real
-- engine's public lifecycle state. No call-counting.
--
-- HEADLESS NOTE: SS-1/SS-3 require a real GPU surface to put an engine into
-- the "playing" state (PlaybackController::Play asserts without a surface).
-- Surface creation is hard-asserted: --test mode always provides Metal
-- surfaces, so a failure is an environment defect, never a skip.
--
-- OPEN QUESTIONS: none.
--
-- Runs via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_transport_subscribes_to_signals.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_transport_subscribes_to_signals.lua (integration) ===")

require("test_env")
local database  = require("core.database")
local Signals   = require("core.signals")
local transport = require("core.playback.transport")

-- ── DB: one project + a timeline (record) + a master (source) so the two
--    role engines hold DISTINCT sequences. A single project keeps the REAL
--    project_changed cascade's other in-process listeners (which resolve
--    the active project) from tripping a "multiple projects" assert. ──────
local DB = "/tmp/jve/test_transport_signals_integ.db"
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
      VALUES ('media_s', 'proj', %q, 'S', 108, 24000, 1001, 640, 360, 2, 48000, %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, start_timecode_frame, created_at, modified_at)
      VALUES ('tl', 'proj', 'Timeline', 'sequence', 24000, 1001, 48000, 640, 360,
              0, 300, 0, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('tl_v1', 'tl', 'V1', 'VIDEO', 1, 1);
]], now, now, media_path, now, now, now, now)))
local master_id = require("test_env").create_test_masterclip_sequence(
    "proj", "S", 24000, 1001, 108, "media_s")

if transport.is_bootstrapped() then transport.shutdown() end
transport.init("proj")

local src = transport.engine_for_role("source")
local rec = transport.engine_for_role("record")

-- Real GPU surfaces so engines can actually enter the "playing" state.
local WIDGET = qt_constants.WIDGET
-- --test mode always provides Metal surfaces (every GPU test in this suite
-- relies on it); a creation failure is an environment defect, not a reason
-- to silently skip the play-dependent scenarios.
local surf_a = WIDGET.CREATE_GPU_VIDEO_SURFACE()
local surf_b = WIDGET.CREATE_GPU_VIDEO_SURFACE()
assert(surf_a and surf_b, "GPU surface creation failed — play-dependent "
    .. "scenarios SS-1/SS-3 cannot run; fix the environment, do not skip")
src:set_surface(surf_a)
rec:set_surface(surf_b)

-- Helper: rebind both engines to their role sequences from clean state.
local function rebind()
    transport.bind_role_to_sequence("source", master_id)
    transport.bind_role_to_sequence("record", "tl")
end
rebind()

-- Drive BOTH engines into the "playing" state. Audio ownership is single
-- (only one side produces samples at a time — that's I1), but the playing
-- STATE is per-engine. play() acquires audio for the calling engine; a
-- second play() on the other engine hands audio over to it. Replaying the
-- first re-grabs audio, leaving both engines in state="playing".
local function play_both()
    if not rec:is_playing() then rec:play() end
    if not src:is_playing() then src:play() end
    if not rec:is_playing() then rec:play() end
    assert(src:is_playing() and rec:is_playing(),
        "fixture: both engines must be playing")
end

-- ── SS-1  cleared(seq) stops ONLY the engine holding seq ─────────────────
do
    print("\n-- (SS-1) displayed_tab_cleared stops only the holder --")
    play_both()
    Signals.emit("displayed_tab_cleared", "tl")  -- record holds 'tl'
    assert(not rec:is_playing(), string.format(
        "displayed_tab_cleared('tl') must stop the record engine (holds tl); "
        .. "rec.state=%s", tostring(rec.state)))
    assert(src:is_playing(), string.format(
        "displayed_tab_cleared('tl') must NOT stop the source engine "
        .. "(holds the master, not tl); src.state=%s", tostring(src.state)))
    print("  PASS: only the engine holding the cleared seq stopped")

    src:stop()
    rebind()
end

-- ── SS-2  cleared(seq) nobody holds → no-op ──────────────────────────────
do
    print("\n-- (SS-2) displayed_tab_cleared(unheld seq) is a no-op --")
    rec:play()
    assert(rec:is_playing(), "fixture: record playing before unheld-clear")
    Signals.emit("displayed_tab_cleared", "no-such-seq")
    assert(rec:is_playing(), string.format(
        "displayed_tab_cleared for a seq no engine holds must not stop "
        .. "any engine; rec.state=%s", tostring(rec.state)))
    print("  PASS: clearing an unheld sequence disturbs no engine")
    rec:stop()
    rebind()
end

-- ── SS-3  displayed_tab_changed parks BOTH playing engines ───────────────
do
    print("\n-- (SS-3) displayed_tab_changed stops both playing engines --")
    play_both()
    Signals.emit("displayed_tab_changed", "tl", master_id)
    assert(not src:is_playing() and not rec:is_playing(), string.format(
        "displayed_tab_changed must park BOTH engines when playing; "
        .. "src=%s rec=%s", tostring(src.state), tostring(rec.state)))
    print("  PASS: tab change parked both playing engines")
    rebind()
end

-- ── SS-4  displayed_tab_changed on parked engines → no-op (no raise) ─────
print("\n-- (SS-4) displayed_tab_changed is a no-op for parked engines --")
do
    assert(not src:is_playing() and not rec:is_playing(),
        "fixture: both engines parked")
    -- Idempotent: emitting against already-stopped engines must not raise.
    Signals.emit("displayed_tab_changed", "tl", master_id)
    assert(not src:is_playing() and not rec:is_playing(),
        "displayed_tab_changed must leave parked engines parked")
    print("  PASS: tab change on parked engines is a clean no-op")
end

-- ── SS-5  project_changed tears down BOTH role engines ───────────────────
print("\n-- (SS-5) project_changed tears down both engines --")
do
    rebind()
    assert(src.loaded_sequence_id == master_id and rec.loaded_sequence_id == "tl",
        "fixture: both engines loaded before project_changed")

    -- Emit the REAL signal. Transport's priority-5 handler walks both role
    -- engines and tears them down regardless of the new project_id. We pass
    -- the currently-open project so the other in-process listeners that
    -- resolve the active project don't trip on a nonexistent / ambiguous id.
    Signals.emit("project_changed", "proj")

    assert(src.loaded_sequence_id == nil, string.format(
        "project_changed must tear down the source engine "
        .. "(loaded_sequence_id→nil); got %s", tostring(src.loaded_sequence_id)))
    assert(rec.loaded_sequence_id == nil, string.format(
        "project_changed must tear down the record engine "
        .. "(loaded_sequence_id→nil); got %s", tostring(rec.loaded_sequence_id)))
    assert(src._playback_controller == nil and rec._playback_controller == nil,
        "project_changed teardown must release both engines' playback controllers")
    print("  PASS: both role engines torn down to the unloaded state")
end

if transport.is_bootstrapped() then transport.shutdown() end
database.shutdown()
print("\nPASS test_transport_subscribes_to_signals.lua")
os.exit(0)
