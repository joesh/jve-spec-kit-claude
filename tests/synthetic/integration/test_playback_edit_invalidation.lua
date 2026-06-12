-- Integration: a timeline edit re-queries clips on the loaded engine only.
--
-- REPLACES (from tests/synthetic/lua/):
--   test_playback_edit_invalidation.lua
--
-- Honest conversion. The rejected original replaced core.qt_constants,
-- core.signals, core.logger, models.track, core.renderer AND models.sequence
-- with fakes, then asserted that a fake RELOAD_ALL_CLIPS counter ticked.
-- This version runs inside JVEEditor (--test) with REAL bindings, REAL
-- signals, and REAL PlaybackEngines bound to REAL DB sequences (each gets a
-- real C++ PlaybackController). The ONLY instrumentation is a pass-through
-- wrapper on PLAYBACK.RELOAD_ALL_CLIPS that counts calls and UNCONDITIONALLY
-- delegates to the real binding, restored after the scenarios.
--
-- No play() is invoked — the edit-invalidation path (content_changed → clip
-- re-query) fires on a parked engine, so the C++ AudioPump never starts.
--
-- DOMAIN RULES PINNED (017 FR-027; edit = content_changed):
--   EI-1  content_changed for the LOADED sequence re-queries the engine's
--         clips (one RELOAD_ALL_CLIPS on its controller).
--   EI-2  content_changed for a DIFFERENT sequence does NOT re-query — the
--         engine ignores edits to sequences it isn't showing.
--   EI-3  Each edit on the loaded sequence triggers its own re-query (edits
--         are not coalesced): N emissions → N re-queries.
--   EI-4  A torn-down engine (transport project_changed teardown) ignores
--         content_changed even for the sequence it used to hold — the
--         lifecycle invariant (loaded_sequence_id nil ⟺ controller nil) means
--         there is nothing to re-query.
--   EI-5  A constructed-but-never-loaded engine ignores content_changed for
--         any sequence id (no controller, no loaded sequence).
--
-- OPEN QUESTIONS: none.
--
-- Runs via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_playback_edit_invalidation.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_playback_edit_invalidation.lua (integration) ===")

require("test_env")
local database       = require("core.database")
local Signals        = require("core.signals")
local transport      = require("core.playback.transport")
local PlaybackEngine = require("core.playback.playback_engine")
local qt             = require("core.qt_constants")

-- ── DB: project + two distinct timelines ─────────────────────────────────
local DB = "/tmp/jve/test_edit_invalidation_integ.db"
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
      VALUES ('media_e', 'proj', %q, 'E', 108, 24000, 1001, 640, 360, 2, 48000, %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, start_timecode_frame, created_at, modified_at)
      VALUES ('tl',  'proj', 'Timeline',  'sequence', 24000, 1001, 48000, 640, 360,
              0, 300, 0, 0, %d, %d),
             ('tl2', 'proj', 'Timeline2', 'sequence', 24000, 1001, 48000, 640, 360,
              0, 300, 0, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('tl_v1', 'tl', 'V1', 'VIDEO', 1, 1),
             ('tl2_v1', 'tl2', 'V1', 'VIDEO', 1, 1);
]], now, now, media_path, now, now, now, now, now, now)))

if transport.is_bootstrapped() then transport.shutdown() end
transport.init("proj")
transport.bind_role_to_sequence("record", "tl")
local rec = transport.engine_for_role("record")
assert(rec.loaded_sequence_id == "tl" and rec._playback_controller ~= nil,
    "fixture: record engine must be loaded with 'tl' and own a controller")

-- Pass-through wrapper: count RELOAD_ALL_CLIPS, unconditionally delegate.
local reloads = 0
local real_reload = qt.PLAYBACK.RELOAD_ALL_CLIPS
qt.PLAYBACK.RELOAD_ALL_CLIPS = function(...)
    reloads = reloads + 1
    return real_reload(...)
end
local function reset() reloads = 0 end

-- ── EI-1  edit on the loaded sequence re-queries ─────────────────────────
print("\n-- (EI-1) edit on the loaded sequence → re-query --")
do
    reset()
    Signals.emit("content_changed", "tl")
    assert(reloads == 1, string.format(
        "content_changed('tl') must re-query the engine loaded with 'tl' "
        .. "exactly once; got %d", reloads))
    print("  PASS: edit on the loaded sequence re-queried clips once")
end

-- ── EI-2  edit on a different sequence does not re-query ──────────────────
print("\n-- (EI-2) edit on a different sequence → no re-query --")
do
    reset()
    Signals.emit("content_changed", "tl2")
    assert(reloads == 0, string.format(
        "content_changed('tl2') must NOT re-query the engine showing 'tl'; "
        .. "got %d re-query/queries", reloads))
    print("  PASS: edit on an unrelated sequence left the engine alone")
end

-- ── EI-3  edits are not coalesced ────────────────────────────────────────
print("\n-- (EI-3) three edits → three re-queries (no coalescing) --")
do
    reset()
    Signals.emit("content_changed", "tl")
    Signals.emit("content_changed", "tl")
    Signals.emit("content_changed", "tl")
    assert(reloads == 3, string.format(
        "three edits on the loaded sequence must produce three re-queries "
        .. "(not coalesced); got %d", reloads))
    print("  PASS: each edit produced its own re-query")
end

-- ── EI-4  torn-down engine ignores content_changed ───────────────────────
print("\n-- (EI-4) torn-down engine ignores content_changed --")
do
    PlaybackEngine.teardown_engine(rec)
    assert(rec.loaded_sequence_id == nil and rec._playback_controller == nil,
        "fixture: teardown must clear loaded_sequence_id and controller")
    reset()
    Signals.emit("content_changed", "tl")  -- the seq it used to hold
    assert(reloads == 0, string.format(
        "a torn-down engine must ignore content_changed even for its "
        .. "ex-sequence (lifecycle invariant); got %d re-query/queries", reloads))
    print("  PASS: torn-down engine ignored the edit for its former sequence")
end

-- ── EI-5  constructed-but-unloaded engine ignores content_changed ────────
print("\n-- (EI-5) never-loaded engine ignores content_changed --")
do
    local fresh = PlaybackEngine.new("source")
    assert(fresh.loaded_sequence_id == nil,
        "fixture: a freshly constructed engine has loaded_sequence_id nil")
    reset()
    Signals.emit("content_changed", "tl")
    assert(reloads == 0, string.format(
        "a never-loaded engine must ignore content_changed for any "
        .. "sequence id; got %d re-query/queries", reloads))
    print("  PASS: never-loaded engine ignored the edit")
end

-- Restore the real binding.
qt.PLAYBACK.RELOAD_ALL_CLIPS = real_reload
if transport.is_bootstrapped() then transport.shutdown() end
database.shutdown()
print("\nPASS test_playback_edit_invalidation.lua")
os.exit(0)
