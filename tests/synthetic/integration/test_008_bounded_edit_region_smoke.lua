-- 008 smoke: bounded edit region — edit cost doesn't scale with sequence size.
--
-- Per FR-1/FR-2/FR-3 the edit pipeline must load only clips that participate
-- in the edit. A single trim on a small sequence vs the SAME trim shape on
-- a 20-track 200-clip sequence must take comparable time (within a small
-- constant factor), NOT linear in N.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_008_bounded_edit_region_smoke.lua ===")

require("test_env")
local database = require("core.database")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_008_bounded.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(DB); os.remove(DB..".wal"); os.remove(DB..".shm")
assert(database.init(DB))
local db = database.get_connection()
local now = os.time()

assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p','P','passthrough','{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',%d,%d);
    -- One synthetic master so clips have a sequence_id to reference.
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
      VALUES ('src','p','SRC','master',24,1,NULL,1920,1080,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
      VALUES ('src-v1','src','V1','VIDEO',1);
    UPDATE sequences SET default_video_layer_track_id='src-v1' WHERE id='src';
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
        created_at, modified_at)
      VALUES ('med','p','m.mov','/tmp/m.mov',100000,24,1,0,0,%d,%d);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr','p','src','src-v1','med',0,100000,0,100000,1,1.0,0,%d,%d);
]], now, now, now, now, now, now, now, now)))

local function build_seq(seq_id, n_tracks, clips_per_track)
    db:exec(string.format([[
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
            fps_denominator, audio_sample_rate, width, height, playhead_frame,
            view_start_frame, view_duration_frames, start_timecode_frame,
            created_at, modified_at)
          VALUES ('%s','p','%s','sequence',24,1,48000,1920,1080,
                  0,0,300,0,%d,%d)
    ]], seq_id, seq_id, now, now))
    db:exec("BEGIN")
    for t = 1, n_tracks do
        local tid = seq_id .. "-t" .. t
        db:exec(string.format(
            "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
            .. "VALUES ('%s','%s','V%d','VIDEO',%d)", tid, seq_id, t, t))
        for c = 1, clips_per_track do
            local cid = string.format("%s-t%d-c%d", seq_id, t, c)
            local start = (c - 1) * 100
            db:exec(string.format(
                "INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id, "
                .. "track_id, source_in_frame, source_out_frame, sequence_start_frame, "
                .. "duration_frames, fps_mismatch_policy, enabled, volume, "
                .. "playhead_frame, name, created_at, modified_at) "
                .. "VALUES ('%s','p','%s','src','%s',0,80,%d,80,'passthrough',1,1.0,0,"
                .. "'c%d',%d,%d)",
                cid, seq_id, tid, start, c, now, now))
        end
    end
    db:exec("COMMIT")
end

build_seq("small", 1,  5)
build_seq("big",   20, 200)

local function trim_time(seq_id, target_clip)
    command_manager.init(seq_id, "p")
    local t0 = os.clock()
    local res = command_manager.execute("TrimHead", {
        project_id  = "p",
        sequence_id = seq_id,
        clip_ids    = { target_clip },
        trim_frame  = 110,
    })
    local elapsed = (os.clock() - t0) * 1000
    assert(res and res.success, "TrimHead failed: " .. tostring(res and res.error_message))
    return elapsed
end

local t_small = trim_time("small", "small-t1-c2")
local t_big   = trim_time("big",   "big-t1-c2")

print(string.format("  small (1 track, 5 clips):     %.1fms", t_small))
print(string.format("  big   (20 tracks, 4000 clips): %.1fms", t_big))

-- If the pipeline loaded ALL clips it'd be ~800× slower for big vs small
-- (4000 clips / 5 clips). Bounded edit region keeps it well below that
-- ceiling — small constant factors from per-track gap recompute remain
-- (scope = affected tracks × clips/track), but the global O(N) scan is
-- the regression we're guarding against. 100× headroom catches scan-all
-- while leaving room for legitimate per-track work.
local ratio = t_big / math.max(t_small, 0.1)
assert(ratio < 100, string.format(
    "FR-1/FR-3: big-sequence trim is %.1f× slower than small-sequence trim "
    .. "(%.1fms vs %.1fms). Edit cost is scaling with sequence size — "
    .. "bounded-region invariants likely broken.", ratio, t_big, t_small))
print(string.format("  PASS: big/small ratio = %.1f× (limit 100×) — bounded edit region intact",
    ratio))

print("\n✅ test_008_bounded_edit_region_smoke.lua passed")
