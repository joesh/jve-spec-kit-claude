-- T036 (013): CT-C7 SplitClip preserves per-clip overrides on both halves —
-- Phase 4a (master_track_id identity).
--
-- Split divides one clip row into two at a chosen frame on the owner
-- timeline. Arithmetic (per commands.md §Split):
--   Left half:  sequence_start unchanged; duration = split_offset;
--               source_in  unchanged; source_out = source_in + source_offset.
--   Right half: sequence_start = orig_ts + split_offset;
--               duration = orig_dur - split_offset;
--               source_in  = orig_source_in + source_offset;
--               source_out unchanged.
-- source_offset is derived from split_offset under the clip's own
-- fps_mismatch_policy via owner_delta_to_source.
--
-- Override preservation (the core of CT-C7): master_layer_track_id,
-- fps_mismatch_policy, and all clip_channel_override rows present on the
-- original must land on BOTH halves. Overrides are keyed by master_track_id
-- (track UUID) under Phase 4a.
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

local DB_PATH = "/tmp/jve/test_013_split_preserves_overrides.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    local db = database.get_connection()
    db:exec(require("import_schema"))
    return db
end

local function build_fixture(owner_fps_num, nested_fps_num)
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

    Sequence.create("m", project_id, { fps_numerator = nested_fps_num, fps_denominator = 1 }, 1920, 1080, {
        id = "m",
        kind = "master",
    }):save()

    local seq_id = "e"
    Sequence.create("edit", project_id, { fps_numerator = owner_fps_num, fps_denominator = 1 }, 1920, 1080, {
        id = seq_id,
        kind = "sequence",
        audio_sample_rate = 48000,
    }):save()

    Track.create_video("V1", "m", { id = "m-v1", index = 1 }):save()
    Track.create_video("V2", "m", { id = "m-v2", index = 2 }):save()
    -- Two master AUDIO tracks so overrides can target distinct UUIDs.
    Track.create_audio("A1", "m", { id = "m-a1", index = 1 }):save()
    Track.create_audio("A2", "m", { id = "m-a2", index = 2 }):save()
    Track.create_video("V1", seq_id, { id = "e-v1", index = 1 }):save()

    db:exec("UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'")

    local media_id = "med-v"
    Media.create({
        id = media_id,
        project_id = project_id,
        name = "v.mov",
        file_path = "/tmp/v.mov",
        duration_frames = 2000,
        fps_numerator = 24,
        fps_denominator = 1,
        audio_channels = 0,
        metadata = '{"start_tc_value":0,"start_tc_rate":24}'
    }):save()

    -- Ensure a media ref exists on the master track
    db:exec([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', 0, 2000, 0, 2000, 48000,
            1, 1.0, 0, 0, 0);
    ]])

    command_manager.init(seq_id, project_id)

    return db
end

