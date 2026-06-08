-- T037 (013): CT-C8 Duplicate copies per-clip overrides.
--
-- Duplicate creates a new clips row with the same shape, shifted by
-- delta_frames on the same or a different track. Per commands.md §Duplicate:
--   - master_layer_track_id, fps_mismatch_policy, source_in/out, duration,
--     enabled, volume, etc. are copied verbatim
--   - all clip_channel_override rows are cloned to the new clip_id
--   - sequence_start_frame = original.sequence_start_frame + delta_frames
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

local DB_PATH = "/tmp/jve/test_013_duplicate_copies_overrides.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    local db = database.get_connection()
    db:exec(require("import_schema"))
    return db
end

local function build_fixture()
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

    Sequence.create("m", project_id, { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080, {
        id = "m",
        kind = "master",
    }):save()

    local seq_id = "e"
    Sequence.create("edit", project_id, { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080, {
        id = seq_id,
        kind = "sequence",
        audio_sample_rate = 48000,
    }):save()

    Track.create_video("V1", "m", { id = "m-v1", index = 1 }):save()
    Track.create_video("V2", "m", { id = "m-v2", index = 2 }):save()
    Track.create_video("V1", seq_id, { id = "e-v1", index = 1 }):save()
    Track.create_video("V2", seq_id, { id = "e-v2", index = 2 }):save()
    
    db:exec("UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'")

    local media_id = "med"
    Media.create({
        id = media_id,
        project_id = project_id,
        name = "a.mov",
        file_path = "/tmp/a.mov",
        duration_frames = 1000,
        fps_numerator = 24,
        fps_denominator = 1,
        audio_channels = 0,
        metadata = '{"start_tc_value":0,"start_tc_rate":24}'
    }):save()

    db:exec([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 1000, 0, 1000, 48000, 1, 1.0, 0, 0, 0);
    ]])

    command_manager.init(seq_id, project_id)

    return db
end

local function seed_clip(db, clip_id, master_layer)
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
    local cid = Clip.create({
        id = clip_id,
        project_id = "p1",
        owner_sequence_id = "e",
        track_id = "e-v1",
        sequence_id = "m",
        name = clip_id,
        sequence_start_frame = 100,
        duration_frames = 50,
        source_in_frame = 200,
        source_out_frame = 250,
        source_in_subframe = sub_in,
        source_out_subframe = sub_out,
        master_layer_track_id = master_layer,
        fps_mismatch_policy = "resample",
        enabled = true,
        volume = 0.75,
        playhead_frame = 0,
    })
    assert(cid == clip_id, "seed_clip failed")
end

local function seed_override(db, clip_id, channel, enabled, gain_db)
    assert(db:exec(string.format([[
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('%s', %d, %d, %f)
    ]], clip_id, channel, enabled and 1 or 0, gain_db)))
end

local function load_clip(db, id)
    local c = Clip.load_optional(id)
    assert(c, "clip not found: " .. id)
    return {
        sequence_start = c.sequence_start,
        duration       = c.duration,
        source_in      = c.source_in,
        source_out     = c.source_out,
        master_layer   = c.master_layer_track_id,
        policy         = c.fps_mismatch_policy,
        enabled        = c.enabled,
        volume         = c.volume,
        track_id       = c.track_id,
        owner_seq_id   = c.owner_sequence_id,
        nested_seq_id  = c.sequence_id,
    }
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

local Duplicate = require("core.commands.duplicate")
assert(type(Duplicate.execute) == "function",
    "T047 not landed: core.commands.duplicate must export .execute")

local function execute_cmd(module, params)
    command_manager.begin_command_event("script")
    local ok, result_or_err = pcall(module.execute, params)
    command_manager.end_command_event()
    if not ok then return false, result_or_err end
    return result_or_err == nil or (type(result_or_err) == "table" and result_or_err.success ~= false), result_or_err
end

