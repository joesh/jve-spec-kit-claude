-- T039 (013): Insert cycle refusal.
--
-- The containment DAG must stay acyclic. Insert refuses any
-- placement that would close a cycle — direct (sequence inside itself)
-- or transitive (E1 already contains a clip pointing to E2; inserting E1
-- into E2 would close the loop).
--
-- Refusal is loud (raises a user-visible error) and DB state is
-- unchanged: no clips row written, no clip_links row written.
--
-- Black-box: drives Insert.execute against a DB built via direct SQL
-- and verifies the clips table has zero rows after refusal.

require("test_env")
local database = require("core.database")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Media = require("models.media")
local Clip = require("models.clip")
local command_manager = require("core.command_manager")

local DB_PATH = "/tmp/jve/test_013_insert_cycle_refuse.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    local db = database.get_connection()
    db:exec(require("import_schema"))
    return db
end

local function clips_count(db)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips")
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0); stmt:finalize()
    return n
end

local function link_count(db)
    local stmt = db:prepare("SELECT COUNT(*) FROM clip_links")
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0); stmt:finalize()
    return n
end

local Insert = require("core.commands.insert")
assert(type(Insert.execute) == "function",
    "T040 not landed: core.commands.insert must export .execute")

local function execute_cmd(module, params)
    command_manager.begin_command_event("script")
    local ok, result_or_err = pcall(module.execute, params)
    command_manager.end_command_event()
    if not ok then return false, result_or_err end
    return result_or_err == nil or (type(result_or_err) == "table" and result_or_err.success ~= false), result_or_err
end

-- -------------------------------------------------------------------------
-- Direct cycle: insert sequence E into itself.
-- -------------------------------------------------------------------------
print("-- Insert E into E refuses (direct cycle) --")
do
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
    Sequence.create("e", project_id, { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080, {
        id = seq_id,
        kind = "sequence",
        audio_sample_rate = 48000,
    }):save()

    Track.create_video("V1", seq_id, { id = "e-v1", index = 1 }):save()
    
    command_manager.init(seq_id, project_id)

    local before_clips = clips_count(db)
    local before_links = link_count(db)
    local ok, err = execute_cmd(Insert, {
        sequence_id           = "e",
        source_sequence_id    = "e",     -- same as owner — direct cycle
        sequence_start_frame  = 0,
        target_video_track_id = "e-v1",
    })
    assert(not ok, "direct cycle (E in E) must refuse")
    assert(type(err) == "string" and err:find("cycle"), string.format(
        "refusal must mention 'cycle'; got: %s", tostring(err)))
    assert(clips_count(db) == before_clips,
        "no clips row may be written on a refused cycle")
    assert(link_count(db) == before_links,
        "no clip_links row may be written on a refused cycle")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Transitive cycle: E1 already contains a clip referencing E2 (so E2 is
-- reachable from E1). Inserting E1 into E2 would close the loop.
-- -------------------------------------------------------------------------
print("-- Insert E1 into E2 refuses (transitive cycle) --")
do
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
    
    local media_id = "med"
    Media.create({
        id = media_id,
        project_id = project_id,
        name = "v.mov",
        file_path = "/tmp/v.mov",
        duration_frames = 100,
        fps_numerator = 24,
        fps_denominator = 1,
        audio_channels = 0,
        metadata = '{"start_tc_value":0,"start_tc_rate":24}'
    }):save()
    
    local mc_id = Sequence.ensure_master(media_id, project_id)

    Sequence.create("e1", project_id, { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080, {
        id = "e1",
        kind = "sequence",
        audio_sample_rate = 48000,
    }):save()
    
    Sequence.create("e2", project_id, { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080, {
        id = "e2",
        kind = "sequence",
        audio_sample_rate = 48000,
    }):save()

    Track.create_video("V1", "e1", { id = "e1-v1", index = 1 }):save()
    Track.create_video("V1", "e2", { id = "e2-v1", index = 1 }):save()
    
    -- E2 contains a clip referencing master M (non-zero effective duration).
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
    Clip.create({
        id = "c-e2-uses-m",
        project_id = project_id,
        owner_sequence_id = "e2",
        track_id = "e2-v1",
        sequence_id = mc_id,
        name = "c2",
        sequence_start_frame = 0,
        duration_frames = 50,
        source_in_frame = 0,
        source_out_frame = 50,
        source_in_subframe = sub_in,
        source_out_subframe = sub_out,
        fps_mismatch_policy = "passthrough",
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
    
    -- E1 contains a clip whose sequence_id is E2 — closes the
    -- reachability E1 -> E2.
    Clip.create({
        id = "c-e1-uses-e2",
        project_id = project_id,
        owner_sequence_id = "e1",
        track_id = "e1-v1",
        sequence_id = "e2",
        name = "c1",
        sequence_start_frame = 0,
        duration_frames = 50,
        source_in_frame = 0,
        source_out_frame = 50,
        source_in_subframe = sub_in,
        source_out_subframe = sub_out,
        fps_mismatch_policy = "passthrough",
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
    
    command_manager.init("e2", project_id)

    local before_clips = clips_count(db)
    local before_links = link_count(db)
    local ok, err = execute_cmd(Insert, {
        sequence_id           = "e2",
        source_sequence_id    = "e1",    -- e1 already references e2
        sequence_start_frame  = 0,
        target_video_track_id = "e2-v1",
    })
    assert(not ok, "transitive cycle (E1 into E2 where E1 references E2) must refuse")
    assert(type(err) == "string" and err:find("cycle"), string.format(
        "refusal must mention 'cycle'; got: %s", tostring(err)))
    assert(clips_count(db) == before_clips,
        "no clips row may be written on a refused transitive cycle")
    assert(link_count(db) == before_links,
        "no clip_links row may be written on a refused transitive cycle")
    print("  ok")
end

print("✅ test_013_insert_cycle_refuse.lua passed")