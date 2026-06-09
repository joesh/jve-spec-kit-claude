#!/usr/bin/env luajit

-- NSF: command_manager.execute_interactive returns either `true`,
-- `{success=true}`, `{success=false, error_message=...}`, or nil — and
-- callers (notably the track-header wire_* helpers) used to discard the
-- result. A failed command produced a frozen button with no user-visible
-- failure (NSF half-2: did the pipeline actually do what it claimed?).
-- command_dispatch.execute_or_fail is the testable seam used by every
-- such caller; this test pins its contract.

require("test_env")

print("=== test_nsf_command_dispatch.lua ===")

local command_dispatch = require("core.command_dispatch")
assert(type(command_dispatch.execute_or_fail) == "function",
    "command_dispatch.execute_or_fail must be exported")

-- Stub command_manager per case. `require("core.command_manager")` is
-- called inside execute_or_fail, so each stub is picked up at call time.
local function stub_dispatch_returning(return_value)
    package.loaded["core.command_manager"] = {
        execute_interactive = function(_name, _params) return return_value end,
    }
end

-- ── Happy path: success results pass through ─────────────────────────────
stub_dispatch_returning(true)
assert(pcall(command_dispatch.execute_or_fail, "FakeCommand", {}, "ctx"),
    "FAIL: `true` return must be accepted as success")

stub_dispatch_returning({ success = true })
assert(pcall(command_dispatch.execute_or_fail, "FakeCommand", {}, "ctx"),
    "FAIL: {success=true} must be accepted as success")

-- ── Error path: {success=false} surfaces with actionable context ────────
stub_dispatch_returning({ success = false, error_message = "track is locked" })
local ok, err = pcall(command_dispatch.execute_or_fail,
    "ToggleTrackPreference", { track_id = "v1" }, "lock toggle click")
assert(not ok, "FAIL: {success=false} must surface as a Lua error, not be "
    .. "silently swallowed")
assert(type(err) == "string", "FAIL: error must be a string, got " .. type(err))
assert(err:find("ToggleTrackPreference"),
    "FAIL: error must name the failing command; got: " .. err)
assert(err:find("lock toggle click"),
    "FAIL: error must include the caller's context tag; got: " .. err)
assert(err:find("track is locked"),
    "FAIL: error must include the underlying error_message; got: " .. err)

-- ── Error path: nil result also surfaces ────────────────────────────────
stub_dispatch_returning(nil)
local ok2, err2 = pcall(command_dispatch.execute_or_fail, "FakeCommand", {}, "ctx")
assert(not ok2, "FAIL: nil result must raise — the caller asked the command "
    .. "system to do something and got nothing back")
assert(err2:find("FakeCommand"),
    "FAIL: error must name the command: " .. tostring(err2))

-- ── Input validation: missing command_name / context_tag asserts ────────
stub_dispatch_returning(true)
assert(not pcall(command_dispatch.execute_or_fail, "", {}, "ctx"),
    "FAIL: empty command_name must assert")
assert(not pcall(command_dispatch.execute_or_fail, "FakeCommand", {}, ""),
    "FAIL: empty context_tag must assert")
assert(not pcall(command_dispatch.execute_or_fail, "FakeCommand", {}, nil),
    "FAIL: nil context_tag must assert")

print("  command_dispatch.execute_or_fail surfaces failures with full context — OK")
print("\n✅ test_nsf_command_dispatch.lua passed")
