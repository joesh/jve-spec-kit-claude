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

-- Production code calls qt_fs_mkdir_p (registered as a global by qt_bindings.cpp
-- in the editor). The harness runs under plain luajit with no Qt bindings, so
-- stub it via /bin/mkdir -p before any production module loads. (test_env.lua
-- provides the same stub for tests that require it directly, but many tests
-- don't.)
if not _G.qt_fs_mkdir_p then
    _G.qt_fs_mkdir_p = function(path)
        if type(path) ~= "string" or path == "" then
            return nil, "qt_fs_mkdir_p: path required"
        end
        local rc = os.execute(string.format("/bin/mkdir -p %q", path))
        if rc == 0 or rc == true then return true end
        return nil, string.format("/bin/mkdir -p exited %s", tostring(rc))
    end
end

-- qt_get_pid: production via misc_bindings.cpp::lua_qt_get_pid; harness
-- uses LuaJIT FFI getpid(2). project_open.our_pid() and the resolve_bridge
-- client both assert this is a function, so it must exist before any
-- production module loads.
if not _G.qt_get_pid then
    local ffi = require("ffi")
    pcall(ffi.cdef, "int getpid(void);")
    _G.qt_get_pid = function() return tonumber(ffi.C.getpid()) end
end

-- qt_thread_msleep / qt_fs_path_exists — production via misc_bindings.cpp
-- (QThread::msleep / QFileInfo::exists). Harness uses FFI usleep + /bin/test.
if not _G.qt_thread_msleep then
    local ffi = require("ffi")
    pcall(ffi.cdef, "int usleep(unsigned int usec);")
    _G.qt_thread_msleep = function(ms)
        assert(type(ms) == "number" and ms >= 0,
            "qt_thread_msleep: ms must be non-negative number")
        ffi.C.usleep(math.floor(ms * 1000))
    end
end
if not _G.qt_fs_path_exists then
    _G.qt_fs_path_exists = function(path)
        assert(type(path) == "string" and path ~= "",
            "qt_fs_path_exists: path must be non-empty string")
        local ok = os.execute(string.format("/bin/test -e %q", path))
        return ok == 0 or ok == true
    end
end

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
