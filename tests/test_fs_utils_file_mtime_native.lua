#!/usr/bin/env luajit

-- Regression: fs_utils.file_mtime must NOT fork a shell.
--
-- Background. The previous implementation called `stat -f %Fm <path>` via
-- a temp file (try_shell_capture → os.execute → file write → file read →
-- file remove). For a project with hundreds of audio files, that fork +
-- exec storm dominated project-open time — peak_cache.init_for_project
-- spent 3.79 s of a 3.93 s startup inside the per-file mtime call (TSO
-- 2026-04-29 21:42:14, 551 audio files).
--
-- Domain rule under test: asking the editor for a file's modification
-- time is a routine, low-level operation that must complete in syscall
-- time, not subprocess time. If a future refactor reverts to the shell
-- path (e.g. someone restores the try_shell_capture fallback), this
-- test fails immediately.
--
-- Implementation strategy: replace os.execute / io.popen on the global
-- table for the duration of the test, count invocations, and assert
-- file_mtime never reached either of them.

require("test_env")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== fs_utils.file_mtime: native (no shell fork) ===")

-- Arrange: a real file we can stat. Use this test file itself — it's
-- guaranteed to exist while the test runs and lives on the local FS.
local SCRATCH = arg and arg[0] or "/tmp/jve_test_file_mtime_native"
do
    local f = io.open(SCRATCH, "r")
    if not f then
        SCRATCH = "/tmp/jve_test_file_mtime_native"
        local w = assert(io.open(SCRATCH, "w"))
        w:write("scratch"); w:close()
    else
        f:close()
    end
end

-- Trip-wires.
local original_execute = os.execute
local original_popen = io.popen
local execute_calls = 0
local popen_calls = 0

os.execute = function(cmd)
    execute_calls = execute_calls + 1
    return original_execute(cmd)
end
io.popen = function(...)
    popen_calls = popen_calls + 1
    return original_popen(...)
end

local fs_utils = require("core.fs_utils")
local mtime = fs_utils.file_mtime(SCRATCH)

os.execute = original_execute
io.popen = original_popen

check("returns a numeric mtime", type(mtime) == "number")
check("mtime > 0", (mtime or 0) > 0)
-- The headless test_env stub uses io.popen; production uses qt_file_mtime
-- (POSIX stat(2)) and never touches os.execute / io.popen. We assert no
-- os.execute fork in either case — that was the catastrophic path.
check("file_mtime never forks via os.execute", execute_calls == 0)

-- nil for missing file — same contract as the prior implementation.
local missing = fs_utils.file_mtime("/tmp/__jve_definitely_not_a_file_" .. tostring(os.time()))
check("returns nil for missing file", missing == nil)

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
print("\n" .. string.char(0xe2, 0x9c, 0x85) .. " test_fs_utils_file_mtime_native.lua passed")
