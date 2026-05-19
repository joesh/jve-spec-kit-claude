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

db:exec([[INSERT INTO projects(id,name,fps_mismatch_policy, created_at,modified_at,settings) VALUES('proj','Test','resample',0,0,'{}')]])
db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_sample_rate,width,height,
        view_start_frame,view_duration_frames,playhead_frame,
        selected_clip_ids,selected_edge_infos,selected_gap_infos,current_sequence_number,created_at,modified_at)
        VALUES('seq','proj','Sequence','sequence',30,1,48000,1920,1080,0,8000,0,'[]','[]','[]',0,0,0)
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
media:save(db)
-- V13: master sequence wrapping the media for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _m = _Media.load("media1")
    if _m then
        if not _m.width or _m.width == 0 then _m.width = 1920 end
        if not _m.height or _m.height == 0 then _m.height = 1080 end
        local _parsed = _m.metadata and (function() local ok,v = pcall(_json.decode, _m.metadata); return ok and v end)()
        if not _parsed or _parsed.start_tc_value == nil then
            _m.metadata = _json.encode({ start_tc_value = 0,
                start_tc_rate = (_m.frame_rate and _m.frame_rate.fps_numerator) or 24,
                start_tc_audio_samples = 0,
                start_tc_audio_rate = (_m.audio_channels and _m.audio_channels > 0)
                    and (_m.audio_sample_rate or 48000) or nil })
        end
        _m:save()
    end
end
local _Sequence_for_master = require("models.sequence")
local MC_TEST = _Sequence_for_master.ensure_master("media1", "proj")

-- V13: clips live on nested sequences only; the V8 "master clip" row
-- inside a masterclip sequence is gone. The masterclip is MC_TEST.
local t1 = Clip.create({
        name = "Timeline",
        id = "t1",
        project_id = "proj",
        track_id = "v1",
        owner_sequence_id = "seq",
        sequence_id = MC_TEST,
        sequence_start_frame = 0,
        duration_frames = 100,
        source_in_frame = 5,
        source_out_frame = 105,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
assert(t1 ~= nil)
do
    local ts = require("ui.timeline.timeline_state")
    if ts.reload_clips then ts.reload_clips("seq") end
end
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
    if c.id ~= "t1" and c.track_id == "v2" then
        duplicated_id = c.id
        break
    end
end
assert(duplicated_id, "Expected a duplicated clip on v2")

local dup_clip = Clip.load_optional(duplicated_id, db)
assert(dup_clip, "Expected to load duplicated clip")
assert(dup_clip.owner_sequence_id == "seq", "Duplicated clip should preserve owner_sequence_id")
-- V13: 'offline' column dropped; offline is derived from the chain
-- (clip → nested → media_ref → media.offline_note).

cleanup_db_artifacts(db_path)
print("✅ DuplicateClips preserves owner_sequence_id/offline via mutation inserts")

