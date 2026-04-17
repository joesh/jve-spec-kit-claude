--- On-demand bug capture: DB snapshot + recent commands + logger tail.
--
-- @file bug_capture.lua
local log = require("core.logger").for_area("commands")
local time_utils = require("core.time_utils")
local dkjson = require("dkjson")

local M = {}

local RECENT_COMMAND_LIMIT = 50

local function bugs_dir()
    local db = require("core.database")
    local project_path = db.get_path()
    assert(project_path, "bug_capture: no project open")
    local project_dir = project_path:match("(.*/)")
    assert(project_dir, "bug_capture: cannot derive directory from " .. project_path)
    return project_dir .. "bugs"
end

local function mkdir_p(dir)
    local ok = os.execute(string.format("mkdir -p %q", dir))
    assert(ok == true or ok == 0,
        "bug_capture: failed to create directory: " .. dir)
end

local function copy_file(src, dst)
    local ok = os.execute(string.format("cp %q %q", src, dst))
    assert(ok == true or ok == 0,
        string.format("bug_capture: failed to copy %s → %s", src, dst))
end

local function dump_recent_commands(db, capture_dir)
    local conn = db.get_connection()
    assert(conn, "bug_capture.dump_recent_commands: no database connection")

    local stmt = conn:prepare(string.format(
        "SELECT sequence_number, command_type, command_args, timestamp, " ..
        "pre_hash, post_hash, sequence_id " ..
        "FROM commands ORDER BY sequence_number DESC LIMIT %d",
        RECENT_COMMAND_LIMIT))
    assert(stmt, "bug_capture.dump_recent_commands: failed to prepare query")

    local commands = {}
    while stmt:step() do
        table.insert(commands, {
            sequence_number = stmt:value(0),
            command_type    = stmt:value(1),
            command_args    = stmt:value(2),
            timestamp       = stmt:value(3),
            pre_hash        = stmt:value(4),
            post_hash       = stmt:value(5),
            sequence_id     = stmt:value(6),
        })
    end
    stmt:close()

    local json_str = assert(dkjson.encode(commands, { indent = true }))
    local path = capture_dir .. "/recent_commands.json"
    local f = assert(io.open(path, "w"))
    f:write(json_str)
    f:close()
    return path
end

local function capture_logger_tail(capture_dir)
    local captures_dir = os.getenv("HOME")
    if not captures_dir then return nil end
    captures_dir = captures_dir .. "/.jve"
    local log_path = captures_dir .. "/jve.log"
    local f = io.open(log_path, "r")
    if not f then return nil end
    f:close()

    local tail_path = capture_dir .. "/logger_tail.txt"
    os.execute(string.format("tail -c 1048576 %q > %q", log_path, tail_path))
    return tail_path
end

function M.capture(opts)
    opts = opts or {}
    local db = require("core.database")
    assert(db.has_connection(), "bug_capture.capture: no database connection")

    local stamp = time_utils.human_datestamp_for_filename(os.time())
    local base = bugs_dir()
    local capture_dir = base .. "/" .. stamp
    mkdir_p(capture_dir)

    local project_path = db.get_path()
    copy_file(project_path, capture_dir .. "/project.jvp")

    local wal = project_path .. "-wal"
    local f_wal = io.open(wal, "r")
    if f_wal then
        f_wal:close()
        copy_file(wal, capture_dir .. "/project.jvp-wal")
    end

    dump_recent_commands(db, capture_dir)

    capture_logger_tail(capture_dir)

    if opts.description or opts.error_message then
        local meta = {
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            description = opts.description,
            error_message = opts.error_message,
            stack_trace = opts.stack_trace,
        }
        local meta_json = assert(dkjson.encode(meta, { indent = true }))
        local mf = assert(io.open(capture_dir .. "/metadata.json", "w"))
        mf:write(meta_json)
        mf:close()
    end

    log.event("Bug captured: %s", capture_dir)
    return capture_dir
end

return M