local function seed_clip(clip_id, policy, master_layer_track_id,
                        sequence_start, duration, source_in, source_out)
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
    local cid = Clip.create({
        id = clip_id,
        project_id = "p1",
        owner_sequence_id = "e",
        track_id = "e-v1",
        sequence_id = "m",
        name = clip_id,
        sequence_start_frame = sequence_start,
        duration_frames = duration,
        source_in_frame = source_in,
        source_out_frame = source_out,
        source_in_subframe = sub_in,
        source_out_subframe = sub_out,
        master_layer_track_id = master_layer_track_id,
        fps_mismatch_policy = policy,
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
    assert(cid == clip_id, "seed_clip failed")
end

-- Insert an override keyed by master_track_id (Phase 4a).
local function seed_override(db, clip_id, master_track_id, enabled, gain_db)
    assert(db:exec(string.format([[
        INSERT INTO clip_channel_override (clip_id, master_track_id, enabled, gain_db)
        VALUES ('%s', '%s', %d, %f)
    ]], clip_id, master_track_id, enabled and 1 or 0, gain_db)))
end

local function load_clip(id)
    local c = Clip.load_optional(id)
    assert(c, "load_clip: not found: " .. id)
    return {
        sequence_start        = c.sequence_start,
        duration              = c.duration,
        source_in             = c.source_in,
        source_out            = c.source_out,
        master_layer_track_id = c.master_layer_track_id,
        fps_mismatch_policy   = c.fps_mismatch_policy,
        track_id              = c.track_id,
        owner_sequence_id     = c.owner_sequence_id,
        source_sequence_id    = c.sequence_id,
    }
end

local function load_overrides(db, clip_id)
    local stmt = db:prepare([[
        SELECT master_track_id, enabled, gain_db
        FROM clip_channel_override WHERE clip_id = ?
        ORDER BY master_track_id ASC
    ]])
    stmt:bind_value(1, clip_id)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            master_track_id = stmt:value(0),
            enabled         = stmt:value(1) == 1,
            gain_db         = stmt:value(2),
        }
    end
    stmt:finalize()
    return rows
end

local SplitClip = require("core.commands.split_clip")
assert(type(SplitClip.execute) == "function",
    "T045 not landed: core.commands.split_clip must export .execute")

local function execute_cmd(module, params)
    command_manager.begin_command_event("script")
    local ok, result_or_err = pcall(module.execute, params)
    command_manager.end_command_event()
    if not ok then return false, result_or_err end
    return result_or_err == nil or (type(result_or_err) == "table" and result_or_err.success ~= false), result_or_err
end

-- -------------------------------------------------------------------------
-- CT-C7 core: master_layer_track_id and channel overrides copy to both halves.
-- Clip [100,200) source [0,100), master_layer_track_id='m-v2', policy=passthrough.
-- Split at owner frame 150: left [100,150) source [0,50), right [150,200)
-- source [50,100). Both halves keep master_layer_track_id='m-v2' and both
-- channel override rows (keyed to m-a1 and m-a2).
-- -------------------------------------------------------------------------
print("-- CT-C7 Split preserves master_layer_track_id + channel overrides --")
do
    local db = build_fixture(24, 24)
    seed_clip("c", "passthrough", "m-v2", 100, 100, 0, 100)
    seed_override(db, "c", "m-a1", true,  -3.0)
    seed_override(db, "c", "m-a2", false,  0.0)

    local success, result = execute_cmd(SplitClip, {
        sequence_id = "e", clip_id = "c", split_frame = 150,
    })
    assert(success, "SplitClip failed")
    assert(type(result) == "table" and result.second_clip_id,
        "SplitClip must return second_clip_id")
    local second_id = result.second_clip_id

    local left  = load_clip("c")
    local right = load_clip(second_id)

    -- Arithmetic.
    assert(left.sequence_start == 100 and left.duration == 50
           and left.source_in == 0 and left.source_out == 50, string.format(
        "left expected [tl=100,d=50,s=(0,50)]; got [tl=%d,d=%d,s=(%d,%d)]",
        left.sequence_start, left.duration, left.source_in, left.source_out))
    assert(right.sequence_start == 150 and right.duration == 50
           and right.source_in == 50 and right.source_out == 100, string.format(
        "right expected [tl=150,d=50,s=(50,100)]; got [tl=%d,d=%d,s=(%d,%d)]",
        right.sequence_start, right.duration, right.source_in, right.source_out))

    -- Structural preservation on both halves.
    assert(left.master_layer_track_id  == "m-v2", "left master_layer_track_id lost")
    assert(right.master_layer_track_id == "m-v2", "right master_layer_track_id lost")
    assert(left.fps_mismatch_policy  == "passthrough", "left policy lost")
    assert(right.fps_mismatch_policy == "passthrough", "right policy lost")
    assert(left.track_id == right.track_id and left.track_id == "e-v1",
        "both halves on the same owner track")
    assert(left.owner_sequence_id  == "e" and right.owner_sequence_id  == "e")
    assert(left.source_sequence_id == "m" and right.source_sequence_id == "m")

    -- Channel overrides — same rows on both halves, keyed by master_track_id.
    local left_ovs  = load_overrides(db, "c")
    local right_ovs = load_overrides(db, second_id)
    assert(#left_ovs  == 2, string.format("left should have 2 overrides; got %d", #left_ovs))
    assert(#right_ovs == 2, string.format("right should have 2 overrides; got %d", #right_ovs))
    for i = 1, 2 do
        assert(left_ovs[i].master_track_id == right_ovs[i].master_track_id
               and left_ovs[i].enabled == right_ovs[i].enabled
               and left_ovs[i].gain_db == right_ovs[i].gain_db,
            string.format("override[%d] mismatch between halves", i))
    end
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Resample policy: owner frames → nested frames via owner_delta_to_source.
-- owner=24fps, nested=25fps, split_offset=24 owner → 25 nested.
-- -------------------------------------------------------------------------
print("-- Split under resample scales source_offset by fps ratio --")
do
    local _ = build_fixture(24, 25)
    -- Clip: 96 owner frames playing 100 nested frames (25fps in 24fps owner).
    seed_clip("c", "resample", nil, 0, 96, 0, 100)
    local success, result = execute_cmd(SplitClip, {
        sequence_id = "e", clip_id = "c", split_frame = 24,
    })
    assert(success, "SplitClip failed")
    local left  = load_clip("c")
    local right = load_clip(result.second_clip_id)

    assert(left.sequence_start == 0 and left.duration == 24
           and left.source_in == 0 and left.source_out == 25, string.format(
        "left expected [tl=0,d=24,s=(0,25)]; got [tl=%d,d=%d,s=(%d,%d)]",
        left.sequence_start, left.duration, left.source_in, left.source_out))
    assert(right.sequence_start == 24 and right.duration == 72
           and right.source_in == 25 and right.source_out == 100, string.format(
        "right expected [tl=24,d=72,s=(25,100)]; got [tl=%d,d=%d,s=(%d,%d)]",
        right.sequence_start, right.duration, right.source_in, right.source_out))
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Error: split_frame outside the clip's bounds.
-- -------------------------------------------------------------------------
print("-- Split outside clip bounds refuses --")
do
    local _ = build_fixture(24, 24)
    seed_clip("c", "passthrough", nil, 100, 100, 0, 100)
    for _, bad in ipairs({ 100, 200, 50, 250 }) do
        local ok, _ = execute_cmd(SplitClip, {
            sequence_id = "e", clip_id = "c", split_frame = bad,
        })
        assert(not ok, string.format(
            "split_frame=%d is outside clip [100,200), must refuse", bad))
    end
    -- DB unchanged.
    local c = load_clip("c")
    assert(c.sequence_start == 100 and c.duration == 100
           and c.source_in == 0 and c.source_out == 100,
        "DB unchanged after refused split")
    print("  ok")
end

print("✅ test_013_split_preserves_overrides.lua passed")