-- -------------------------------------------------------------------------
-- CT-C8: duplicate of a clip with 3 overrides yields a new clip with 3
-- matching override rows AND copies master_layer_track_id + policy.
-- Original sits at [100,150) on e-v1. Duplicate to e-v2 with delta=200.
-- -------------------------------------------------------------------------
print("-- CT-C8 Duplicate copies master_layer_track_id + policy + overrides --")
do
    local db = build_fixture()
    seed_clip(db, "c", "m-v2")
    seed_override(db, "c", 0, true,  -3.0)
    seed_override(db, "c", 1, false,  0.0)
    seed_override(db, "c", 2, true,  -6.0)

    local success, result = execute_cmd(Duplicate, {
        sequence_id     = "e",
        clip_id         = "c",
        target_track_id = "e-v2",
        delta_frames    = 200,
    })
    assert(success, "Duplicate failed")
    assert(type(result) == "table" and result.new_clip_id,
        "Duplicate must return new_clip_id")
    local new_id = result.new_clip_id
    assert(new_id ~= "c", "duplicate must produce a fresh id")

    local orig = load_clip(db, "c")
    local new  = load_clip(db, new_id)

    -- Original untouched.
    assert(orig.sequence_start == 100 and orig.duration == 50
           and orig.source_in == 200 and orig.source_out == 250,
        "original clip must not be modified by Duplicate")
    assert(orig.master_layer == "m-v2" and orig.policy == "resample",
        "original structural fields must not be modified")

    -- New clip: shifted by +200 on the target track.
    assert(new.sequence_start == 300 and new.duration == 50,
        string.format("expected duplicate at [300,350); got [%d,%d)",
            new.sequence_start, new.sequence_start + new.duration))
    assert(new.track_id == "e-v2", "duplicate must land on target_track_id")
    assert(new.owner_seq_id == "e" and new.nested_seq_id == "m",
        "duplicate must preserve owner+nested sequences")

    -- Source window copied verbatim.
    assert(new.source_in == 200 and new.source_out == 250,
        "source window must be copied verbatim")

    -- Structural overrides preserved.
    assert(new.master_layer == "m-v2", "master_layer_track_id must copy")
    assert(new.policy == "resample",   "fps_mismatch_policy must copy")
    assert(new.enabled == true and math.abs(new.volume - 0.75) < 1e-9,
        "enabled/volume must copy")

    -- Channel override rows.
    local orig_ovs = load_overrides(db, "c")
    local new_ovs  = load_overrides(db, new_id)
    assert(#orig_ovs == 3 and #new_ovs == 3, string.format(
        "both clips must have 3 overrides; orig=%d new=%d",
        #orig_ovs, #new_ovs))
    for i = 1, 3 do
        assert(orig_ovs[i].channel_index == new_ovs[i].channel_index
               and orig_ovs[i].enabled == new_ovs[i].enabled
               and orig_ovs[i].gain_db == new_ovs[i].gain_db,
            string.format("override[%d] mismatch between original and duplicate", i))
    end
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Duplicate at delta=0 onto the SAME track must refuse: it would create
-- two clips with the same [sequence_start, duration), tripping the video
-- overlap trigger. Refusal is loud; DB unchanged.
-- -------------------------------------------------------------------------
print("-- Duplicate at delta=0 on same track refuses --")
do
    local db = build_fixture()
    seed_clip(db, "c", nil)
    local success, err = execute_cmd(Duplicate, {
        sequence_id     = "e",
        clip_id         = "c",
        target_track_id = "e-v1",
        delta_frames    = 0,
    })
    assert(not success, "delta=0 onto same track must refuse (overlap)")
    -- DB unchanged: still exactly one clip on e.
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = 'e'")
    stmt:exec(); stmt:next()
    local n = stmt:value(0); stmt:finalize()
    assert(n == 1, string.format("expected 1 clip after refused dup; got %d", n))
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Duplicate with no overrides: still copies structural fields, zero
-- override rows on either side.
-- -------------------------------------------------------------------------
print("-- Duplicate of clip with no overrides --")
do
    local db = build_fixture()
    seed_clip(db, "c", nil)
    local success, result = execute_cmd(Duplicate, {
        sequence_id     = "e",
        clip_id         = "c",
        target_track_id = "e-v1",
        delta_frames    = 100,
    })
    assert(success, "Duplicate failed")
    local new_ovs = load_overrides(db, result.new_clip_id)
    assert(#new_ovs == 0, "no overrides on either side")
    local new = load_clip(db, result.new_clip_id)
    assert(new.sequence_start == 200 and new.duration == 50,
        "duplicate at +100 lands at [200,250)")
    print("  ok")
end

print("✅ test_013_duplicate_copies_overrides.lua passed")
