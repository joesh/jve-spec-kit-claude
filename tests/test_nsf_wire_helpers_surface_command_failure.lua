#!/usr/bin/env luajit

-- NSF: track-header button helpers (wire_toggle_preference,
-- wire_sync_mode_cycle, wire_waveform_display_toggle) dispatched commands
-- via command_manager.execute_interactive and discarded the return value.
-- A failed command produced a frozen button and an entry in the command
-- log — but no user-visible failure. NSF half-2 (output invariants):
-- "did the pipeline actually do what it claimed to do?". The click
-- handler must surface a loud failure when the dispatch returns
-- {success=false}, not silently shrug.

require("test_env")

print("=== test_nsf_wire_helpers_surface_command_failure.lua ===")

-- The helper that the wire_* callers use to dispatch + verify.
-- Extracted to make this contract testable without spinning up a Qt
-- widget hierarchy.
local dispatch = require("ui.timeline.dispatch_or_fail")
assert(type(dispatch.execute_or_fail) == "function",
    "dispatch_or_fail.execute_or_fail must exist (testable helper)")

-- ── Happy path: success result passes through ───────────────────────────
do
    package.loaded["core.command_manager"] = {
        execute_interactive = function(_name, _params) return true end,
    }
    local ok = pcall(dispatch.execute_or_fail, "FakeCommand", {}, "ctx")
    assert(ok, "FAIL: dispatch_or_fail must accept a `true` return as success")
end

do
    package.loaded["core.command_manager"] = {
        execute_interactive = function(_name, _params)
            return { success = true }
        end,
    }
    local ok = pcall(dispatch.execute_or_fail, "FakeCommand", {}, "ctx")
    assert(ok, "FAIL: dispatch_or_fail must accept {success=true} as success")
end

-- ── Error path: {success=false} must raise with actionable context ──────
do
    package.loaded["core.command_manager"] = {
        execute_interactive = function(_name, _params)
            return { success = false, error_message = "track is locked" }
        end,
    }
    local ok, err = pcall(dispatch.execute_or_fail,
        "ToggleTrackPreference", { track_id = "v1" }, "lock toggle click")
    assert(not ok, "FAIL: a {success=false} result must surface as a Lua error, "
        .. "not be silently swallowed by the click handler")
    assert(type(err) == "string", "FAIL: error must be a string, got " .. type(err))
    assert(err:find("ToggleTrackPreference"),
        "FAIL: error message must name the failing command; got: " .. err)
    assert(err:find("lock toggle click"),
        "FAIL: error message must include the caller's context tag; got: " .. err)
    assert(err:find("track is locked"),
        "FAIL: error message must include the underlying error_message; got: " .. err)
end

-- ── Error path: nil / falsy result must also surface ────────────────────
do
    package.loaded["core.command_manager"] = {
        execute_interactive = function(_name, _params) return nil end,
    }
    local ok, err = pcall(dispatch.execute_or_fail, "FakeCommand", {}, "ctx")
    assert(not ok, "FAIL: nil dispatch result must raise; the caller asked the "
        .. "command system to do something and got nothing back.")
    assert(err:find("FakeCommand"),
        "FAIL: error must name the command: " .. tostring(err))
end

print("  dispatch_or_fail surfaces command failures with full context — OK")
print("\n✅ test_nsf_wire_helpers_surface_command_failure.lua passed")
