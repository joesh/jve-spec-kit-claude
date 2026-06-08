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
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Media = require("models.media")
local Clip = require("models.clip")
local command_manager = require("core.command_manager")

local DB_PATH = "/tmp/jve/test_013_slip_slide_roll.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    local db = database.get_connection()
    db:exec(require("import_schema"))
    return db
end

local function build_fixture(owner_fps, nested_native_duration)
    local db = fresh_db()
    
    local project_id = "p1"
    Project.create("p", {
        id = project_id,
        fps_mismatch_policy = "passthrough",
        settings = {
            master_clock_hz = 192000,
            default_fps = { num = 24, den = 1 }
        }
    }):save()

    local seq_id = "e"
    Sequence.create("edit", project_id, { fps_numerator = owner_fps, fps_denominator = 1 }, 1920, 1080, {
        id = seq_id,
        kind = "sequence",
        audio_sample_rate = 48000,
    }):save()

    Track.create_video("V1", seq_id, { id = "e-v1", index = 1 }):save()

    local media_id = "med-v"
    Media.create({
        id = media_id,
        project_id = project_id,
        name = "v.mov",
        file_path = "/tmp/v.mov",
        duration_frames = nested_native_duration,
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
        audio_channels = 0,
        metadata = '{"start_tc_value":0,"start_tc_rate":24}'
    }):save()

    local MC_TEST = Sequence.ensure_master(media_id, project_id)

    command_manager.init(seq_id, project_id)

    return db, MC_TEST
end

