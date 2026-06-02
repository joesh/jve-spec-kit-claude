#!/usr/bin/env luajit

-- Regression: importing an FCP7 XML should reuse existing media rows by
-- file_path. Undo must not delete pre-existing media rows that were merely
-- referenced.

local test_env = require("test_env")
local ui       = require("integration.ui_test_env")

_G.qt_create_single_shot_timer = function() end

print("=== test_import_reuses_existing_media_by_path ===")

local DB = "/tmp/jve/test_import_reuses_existing_media_by_path.jvp"
local _, info = ui.launch({
    db_path      = DB,
    project_name = "Default Project",
})

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Command         = require("command")
local fcp7_importer   = require("importers.fcp7_xml_importer")

local function scalar(sql, value)
    local db = database.get_connection()
    local stmt = assert(db:prepare(sql), "Failed to prepare: " .. sql)
    if value ~= nil then stmt:bind_value(1, value) end
    assert(stmt:exec() and stmt:next(), "Failed to execute scalar")
    local result = stmt:value(0) or 0
    stmt:finalize()
    return result
end

local function load_fixture_contents()
    local fixture_path = test_env.require_fixture(
        "tests/fixtures/resolve/sample_timeline_fcp7xml.xml")
    local handle = assert(io.open(fixture_path, "r"))
    local contents = assert(handle:read("*all"))
    handle:close()
    return contents
end

local function pick_any_media_path(xml_contents)
    local parsed = fcp7_importer.import_xml(nil, info.project.id,
        { xml_content = xml_contents })
    assert(parsed and parsed.success, "Fixture should parse successfully")
    for _, mfi in pairs(parsed.media_files or {}) do
        if mfi and mfi.path and mfi.path ~= "" then return mfi.path end
    end
    error("Fixture contained no media file paths")
end

local xml_contents = load_fixture_contents()
local existing_path = pick_any_media_path(xml_contents)

-- Seed a media row at existing_path. The importer should adopt this row
-- (by file_path match) rather than create a duplicate, and undo must
-- leave it intact.
do
    local db = database.get_connection()
    local stmt = assert(db:prepare([[
        INSERT INTO media (
            id, project_id, name, file_path,
            duration_frames, fps_numerator, fps_denominator,
            width, height, audio_channels, codec,
            created_at, modified_at, metadata
        )
        VALUES (
            'media_existing', ?, 'Existing Media', ?,
            12000, 30000, 1001,
            1920, 1080, 0, '',
            0, 0, '{"start_tc_value":0,"start_tc_rate":30}'
        );
    ]]))
    stmt:bind_value(1, info.project.id)
    stmt:bind_value(2, existing_path)
    assert(stmt:exec(), stmt:last_error() or "Failed to insert pre-existing media")
    stmt:finalize()
end

command_manager.activate_timeline_stack(info.sequences[1].id)

local import_cmd = Command.create("ImportFCP7XML", info.project.id)
import_cmd:set_parameter("project_id", info.project.id)
import_cmd:set_parameter("xml_path", "<memory>")
import_cmd:set_parameter("xml_contents", xml_contents)

local exec_result = command_manager.execute(import_cmd)
assert(exec_result.success,
    exec_result.error_message or "ImportFCP7XML should succeed")

local import_record = command_manager.get_last_command(info.project.id)
assert(import_record, "Import command should be present after execute")

local created_media_ids = import_record:get_parameter("created_media_ids") or {}
for _, media_id in ipairs(created_media_ids) do
    assert(media_id ~= "media_existing",
        "Importer should not mark pre-existing media as created")
end

local referenced = scalar([[
    SELECT COUNT(*) FROM clips c
    WHERE EXISTS (
        SELECT 1 FROM media_refs mr
        WHERE mr.owner_sequence_id = c.sequence_id
          AND mr.media_id = ?
    )
]], "media_existing")
assert(referenced > 0,
    "Imported clips should reference the pre-existing media row")

assert(command_manager.undo().success, "Undo import should succeed")
assert(scalar("SELECT COUNT(*) FROM media WHERE id = ?", "media_existing") == 1,
    "Undo import must not delete pre-existing media rows")

print("✅ ImportFCP7XML reuses existing media by file_path and undo preserves it")
