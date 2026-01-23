#!/usr/bin/env luajit

-- Set up LUA_PATH before any requires
-- Determine root directory from this file's location (tests/test_harness.lua)
local function get_root_dir()
    local info = debug.getinfo(1, "S")
    local path = info.source:match("@?(.+)")
    if path then
        -- Remove filename to get tests/ directory, then go up one level
        local tests_dir = path:match("(.+)[/\\]") or "."
        local root = tests_dir:match("(.+)[/\\]") or ".."
        return root
    end
    return ".."
end

local root = get_root_dir()
package.path = root .. "/src/lua/?.lua;"
    .. root .. "/src/lua/?/init.lua;"
    .. root .. "/tests/?.lua;"
    .. root .. "/tests/?/init.lua;"
    .. package.path

-- Now we can require modules
local command_manager = require("core.command_manager")

if rawget(_G, "__JVE_TEST_HARNESS_RUNNING") then
    return
end
_G.__JVE_TEST_HARNESS_RUNNING = true


if command_manager.peek_command_event_origin and not command_manager.peek_command_event_origin() then
    command_manager.begin_command_event("script")
end

local script = arg and arg[1]
if not script or script == "" then
    return
end

local self = debug.getinfo(1, "S").source
if self and self:sub(1, 1) == "@" then
    self = self:sub(2)
end

local self_base = self and self:match("([^/\\]+)$")
local script_base = script:match("([^/\\]+)$")

if self_base and script_base and script_base == self_base then
    return
end

dofile(script)
