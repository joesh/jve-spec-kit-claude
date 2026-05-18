-- T035 (013): CT-C4 Slip, CT-C5 Slide, CT-C6 Roll contract tests.
--
-- Slip:  move source_in AND source_out by ±N nested frames. Window
--        content changes, but the clip's position and duration on the
--        owner timeline are unchanged. Must keep the source window
--        within [0, nested.native_duration] (source window: non-empty, lower bound >= 0).
--
-- Slide: move sequence_start by ±N owner frames. Source window is
--        unchanged. Adjacent clips on the same track ripple (the
--        previous clip extends/shrinks to absorb the slide on one side;
--        the next clip shifts on the other). For this contract test
--        we exercise the core mutation on a single clip with no
--        neighbors — ripple-on-neighbors lives with T046.
--
-- Roll:  between two adjacent clips A (outgoing) and B (incoming),
--        shift the shared edit point by ±N owner frames.
--          A.source_out shifts by source_delta_A;
--          A.duration +=/- N;
--          B.source_in shifts by source_delta_B;
--          B.sequence_start +=/- N;
--          B.duration -=/+ N.
--        Each side uses its own fps_mismatch_policy. Source window must be
--        non-empty with lower bound >= 0 on both sides.
--
-- Black-box DB-state assertions.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_013_slip_slide_roll.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function build_fixture(owner_fps, nested_native_duration)
    local db = fresh_db()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', %d, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-v', 'p1', 'v.mov', '/tmp/v.mov', %d, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', 0, %d, 0, %d, 48000,
            1, 1.0, 0, 0, 0);
    ]], owner_fps, nested_native_duration, nested_native_duration, nested_native_duration)))
    return db
end

local function seed_clip(db, clip_id, policy,
                       sequence_start, duration, source_in, source_out)
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            fps_mismatch_policy, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('%s', 'p1', 'e', 'e-v1', 'm', '%s', %d, %d, %d, %d,
            '%s', 1, 1.0, 0, 0, 0)
    ]], clip_id, clip_id, sequence_start, duration, source_in, source_out,
       policy)))
end

