#!/usr/bin/env luajit

-- Regression: drp_importer.convert() must pass project_id and
-- owner_sequence_id to Clip.create for timeline clips. Without these,
-- Clip.create asserts since the masterclip invariant requires them.

require("test_env")

local drp_converter = require("importers.drp_importer")
local database = require("core.database")

local test_env = require("test_env")
local fixture_path = test_env.require_fixture("tests/fixtures/resolve/sample_project.drp")

local JVP_PATH = "/tmp/jve/test_drp_converter_clips.jvp"
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-wal")
os.remove(JVP_PATH .. "-shm")

print("\n=== DRP Converter Clip Creation Regression ===")

-- Convert must succeed (previously asserted on missing owner_sequence_id)
local ok, err = drp_converter.convert(fixture_path, JVP_PATH, nil, {audio_sample_rate = 48000})
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

-- V13: all clips live in a nested sequence (clips must be owned by a kind='sequence' sequence). owner_sequence_id +
-- project_id are NOT NULL at schema level, so the original orphan/no-project
-- queries are unfalsifiable — INSERT would have failed before reaching this
-- assertion. We keep the count-positive check; structural integrity is the
-- ownership + acyclicity triggers' job.
local clip_count = scalar("SELECT COUNT(*) FROM clips")
assert(clip_count and clip_count > 0,
    string.format("Expected clips, got %s", tostring(clip_count)))
print(string.format("  %d clip(s) created", clip_count))

-- Verify master sequences were auto-created for media (V13: kind='master')
local mc_count = scalar("SELECT COUNT(*) FROM sequences WHERE kind = 'master'")
assert(mc_count and mc_count > 0,
    string.format("Expected master sequence(s), got %s", tostring(mc_count)))
print(string.format("  %d master sequence(s) auto-created", mc_count))

-- Cleanup
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-wal")
os.remove(JVP_PATH .. "-shm")

print("✅ test_drp_converter_clip_creation.lua passed")
