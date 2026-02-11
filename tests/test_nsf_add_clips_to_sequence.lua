#!/usr/bin/env luajit
-- NSF Tests: AddClipsToSequence must not silently fail on missing stream clips
--
-- When copying properties from masterclip to timeline clip, if the source
-- stream clip cannot be found, the command must ASSERT, not silently skip.

require("test_env")

print("=== test_nsf_add_clips_to_sequence.lua ===")

--------------------------------------------------------------------------------
-- Test 1: Caller must assert on missing source stream clip
--------------------------------------------------------------------------------

print("\n--- Test 1: Caller must assert when source stream expected ---")

-- Read the add_clips_to_sequence source and verify it asserts on nil
local cmd_path = "../src/lua/core/commands/add_clips_to_sequence.lua"
local handle = io.open(cmd_path, "r")
assert(handle, "Could not open add_clips_to_sequence.lua")
local content = handle:read("*a")
handle:close()

-- The violation pattern: `if source_clip_id then` without else-assert
-- Correct pattern: assert(source_clip_id, ...) after calling find_source_stream_clip

-- Check for the NSF violation pattern: silent skip when source_clip_id is nil
local has_silent_skip = content:match("if%s+source_clip_id%s+then") and
                        not content:match("assert%(source_clip_id")

if has_silent_skip then
    print("NSF VIOLATION: find_source_stream_clip returns nil without assert")
    print("  Found: `if source_clip_id then` pattern (silent skip on nil)")
    print("  Expected: assert(source_clip_id, ...) or explicit error")
    error("add_clips_to_sequence.lua silently skips on missing source stream clip")
end

-- Verify assert pattern exists for source_clip_id
local has_assert = content:match("assert%(source_clip_id")
if not has_assert then
    print("NSF VIOLATION: No assert on source_clip_id found")
    error("add_clips_to_sequence.lua must assert on missing source stream clip")
end

print("✓ Caller asserts when source stream clip expected but missing")

--------------------------------------------------------------------------------
-- Test 2: find_source_stream_clip asserts on invalid inputs
--------------------------------------------------------------------------------

print("\n--- Test 2: find_source_stream_clip asserts on invalid inputs ---")

-- The function must assert on programming errors (invalid inputs)
local func_body = content:match("local function find_source_stream_clip.-\nend")
assert(func_body, "Could not find find_source_stream_clip function")

-- Verify asserts exist for required parameters
local has_input_asserts = func_body:match("assert%(masterclip_sequence_id") and
                          func_body:match("assert%(role")
if not has_input_asserts then
    print("NSF VIOLATION: find_source_stream_clip missing input validation asserts")
    error("find_source_stream_clip must assert on invalid inputs")
end

-- Verify database errors assert (not just log and return nil)
local has_db_asserts = func_body:match("assert%(db:prepare") or func_body:match("assert%(exec_ok")
if not has_db_asserts then
    print("NSF VIOLATION: find_source_stream_clip doesn't assert on database errors")
    error("find_source_stream_clip must assert on database errors")
end

print("✓ find_source_stream_clip asserts on invalid inputs and DB errors")

--------------------------------------------------------------------------------
-- Test 3: Legitimate nil return is documented (stream doesn't exist)
--------------------------------------------------------------------------------

print("\n--- Test 3: Nil return is only for 'stream not found' case ---")

-- The only valid return nil is when the stream genuinely doesn't exist
-- (e.g., video-only masterclip has no audio track)
-- This should be documented in comments

local has_nil_return_comment = func_body:match("%-%-.*no track") or
                               func_body:match("%-%-.*doesn't exist") or
                               func_body:match("%-%-.*video%-only") or
                               func_body:match("%-%-.*audio%-only")
if not has_nil_return_comment then
    print("WARNING: return nil case not documented")
end

-- Count return nil statements - should only be for legitimate "not found"
local nil_count = 0
for _ in func_body:gmatch("return%s+nil") do
    nil_count = nil_count + 1
end

-- Should have at most 2 return nil (no track found, no clip found)
assert(nil_count <= 2, string.format(
    "Too many return nil statements (%d) - each must be for legitimate 'not found' case",
    nil_count))

print(string.format("✓ %d return nil statements (legitimate 'not found' cases)", nil_count))

print("\n✅ test_nsf_add_clips_to_sequence.lua passed")