local function load_clip(db, id)
    local stmt = db:prepare([[
        SELECT sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "load_clip: not found: " .. id)
    local r = {
        sequence_start = stmt:value(0),
        duration       = stmt:value(1),
        source_in      = stmt:value(2),
        source_out     = stmt:value(3),
    }
    stmt:finalize()
    return r
end

local Slip  = require("core.commands.slip")
local Slide = require("core.commands.slide")
local Roll  = require("core.commands.roll")
assert(type(Slip.execute) == "function",
    "T044 not landed: core.commands.slip must export .execute")
assert(type(Slide.execute) == "function",
    "T044 not landed: core.commands.slide must export .execute")
assert(type(Roll.execute) == "function",
    "T044 not landed: core.commands.roll must export .execute")

-- -------------------------------------------------------------------------
-- CT-C4 Slip: positive slip of 5 nested frames. Clip [100, 200) source
-- [50, 150) → still [100, 200), source [55, 155). Timeline untouched.
-- -------------------------------------------------------------------------
print("-- CT-C4 Slip +5 --")
do
    local db = build_fixture(24, 1000)
    seed_clip(db, "c", "passthrough", 100, 100, 50, 150)
    Slip.execute({
        sequence_id = "e", clip_id = "c", delta_source_frames = 5,
    })
    local c = load_clip(db, "c")
    assert(c.sequence_start == 100 and c.duration == 100, string.format(
        "timeline must not move under Slip; got [tl=%d,d=%d]",
        c.sequence_start, c.duration))
    assert(c.source_in == 55 and c.source_out == 155, string.format(
        "source must shift by +5 under Slip; got [%d,%d)",
        c.source_in, c.source_out))
    print("  ok")
end

-- Negative slip.
print("-- Slip -10 --")
do
    local db = build_fixture(24, 1000)
    seed_clip(db, "c", "passthrough", 100, 100, 50, 150)
    Slip.execute({
        sequence_id = "e", clip_id = "c", delta_source_frames = -10,
    })
    local c = load_clip(db, "c")
    assert(c.sequence_start == 100 and c.duration == 100, "timeline untouched")
    assert(c.source_in == 40 and c.source_out == 140, string.format(
        "source shifted by -10; got [%d,%d)", c.source_in, c.source_out))
    print("  ok")
end

-- Error: Slip that would push source_in below 0 (source window lower bound must be >= 0).
print("-- Slip that underflows refuses --")
do
    local db = build_fixture(24, 1000)
    seed_clip(db, "c", "passthrough", 100, 100, 5, 105)
    local ok = pcall(Slip.execute, {
        sequence_id = "e", clip_id = "c", delta_source_frames = -10,
    })
    assert(not ok, "Slip past source_in=0 must refuse")
    local c = load_clip(db, "c")
    assert(c.source_in == 5 and c.source_out == 105,
        "DB unchanged after refused underflow")
    print("  ok")
end

-- Error: Slip that would push source_out past nested native duration.
print("-- Slip that overflows nested bounds refuses --")
do
    -- nested has 200-frame native duration.
    local db = build_fixture(24, 200)
    seed_clip(db, "c", "passthrough", 0, 100, 95, 195)
    local ok = pcall(Slip.execute, {
        sequence_id = "e", clip_id = "c", delta_source_frames = 10,
    })
    assert(not ok, "Slip past source_out=nested.duration must refuse")
    local c = load_clip(db, "c")
    assert(c.source_in == 95 and c.source_out == 195,
        "DB unchanged after refused overflow")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- CT-C5 Slide: +N shifts sequence_start; window unchanged.
-- -------------------------------------------------------------------------
print("-- CT-C5 Slide +15 --")
do
    local db = build_fixture(24, 1000)
    seed_clip(db, "c", "passthrough", 100, 100, 50, 150)
    Slide.execute({
        sequence_id = "e", clip_id = "c", delta_timeline_frames = 15,
    })
    local c = load_clip(db, "c")
    assert(c.sequence_start == 115 and c.duration == 100, string.format(
        "timeline shifts by +15; got [tl=%d,d=%d]",
        c.sequence_start, c.duration))
    assert(c.source_in == 50 and c.source_out == 150,
        "source window unchanged under Slide")
    print("  ok")
end

-- Slide negative: sequence_start must not go below 0.
print("-- Slide that drags past frame 0 refuses --")
do
    local db = build_fixture(24, 1000)
    seed_clip(db, "c", "passthrough", 10, 100, 50, 150)
    local ok = pcall(Slide.execute, {
        sequence_id = "e", clip_id = "c", delta_timeline_frames = -20,
    })
    assert(not ok, "Slide below 0 must refuse")
    local c = load_clip(db, "c")
    assert(c.sequence_start == 10, "DB unchanged after refused slide")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- CT-C6 Roll: two adjacent clips A [0,100) source [0,100) and B [100,200)
-- source [200,300) on the same track. Roll the boundary by +10 owner.
-- A: sequence_start=0 unchanged, duration 100→110, source_out 100→110.
-- B: sequence_start 100→110, duration 100→90, source_in 200→210.
-- Both passthrough 1:1.
-- -------------------------------------------------------------------------
print("-- CT-C6 Roll +10 at boundary --")
do
    local db = build_fixture(24, 1000)
    seed_clip(db, "a", "passthrough", 0, 100, 0, 100)
    seed_clip(db, "b", "passthrough", 100, 100, 200, 300)
    Roll.execute({
        sequence_id = "e",
        outgoing_clip_id = "a",
        incoming_clip_id = "b",
        delta_timeline_frames = 10,
    })
    local a = load_clip(db, "a")
    local b = load_clip(db, "b")
    assert(a.sequence_start == 0 and a.duration == 110
           and a.source_in == 0 and a.source_out == 110, string.format(
        "A after +10 Roll expected [tl=0,d=110,s=(0,110)]; got [tl=%d,d=%d,s=(%d,%d)]",
        a.sequence_start, a.duration, a.source_in, a.source_out))
    assert(b.sequence_start == 110 and b.duration == 90
           and b.source_in == 210 and b.source_out == 300, string.format(
        "B after +10 Roll expected [tl=110,d=90,s=(210,300)]; got [tl=%d,d=%d,s=(%d,%d)]",
        b.sequence_start, b.duration, b.source_in, b.source_out))
    print("  ok")
end

-- Roll negative: the boundary moves leftward.
print("-- Roll -10 at boundary --")
do
    local db = build_fixture(24, 1000)
    seed_clip(db, "a", "passthrough", 0, 100, 0, 100)
    seed_clip(db, "b", "passthrough", 100, 100, 200, 300)
    Roll.execute({
        sequence_id = "e",
        outgoing_clip_id = "a",
        incoming_clip_id = "b",
        delta_timeline_frames = -10,
    })
    local a = load_clip(db, "a")
    local b = load_clip(db, "b")
    assert(a.duration == 90 and a.source_out == 90,
        "A shrunk 10 from the right")
    assert(b.sequence_start == 90 and b.duration == 110
           and b.source_in == 190,
        "B grew 10 on the left")
    print("  ok")
end

-- Error: Roll that would collapse A to 0 duration.
print("-- Roll that collapses A refuses --")
do
    local db = build_fixture(24, 1000)
    seed_clip(db, "a", "passthrough", 0, 50,  0,   50)
    seed_clip(db, "b", "passthrough", 50, 100, 200, 300)
    local ok = pcall(Roll.execute, {
        sequence_id = "e",
        outgoing_clip_id = "a",
        incoming_clip_id = "b",
        delta_timeline_frames = -50,
    })
    assert(not ok, "Roll collapsing A to zero must refuse")
    print("  ok")
end

-- Error: Roll that would push A's source_out past master coverage.
print("-- Roll that overflows A's master coverage refuses --")
do
    -- nested has 200-frame coverage. A currently ends at 180 (source_out).
    -- Roll N=+25 would push A.source_out to 205 > 200 → must refuse.
    local db = build_fixture(24, 200)
    seed_clip(db, "a", "passthrough", 0,  100, 80,  180)
    seed_clip(db, "b", "passthrough", 100, 50, 180, 230)
    local ok = pcall(Roll.execute, {
        sequence_id = "e",
        outgoing_clip_id = "a",
        incoming_clip_id = "b",
        delta_timeline_frames = 25,
    })
    assert(not ok, "Roll past A.source_out=master.coverage must refuse")
    local a = load_clip(db, "a")
    assert(a.source_out == 180, "DB unchanged after refused roll overflow: source_out=" .. tostring(a.source_out))
    print("  ok")
end

-- Error: non-adjacent clips. B's start != A's end → refuse.
print("-- Roll on non-adjacent clips refuses --")
do
    local db = build_fixture(24, 1000)
    seed_clip(db, "a", "passthrough", 0, 100, 0, 100)
    seed_clip(db, "b", "passthrough", 150, 100, 200, 300)  -- gap
    local ok = pcall(Roll.execute, {
        sequence_id = "e",
        outgoing_clip_id = "a",
        incoming_clip_id = "b",
        delta_timeline_frames = 10,
    })
    assert(not ok, "Roll on non-adjacent clips must refuse")
    print("  ok")
end

print("✅ test_013_slip_slide_roll.lua passed")
