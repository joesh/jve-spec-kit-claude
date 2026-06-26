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

-- qt_get_cpu_info / qt_get_system_memory_mb / qt_get_uname /
-- qt_get_gpu_info_metal — production via hardware_bindings.{cpp,mm}.
-- Harness stubs return plausible synthetic values so telemetry-side
-- tests can drive register/heartbeat paths.
if not _G.qt_get_uname then
    _G.qt_get_uname = function()
        return { platform = "Darwin", os_version = "24.6.0", arch = "arm64" }
    end
end
if not _G.qt_get_cpu_info then
    _G.qt_get_cpu_info = function()
        return {
            model = "Apple M2 Pro (stub)",
            cores_physical = 10, cores_logical = 10,
            perf_cores = 8, eff_cores = 2,
        }
    end
end
if not _G.qt_get_system_memory_mb then
    _G.qt_get_system_memory_mb = function() return 32768 end
end
if not _G.qt_get_gpu_info_metal then
    _G.qt_get_gpu_info_metal = function()
        return {
            vendor = "Apple", model = "Apple M2 Pro GPU (stub)",
            memory_mb = 22016, api = "Metal", unified_memory = true,
        }
    end
end

-- qt_hmac_sha256 — production via crypto_bindings.cpp (OpenSSL HMAC).
-- Harness stubs via /usr/bin/openssl dgst -mac HMAC -macopt hexkey:<...>
-- so standalone luajit tests for transport.lua can drive HMAC paths.
if not _G.qt_hmac_sha256 then
    _G.qt_hmac_sha256 = function(key_hex, message)
        assert(type(key_hex) == "string" and key_hex:match("^%x+$"),
            "qt_hmac_sha256: key must be hex string")
        assert(type(message) == "string", "qt_hmac_sha256: message must be string")
        local tmppath = os.tmpname()
        local f = assert(io.open(tmppath, "wb"))
        f:write(message)
        f:close()
        local cmd = "/usr/bin/openssl dgst -sha256 -mac HMAC -macopt hexkey:" ..
            key_hex .. " < " .. tmppath
        local p = assert(io.popen(cmd))
        local line = p:read("*l")
        p:close()
        os.remove(tmppath)
        assert(line, "qt_hmac_sha256 stub: openssl produced no output")
        local hex = line:match("(%x+)%s*$")
        assert(hex and #hex == 64, "qt_hmac_sha256 stub: unexpected output " .. tostring(line))
        return hex
    end
end

-- qt_fs_remove_dir_recursive / qt_fs_listdir — production via
-- misc_bindings.cpp (QDir). Harness stubs use POSIX rm -rf / ls; the
-- bug_reporter exporter calls these to clean up per-capture
-- screenshots/ subdir before payload zips.
if not _G.qt_fs_remove_dir_recursive then
    _G.qt_fs_remove_dir_recursive = function(path)
        assert(type(path) == "string" and path ~= "",
            "qt_fs_remove_dir_recursive: path required")
        local rc = os.execute(string.format("/bin/rm -rf %q", path))
        if rc == 0 or rc == true then return true end
        return false, string.format("/bin/rm -rf exited %s", tostring(rc))
    end
end
if not _G.qt_fs_listdir then
    _G.qt_fs_listdir = function(path)
        assert(type(path) == "string" and path ~= "",
            "qt_fs_listdir: path required")
        local p = io.popen("/bin/ls -1A " .. string.format("%q", path) .. " 2>/dev/null")
        if not p then return nil, "popen failed" end
        local out = {}
        for line in p:lines() do out[#out + 1] = line end
        p:close()
        return out
    end
end

-- qt_get_build_info — production via misc_bindings.cpp returns the
-- generated JVE_GIT_SHA; harness stub returns a syntactically valid
-- 7-hex-char SHA so core.build_info loads without asserting. Tests
-- that need the actual SHA (none yet) can stub themselves.
if not _G.qt_get_build_info then
    _G.qt_get_build_info = function() return { git_sha = "0000000" } end
end

-- qt_monotonic_s — production via misc_bindings.cpp::lua_qt_monotonic_s
-- (chrono::steady_clock). Harness uses os.time + a synthetic offset so
-- the bug_reporter ring buffer can compute elapsed-ms. Tests that need
-- deterministic time injection monkey-patch _G.qt_monotonic_s directly
-- (e.g. test_bug_reporter_capture_monotonic). For tests that don't, the
-- real os.time gives them a real wall clock that survives across calls.
if not _G.qt_monotonic_s then
    local start = os.time()
    _G.qt_monotonic_s = function() return os.time() - start end
end

-- qt_sha256 — production via src/bug_reporter/crypto_bindings.cpp
-- (OpenSSL EVP_Digest). Harness stubs via /usr/bin/shasum -a 256 on a
-- temp file (handles arbitrary bytes including embedded NULs without
-- shell-escaping). Used by bug_reporter.signature and the worker
-- transport's payload hash.
if not _G.qt_sha256 then
    _G.qt_sha256 = function(s)
        assert(type(s) == "string", "qt_sha256: argument must be a string")
        local tmppath = os.tmpname()
        local f = assert(io.open(tmppath, "wb"))
        f:write(s)
        f:close()
        local p = assert(io.popen("/usr/bin/shasum -a 256 < " .. tmppath))
        local line = p:read("*l")
        p:close()
        os.remove(tmppath)
        assert(line, "qt_sha256 stub: shasum produced no output")
        local hex = line:match("^(%x+)")
        assert(hex and #hex == 64, "qt_sha256 stub: unexpected shasum line " .. tostring(line))
        return hex
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
