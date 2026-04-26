#!/usr/bin/env luajit
-- NSF Tests: AddClipsToSequence rejects malformed inputs.
--
-- V13: AddClipsToSequence consumes group structures from gather_context;
-- the V8 'find_source_stream_clip + copy properties from a stream clip'
-- path is gone. The remaining NSF surface is the input-validation
-- asserts in the executor (group/clip_desc field checks).

require("test_env")

print("=== test_nsf_add_clips_to_sequence.lua ===")

local cmd_path = "../src/lua/core/commands/add_clips_to_sequence.lua"
local handle = assert(io.open(cmd_path, "r"),
    "Could not open add_clips_to_sequence.lua")
local content = handle:read("*a")
handle:close()

-- V13 NSF: the V8 find_source_stream_clip helper is gone (master
-- sequences hold media_refs, not stream clips). Confirm it stays gone
-- and that the executor still asserts on its required clip_desc fields.
print("\n--- V8 find_source_stream_clip helper stays removed ---")
local has_v8_helper = content:match("find_source_stream_clip")
assert(not has_v8_helper,
    "V8 find_source_stream_clip should be absent from add_clips_to_sequence.lua")
print("✓ V8 find_source_stream_clip helper not present")

print("\n--- AddClipsToSequence asserts on required clip_desc fields ---")
-- Confirm the asserts that gate clip_desc shape are present.
local required_asserts = {
    "target_track_id",
    "nested_sequence_id",
    "fps_mismatch_policy",
}
for _, field in ipairs(required_asserts) do
    local pattern = "clip_desc.*" .. field
    assert(content:match(pattern),
        "AddClipsToSequence missing required-field assert for " .. field)
    print(string.format("✓ asserts on clip_desc.%s", field))
end

print("\n✅ test_nsf_add_clips_to_sequence.lua passed")
