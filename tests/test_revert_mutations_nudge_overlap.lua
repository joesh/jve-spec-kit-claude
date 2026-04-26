#!/usr/bin/env luajit

-- Regression: undoing a nudge must restore occluded clips without triggering VIDEO_OVERLAP.
-- This caught command_helper.revert_mutations re-inserting deleted clips before moving the
-- nudged clip back, causing an overlap during undo.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local import_schema = require("import_schema")
local command_helper = require("core.command_helper")

local DB_PATH = "/tmp/jve/test_revert_mutations_nudge_overlap.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

assert(db:exec([[INSERT INTO projects(id,name,fps_mismatch_policy, created_at,modified_at) VALUES('proj','P','resample',0,0);]]))
assert(db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at)
                 VALUES('seq','proj','Seq','nested',24,1,48000,1920,1080,0,10000,0,0,0);]]))
assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan)
                 VALUES('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0);]]))

-- V13 fixture: placeholder master sequence (clips.nested_sequence_id FK
-- + INV-1 require the referenced master to exist with kind='master').
do
    assert(db:exec("INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at) VALUES('_v13_placeholder_master','proj','PlaceholderMaster','master',24,1,48000,1920,1080,0,2000,0,0,0);"))
    assert(db:exec("INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES('_v13_placeholder_master_v1','_v13_placeholder_master','V1','VIDEO',1,1,0,0,0,1.0,0.0);"))
    db:exec("INSERT OR IGNORE INTO media(id,project_id,name,file_path,duration_frames,fps_numerator,fps_denominator,width,height,audio_channels,codec,metadata,created_at,modified_at) VALUES('_v13_placeholder_master_media','proj','PlaceholderMedia','/tmp/placeholder.mov',2000,24,1,1920,1080,2,'prores','{{}}',0,0);")
    db:exec("INSERT OR IGNORE INTO media_refs(id,project_id,owner_sequence_id,track_id,media_id,source_in_frame,source_out_frame,timeline_start_frame,duration_frames,enabled,volume,playhead_frame,created_at,modified_at) VALUES('_v13_placeholder_master_mref','proj','_v13_placeholder_master','_v13_placeholder_master_v1','_v13_placeholder_master_media',0,2000,0,2000,1,1.0,0,0,0);")
end

local function insert_clip(id, start_frames, duration_frames)
    local stmt = db:prepare([[
INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, nested_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    (?, ?, ?, ?, 'seq', '_v13_placeholder_master', ?, ?, ?, ?, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);]])
    stmt:bind_value(1, id)
    stmt:bind_value(2, "proj")
    stmt:bind_value(3, "timeline")
    stmt:bind_value(4, "v1")
    stmt:bind_value(5, start_frames)
    stmt:bind_value(6, duration_frames)
    stmt:bind_value(7, 0)
    stmt:bind_value(8, duration_frames)
    assert(stmt:exec(), "failed to insert clip " .. id)
    stmt:finalize()
end

-- Two clips on the same track; moving A right over B deletes B. Undo must move A back
-- before re-inserting B or VIDEO_OVERLAP fires.
insert_clip("A", 0, 100)
insert_clip("B", 110, 100)

-- Planned mutations from the forward nudge (delete occluded B, move A right).
local mutations = {
    {
        type = "delete",
        clip_id = "B",
        previous = {
            id = "B",
            project_id = "proj",
            clip_kind = "nested",
            name = "B",
            track_id = "v1",
            media_id = nil,
            timeline_start = 110,
            start_value = 110,
            duration = 100,
            source_in = 0,
            source_out = 100,
            fps_numerator = 24,
            fps_denominator = 1,
            enabled = true,
            created_at = 0,
            modified_at = 0,
        },
    },
    {
        type = "update",
        clip_id = "A",
        track_id = "v1",
        timeline_start_frame = 120, -- A nudged right by 120 frames
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        enabled = 1,
        previous = {
            id = "A",
            track_id = "v1",
            timeline_start = 0,
            start_value = 0,
            duration = 100,
            source_in = 0,
            source_out = 100,
            fps_numerator = 24,
            fps_denominator = 1,
            enabled = true,
        },
    },
}

-- Forward mutations must apply cleanly.
local apply_ok, apply_err = command_helper.apply_mutations(db, mutations)
assert(apply_ok, "apply_mutations failed: " .. tostring(apply_err))

-- Undo should succeed without hitting VIDEO_OVERLAP.
local nudge_cmd = {
    type = "Nudge",
    parameters = {},
    set_parameter = function(self, key, value)
        self.parameters[key] = value
    end,
    get_parameter = function(self, key)
        return self.parameters[key]
    end,
}
nudge_cmd:set_parameter("nudge_amount", 120)
nudge_cmd:set_parameter("nudge_amount", 120)

local undo_ok, undo_err = command_helper.revert_mutations(db, mutations, nudge_cmd, "seq")
assert(undo_ok, "revert_mutations failed: " .. tostring(undo_err))

-- Verify both clips are back and non-overlapping at their original positions.
local q = db:prepare("SELECT id, timeline_start_frame, duration_frames FROM clips WHERE track_id = 'v1' ORDER BY timeline_start_frame")
assert(q:exec(), "clip query failed")
local clips = {}
while q:next() do
    table.insert(clips, {
        id = q:value(0),
        start = q:value(1),
        dur = q:value(2),
    })
end
q:finalize()

assert(#clips == 2, "expected both clips restored, found " .. #clips)
assert(clips[1].id == "A" and clips[1].start == 0 and clips[1].dur == 100, "clip A not restored to original")
assert(clips[2].id == "B" and clips[2].start == 110 and clips[2].dur == 100, "clip B not restored to original")
assert(clips[1].start + clips[1].dur <= clips[2].start, "overlap detected after undo")

os.remove(DB_PATH)
print("✅ revert_mutations restores occluded clips without VIDEO_OVERLAP on undo")
