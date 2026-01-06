require("test_env")

local sqlite3 = require("core.sqlite3")
local json = require("dkjson")
local Command = require("command")

local tmp_db_path = os.tmpname() .. ".sqlite"
local db, err = sqlite3.open(tmp_db_path)
assert(db, err or "failed to open sqlite db")

assert(db:exec([[
    CREATE TABLE commands (
        id TEXT PRIMARY KEY,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        undo_group_id INTEGER,
        playhead_value INTEGER DEFAULT 0,
        playhead_rate REAL DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_gap_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]',
        selected_gap_infos_pre TEXT DEFAULT '[]'
    );
]]), "failed to create commands table")

local cmd = Command.create("TestPersistParams", "proj")
cmd.sequence_number = 1
cmd.executed_at = os.time()
cmd.playhead_value = 0
cmd.playhead_rate = { fps_numerator = 30, fps_denominator = 1 }
cmd:set_parameter("foo", "bar")
cmd:set_parameter("__preloaded_clip_snapshot", { clips = { { id = "c1" } } })
cmd:set_parameter("__timeline_active_region", { start = 10, finish = 20 })

assert(cmd:save(db), "expected command save to succeed")

local q = db:prepare("SELECT command_args FROM commands WHERE id = ?")
assert(q, "failed to prepare query")
q:bind_value(1, cmd.id)
assert(q:exec() and q:next(), "failed to read saved command row")

local args_json = q:value(0) or ""
q:finalize()

local decoded = json.decode(args_json)
assert(type(decoded) == "table", "expected command_args to decode to a table")
assert(decoded.foo == "bar", "expected non-ephemeral args to persist")
assert(decoded.__preloaded_clip_snapshot == nil, "expected __* args to be excluded from persistence")
assert(decoded.__timeline_active_region == nil, "expected __* args to be excluded from persistence")

local serialized = cmd:serialize()
assert(not serialized:match("__preloaded_clip_snapshot"), "expected serialize() to omit __* args")

db:close()
os.remove(tmp_db_path)

