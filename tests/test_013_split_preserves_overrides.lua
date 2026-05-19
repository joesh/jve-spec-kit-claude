-- T036 (013): CT-C7 SplitClip preserves per-clip overrides on both halves.
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
-- original must land on BOTH halves.
--
-- Black-box DB-state assertions.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_013_split_preserves_overrides.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function build_fixture(owner_fps_num, nested_fps_num)
    local db = fresh_db()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'm', 'master', %d, 1, NULL, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', %d, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('m-v2', 'm', 'V2', 'VIDEO', 2),
               ('e-v1', 'e', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-v', 'p1', 'v.mov', '/tmp/v.mov', 2000, %d, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', 0, 2000, 0, 2000, 48000,
            1, 1.0, 0, 0, 0);
    ]], nested_fps_num, owner_fps_num, nested_fps_num)))
    return db
end

local function seed_clip(db, clip_id, policy, master_layer_track_id,
                        sequence_start, duration, source_in, source_out)
    local master_val = master_layer_track_id and ("'" .. master_layer_track_id .. "'") or "NULL"
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('%s', 'p1', 'e', 'e-v1', 'm', '%s',
            %d, %d, %d, %d,
            %s, '%s',
            1, 1.0, 0, 0, 0)
    ]], clip_id, clip_id, sequence_start, duration, source_in, source_out,
       master_val, policy)))
end

local function seed_override(db, clip_id, channel_index, enabled, gain_db)
    assert(db:exec(string.format([[
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('%s', %d, %d, %f)
    ]], clip_id, channel_index, enabled and 1 or 0, gain_db)))
end

local function load_clip(db, id)
    local stmt = db:prepare([[
        SELECT sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               master_layer_track_id, fps_mismatch_policy, track_id,
               owner_sequence_id, sequence_id
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "load_clip: not found: " .. id)
    local r = {
        sequence_start        = stmt:value(0),
        duration              = stmt:value(1),
        source_in             = stmt:value(2),
        source_out            = stmt:value(3),
        master_layer_track_id = stmt:value(4),
        fps_mismatch_policy   = stmt:value(5),
        track_id              = stmt:value(6),
        owner_sequence_id     = stmt:value(7),
        source_sequence_id    = stmt:value(8),
    }
    stmt:finalize()
    return r
end

local function load_overrides(db, clip_id)
    local stmt = db:prepare([[
        SELECT channel_index, enabled, gain_db
        FROM clip_channel_override WHERE clip_id = ?
        ORDER BY channel_index ASC
    ]])
    stmt:bind_value(1, clip_id)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            channel_index = stmt:value(0),
            enabled       = stmt:value(1) == 1,
            gain_db       = stmt:value(2),
        }
    end
    stmt:finalize()
    return rows
end

local SplitClip = require("core.commands.split_clip")
assert(type(SplitClip.execute) == "function",
    "T045 not landed: core.commands.split_clip must export .execute")

-- -------------------------------------------------------------------------
-- CT-C7 core: master_layer_track_id and channel overrides copy to both halves.
-- Clip [100,200) source [0,100), master_layer_track_id='m-v2', policy=passthrough.
-- Split at owner frame 150: left [100,150) source [0,50), right [150,200)
-- source [50,100). Both halves keep master_layer_track_id='m-v2' and both
-- channel override rows.
-- -------------------------------------------------------------------------
print("-- CT-C7 Split preserves master_layer_track_id + channel overrides --")
do
    local db = build_fixture(24, 24)
    seed_clip(db, "c", "passthrough", "m-v2", 100, 100, 0, 100)
    seed_override(db, "c", 0, true,  -3.0)
    seed_override(db, "c", 1, false,  0.0)

    local result = SplitClip.execute({
        sequence_id = "e", clip_id = "c", split_frame = 150,
    })
    assert(type(result) == "table" and result.second_clip_id,
        "SplitClip must return second_clip_id")
    local second_id = result.second_clip_id

    local left  = load_clip(db, "c")
    local right = load_clip(db, second_id)

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

    -- Channel overrides — same rows on both halves.
    local left_ovs  = load_overrides(db, "c")
    local right_ovs = load_overrides(db, second_id)
    assert(#left_ovs  == 2, string.format("left should have 2 overrides; got %d", #left_ovs))
    assert(#right_ovs == 2, string.format("right should have 2 overrides; got %d", #right_ovs))
    for i = 1, 2 do
        assert(left_ovs[i].channel_index == right_ovs[i].channel_index
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
    local db = build_fixture(24, 25)
    -- Clip: 96 owner frames playing 100 nested frames (25fps in 24fps owner).
    seed_clip(db, "c", "resample", nil, 0, 96, 0, 100)
    local result = SplitClip.execute({
        sequence_id = "e", clip_id = "c", split_frame = 24,
    })
    local left  = load_clip(db, "c")
    local right = load_clip(db, result.second_clip_id)

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
    local db = build_fixture(24, 24)
    seed_clip(db, "c", "passthrough", nil, 100, 100, 0, 100)
    for _, bad in ipairs({ 100, 200, 50, 250 }) do
        local ok = pcall(SplitClip.execute, {
            sequence_id = "e", clip_id = "c", split_frame = bad,
        })
        assert(not ok, string.format(
            "split_frame=%d is outside clip [100,200), must refuse", bad))
    end
    -- DB unchanged.
    local c = load_clip(db, "c")
    assert(c.sequence_start == 100 and c.duration == 100
           and c.source_in == 0 and c.source_out == 100,
        "DB unchanged after refused split")
    print("  ok")
end

print("✅ test_013_split_preserves_overrides.lua passed")
