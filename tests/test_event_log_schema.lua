#!/usr/bin/env luajit
-- Regression Test: Event Log Schema Consistency
-- Verifies that event_log.lua can successfully insert into the read-model database.

package.path = package.path .. ";./src/lua/?.lua"

local event_log = require("core.event_log")
local Rational = require("core.rational")
local database = require("core.database") -- To init main DB if needed, or just for event_log init context

print("=== Testing Event Log Schema Consistency ===\n")

-- Setup temporary test environment
local test_dir = "/tmp/jve_test_event_log"
os.execute("rm -rf " .. test_dir)
os.execute("mkdir -p " .. test_dir)

-- Initialize event log (this creates the readmodel sqlite db)
local project_path = test_dir .. "/test_project.jvp"
local ok, err = pcall(event_log.init, project_path)
if not ok then
    print("❌ Failed to init event log: " .. tostring(err))
    os.exit(1)
end
print("✅ Event log initialized at " .. project_path)

-- Mock Command object for Insert
local insert_command = {
    id = "cmd_123",
    type = "Insert",
    sequence_number = 1,
    parameters = {
        clip_id = "clip_abc",
        media_id = "media_xyz",
        track_id = "track_v1",
        insert_time = Rational.new(0, 24, 1),
        duration = Rational.new(24, 24, 1),
        source_in = Rational.new(0, 24, 1),
        source_out = Rational.new(24, 24, 1),
        sequence_id = "seq_main"
    },
    get_parameter = function(self, key)
        return self.parameters[key]
    end,
    playhead_value = 0
}

-- Context
local context = {
    sequence_id = "seq_main",
    project_id = "proj_1"
}

-- Attempt to record command (this triggers apply_timeline_event)
print("Attempting to record Insert command...")
local success, msg = event_log.record_command(insert_command, context)

if success then
    print("✅ Successfully recorded Insert command.")
else
    print("❌ Failed to record Insert command: " .. tostring(msg))
    -- We expect this to FAIL currently if the bug exists.
end

-- Cleanup
os.execute("rm -rf " .. test_dir)

if success then
    os.exit(0)
else
    os.exit(1)
end
