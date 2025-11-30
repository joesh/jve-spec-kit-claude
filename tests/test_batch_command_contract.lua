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
    
    -- Bootstrap basic schema if needed
    db:exec([[
        CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT, settings TEXT, created_at INTEGER, modified_at INTEGER);
        CREATE TABLE IF NOT EXISTS sequences (id TEXT PRIMARY KEY, project_id TEXT, name TEXT, kind TEXT, fps_numerator INTEGER, fps_denominator INTEGER, width INTEGER, height INTEGER, timecode_start_frame INTEGER, playhead_frame INTEGER, view_start_frame INTEGER, view_duration_frames INTEGER, mark_in_frame INTEGER, mark_out_frame INTEGER, current_sequence_number INTEGER, audio_rate INTEGER, selected_clip_ids TEXT, selected_edge_infos TEXT);
        CREATE TABLE IF NOT EXISTS tracks (id TEXT PRIMARY KEY, sequence_id TEXT, name TEXT, track_type TEXT, track_index INTEGER, enabled BOOLEAN, locked BOOLEAN, muted BOOLEAN, soloed BOOLEAN, volume REAL, pan REAL, timebase_type TEXT, timebase_rate REAL);
        CREATE TABLE IF NOT EXISTS clips (id TEXT PRIMARY KEY, project_id TEXT, clip_kind TEXT, name TEXT, track_id TEXT, media_id TEXT, source_sequence_id TEXT, parent_clip_id TEXT, owner_sequence_id TEXT, start_value REAL, duration_value REAL, source_in_value REAL, source_out_value REAL, timebase_type TEXT, timebase_rate REAL, enabled BOOLEAN, offline BOOLEAN, created_at INTEGER, modified_at INTEGER);
        CREATE TABLE IF NOT EXISTS media (id TEXT PRIMARY KEY, project_id TEXT, file_path TEXT, name TEXT, duration_value REAL, frame_rate REAL, width INTEGER, height INTEGER, audio_channels INTEGER, codec TEXT, created_at INTEGER, modified_at INTEGER, metadata TEXT);
        CREATE TABLE IF NOT EXISTS commands (id TEXT PRIMARY KEY, parent_id TEXT, sequence_number INTEGER UNIQUE, command_type TEXT, command_args TEXT, parent_sequence_number INTEGER, pre_hash TEXT, post_hash TEXT, timestamp INTEGER, playhead_value REAL, playhead_rate REAL, selected_clip_ids TEXT, selected_edge_infos TEXT, selected_gap_infos TEXT, selected_clip_ids_pre TEXT, selected_edge_infos_pre TEXT, selected_gap_infos_pre TEXT);
    ]])

    -- Initialize Command Manager
    CommandManager.init(db, "default_sequence", "default_project")

    -- Create default project
    db:exec("INSERT INTO projects (id, name) VALUES ('default_project', 'Test Project')")

    -- Stub timeline_state
    local timeline_state = require("ui.timeline.timeline_state")
    timeline_state.get_playhead_value = function() return 0 end
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