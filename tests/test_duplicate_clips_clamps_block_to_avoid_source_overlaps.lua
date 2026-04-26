#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local import_schema = require("import_schema")
local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")

local function remove_best_effort(path)
    if not path or path == "" then
        return
    end
    os.remove(path)
end

local function cleanup_db_artifacts(db_path)
    remove_best_effort(db_path)
    remove_best_effort(db_path .. "-wal")
    remove_best_effort(db_path .. "-shm")
    os.execute(string.format("rm -rf %q", db_path .. ".events"))
end

local db_path = "/tmp/jve/test_duplicate_clips_clamps_block_to_avoid_source_overlaps.db"
cleanup_db_artifacts(db_path)
database.set_path(db_path)
local db = database.get_connection()
db:exec(import_schema)

db:exec([[INSERT INTO projects(id,name,fps_mismatch_policy, created_at,modified_at,settings) VALUES('proj','Test','resample',0,0,'{}')]])

    -- V13 placeholder master sequence (test references nested_sequence_id='mc_test' literally)
    db:exec(string.format([[INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('mc_test_media', 'proj', 'placeholder', '_placeholder', 10000, 30, 1, 1920, 1080, 0, 'raw', 0, 0)]]))
    db:exec(string.format([[INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('mc_test', 'proj', 'mc_test', 'master', 30, 1, 48000, 1920, 1080, 0, 0)]]))
    db:exec(string.format([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('mc_test_v1', 'mc_test', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0)]]))
    db:exec(string.format([[UPDATE sequences SET default_video_layer_track_id = 'mc_test_v1' WHERE id = 'mc_test']]))
    db:exec(string.format([[INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mc_test_mr', 'proj', 'mc_test', 'mc_test_v1', 'mc_test_media', 0, 10000, 0, 10000, 1, 1.0, 0, 0, 0)]]))
db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,
        view_start_frame,view_duration_frames,playhead_frame,
        selected_clip_ids,selected_edge_infos,selected_gap_infos,current_sequence_number,created_at,modified_at)
        VALUES('seq','proj','Sequence','nested',30,1,48000,1920,1080,0,8000,0,'[]','[]','[]',0,0,0)
    ]])
db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES
        ('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0)
    ]])
db:exec([[INSERT INTO media(id,project_id,name,file_path,duration_frames,fps_numerator,fps_denominator,created_at,modified_at)
          VALUES('media1','proj','Media1','/tmp/test.mov',1000,30,1,0,0)]])

command_manager.init("seq", "proj")

-- Two disjoint clips on the same track with a small gap.
-- c1: [0, 10)   c2: [12, 22)
local c1 = Clip.create({
        name = "C1",
        id = "c1",
        project_id = "proj",
        track_id = "v1",
        owner_sequence_id = "seq",
        nested_sequence_id = "mc_test",
        timeline_start_frame = 0,
        duration_frames = 10,
        source_in_frame = 0,
        source_out_frame = 10,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
c1:save(db)
local c2 = Clip.create({
        name = "C2",
        id = "c2",
        project_id = "proj",
        track_id = "v1",
        owner_sequence_id = "seq",
        nested_sequence_id = "mc_test",
        timeline_start_frame = 12,
        duration_frames = 10,
        source_in_frame = 0,
        source_out_frame = 10,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
c2:save(db)
-- Duplicate both clips with delta=5. The duplicates should land at [5, 15) and [17, 27).
-- This overlaps the source clips — resolve_occlusions should trim them (overwrite behavior).
local dup = Command.create("DuplicateClips", "proj")
dup:set_parameter("project_id", "proj")
dup:set_parameter("sequence_id", "seq")
dup:set_parameter("clip_ids", {"c1", "c2"})
dup:set_parameter("delta_frames", 5)
dup:set_parameter("target_track_id", "v1")
dup:set_parameter("anchor_clip_id", "c1")

local result = command_manager.execute(dup)
assert(result.success, result.error_message or "DuplicateClips failed")

local clips = database.load_clips("seq")
local by_start = {}
for _, clip in ipairs(clips) do
    if clip.track_id == "v1" and clip.clip_kind == "timeline" then
        by_start[clip.timeline_start] = (by_start[clip.timeline_start] or 0) + 1
    end
end

-- Duplicates land at requested positions (5 and 17)
assert(by_start[5], "Duplicate of c1 should land at frame 5 (requested delta)")
assert(by_start[17], "Duplicate of c2 should land at frame 17 (requested delta)")

-- Source c1 was [0,10), duplicate lands at [5,15) → c1 trimmed to [0,5)
assert(by_start[0], "Source c1 should be trimmed to start at 0")

cleanup_db_artifacts(db_path)
print("✅ DuplicateClips overwrites at requested position (no source clamping)")
