#!/usr/bin/env luajit

-- Test BatchCommand parameter contract and transaction safety
-- Ensures parameter name matches between caller and executor

package.path = package.path .. ";../src/lua/?.lua;../src/lua/core/?.lua;../src/lua/models/?.lua"

local command_manager = require('core.command_manager')
local Command = require('command')
local database = require('core.database')

print("=== BatchCommand Parameter Contract Tests ===\n")

-- Setup test database
local test_db_path = "/tmp/test_batch_command_contract.db"
os.remove(test_db_path)  -- Clean slate

database.init(test_db_path)
local db = database.get_connection()

-- Create minimal schema for testing
db:exec([[
    CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        current_sequence_number INTEGER
    );

    CREATE TABLE IF NOT EXISTS tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS clips (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        media_id TEXT,
        start_time INTEGER NOT NULL,
        duration INTEGER NOT NULL,
        source_in INTEGER NOT NULL,
        source_out INTEGER NOT NULL,
        enabled BOOLEAN DEFAULT 1
    );

    CREATE TABLE IF NOT EXISTS media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        file_path TEXT UNIQUE NOT NULL,
        name TEXT NOT NULL,
        duration INTEGER,
        frame_rate REAL,
        width INTEGER,
        height INTEGER
    );

    CREATE TABLE IF NOT EXISTS commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        playhead_time INTEGER DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]'
    );
]])

-- Insert test data
db:exec([[
    INSERT INTO projects (id, name) VALUES ('test_project', 'Test Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('test_sequence', 'test_project', 'Test Sequence', 30.0, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, track_type, track_index)
    VALUES ('track_v1', 'test_sequence', 'VIDEO', 1);
]])

command_manager.init(db, 'test_sequence')

-- Test 1: BatchCommand accepts commands_json parameter
print("Test 1: BatchCommand accepts commands_json parameter")
local json = require("dkjson")
local command_specs = {
    {
        command_type = "CreateSequence",
        project_id = "test_project",
        parameters = {
            sequence_name = "Batch Test Sequence",
            frame_rate = 30.0,
            width = 1920,
            height = 1080
        }
    }
}

local batch_cmd = Command.create("BatchCommand", "test_project")
batch_cmd:set_parameter("commands_json", json.encode(command_specs))

local result = command_manager.execute(batch_cmd)
if result.success then
    print("✅ PASS: BatchCommand accepted commands_json parameter\n")
else
    print("❌ FAIL: BatchCommand rejected commands_json parameter")
    print("   Error: " .. (result.error_message or "unknown") .. "\n")
    os.exit(1)
end

-- Test 2: BatchCommand with wrong parameter name fails gracefully
print("Test 2: BatchCommand with wrong parameter name fails gracefully")
local bad_cmd = Command.create("BatchCommand", "test_project")
bad_cmd:set_parameter("commands", json.encode(command_specs))  -- Wrong name

local bad_result = command_manager.execute(bad_cmd)
if not bad_result.success then
    print("✅ PASS: BatchCommand correctly rejected wrong parameter name\n")
else
    print("❌ FAIL: BatchCommand should have rejected 'commands' parameter")
    print("   It should only accept 'commands_json'\n")
    os.exit(1)
end

-- Test 3: BatchCommand transaction rollback on failure
print("Test 3: BatchCommand transaction rollback on failure")

-- Create a batch with an invalid command type
local bad_batch_specs = {
    {
        command_type = "CreateSequence",
        project_id = "test_project",
        parameters = {
            sequence_name = "First Sequence",
            frame_rate = 30.0,
            width = 1920,
            height = 1080
        }
    },
    {
        command_type = "NonExistentCommand",  -- This will fail
        project_id = "test_project",
        parameters = {}
    }
}

-- Count sequences before
local count_before = 0
local count_query = db:prepare("SELECT COUNT(*) FROM sequences")
if count_query and count_query:exec() and count_query:next() then
    count_before = count_query:value(0)
end

local rollback_cmd = Command.create("BatchCommand", "test_project")
rollback_cmd:set_parameter("commands_json", json.encode(bad_batch_specs))
local rollback_result = command_manager.execute(rollback_cmd)

-- Count sequences after (should be same - transaction rolled back)
local count_after = 0
count_query = db:prepare("SELECT COUNT(*) FROM sequences")
if count_query and count_query:exec() and count_query:next() then
    count_after = count_query:value(0)
end

if not rollback_result.success and count_after == count_before then
    print("✅ PASS: BatchCommand rolled back transaction on failure")
    print("   Sequences before: " .. count_before .. ", after: " .. count_after .. "\n")
else
    print("❌ FAIL: BatchCommand did not properly rollback transaction")
    print("   Sequences before: " .. count_before .. ", after: " .. count_after)
    print("   Expected: no change\n")
    os.exit(1)
end

-- Test 4: BatchCommand empty array
print("Test 4: BatchCommand with empty command array")
local empty_cmd = Command.create("BatchCommand", "test_project")
empty_cmd:set_parameter("commands_json", "[]")
local empty_result = command_manager.execute(empty_cmd)

if empty_result.success then
    print("✅ PASS: BatchCommand handled empty array gracefully\n")
else
    print("⚠️  WARNING: BatchCommand rejected empty array")
    print("   This may be intentional, but consider if empty batches are valid\n")
end

print("=== All BatchCommand Contract Tests Passed ===")
os.remove(test_db_path)
os.exit(0)
