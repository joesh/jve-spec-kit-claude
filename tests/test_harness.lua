#!/usr/bin/env luajit

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
