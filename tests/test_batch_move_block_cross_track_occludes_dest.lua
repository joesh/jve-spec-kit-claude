#!/usr/bin/env luajit

-- Regression: moving a block of clips to another track with an existing clip should resolve occlusions (no overlaps, dest clip removed/trimmed).

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local import_schema = require("import_schema")
local Command = require("command")

local DB_PATH = "/tmp/jve/test_batch_move_block_cross_track.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Minimal project/sequence/tracks
assert(db:exec([[INSERT INTO projects(id,name,fps_mismatch_policy, created_at,modified_at) VALUES('proj','P','resample',0,0);]]))
assert(db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_sample_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at)
                 VALUES('seq','proj','Seq','sequence',24,1,48000,1920,1080,0,2000,0,0,0);]]))
assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan)
                 VALUES('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0),
                        ('v2','seq','V2','VIDEO',2,1,0,0,0,1.0,0.0);]]))

-- V13 fixture: placeholder master sequence (clips.source_sequence_id FK
-- + media_refs must be owned by a kind='master' sequence).
do
    assert(db:exec("INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_sample_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at) VALUES('_v13_placeholder_master','proj','PlaceholderMaster','master',24,1,48000,1920,1080,0,2000,0,0,0);"))
    assert(db:exec("INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES('_v13_placeholder_master_v1','_v13_placeholder_master','V1','VIDEO',1,1,0,0,0,1.0,0.0);"))
    db:exec("INSERT OR IGNORE INTO media(id,project_id,name,file_path,duration_frames,fps_numerator,fps_denominator,width,height,audio_channels,codec,metadata,created_at,modified_at) VALUES('_v13_placeholder_master_media','proj','PlaceholderMedia','/tmp/placeholder.mov',2000,24,1,1920,1080,2,'prores','{{}}',0,0);")
    db:exec("INSERT OR IGNORE INTO media_refs(id,project_id,owner_sequence_id,track_id,media_id,source_in_frame,source_out_frame,sequence_start_frame,duration_frames,enabled,volume,playhead_frame,created_at,modified_at) VALUES('_v13_placeholder_master_mref','proj','_v13_placeholder_master','_v13_placeholder_master_v1','_v13_placeholder_master_media',0,2000,0,2000,1,1.0,0,0,0);")
end

local function insert_clip(id, track, start_frames, duration_frames)
    local stmt = db:prepare([[
INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    (?, ?, ?, ?, 'seq', '_v13_placeholder_master', ?, ?, ?, ?, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);]])
    stmt:bind_value(1, id)

    stmt:bind_value(2, "proj")

    stmt:bind_value(3, "timeline")

    stmt:bind_value(4, track)

    stmt:bind_value(5, start_frames)

    stmt:bind_value(6, duration_frames)

    stmt:bind_value(7, 0)

    stmt:bind_value(8, duration_frames)
    if not stmt:exec() then
        error("failed to insert clip " .. id .. ": " .. tostring(db:last_error()))
    end
    stmt:finalize()
end

insert_clip("c1", "v1", 0,   100)
insert_clip("c2", "v1", 150, 100)
insert_clip("dest", "v2", 0, 120) -- will be occluded by the move

command_manager.init("seq", "proj")

command_manager.begin_undo_group("batch_move")

local move1 = Command.create("MoveClipToTrack", "proj")
move1:set_parameter("clip_id", "c1")
move1:set_parameter("target_track_id", "v2")
local exec1 = command_manager.execute(move1)
assert(exec1 and exec1.success, "move c1 failed")

local move2 = Command.create("MoveClipToTrack", "proj")
move2:set_parameter("clip_id", "c2")
move2:set_parameter("target_track_id", "v2")
local exec = command_manager.execute(move2)
assert(exec and exec.success, "move c2 failed")

command_manager.end_undo_group()

-- v2 should now contain c1 and c2 only, no overlaps
local q = db:prepare("SELECT id, sequence_start_frame, duration_frames FROM clips WHERE track_id = 'v2' ORDER BY sequence_start_frame")
assert(q:exec(), "query failed")
local clips = {}
while q:next() do
    table.insert(clips, {id = q:value(0), start = q:value(1), dur = q:value(2)})
end
q:finalize()

-- There should be no overlaps on v2, and the original dest clip should be removed or trimmed.
table.sort(clips, function(a,b) return a.start < b.start end)
for i = 2, #clips do
    local prev = clips[i-1]
    local cur = clips[i]
    assert(prev.start + prev.dur <= cur.start, "clips on v2 should not overlap after move")
end

local found_c1, found_c2 = false, false
for _, c in ipairs(clips) do
    if c.id == "c1" then found_c1 = true end
    if c.id == "c2" then found_c2 = true end
    if c.id == "dest" then
        assert(c.start >= 100, "dest clip should be trimmed to avoid overlap")
        assert(c.dur <= 120, "dest clip duration should not grow")
    end
end
assert(found_c1 and found_c2, "expected c1 and c2 on destination track")
-- Dest may be deleted or trimmed; either is acceptable as long as no overlaps remain.

os.remove(DB_PATH)
print("✅ Batch move to occupied track resolves occlusions and avoids overlaps")
