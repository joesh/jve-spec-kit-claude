-- T036a (013): CT-C7b Blade — razor at playhead across linked tracks.
--
-- Blade is the cross-track razor. Given a sequence_id, a blade frame, and
-- a set of tracks "armed" for the cut, Blade splits every clip that
-- straddles the blade frame on those tracks. Each split is a SplitClip
-- mutation (T045).
--
-- Distinct from a single-clip Split: Blade preserves link groups across
-- the cut. If V+A clips were linked (one link_group_id), then after Blade:
--   - the LEFT halves remain in the original link group
--   - the RIGHT halves form a NEW link group together
-- so an A+V pair on the timeline becomes two A+V pairs after the cut.
--
-- Black-box DB-state assertions.

require("test_env")
local database = require("core.database")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Media = require("models.media")
local Clip = require("models.clip")

local DB_PATH = "/tmp/jve/test_013_blade_across_linked_tracks.db"

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
        duration_frames = 1000,
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
          ('mr-v', 'p1', 'm', 'm-v1', 'med', 0, 1000, 0, 1000, 48000, 1, 1.0, 0, 0, 0),
          ('mr-a', 'p1', 'm', 'm-a1', 'med', 0, 1000, 0, 1000, 48000, 1, 1.0, 0, 0, 0);
    ]])

    return db
end

local function seed_clip(db, clip_id, track_id, sequence_start, duration,
                        source_in, source_out)
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

local function link_clips(db, group_id, clips)
    for _, c in ipairs(clips) do
        assert(db:exec(string.format([[
            INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
            VALUES ('%s', '%s', '%s', 0, 1)
        ]], group_id, c.id, c.role)))
    end
end

local function load_clip(db, id)
    local c = Clip.load_optional(id)
    assert(c, "load_clip: not found: " .. id)
    return {
        sequence_start = c.sequence_start,
        duration       = c.duration,
        source_in      = c.source_in,
        source_out     = c.source_out,
        track_id       = c.track_id,
    }
end

