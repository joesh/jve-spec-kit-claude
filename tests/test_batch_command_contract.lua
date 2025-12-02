-- Tests for BatchCommand Parameter Contract
-- Verifies that BatchCommand accepts JSON parameters as a string.

local function test_batch_command_contract()
    local CommandManager = require("core.command_manager")
    local Command = require("command")
    local database = require("core.database")
    local json = require("dkjson")

    print("=== BatchCommand Parameter Contract Tests ===")

    -- Setup database
    local db_path = "/tmp/jve/test_batch_command_contract.db"
    os.remove(db_path)
    
    -- Initialize database connection using set_path
    local ok = database.set_path(db_path)
    if not ok then
        print("❌ FAIL: Could not set database path")
        os.exit(1)
    end
    local db = database.get_connection()
    if not db then
        print("❌ FAIL: Could not get database connection")
        os.exit(1)
    end
    
    -- Load main schema for consistency
    db:exec(require('import_schema'))
    db:exec(string.format([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Test Project', %d, %d);
    ]], os.time(), os.time()))

    -- Initialize Command Manager
    CommandManager.init(db, "default_sequence", "default_project")

    -- Stub timeline_state
    local timeline_state = require("ui.timeline.timeline_state")
    timeline_state.get_playhead_position = function() return 0 end
    timeline_state.get_sequence_frame_rate = function() return 30 end
    timeline_state.get_sequence_id = function() return "default_sequence" end

    print("Test 1: BatchCommand accepts commands_json parameter")
    
    local sub_commands = {
        {
            command_type = "CreateSequence",
            project_id = "default_project",
            parameters = {
                name = "Test Sequence",
                project_id = "default_project",
                frame_rate = 30.0,
                width = 1920,
                height = 1080
            }
        }
    }
    
    local batch_cmd = Command.create("BatchCommand", "default_project")
    batch_cmd:set_parameter("commands_json", json.encode(sub_commands))
    
    local result = CommandManager.execute(batch_cmd)
    
    if result.success then
        print("✅ PASS: BatchCommand executed successfully")
    else
        print("❌ FAIL: BatchCommand rejected commands_json parameter")
        print("   Error: " .. tostring(result.error_message))
        os.exit(1)
    end
end

test_batch_command_contract()