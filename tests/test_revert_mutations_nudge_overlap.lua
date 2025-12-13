#!/usr/bin/env luajit

-- Regression: undoing a nudge must restore occluded clips without triggering VIDEO_OVERLAP.
-- This caught command_helper.revert_mutations re-inserting deleted clips before moving the
-- nudged clip back, causing an overlap during undo.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local import_schema = require("import_schema")
local command_helper = require("core.command_helper")
local Rational = require("core.rational")

local DB_PATH = "/tmp/jve/test_revert_mutations_nudge_overlap.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

assert(db:exec([[INSERT INTO projects(id,name,created_at,modified_at) VALUES('proj','P',0,0);]]))
assert(db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at)
                 VALUES('seq','proj','Seq','timeline',24,1,48000,1920,1080,0,10000,0,0,0);]]))
assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan)
                 VALUES('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0);]]))

local function insert_clip(id, start_frames, duration_frames)
    local stmt = db:prepare([[INSERT INTO clips(
        id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, created_at, modified_at
    ) VALUES(?,?,?,?,?,?,?,?,?,?,24,1,1,0,0)]])
    stmt:bind_value(1, id)
    stmt:bind_value(2, "proj")
    stmt:bind_value(3, "timeline")
    stmt:bind_value(4, id)
    stmt:bind_value(5, "v1")
    stmt:bind_value(6, nil)
    stmt:bind_value(7, start_frames)
    stmt:bind_value(8, duration_frames)
    stmt:bind_value(9, 0)
    stmt:bind_value(10, duration_frames)
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
            clip_kind = "timeline",
            name = "B",
            track_id = "v1",
            media_id = nil,
            timeline_start = Rational.new(110, 24, 1),
            start_value = Rational.new(110, 24, 1),
            duration = Rational.new(100, 24, 1),
            source_in = Rational.new(0, 24, 1),
            source_out = Rational.new(100, 24, 1),
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
            timeline_start = Rational.new(0, 24, 1),
            start_value = Rational.new(0, 24, 1),
            duration = Rational.new(100, 24, 1),
            source_in = Rational.new(0, 24, 1),
            source_out = Rational.new(100, 24, 1),
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
nudge_cmd:set_parameter("nudge_amount_rat", Rational.new(120, 24, 1))
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
