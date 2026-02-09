#!/usr/bin/env luajit

-- Test: All menu commands must have loadable executors
-- Regression: OpenProject was unexecutable because it requires no_project_context
-- but command_manager required active_project_id for all commands.

require("test_env")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

print("\n=== Menu Commands Loadable Test ===")

-- ---------------------------------------------------------------------------
-- Parse menus.xml to extract command names
-- ---------------------------------------------------------------------------

local function parse_menus_xml()
    local repo_root = os.getenv("PWD"):match("(.*/jve%-spec%-kit%-claude)") or "/Users/joe/Local/jve-spec-kit-claude"
    local xml_path = repo_root .. "/menus.xml"

    local f = io.open(xml_path, "r")
    if not f then
        error("Cannot open menus.xml at: " .. xml_path)
    end
    local content = f:read("*a")
    f:close()

    local commands = {}
    -- Match command="CommandName" in XML
    for cmd in content:gmatch('command="([^"]+)"') do
        commands[cmd] = true
    end
    return commands
end

-- Commands that are handled specially (not via command_manager.execute)
local DISPATCH_TABLE_COMMANDS = {
    Undo = true,
    Redo = true,
    Quit = true,
    Delete = true,
    Insert = true,
    Overwrite = true,
    Replace = true,
}

-- Commands that aren't implemented yet (should shrink over time)
local NOT_YET_IMPLEMENTED = {
    NewProject = true,
    SaveProject = true,
    SaveProjectAs = true,
    ExportFCP7XML = true,
    ExportPremiereXML = true,
    ExportEDL = true,
    ImportPremiereXML = true,
    ProjectSettings = true,
    Cut = true,
    Copy = true,
    Paste = true,
    SelectAll = true,
    DeselectAll = true,
    EditHistory = true,
    Nudge = true,
    ToggleClipEnabled = true,
    MatchFrame = true,
    RevealInFilesystem = true,
    RippleDelete = true,
    CloseGap = true,
    TimelineZoomIn = true,
    TimelineZoomOut = true,
    TimelineZoomFit = true,
    GoToStart = true,
    GoToEnd = true,
    GoToTimecode = true,
    NewBin = true,
    RenameItem = true,
    ShowRelinkDialog = true,
    ConsolidateMedia = true,
    TagMedia = true,
    ManageTags = true,
    ShowProjectBrowser = true,
    ShowTimeline = true,
    ShowInspector = true,
    ShowViewer = true,
    ToggleMaximizePanel = true,
    LoadWorkspace = true,
    SaveWorkspace = true,
    ManageWorkspaces = true,
    OpenUserManual = true,
    OpenShortcutsReference = true,
    ReportBug = true,
    CheckUpdates = true,
    ShowAbout = true,
    ShowKeyboardCustomization = true,
}

-- ---------------------------------------------------------------------------
-- Test: All non-dispatch commands have loadable executors
-- ---------------------------------------------------------------------------

print("\n--- Executor loading ---")

local registry = require("core.command_registry")
-- Initialize registry with a mock db
registry.init({}, function() end)

local commands = parse_menus_xml()
local tested = 0
local skipped_dispatch = 0
local skipped_unimplemented = 0

for cmd_name, _ in pairs(commands) do
    if DISPATCH_TABLE_COMMANDS[cmd_name] then
        skipped_dispatch = skipped_dispatch + 1
    elseif NOT_YET_IMPLEMENTED[cmd_name] then
        skipped_unimplemented = skipped_unimplemented + 1
    else
        tested = tested + 1
        local executor = registry.get_executor(cmd_name)
        check(cmd_name .. " has executor", executor ~= nil)

        if executor then
            local spec = registry.get_spec(cmd_name)
            check(cmd_name .. " has spec", spec ~= nil)
        end
    end
end

print(string.format("\nTested: %d, Dispatch-table: %d, Unimplemented: %d",
    tested, skipped_dispatch, skipped_unimplemented))

-- ---------------------------------------------------------------------------
-- Test: no_project_context commands are properly flagged
-- ---------------------------------------------------------------------------

print("\n--- no_project_context flag ---")

-- OpenProject must have no_project_context = true
do
    local spec = registry.get_spec("OpenProject")
    check("OpenProject spec exists", spec ~= nil)
    check("OpenProject has no_project_context", spec and spec.no_project_context == true)
end

-- ---------------------------------------------------------------------------
-- Test: no_project_context commands can normalize without active project
-- ---------------------------------------------------------------------------

print("\n--- Normalize without active project ---")

-- Set up minimal command_manager state (no active project)
local command_manager = require("core.command_manager")

-- Create a test database
local test_db_path = "/tmp/jve/test_menu_commands_" .. os.time() .. ".db"
os.execute("mkdir -p /tmp/jve")
os.execute("rm -f " .. test_db_path .. "*")

local database = require("core.database")
database.init(test_db_path)
local db = database.get_connection()

-- DON'T call command_manager.init - simulates no active project
-- command_manager.init(db, sequence_id, project_id)

-- Test that OpenProject can be called via execute_ui pattern
do
    -- Start a command event (required by normalize_command)
    command_manager.begin_command_event("ui")

    -- Try to execute OpenProject without an active project
    -- This should NOT fail at normalize_command stage
    local ok, result = pcall(function()
        return command_manager.execute("OpenProject", {
            interactive = false,
            project_path = "/tmp/nonexistent.jvp"
        })
    end)

    -- We expect the command to fail (file doesn't exist), but NOT because of project_id
    if not ok then
        local err_msg = tostring(result)
        -- These are acceptable failures (file/project issues, not project_id issues)
        local acceptable = err_msg:match("project_id") == nil
        check("OpenProject doesn't fail on project_id requirement", acceptable)
        if not acceptable then
            print("  Error was: " .. err_msg)
        end
    else
        -- Command ran (might have failed gracefully)
        check("OpenProject executed without project_id error", true)
    end

    command_manager.end_command_event()
end

-- Cleanup
os.execute("rm -f " .. test_db_path .. "*")

-- Summary
print(string.format("\n=== Menu Commands Loadable: %d passed, %d failed ===", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_menu_commands_loadable.lua passed")