local function seed_clip(clip_id, policy, mc_id,
                       sequence_start, duration, source_in, source_out)
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
    local cid = Clip.create({
        id = clip_id,
        project_id = "p1",
        owner_sequence_id = "e",
        track_id = "e-v1",
        sequence_id = mc_id,
        name = clip_id,
        sequence_start_frame = sequence_start,
        duration_frames = duration,
        source_in_frame = source_in,
        source_out_frame = source_out,
        source_in_subframe = sub_in,
        source_out_subframe = sub_out,
        fps_mismatch_policy = policy,
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
    assert(cid == clip_id, "seed_clip failed")
end

local function load_clip(id)
    local c = Clip.load_optional(id)
    assert(c, "load_clip: not found: " .. id)
    return {
        sequence_start = c.sequence_start,
        duration       = c.duration,
        source_in      = c.source_in,
        source_out     = c.source_out,
    }
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

-- Helper: execute command with proper event wrapping
local function execute_cmd(module, params)
    command_manager.begin_command_event("script")
    -- bypass command manager registry to just call execute for testing
    local ok, result_or_err = pcall(module.execute, params)
    command_manager.end_command_event()
    if not ok then return false, result_or_err end
    return result_or_err == nil or (type(result_or_err) == "table" and result_or_err.success ~= false)
end

-- -------------------------------------------------------------------------
-- CT-C4 Slip: positive slip of 5 nested frames. Clip [100, 200) source
-- [50, 150) → still [100, 200), source [55, 155). Timeline untouched.
-- -------------------------------------------------------------------------
print("-- CT-C4 Slip +5 --")
do
    local db, mc_id = build_fixture(24, 1000)
    seed_clip("c", "passthrough", mc_id, 100, 100, 50, 150)
    assert(execute_cmd(Slip, {
        sequence_id = "e", clip_id = "c", delta_source_frames = 5,
    }))
    local c = load_clip("c")
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
    local db, mc_id = build_fixture(24, 1000)
    seed_clip("c", "passthrough", mc_id, 100, 100, 50, 150)
    assert(execute_cmd(Slip, {
        sequence_id = "e", clip_id = "c", delta_source_frames = -10,
    }))
    local c = load_clip("c")
    assert(c.sequence_start == 100 and c.duration == 100, "timeline untouched")
    assert(c.source_in == 40 and c.source_out == 140, string.format(
        "source shifted by -10; got [%d,%d)", c.source_in, c.source_out))
    print("  ok")
end

-- Error: Slip that would push source_in below 0 (source window lower bound must be >= 0).
print("-- Slip that underflows refuses --")
do
    local db, mc_id = build_fixture(24, 1000)
    seed_clip("c", "passthrough", mc_id, 100, 100, 5, 105)
    local success, err = execute_cmd(Slip, {
        sequence_id = "e", clip_id = "c", delta_source_frames = -10,
    })
    assert(not success, "Slip past source_in=0 must refuse")
    local c = load_clip("c")
    assert(c.source_in == 5 and c.source_out == 105,
        "DB unchanged after refused underflow")
    print("  ok")
end

-- Error: Slip that would push source_out past nested native duration.
print("-- Slip that overflows nested bounds refuses --")
do
    -- nested has 200-frame native duration.
    local db, mc_id = build_fixture(24, 200)
    seed_clip("c", "passthrough", mc_id, 0, 100, 95, 195)
    local success, err = execute_cmd(Slip, {
        sequence_id = "e", clip_id = "c", delta_source_frames = 10,
    })
    assert(not success, "Slip past source_out=nested.duration must refuse")
    local c = load_clip("c")
    assert(c.source_in == 95 and c.source_out == 195,
        "DB unchanged after refused overflow")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- CT-C5 Slide: +N shifts sequence_start; window unchanged.
-- -------------------------------------------------------------------------
print("-- CT-C5 Slide +15 --")
do
    local db, mc_id = build_fixture(24, 1000)
    seed_clip("c", "passthrough", mc_id, 100, 100, 50, 150)
    assert(execute_cmd(Slide, {
        sequence_id = "e", clip_id = "c", delta_timeline_frames = 15,
    }))
    local c = load_clip("c")
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
    local db, mc_id = build_fixture(24, 1000)
    seed_clip("c", "passthrough", mc_id, 10, 100, 50, 150)
    local success, err = execute_cmd(Slide, {
        sequence_id = "e", clip_id = "c", delta_timeline_frames = -20,
    })
    assert(not success, "Slide below 0 must refuse")
    local c = load_clip("c")
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
    local db, mc_id = build_fixture(24, 1000)
    seed_clip("a", "passthrough", mc_id, 0, 100, 0, 100)
    seed_clip("b", "passthrough", mc_id, 100, 100, 200, 300)
    assert(execute_cmd(Roll, {
        sequence_id = "e",
        outgoing_clip_id = "a",
        incoming_clip_id = "b",
        delta_timeline_frames = 10,
    }))
    local a = load_clip("a")
    local b = load_clip("b")
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
    local db, mc_id = build_fixture(24, 1000)
    seed_clip("a", "passthrough", mc_id, 0, 100, 0, 100)
    seed_clip("b", "passthrough", mc_id, 100, 100, 200, 300)
    assert(execute_cmd(Roll, {
        sequence_id = "e",
        outgoing_clip_id = "a",
        incoming_clip_id = "b",
        delta_timeline_frames = -10,
    }))
    local a = load_clip("a")
    local b = load_clip("b")
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
    local db, mc_id = build_fixture(24, 1000)
    seed_clip("a", "passthrough", mc_id, 0, 50,  0,   50)
    seed_clip("b", "passthrough", mc_id, 50, 100, 200, 300)
    local success, err = execute_cmd(Roll, {
        sequence_id = "e",
        outgoing_clip_id = "a",
        incoming_clip_id = "b",
        delta_timeline_frames = -50,
    })
    assert(not success, "Roll collapsing A to zero must refuse")
    print("  ok")
end

-- Error: Roll that would push A's source_out past master coverage.
print("-- Roll that overflows A's master coverage refuses --")
do
    -- nested has 200-frame coverage. A currently ends at 180 (source_out).
    -- Roll N=+25 would push A.source_out to 205 > 200 → must refuse.
    local db, mc_id = build_fixture(24, 200)
    seed_clip("a", "passthrough", mc_id, 0,  100, 80,  180)
    seed_clip("b", "passthrough", mc_id, 100, 50, 180, 230)
    local success, err = execute_cmd(Roll, {
        sequence_id = "e",
        outgoing_clip_id = "a",
        incoming_clip_id = "b",
        delta_timeline_frames = 25,
    })
    assert(not success, "Roll past A.source_out=master.coverage must refuse")
    local a = load_clip("a")
    assert(a.source_out == 180, "DB unchanged after refused roll overflow: source_out=" .. tostring(a.source_out))
    print("  ok")
end

-- Error: non-adjacent clips. B's start != A's end → refuse.
print("-- Roll on non-adjacent clips refuses --")
do
    local db, mc_id = build_fixture(24, 1000)
    seed_clip("a", "passthrough", mc_id, 0, 100, 0, 100)
    seed_clip("b", "passthrough", mc_id, 150, 100, 200, 300)  -- gap
    local success, err = execute_cmd(Roll, {
        sequence_id = "e",
        outgoing_clip_id = "a",
        incoming_clip_id = "b",
        delta_timeline_frames = 10,
    })
    assert(not success, "Roll on non-adjacent clips must refuse")
    print("  ok")
end

print("✅ test_013_slip_slide_roll.lua passed")
