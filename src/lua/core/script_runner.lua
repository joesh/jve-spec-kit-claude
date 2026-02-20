--- Script runner for automated JVE control
--
-- Loads and executes a Lua script after the app finishes initializing.
-- Triggered by JVE_SCRIPT env var pointing to a .lua file.
--
-- Scripts run in the app's Lua state with full access to modules.
--
-- Usage:
--   JVE_SCRIPT=/tmp/jve/script.lua ./build/bin/JVEEditor
--
-- Scripts can use:
--   require("core.command_manager").execute("CommandName", {params})
--   require("core.command_manager").execute("Quit")
--   require("core.lua_profiler").start() / .stop()
--   qt_create_single_shot_timer(ms, callback)
--
-- @file script_runner.lua
local M = {}

function M.run(script_path)
    assert(type(script_path) == "string" and script_path ~= "",
        "script_runner.run: script_path must be a non-empty string")

    io.stderr:write("[script_runner] Loading: " .. script_path .. "\n")

    local chunk, load_err = loadfile(script_path)
    if not chunk then
        io.stderr:write("[script_runner] LOAD ERROR: " .. tostring(load_err) .. "\n")
        return false
    end

    local ok, err = xpcall(chunk, debug.traceback)
    if not ok then
        io.stderr:write("[script_runner] EXEC ERROR:\n" .. tostring(err) .. "\n")
        return false
    end

    io.stderr:write("[script_runner] Script chunk returned\n")
    return true
end

return M
