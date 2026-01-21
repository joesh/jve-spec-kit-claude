#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local import_schema = require("import_schema")
local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local Rational = require("core.rational")

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

db:exec([[INSERT INTO projects(id,name,created_at,modified_at,settings) VALUES('proj','Test',0,0,'{}')]])
db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,
        view_start_frame,view_duration_frames,playhead_frame,
        selected_clip_ids,selected_edge_infos,selected_gap_infos,current_sequence_number,created_at,modified_at)
        VALUES('seq','proj','Sequence','timeline',30,1,48000,1920,1080,0,8000,0,'[]','[]','[]',0,0,0)
    ]])
db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES
        ('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0)
    ]])
db:exec([[INSERT INTO media(id,project_id,name,file_path,duration_frames,fps_numerator,fps_denominator,created_at,modified_at)
          VALUES('media1','proj','Media1','/tmp/test.mov',1000,30,1,0,0)]])

command_manager.init("seq", "proj")

-- Two disjoint clips on the same track with a small gap.
local c1 = Clip.create("C1", "media1", {
    id = "c1",
    project_id = "proj",
    track_id = "v1",
    owner_sequence_id = "seq",
    timeline_start = Rational.new(0, 30, 1),
    duration = Rational.new(10, 30, 1),
    source_in = Rational.new(0, 30, 1),
    source_out = Rational.new(10, 30, 1),
    fps_numerator = 30, fps_denominator = 1
})
assert(c1:save(db))

local c2 = Clip.create("C2", "media1", {
    id = "c2",
    project_id = "proj",
    track_id = "v1",
    owner_sequence_id = "seq",
    timeline_start = Rational.new(12, 30, 1),
    duration = Rational.new(10, 30, 1),
    source_in = Rational.new(0, 30, 1),
    source_out = Rational.new(10, 30, 1),
    fps_numerator = 30, fps_denominator = 1
})
assert(c2:save(db))

local dup = Command.create("DuplicateClips", "proj")
dup:set_parameter("project_id", "proj")
dup:set_parameter("sequence_id", "seq")
dup:set_parameter("clip_ids", {"c1", "c2"})
dup:set_parameter("delta_rat", Rational.new(5, 30, 1))
dup:set_parameter("target_track_id", "v1")
dup:set_parameter("anchor_clip_id", "c1")

local result = command_manager.execute(dup)
assert(result.success, result.error_message or "DuplicateClips failed")

local clips = database.load_clips("seq")
local starts = {}
for _, clip in ipairs(clips) do
    if clip.track_id == "v1" and clip.clip_kind == "timeline" then
        starts[clip.id] = clip.timeline_start.frames
    end
end

assert(starts.c1 == 0, "Original clip c1 should remain at 0")
assert(starts.c2 == 12, "Original clip c2 should remain at 12")

-- The requested delta would overlap the source selection; the command must clamp
-- to the nearest non-overlapping placement (to the right by default).
local found_22, found_34 = false, false
for _, start in pairs(starts) do
    if start == 22 then
        found_22 = true
    elseif start == 34 then
        found_34 = true
    end
end

assert(found_22 and found_34,
    "Expected duplicates to clamp to starts 22 and 34 on V1 (block placement)")

cleanup_db_artifacts(db_path)
print("✅ DuplicateClips clamps delta to avoid overwriting the source selection")

