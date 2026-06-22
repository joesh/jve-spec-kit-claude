-- Regression gate for the 32× shuttle catastrophic-freeze bug (spec 025
-- FR-003). Drives the real anamnesis-gold-timeline.jvp through the full
-- PlaybackEngine path. Local-only: depends on Joe's project + media on disk.
-- Not registered in any batch runner; run via:
--   JVEEditor --test tests/synthetic/integration/test_playback_shuttle_gold_timeline.lua

local ienv = require("synthetic.integration.integration_test_env")

print("=== test_playback_shuttle_gold_timeline.lua ===")

ienv.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
local CONTROL = qt_constants.CONTROL
assert(PLAYBACK and PLAYBACK.SET_SPEED and PLAYBACK.GET_DIAG_SUMMARY)
assert(CONTROL and CONTROL.PROCESS_EVENTS)

-- Test parameters — change here, derivation propagates.
local HOLD_SEC = 4.0
local TOP_SPEED = 32.0
local LADDER = { 1.25, 1.5, 1.75, 2.0, 4.0, 8.0, 16.0, TOP_SPEED }
local PASS_BOUND_MS = 1000  -- human-perceptible "video frozen" threshold
local TICK_SEC = 1/60       -- 60Hz CVDisplayLink poll cadence
local SETTLE_SEC = 0.10     -- post-seek let-state-quiesce
local WARMUP_SEC = 0.50     -- post-play before ramp begins
local LADDER_DWELL_SEC = 0.08  -- per-rung dwell during ramp

local function poll_sleep(seconds)
    os.execute(string.format("sleep %.3f", seconds))
    CONTROL.PROCESS_EVENTS()
end

local function drive_for(seconds)
    local ticks = math.max(1, math.floor(seconds / TICK_SEC))
    for _ = 1, ticks do poll_sleep(TICK_SEC) end
end

--------------------------------------------------------------------------------
-- Step 1: copy the gold project so we don't fight the live editor's pidlock.
--------------------------------------------------------------------------------
local GOLD = os.getenv("HOME") .. "/Documents/JVE Projects/anamnesis-gold-timeline.jvp"
local TEST_COPY = "/tmp/jve_test_anamnesis_gold_copy.jvp"
do
    local src = io.open(GOLD, "rb")
    assert(src, "test_playback_shuttle_gold_timeline: required project not present at " .. GOLD ..
        " (local-only regression test — do not run in environments without this file)")
    src:close()
    os.remove(TEST_COPY); os.remove(TEST_COPY .. "-wal"); os.remove(TEST_COPY .. "-shm")
    local rc = os.execute(string.format("cp %q %q", GOLD, TEST_COPY))
    assert(rc == 0 or rc == true, "failed to copy gold project")
end

--------------------------------------------------------------------------------
-- Step 2: open the database
--------------------------------------------------------------------------------
local database = require("core.database")
assert(database.init(TEST_COPY), "database.init failed")
local db = database.get_connection()

-- Find a top-level timeline sequence + project audio rate
local seq_id, total_frames, fps_num, fps_den
do
    -- Pick the top-level sequence with the most distinct media references —
    -- that's the actual editorial timeline (gold master candidate), not the
    -- per-clip "import N copy" sub-sequences that share a single media file.
    -- The shuttle freeze only reproduces at high clip-density.
    local stmt = assert(db:prepare(
        "SELECT s.id, s.view_duration_frames, s.fps_numerator, s.fps_denominator " ..
        "FROM sequences s " ..
        "LEFT JOIN tracks t ON t.sequence_id=s.id " ..
        "LEFT JOIN clips c ON c.track_id=t.id " ..
        "LEFT JOIN media_refs mr ON mr.owner_sequence_id=c.sequence_id " ..
        "WHERE s.kind='sequence' " ..
        "GROUP BY s.id " ..
        "ORDER BY COUNT(DISTINCT mr.media_id) DESC LIMIT 1"))
    assert(stmt:exec() and stmt:next(), "no kind='sequence' row in gold project")
    seq_id        = stmt:value(0)
    total_frames  = stmt:value(1)
    fps_num       = stmt:value(2)
    fps_den       = stmt:value(3)
    stmt:finalize()
end
print(string.format("  loaded sequence %s: %d frames @ %d/%d fps",
    seq_id, total_frames, fps_num, fps_den))