local function group_id_for(db, clip_id)
    local stmt = db:prepare(
        "SELECT link_group_id FROM clip_links WHERE clip_id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec())
    local id
    if stmt:next() then id = stmt:value(0) end
    stmt:finalize()
    return id
end

local function members_of(db, link_group_id)
    local stmt = db:prepare(
        "SELECT clip_id FROM clip_links WHERE link_group_id = ? ORDER BY clip_id")
    stmt:bind_value(1, link_group_id)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do rows[#rows + 1] = stmt:value(0) end
    stmt:finalize()
    return rows
end

local Blade = require("core.commands.blade")
assert(type(Blade.execute) == "function",
    "T045a not landed: core.commands.blade must export .execute")

local function execute_cmd(module, params)
    local command_manager = require("core.command_manager")
    command_manager.begin_command_event("script")
    local ok, result_or_err = pcall(module.execute, params)
    command_manager.end_command_event()
    if not ok then return false, result_or_err end
    return result_or_err == nil or (type(result_or_err) == "table" and result_or_err.success ~= false), result_or_err
end

-- -------------------------------------------------------------------------
-- CT-C7b: blade across an A+V linked pair at frame 60.
-- Before: V@e-v1=[0,100), A@e-a1=[0,100), both in link_group G1.
-- After:  V_left[0,60), V_right[60,100); A_left[0,60), A_right[60,100).
--   - V_left + A_left remain in original group G1.
--   - V_right + A_right are in a NEW group G2 (G2 != G1).
-- -------------------------------------------------------------------------
print("-- CT-C7b Blade across A+V linked pair --")
do
    local db = build_fixture()
    seed_clip(db, "v",  "e-v1", 0, 100, 0, 100)
    seed_clip(db, "a",  "e-a1", 0, 100, 0, 100)
    link_clips(db, "G1", {
        { id = "v", role = "video" },
        { id = "a", role = "audio" },
    })
    local g1_before = group_id_for(db, "v")
    assert(g1_before == "G1")

    local command_manager = require("core.command_manager")
    command_manager.init("e", "p1")
    
    local success, result = execute_cmd(Blade, {
        sequence_id = "e",
        blade_frame = 60,
        track_ids   = { "e-v1", "e-a1" },
    })
    
    assert(success, "Blade failed")
    
    assert(type(result) == "table" and type(result.splits) == "table",
        "Blade must return splits table")
    assert(#result.splits == 2,
        string.format("expected 2 splits (V, A); got %d", #result.splits))

    -- Left halves keep their ids ("v", "a") and original group G1.
    local v_left  = load_clip(db, "v")
    local a_left  = load_clip(db, "a")
    assert(v_left.sequence_start == 0 and v_left.duration == 60,
        "V left half wrong window")
    assert(a_left.sequence_start == 0 and a_left.duration == 60,
        "A left half wrong window")
    assert(group_id_for(db, "v") == "G1", "V left lost original group")
    assert(group_id_for(db, "a") == "G1", "A left lost original group")

    -- Right halves: find them in result.splits.
    local v_right_id, a_right_id
    for _, s in ipairs(result.splits) do
        if s.clip_id == "v" then v_right_id = s.second_clip_id end
        if s.clip_id == "a" then a_right_id = s.second_clip_id end
    end
    assert(v_right_id and a_right_id, "Blade result missing second clip ids")

    local v_right = load_clip(db, v_right_id)
    local a_right = load_clip(db, a_right_id)
    assert(v_right.sequence_start == 60 and v_right.duration == 40,
        "V right half wrong window")
    assert(a_right.sequence_start == 60 and a_right.duration == 40,
        "A right half wrong window")

    local g_v_right = group_id_for(db, v_right_id)
    local g_a_right = group_id_for(db, a_right_id)
    assert(g_v_right and g_a_right,
        "Both right halves must be in a link group")
    assert(g_v_right == g_a_right,
        "V_right and A_right must share the SAME new group")
    assert(g_v_right ~= "G1",
        "Right halves must be in a NEW group, not the original G1")

    -- Original G1 must contain only v + a (the left halves), not the right halves.
    local g1_members = members_of(db, "G1")
    table.sort(g1_members)
    assert(#g1_members == 2 and g1_members[1] == "a" and g1_members[2] == "v",
        "G1 must hold exactly the left halves after Blade")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Blade with one armed track only: only that track's clip is split, even
-- when other tracks have clips that span the blade frame.
-- -------------------------------------------------------------------------
print("-- Blade only splits clips on armed tracks --")
do
    local db = build_fixture()
    seed_clip(db, "v",  "e-v1", 0, 100, 0, 100)
    seed_clip(db, "a",  "e-a1", 0, 100, 0, 100)

    local command_manager = require("core.command_manager")
    command_manager.init("e", "p1")
    
    local success, result = execute_cmd(Blade, {
        sequence_id = "e",
        blade_frame = 50,
        track_ids   = { "e-v1" },  -- only V armed
    })
    assert(success, "Blade failed")
    
    assert(#result.splits == 1, string.format(
        "expected 1 split (only V armed); got %d", #result.splits))
    assert(result.splits[1].clip_id == "v",
        "the split must be on the V clip")

    -- A still intact: [0, 100), undivided.
    local a = load_clip(db, "a")
    assert(a.sequence_start == 0 and a.duration == 100,
        "A unchanged when its track wasn't armed")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Blade where the playhead doesn't intersect any clip on armed tracks:
-- no-op, no error, empty splits list.
-- -------------------------------------------------------------------------
print("-- Blade where blade_frame intersects nothing --")
do
    local db = build_fixture()
    seed_clip(db, "v",  "e-v1", 0, 50, 0, 50)
    -- blade at 200 — past the end of v.
    
    local command_manager = require("core.command_manager")
    command_manager.init("e", "p1")
    
    local success, result = execute_cmd(Blade, {
        sequence_id = "e",
        blade_frame = 200,
        track_ids   = { "e-v1", "e-a1" },
    })
    assert(success, "Blade failed")
    
    assert(#result.splits == 0,
        "no splits when blade misses every armed clip")
    local v = load_clip(db, "v")
    assert(v.sequence_start == 0 and v.duration == 50, "V untouched")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Blade exactly on a clip boundary (clip ends at 100, blade at 100):
-- a split AT a boundary is meaningless — no row should split. Mirrors
-- SplitClip's strict-inside refusal.
-- -------------------------------------------------------------------------
print("-- Blade exactly on clip boundary does not split --")
do
    local db = build_fixture()
    seed_clip(db, "v",  "e-v1", 0, 100, 0, 100)
    seed_clip(db, "v2", "e-v1", 100, 100, 100, 200)
    
    local command_manager = require("core.command_manager")
    command_manager.init("e", "p1")
    
    local success, result = execute_cmd(Blade, {
        sequence_id = "e",
        blade_frame = 100,
        track_ids   = { "e-v1" },
    })
    assert(success, "Blade failed")
    
    assert(#result.splits == 0,
        "blade at exact boundary must not split either neighbor")
    local v  = load_clip(db, "v")
    local v2 = load_clip(db, "v2")
    assert(v.duration == 100 and v2.duration == 100,
        "neither neighbor changed")
    print("  ok")
end

print("✅ test_013_blade_across_linked_tracks.lua passed")
