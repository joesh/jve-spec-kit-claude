#!/usr/bin/env luajit

-- Regression: gap edges must be materialized as temporary clips so BatchRippleEdit
-- can ripple the empty space between clips without touching media.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local import_schema = require("import_schema")
local Clip = require("models.clip")

local DB = "/tmp/jve/test_batch_ripple_gap_materialization.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()
assert(db:exec(import_schema))

local function seed_sequence()
    local now = os.time()
    local sql = string.format([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('proj', 'Default', %d, %d);

        INSERT INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate,
            width, height, view_start_frame, view_duration_frames, playhead_frame,
            created_at, modified_at
        )
        VALUES ('seq', 'proj', 'Seq', 'timeline',
                24, 1, 48000, 1920, 1080, 0, 10000, 0, %d, %d);

        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);

        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                           fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
        VALUES
            ('clip_left', 'proj', 'timeline', 'Left', 'v1', NULL, 'seq',
             0, 240, 0, 240, 24, 1, 1, 0, %d, %d),
            ('clip_right', 'proj', 'timeline', 'Right', 'v1', NULL, 'seq',
             720, 240, 0, 240, 24, 1, 1, 0, %d, %d);
    ]], now, now, now, now, now, now, now, now)
    assert(db:exec(sql))
end

local function reset_db()
    assert(db:exec([[
        DELETE FROM clips;
        DELETE FROM tracks;
        DELETE FROM sequences;
        DELETE FROM projects;
    ]]))
    seed_sequence()
    command_manager.init("seq", "proj")
end

reset_db()
local executor = command_manager.get_executor("BatchRippleEdit")
assert(executor, "BatchRippleEdit executor unavailable")

-- Dry run: the plan MUST include a temp gap clip mutation.
local dry_cmd = Command.create("BatchRippleEdit", "proj")
dry_cmd:set_parameter("sequence_id", "seq")
dry_cmd:set_parameter("edge_infos", {
    {clip_id = "clip_left", edge_type = "gap_after", track_id = "v1", trim_type = "ripple"}
})
dry_cmd:set_parameter("delta_frames", 120)
dry_cmd:set_parameter("dry_run", true)

local dry_ok, dry_payload = executor(dry_cmd)
assert(dry_ok and type(dry_payload) == "table", "BatchRippleEdit dry run failed")

local found_temp_gap = false
for _, gap_id in ipairs(dry_payload.materialized_gaps or {}) do
    if type(gap_id) == "string" and gap_id:match("^temp_gap_") then
        found_temp_gap = true
        break
    end
end
assert(found_temp_gap, "BatchRippleEdit must materialize gap edges as temp_gap_* clips during dry run")

-- Execute for real to ensure timeline semantics stay intact.
local cmd = Command.create("BatchRippleEdit", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip_left", edge_type = "gap_after", track_id = "v1", trim_type = "ripple"}
})
cmd:set_parameter("delta_frames", 120) -- drag [ right to close part of the gap and pull downstream clips upstream

local ok, _ = executor(cmd)
assert(ok, "BatchRippleEdit gap-after ripple failed to execute")

local left = Clip.load("clip_left", db)
local right = Clip.load("clip_right", db)

assert(left ~= nil, "Left clip missing after ripple")
assert(right ~= nil, "Right clip missing after ripple")

-- Temp gap ensures the clip stays anchored in time with identical media bounds.
assert(left.timeline_start == 0, string.format("Left clip moved to %d", left.timeline_start))
assert(left.source_in == 0, "Left clip source_in should remain anchored")
assert(left.source_out == 240, "Left clip duration should not change when closing downstream gap")
assert(left.duration == 240, "Closing downstream gap must not trim the upstream clip media")

-- Downstream clip should shift upstream by the delta but keep its media range.
assert(right.timeline_start == 600,
    string.format("Right clip should shift upstream to 600, got %d", right.timeline_start))
assert(right.source_in == 0 and right.source_out == 240,
    "Right clip media bounds should stay fixed while the gap closes")

-- Reset to original state and verify dragging the downstream gap handle LEFT (negative delta)
-- closes the gap even when command replay sanitizes the temp gap id.
reset_db()

local cmd_grow = Command.create("BatchRippleEdit", "proj")
cmd_grow:set_parameter("sequence_id", "seq")
cmd_grow:set_parameter("edge_infos", {
    {clip_id = "clip_right", edge_type = "gap_before", track_id = "v1", trim_type = "ripple"}
})
cmd_grow:set_parameter("delta_frames", -120)

local ok_grow = executor(cmd_grow)
assert(ok_grow, "BatchRippleEdit gap-before positive delta failed to execute")

local left_after = Clip.load("clip_left", db)
local right_after = Clip.load("clip_right", db)
assert(left_after.timeline_start == 0, "Left clip should remain anchored when dragging gap handle right")
assert(right_after.timeline_start == 600,
    string.format("Dragging gap handle left should close the gap; expected right clip at 600, got %d", right_after.timeline_start))

os.remove(DB)
print("✅ BatchRippleEdit materializes gap edges and keeps upstream media untouched")