-- Preflight: locate a window on the VIDEO tracks where every clip's media
-- exists on disk. Window = HOLD_SEC × TOP_SPEED × fps timeline-frames (the
-- range the playhead will traverse during the hold). Refuses to measure if
-- no clean window exists — cadence_max=0 from missing media is indistinguishable
-- from the actual freeze bug.
local SEEK_FRAME
do
    local WINDOW_FRAMES = math.ceil(HOLD_SEC * TOP_SPEED * fps_num / fps_den)

    local stmt = assert(db:prepare(
        "SELECT c.sequence_start_frame, c.duration_frames, m.file_path " ..
        "FROM clips c " ..
        "JOIN tracks t ON c.track_id = t.id " ..
        "JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id " ..
        "JOIN media m ON m.id = mr.media_id " ..
        "WHERE t.sequence_id = ? AND t.track_type='VIDEO' " ..
        "ORDER BY c.sequence_start_frame ASC"))
    stmt:bind_value(1, seq_id)
    assert(stmt:exec())
    local clips = {}
    local seen = {}  -- file_path -> bool present
    while stmt:next() do
        local start = stmt:value(0)
        local dur   = stmt:value(1)
        local path  = stmt:value(2)
        local present = seen[path]
        if present == nil then
            local f = io.open(path, "rb")
            present = (f ~= nil); if f then f:close() end
            seen[path] = present
        end
        clips[#clips+1] = {start=start, end_frame=start+dur, path=path, present=present}
    end
    stmt:finalize()
    assert(#clips > 0, "sequence has no video clips")

    local function window_ok(seek)
        local probe_end = seek + WINDOW_FRAMES
        for _, c in ipairs(clips) do
            if c.end_frame > seek and c.start < probe_end and not c.present then
                return false, c.path
            end
        end
        return true
    end
    for _, c in ipairs(clips) do
        if c.present and window_ok(c.start) then
            SEEK_FRAME = c.start
            break
        end
    end
    assert(SEEK_FRAME,
        string.format("no %d-frame window with all media present", WINDOW_FRAMES))
    print(string.format("  preflight ok: seek=%d (window %df, %d clips scanned)",
        SEEK_FRAME, WINDOW_FRAMES, #clips))
end

local WIDGET = qt_constants.WIDGET
local ok_surf, surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
assert(ok_surf and surface,
    "GPU surface required (must run via JVEEditor --test, not plain luajit)")

local PlaybackEngine = require("core.playback.playback_engine")
local function noop() end
local engine = PlaybackEngine.new("record", {
    on_show_frame       = noop,
    on_show_gap         = noop,
    on_set_rotation     = noop,
    on_set_par          = noop,
    on_position_changed = noop,
})
engine:set_surface(surface)
engine:load(seq_id)

local pc = assert(engine._playback_controller,
    "engine._playback_controller not exposed — accessor changed?")

-- engine:seek asserts SEEK_FRAME ∈ [start_frame, start_frame+total_frames).
local start_frame = engine.start_frame
assert(SEEK_FRAME >= start_frame and SEEK_FRAME < start_frame + total_frames,
    "preflight SEEK_FRAME outside engine range")
print(string.format("  seeking to preflight frame %d (sequence range %d..%d)",
    SEEK_FRAME, start_frame, start_frame + total_frames - 1))
engine:seek(SEEK_FRAME)
drive_for(SETTLE_SEC)
engine:play()
drive_for(WARMUP_SEC)

-- Ramp through the speed ladder via SET_SPEED (mirrors L-key behavior
-- without depending on shuttle_ladder internal state).
for _, target in ipairs(LADDER) do
    PLAYBACK.SET_SPEED(pc, target)
    drive_for(LADDER_DWELL_SEC)
end

print(string.format("  HOLD at %gx for %gs wall", TOP_SPEED, HOLD_SEC))
drive_for(HOLD_SEC)

local diag = PLAYBACK.GET_DIAG_SUMMARY(pc)
print(string.format("  diag: ticks=%d cadence p50/p95/p99/max = %.0f/%.0f/%.0f/%.0f ms",
    diag.tick_count, diag.cadence_p50_ms, diag.cadence_p95_ms, diag.cadence_p99_ms,
    diag.cadence_max_ms))
print(string.format("  diag: drift p50/p95 = %.3f/%.3fs gaps=%d repeats=%d",
    diag.drift_p50_s, diag.drift_p95_s, diag.gap_count, diag.repeat_count))

-- cadence_ms is only written when deliverFrame fires setFrame; cad==0 means
-- zero frames over the hold (the catastrophic freeze).
local cad = diag.cadence_max_ms
assert(cad > 0,
    string.format("FAIL: cadence_max==0 — no frames delivered during %gx hold (%d ticks)",
        TOP_SPEED, diag.tick_count))
assert(cad < PASS_BOUND_MS,
    string.format("FAIL: cadence_max during %gx hold = %.0fms >= %dms (the freeze regressed)",
        TOP_SPEED, cad, PASS_BOUND_MS))
print(string.format("  PASS: cadence_max during %gx hold = %.0fms < %dms",
    TOP_SPEED, cad, PASS_BOUND_MS))

engine:stop()
print("✅ test_playback_shuttle_gold_timeline.lua passed")
