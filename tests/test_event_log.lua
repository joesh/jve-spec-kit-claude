local db = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

local tmp_project = os.tmpname() .. ".jvp"
assert(db.set_path(tmp_project), "Failed to initialize database for event log test")

local db_conn = db.get_connection()
db_conn:exec([[
    CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}'
    );

    CREATE TABLE IF NOT EXISTS sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'timeline',
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start INTEGER NOT NULL DEFAULT 0,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        viewport_start_time INTEGER NOT NULL DEFAULT 0,
        viewport_duration INTEGER NOT NULL DEFAULT 10000,
        mark_in_time INTEGER,
        mark_out_time INTEGER,
        current_sequence_number INTEGER
    );

   CREATE TABLE IF NOT EXISTS tracks (
       id TEXT PRIMARY KEY,
       sequence_id TEXT NOT NULL,
       name TEXT NOT NULL,
       track_type TEXT NOT NULL,
       track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        locked INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        soloed INTEGER NOT NULL DEFAULT 0,
        volume REAL NOT NULL DEFAULT 1.0,
        pan REAL NOT NULL DEFAULT 0.0
    );

    CREATE TABLE IF NOT EXISTS clips (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        clip_kind TEXT NOT NULL DEFAULT 'timeline',
        name TEXT DEFAULT '',
        track_id TEXT,
        media_id TEXT,
        source_sequence_id TEXT,
        parent_clip_id TEXT,
        owner_sequence_id TEXT,
        start_time INTEGER NOT NULL,
        duration INTEGER NOT NULL,
        source_in INTEGER NOT NULL,
        source_out INTEGER NOT NULL,
        enabled BOOLEAN DEFAULT 1,
        offline BOOLEAN DEFAULT 0
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
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]'
    );
]])

db_conn:exec([[
    INSERT OR IGNORE INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT OR IGNORE INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Default Sequence', 30.0, 1920, 1080);
]])

command_manager.init(db_conn, 'default_sequence', 'default_project')

local function cleanup()
    command_manager.unregister_executor("TestLogEvent")
    os.remove(tmp_project)
    os.execute(string.format('rm -rf "%s"', event_dir))
end

command_manager.register_executor("TestLogEvent", function(command)
    command:set_parameter("foo", "bar")
    return true
end)

local command = Command.create("TestLogEvent", "default_project")
command:set_parameter("foo", "bar")
command:set_parameter("__skip_timeline_reload", true)
command:set_parameter("__skip_selection_snapshot", true)

local result = command_manager.execute(command)
assert(result and result.success, "Expected TestLogEvent command to succeed")

local event_dir = tmp_project .. ".events"
local log_path = event_dir .. "/events/events.jsonl"

local log_file = io.open(log_path, "r")
assert(log_file, "Event log file was not created")
local log_contents = log_file:read("*a")
log_file:close()

assert(log_contents:match("TestLogEvent"), "Event log missing command entry")

cleanup()
