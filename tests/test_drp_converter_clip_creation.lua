#!/usr/bin/env luajit

-- Regression: drp_project_converter.convert() must pass project_id and
-- owner_sequence_id to Clip.create for timeline clips. Without these,
-- Clip.create asserts since the masterclip invariant requires them.

require("test_env")

local drp_converter = require("core.drp_project_converter")
local database = require("core.database")

local test_env = require("test_env")
local fixture_path = test_env.resolve_repo_path("tests/fixtures/resolve/sample_project.drp")

local JVP_PATH = "/tmp/jve/test_drp_converter_clips.jvp"
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-wal")
os.remove(JVP_PATH .. "-shm")

print("\n=== DRP Converter Clip Creation Regression ===")

-- Convert must succeed (previously asserted on missing owner_sequence_id)
local ok, err = drp_converter.convert(fixture_path, JVP_PATH)
assert(ok, "drp_converter.convert() failed: " .. tostring(err))

local db = database.get_connection()
assert(db, "No database connection after convert")

-- Helper
local function scalar(sql, param)
    local stmt = assert(db:prepare(sql), "prepare failed: " .. sql)
    if param then stmt:bind_value(1, param) end
    assert(stmt:exec(), "exec failed: " .. sql)
    local val = nil
    if stmt:next() then val = stmt:value(0) end
    stmt:finalize()
    return val
end

-- Verify clips were created
local clip_count = scalar("SELECT COUNT(*) FROM clips WHERE clip_kind = 'timeline'")
assert(clip_count and clip_count > 0,
    string.format("Expected timeline clips, got %s", tostring(clip_count)))
print(string.format("  %d timeline clip(s) created", clip_count))

-- Verify every timeline clip has owner_sequence_id set
local orphan_count = scalar(
    "SELECT COUNT(*) FROM clips WHERE clip_kind = 'timeline' AND owner_sequence_id IS NULL")
assert(orphan_count == 0,
    string.format("Found %d clip(s) without owner_sequence_id", orphan_count))
print("  All timeline clips have owner_sequence_id")

-- Verify every timeline clip has project_id set
local no_project = scalar(
    "SELECT COUNT(*) FROM clips WHERE clip_kind = 'timeline' AND project_id IS NULL")
assert(no_project == 0,
    string.format("Found %d clip(s) without project_id", no_project))
print("  All timeline clips have project_id")

-- Verify masterclip sequences were auto-created for clips with media
local mc_count = scalar("SELECT COUNT(*) FROM sequences WHERE kind = 'masterclip'")
print(string.format("  %d masterclip sequence(s) auto-created", mc_count))

-- Cleanup
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-wal")
os.remove(JVP_PATH .. "-shm")

print("✅ test_drp_converter_clip_creation.lua passed")
