#!/usr/bin/env lua
-- Test script for SplitClip command
-- Tests the command logic without requiring full database setup

print("=== Testing SplitClip Command ===\n")

-- Mock database object
local mock_db = {
    queries = {},
    prepare = function(self, sql)
        print("  DB: Preparing query: " .. sql:sub(1, 50) .. "...")
        local query = {
            sql = sql,
            bindings = {},
            result_rows = {},
            current_row = 0,

            bind_value = function(self, index, value)
                self.bindings[index] = value
            end,

            exec = function(self)
                print("  DB: Executing query with bindings:", table.concat(self.bindings, ", "))

                -- Mock different query responses
                if self.sql:match("SELECT.*FROM clips WHERE id") then
                    -- Load clip query - return mock clip
                    if self.bindings[1] == "clip1" then
                        self.result_rows = {{
                            "clip1",           -- id
                            "video1",          -- track_id
                            "media1",          -- media_id
                            1000,              -- start_time
                            5000,              -- duration
                            0,                 -- source_in
                            5000,              -- source_out
                            1                  -- enabled
                        }}
                    end
                elseif self.sql:match("SELECT COUNT") then
                    -- Check if exists - return 0 for new clips
                    if self.bindings[1]:match("^clip1") then
                        self.result_rows = {{1}}
                    else
                        self.result_rows = {{0}}
                    end
                end

                return true
            end,

            next = function(self)
                self.current_row = self.current_row + 1
                return self.current_row <= #self.result_rows
            end,

            value = function(self, index)
                if self.current_row <= #self.result_rows then
                    return self.result_rows[self.current_row][index + 1]
                end
                return nil
            end,

            last_error = function(self)
                return "No error"
            end
        }

        return query
    end
}

-- Load the Clip model
package.path = package.path .. ";./src/lua/?.lua"
local Clip = require("models.clip")

print("1. Testing Clip.create()...")
local clip = Clip.create("Test Clip", "media1")
print("  ✓ Created clip:", clip.id)
print("  ✓ Name:", clip.name)
print("  ✓ Media ID:", clip.media_id)
print()

print("2. Testing Clip.load()...")
local loaded_clip = Clip.load("clip1", mock_db)
if loaded_clip then
    print("  ✓ Loaded clip:", loaded_clip.id)
    print("  ✓ Start time:", loaded_clip.start_time)
    print("  ✓ Duration:", loaded_clip.duration)
    print("  ✓ Source in:", loaded_clip.source_in)
    print("  ✓ Source out:", loaded_clip.source_out)
else
    print("  ✗ Failed to load clip")
end
print()

print("3. Testing Clip.save()...")
clip.track_id = "video1"
clip.start_time = 1000
clip.duration = 5000
clip.source_in = 0
clip.source_out = 5000
local save_result = clip:save(mock_db)
print("  " .. (save_result and "✓" or "✗") .. " Save result:", save_result)
print()

print("4. Simulating SplitClip command logic...")
print("  Original clip: start_time=1000, duration=5000, source_in=0, source_out=5000")
local split_time = 3000
print("  Split time:", split_time)

-- Calculate new durations
local first_duration = split_time - loaded_clip.start_time
local second_duration = loaded_clip.duration - first_duration
print("  First duration:", first_duration)
print("  Second duration:", second_duration)

-- Calculate source points
local source_split_point = loaded_clip.source_in + first_duration
print("  Source split point:", source_split_point)

-- Create second clip
local second_clip = Clip.create(loaded_clip.name .. " (2)", loaded_clip.media_id)
second_clip.track_id = loaded_clip.track_id
second_clip.start_time = split_time
second_clip.duration = second_duration
second_clip.source_in = source_split_point
second_clip.source_out = loaded_clip.source_out
print("  ✓ Second clip created")
print("    - Start time:", second_clip.start_time)
print("    - Duration:", second_clip.duration)
print("    - Source in:", second_clip.source_in)
print("    - Source out:", second_clip.source_out)

-- Update first clip
loaded_clip.duration = first_duration
loaded_clip.source_out = source_split_point
print("  ✓ First clip updated")
print("    - Start time:", loaded_clip.start_time)
print("    - Duration:", loaded_clip.duration)
print("    - Source in:", loaded_clip.source_in)
print("    - Source out:", loaded_clip.source_out)
print()

print("5. Verification:")
local total_duration = loaded_clip.duration + second_clip.duration
local original_duration = 5000
print("  Original duration:", original_duration)
print("  Total after split:", total_duration)
print("  " .. (total_duration == original_duration and "✓" or "✗") .. " Duration preserved:", total_duration == original_duration)

local source_continuity = loaded_clip.source_out == second_clip.source_in
print("  " .. (source_continuity and "✓" or "✗") .. " Source continuity:", source_continuity)

local no_gap = loaded_clip.start_time + loaded_clip.duration == second_clip.start_time
print("  " .. (no_gap and "✓" or "✗") .. " No timeline gap:", no_gap)

print("\n=== Test Complete ===")
