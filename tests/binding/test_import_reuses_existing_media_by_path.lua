#!/usr/bin/env luajit

-- Regression: importing an FCP7 XML should reuse existing media rows by file_path.
-- Undo must not delete pre-existing media rows that were merely referenced.
-- Uses REAL timeline_state — no mock.

require("test_env")

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local test_env = require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local fcp7_importer = require("importers.fcp7_xml_importer")

local SCHEMA_SQL = require("import_schema")

local function exec(db, sql)
    local ok, err = db:exec(sql)
    assert(ok, err)
end

local function scalar(db, sql, value)
    local stmt = assert(db:prepare(sql), "Failed to prepare statement")
    if value ~= nil then
        stmt:bind_value(1, value)
    end
    assert(stmt:exec() and stmt:next(), "Failed to execute scalar query")
    local result = stmt:value(0) or 0
    stmt:finalize()
    return result
end

local function load_fixture_contents()
    local fixture_path = test_env.resolve_repo_path("tests/fixtures/resolve/sample_timeline_fcp7xml.xml")
    local handle = assert(io.open(fixture_path, "r"))
    local contents = assert(handle:read("*all"))
    handle:close()
    return contents
end

local function pick_any_media_path(xml_contents)
    local parsed = fcp7_importer.import_xml(nil, "default_project", {xml_content = xml_contents})
    assert(parsed and parsed.success, "Fixture should parse successfully")
    for _, info in pairs(parsed.media_files or {}) do
        if info and info.path and info.path ~= "" then
            return info.path
        end
    end
    error("Fixture contained no media file paths")
end

local TEST_DB = "/tmp/jve/test_import_reuses_existing_media_by_path.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")
assert(database.init(TEST_DB))
local db = database.get_connection()

exec(db, SCHEMA_SQL)
exec(db, [[INSERT OR IGNORE INTO tag_namespaces(id, display_name) VALUES('bin', 'Bins');]])
exec(db, [[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'default_sequence', 'default_project', 'Default', 'timeline',
        30, 1, 48000,
        1920, 1080,
        0, 300, 0,
        '[]', '[]', '[]',
        0, strftime('%s','now'), strftime('%s','now')
    );
]])

local xml_contents = load_fixture_contents()
local existing_path = pick_any_media_path(xml_contents)

do
    local stmt = assert(db:prepare([[
        INSERT INTO media (
            id, project_id, name, file_path,
            duration_frames, fps_numerator, fps_denominator,
            width, height, audio_channels, codec,
            created_at, modified_at, metadata
        )
        VALUES (
            'media_existing', 'default_project', 'Existing Media', ?,
            1, 30000, 1001,
            1920, 1080, 0, '',
            strftime('%s','now'), strftime('%s','now'), '{}'
        );
    ]]))
    stmt:bind_value(1, existing_path)
    assert(stmt:exec(), stmt:last_error() or "Failed to insert pre-existing media")
    stmt:finalize()
end

-- Init with REAL timeline_state (reads from DB)
command_manager.init("default_sequence", "default_project")
command_manager.activate_timeline_stack("default_sequence")

local import_cmd = Command.create("ImportFCP7XML", "default_project")
import_cmd:set_parameter("project_id", "default_project")
import_cmd:set_parameter("xml_path", "<memory>")
import_cmd:set_parameter("xml_contents", xml_contents)

local exec_result = command_manager.execute(import_cmd)
assert(exec_result.success, exec_result.error_message or "ImportFCP7XML should succeed")

local import_record = command_manager.get_last_command("default_project")
assert(import_record, "Import command should be present after execute")

local created_media_ids = import_record:get_parameter("created_media_ids") or {}
for _, media_id in ipairs(created_media_ids) do
    assert(media_id ~= "media_existing", "Importer should not mark pre-existing media as created")
end

local referenced = scalar(db, "SELECT COUNT(*) FROM clips WHERE media_id = ?", "media_existing")
assert(referenced > 0, "Imported clips should reference the pre-existing media row")

assert(command_manager.undo().success, "Undo import should succeed")

local remaining_media = scalar(db, "SELECT COUNT(*) FROM media WHERE id = ?", "media_existing")
assert(remaining_media == 1, "Undo import must not delete pre-existing media rows")

os.remove(TEST_DB)
print("✅ ImportFCP7XML reuses existing media by file_path and undo preserves it")
