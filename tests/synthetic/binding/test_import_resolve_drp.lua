#!/usr/bin/env luajit

-- Resolve .drp importer + command regression test

require('test_env')

local drp_importer = require("importers.drp_importer")
local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local blank_project = require("synthetic.helpers.blank_project")

local function assert_true(label, value)
    if not value then
        error(label .. " failed", 2)
    end
end

local function scalar(db, sql, param)
    local stmt = db:prepare(sql)
    assert_true("prepare failed for: " .. sql, stmt ~= nil)
    if param then
        stmt:bind_value(1, param)
    end
    assert_true("exec failed for: " .. sql, stmt:exec())
    local value = nil
    if stmt:next() then
        value = stmt:value(0)
    end
    stmt:finalize()
    return value
end

local test_env = require('test_env')
local fixture_path = test_env.require_fixture("tests/fixtures/resolve/sample_project.drp")

-- Validate raw parser behaviour
local parse_result = drp_importer.parse_drp_file(fixture_path)
assert_true("parse_drp_file success", parse_result and parse_result.success)
assert_true("project metadata present", parse_result.project ~= nil)
assert_true("project name", (parse_result.project.name or ""):len() > 0)
-- frame_rate propagated from first timeline when DRP lacks project-level TimelineFrameRate
assert_true("project frame rate", type(parse_result.project.settings.frame_rate) == "number" and parse_result.project.settings.frame_rate > 0)
assert_true("project settings present", parse_result.project.settings ~= nil)
assert_true("media items parsed", type(parse_result.media_items) == "table")
assert_true("has media items", next(parse_result.media_items) ~= nil)
assert_true("timelines parsed", type(parse_result.timelines) == "table")
assert_true("at least one timeline", #parse_result.timelines > 0)

local timeline = parse_result.timelines[1]
assert_true("timeline name", (timeline.name or ""):len() > 0)
assert_true("timeline has tracks", type(timeline.tracks) == "table" and #timeline.tracks > 0)
local track = timeline.tracks[1]
assert_true("track type", track.type == "VIDEO" or track.type == "AUDIO")
assert_true("track clips", type(track.clips) == "table" and #track.clips > 0)
local clip = track.clips[1]
assert_true("clip duration", clip.duration ~= nil)

-- Open a fresh project via the real OpenProject lifecycle so the .jvp is
-- non-empty (one default project + sequence from the template) — the
-- precondition needed to exercise ImportResolveProject's refusal path.
local info = blank_project.open_fresh("/tmp/jve/test_import_resolve_drp.jvp")

-- ImportResolveProject must REFUSE to run against a non-empty .jvp:
-- first-open of a .drp goes through OpenProject's convert path, which
-- writes a fresh single-project .jvp; this executor is reserved for
-- the genuinely-empty-DB case. The template above seeded one project,
-- so the assertion in the executor must fire.
local cmd = Command.create("ImportResolveProject", info.project_id)
cmd:set_parameter("drp_path", fixture_path)
cmd:set_parameter("audio_sample_rate", 48000)

local exec_result = command_manager.execute(cmd)
assert_true("execute returns a result", type(exec_result) == "table")
assert_true("execute against non-empty DB returns success=false",
    exec_result.success == false)
assert_true(
    "error message names the refusal",
    tostring(exec_result.error_message or "")
        :find("refuses to import into a non-empty .jvp", 1, true) ~= nil)

local db = database.get_connection()
local project_count = scalar(db, "SELECT COUNT(*) FROM projects")
assert_true("project count unchanged after refusal", project_count == 1)

-- Content-import coverage (tracks/clips/media populated correctly from
-- a .drp parse) lives in the _convert_drp_to_jvp tier:
--   tests/synthetic/binding/test_drp_converter_clip_creation.lua
--   tests/synthetic/binding/test_drp_import_marks.lua
--   tests/synthetic/binding/test_drp_reimport_stable_media_ids.lua
-- Don't duplicate that coverage here; this file pins the command-layer
-- contract (parse → refuse-non-empty), not the importer's output shape.

blank_project.cleanup("/tmp/jve/test_import_resolve_drp.jvp")
print("✅ Resolve .drp importer + command test passed")
