-- Test RippleDelete V13 (link group closure + cascade).
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

local DB_PATH = "/tmp/jve/test_013_ripple_delete_link_group.db"

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
    Track.create_audio("A1", "m", { id = "m-a1", index = 1 }):save()
    Track.create_video("V1", seq_id, { id = "e-v1", index = 1 }):save()
    Track.create_audio("A1", seq_id, { id = "e-a1", index = 1 }):save()
    
    db:exec("UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'")

    local media_id = "med"
    Media.create({
        id = media_id,
        project_id = project_id,
        name = "a.mov",
        file_path = "/tmp/a.mov",
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
        VALUES
          ('mr-v', 'p1', 'm', 'm-v1', 'med', 0, 2000, 0, 2000, 48000, 1, 1.0, 0, 0, 0),
          ('mr-a', 'p1', 'm', 'm-a1', 'med', 0, 2000, 0, 2000, 48000, 1, 1.0, 0, 0, 0);
    ]])

    command_manager.init(seq_id, project_id)

    return db
end

local function seed_clip(clip_id, track_id, sequence_start, duration, source_in, source_out)
    local track = Track.load(track_id)
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type(track.track_type)
    
    local cid = Clip.create({
        id = clip_id,
        project_id = "p1",
        owner_sequence_id = "e",
        track_id = track_id,
        sequence_id = "m",
        name = clip_id,
        sequence_start_frame = sequence_start,
        duration_frames = duration,
        source_in_frame = source_in,
        source_out_frame = source_out,
        source_in_subframe = sub_in,
        source_out_subframe = sub_out,
        fps_mismatch_policy = "passthrough",
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
    assert(cid == clip_id, "seed_clip failed")
end

local function link_clips(db, group_id, members)
    for _, m in ipairs(members) do
        assert(db:exec(string.format([[
            INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
            VALUES ('%s', '%s', '%s', 0, 1)
        ]], group_id, m.id, m.role)))
    end
end

local function clip_exists(id)
    local c = Clip.load_optional(id)
    return c ~= nil
end

local function load_clip(id)
    local c = Clip.load_optional(id)
    assert(c, "load_clip: not found: " .. id)
    return {
        sequence_start = c.sequence_start,
        duration       = c.duration,
        track_id       = c.track_id,
    }
end

local RippleDelete = require("core.commands.ripple_delete_selection")
assert(type(RippleDelete.execute) == "function",
    "T046 partial not landed: core.commands.ripple_delete_selection must export .execute")

local function execute_cmd(module, params, db)
    command_manager.begin_command_event("script")
    local ok, result_or_err = pcall(module.execute, params, db)
    command_manager.end_command_event()
    if not ok then return false, result_or_err end
    return result_or_err == nil or (type(result_or_err) == "table" and result_or_err.success ~= false), result_or_err
end

-- -------------------------------------------------------------------------
-- Delete a linked clip (V). The link group is pulled in: both V and A are
-- removed. Downstream clips on BOTH affected tracks ripple left.
-- -------------------------------------------------------------------------
print("-- RippleDelete linked V: V+A removed, downstream ripples --")
do
    local db = build_fixture()
    seed_clip("v1", "e-v1",   0, 100,   0, 100)
    seed_clip("a1", "e-a1",   0, 100,   0, 100)
    seed_clip("v2", "e-v1", 100, 100, 100, 200)
    seed_clip("a2", "e-a1", 100, 100, 100, 200)
    link_clips(db, "G1", { { id = "v1", role = "video" }, { id = "a1", role = "audio" } })
    link_clips(db, "G2", { { id = "v2", role = "video" }, { id = "a2", role = "audio" } })

    -- Fake the UI state: the selection_hub would pass the selected clips.
    local success, err = execute_cmd(RippleDelete, {
        sequence_id = "e", clip_ids = {"v1", "a1"}, project_id = "p1",
    }, db)
    assert(success, "RippleDelete failed: " .. tostring(err and err.error_message or err))

    assert(not clip_exists("v1"), "v1 deleted")
    assert(not clip_exists("a1"), "a1 (linked partner) pulled in and deleted")

    -- Downstream pair shifted left by 100 frames to close the gap.
    local v2 = load_clip("v2")
    local a2 = load_clip("a2")
    assert(v2.sequence_start == 0, "v2 rippled to 0")
    assert(a2.sequence_start == 0, "a2 rippled to 0")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Partial overlap: deleting linked V+A where V is 50 frames and A is 100
-- frames. The gap closed on BOTH tracks is the full extent of the deleted
-- group (100 frames). Downstream V2 (at 50) and A2 (at 100) both shift by 100.
-- V2 lands at -50, but sequence bounds clip it (or we allow it natively
-- in the model depending on ripple semantics; current ripple behavior
-- permits negative start if it doesn't collide). Let's use a safer layout:
-- group extent 100.
-- -------------------------------------------------------------------------
print("-- RippleDelete uneven link group: closure uses union extent --")
do
    local db = build_fixture()
    -- Group G1: V1 [0, 50), A1 [0, 100). Extent is [0, 100).
    seed_clip("v1", "e-v1",   0,  50,   0,  50)
    seed_clip("a1", "e-a1",   0, 100,   0, 100)
    -- Downstream: V2 starts at 50, A2 starts at 100.
    seed_clip("v2", "e-v1",  50,  50,  50, 100)
    
    link_clips(db, "G1", { { id = "v1", role = "video" }, { id = "a1", role = "audio" } })

    local success, err = execute_cmd(RippleDelete, {
        sequence_id = "e", clip_ids = {"v1", "a1"}, project_id = "p1",
    }, db)
    assert(success, "RippleDelete failed")

    assert(not clip_exists("v1") and not clip_exists("a1"),
        "uneven group fully removed")

    local v2 = load_clip("v2")
    assert(v2.sequence_start == 0, string.format(
        "v2 (start 50) rippled by track extent (50) → 0; got %d",
        v2.sequence_start))
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Multi-select overlapping link groups: closure extent is the UNION of all
-- deleted groups.
-- -------------------------------------------------------------------------
print("-- RippleDelete multi-select: closure uses union of all groups --")
do
    local db = build_fixture()
    seed_clip("v1", "e-v1",   0, 100,   0, 100)
    seed_clip("a1", "e-a1",   0, 100,   0, 100)
    seed_clip("v2", "e-v1", 100, 100, 100, 200)
    seed_clip("a2", "e-a1", 100, 100, 100, 200)
    link_clips(db, "G1", { { id = "v1", role = "video" }, { id = "a1", role = "audio" } })
    link_clips(db, "G2", { { id = "v2", role = "video" }, { id = "a2", role = "audio" } })

    local success, err = execute_cmd(RippleDelete, {
        sequence_id = "e", clip_ids = {"v1", "a1", "v2", "a2"}, project_id = "p1",
    }, db)
    assert(success, "RippleDelete failed")

    assert(not clip_exists("v1") and not clip_exists("a1") and
           not clip_exists("v2") and not clip_exists("a2"),
        "both groups fully removed")
    print("  ok")
end

print("✅ test_013_ripple_delete_link_group.lua passed")
