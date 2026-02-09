#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local import_schema = require("import_schema")
local command_manager = require("core.command_manager")
local Command = require("command")
local Media = require("models.media")
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

local db_path = "/tmp/jve/test_duplicate_clips_preserves_structural_fields.db"
cleanup_db_artifacts(db_path)
database.set_path(db_path)
local db = database.get_connection()
db:exec(import_schema)

db:exec([[INSERT INTO projects(id,name,created_at,modified_at,settings) VALUES('proj','Test',0,0,'{}')]])
db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,
        view_start_frame,view_duration_frames,playhead_frame,
        selected_clip_ids,selected_edge_infos,selected_gap_infos,current_sequence_number,created_at,modified_at)
        VALUES('seq','proj','Sequence','timeline',30,1,48000,1920,1080,0,8000,0,'[]','[]','[]',0,0,0)
    ]])
db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES
        ('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0),
        ('v2','seq','V2','VIDEO',2,1,0,0,0,1.0,0.0)
    ]])

command_manager.init("seq", "proj")

local media = Media.create({
    id = "media1",
    project_id = "proj",
    file_path = "/tmp/test.mov",
    name = "Media1",
    duration_frames = 1000,
    fps_numerator = 30,
    fps_denominator = 1,
})
assert(media:save(db))

local master = Clip.create("Master", media.id, {
    id = "master1",
    clip_kind = "master",
    project_id = "proj",
    timeline_start = 0,
    duration = 1000,
    source_in = 0,
    source_out = 1000,
    fps_numerator = 30,
    fps_denominator = 1,
})
assert(master:save(db, {skip_occlusion = true}))

local t1 = Clip.create("Timeline", media.id, {
    id = "t1",
    clip_kind = "timeline",
    project_id = "proj",
    track_id = "v1",
    owner_sequence_id = "seq",
    parent_clip_id = master.id,
    timeline_start = 0,
    duration = 100,
    source_in = 5,
    source_out = 105,
    fps_numerator = 30,
    fps_denominator = 1,
    offline = true,
})
assert(t1:save(db))

local dup = Command.create("DuplicateClips", "proj")
dup:set_parameter("project_id", "proj")
dup:set_parameter("sequence_id", "seq")
dup:set_parameter("clip_ids", {"t1"})
dup:set_parameter("delta_frames", 30)
dup:set_parameter("target_track_id", "v2")
dup:set_parameter("anchor_clip_id", "t1")

local result = command_manager.execute(dup)
assert(result.success, result.error_message or "DuplicateClips failed")

local all = database.load_clips("seq")
local duplicated_id = nil
for _, c in ipairs(all) do
    if c.id ~= "t1" and c.clip_kind == "timeline" and c.track_id == "v2" then
        duplicated_id = c.id
        break
    end
end
assert(duplicated_id, "Expected a duplicated clip on v2")

local dup_clip = Clip.load_optional(duplicated_id, db)
assert(dup_clip, "Expected to load duplicated clip")
assert(dup_clip.owner_sequence_id == "seq", "Duplicated clip should preserve owner_sequence_id")
assert(dup_clip.parent_clip_id == master.id, "Duplicated clip should preserve parent_clip_id")
assert(dup_clip.offline == true, "Duplicated clip should preserve offline flag")

cleanup_db_artifacts(db_path)
print("✅ DuplicateClips preserves owner_sequence_id/parent_clip_id/offline via mutation inserts")

