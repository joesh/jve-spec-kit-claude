#!/usr/bin/env luajit

require("test_env")

local ripple_layout = require("tests.helpers.ripple_layout")
local command_manager = require("core.command_manager")
local Command = require("command")
local database = require("core.database")
local dkjson = require("dkjson")

local TEST_DB = "/tmp/jve/test_batch_ripple_undo_missing_mutations.db"
local layout = ripple_layout.create({db_path = TEST_DB})
local clips = layout.clips
local tracks = layout.tracks

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", -200)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit execution failed")

local db = database.get_connection()
local stmt = assert(db:prepare("SELECT sequence_number, command_args FROM commands ORDER BY sequence_number DESC LIMIT 1"))
assert(stmt:exec() and stmt:next(), "Expected ripple command persisted to commands table")
local seq = stmt:value(0)
local args_json = stmt:value(1)
stmt:finalize()

local args = {}
if type(args_json) == "string" and args_json ~= "" then
    local ok, decoded = pcall(dkjson.decode, args_json)
    if ok and decoded then args = decoded end
end
args.executed_mutations = nil -- Simulate pre-refactor command without stored mutations
local updated_json = dkjson.encode(args)

local update_stmt = assert(db:prepare("UPDATE commands SET command_args = ? WHERE sequence_number = ?"))
update_stmt:bind_value(1, updated_json)
update_stmt:bind_value(2, seq)
assert(update_stmt:exec(), "Failed to strip executed_mutations from command_args")
update_stmt:finalize()

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo should succeed even if executed_mutations are missing")

layout:cleanup()
print("✅ BatchRippleEdit undo succeeds when executed_mutations are missing")
