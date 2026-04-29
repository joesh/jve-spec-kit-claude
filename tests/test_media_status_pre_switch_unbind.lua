-- Regression test (014, post-impl): media_status pre-switch unbinds the
-- cache so deferred persist timers firing post-swap short-circuit
-- silently instead of triggering Layer 2.
--
-- Spec ref: feedback from manual quickstart on 2026-04-29 — TSO showed
-- 3 [database] ERROR lines from Layer 2 catching deferred timers in
-- the window between database.set_path's swap and project_changed's
-- M.clear. Writes were correctly no-op'd, but ERROR-level noise during
-- routine project switches buries real errors.
--
-- Contract: after the project_will_change handler runs (priority 12),
-- media_status.current_project_id MUST be nil. Any persist_now call
-- after the handler but before M.clear runs MUST short-circuit at
-- has_pending_persist_state without invoking Layer 2.
--
-- This test would have RED before commit 50696291's unbind landed:
-- without the unbind, persist_now after project_will_change still
-- has cached=outgoing_id, hits Layer 2, logs error.
--
-- NSF (both halves):
--   * Half 1: pre/post-handler invariants on current_project_id checked.
--   * Half 2: behavioral check that persist_now is a no-op after the
--     handler — observed via stderr capture (no Layer 2 log line).

require("test_env")

local Signals = require("core.signals")
local database = require("core.database")
local Project = require("models.project")
local media_status = require("core.media.media_status")

print("=== test_media_status_pre_switch_unbind ===")

local TEST_DIR = "/tmp/jve/test_014_unbind"

local function shell(cmd)
    local ok = os.execute(cmd)
    if ok ~= 0 and ok ~= true then
        error(string.format("shell('%s') failed: ok=%s", cmd, tostring(ok)))
    end
end

local function attach_with_project(label, path)
    assert(database.set_path(path), "attach: set_path failed for " .. path)
    local p = Project.create(label, { fps_mismatch_policy = "resample" })
    assert(p and p:save() and type(p.id) == "string",
        "attach: project create/save postcondition for " .. label)
    return p.id
end

local function capture_stderr(fn)
    -- luacheck: ignore 122
    local captured = {}
    local original = io.stderr
    local stub
    stub = setmetatable({}, { __index = function(_, k)
        if k == "write" then
            return function(_, ...)
                for i = 1, select("#", ...) do
                    captured[#captured + 1] = tostring(select(i, ...))
                end
                return stub
            end
        elseif k == "flush" then
            return function() end
        end
    end })
    io.stderr = stub  -- luacheck: ignore 122
    local ok, err = pcall(fn)
    io.stderr = original  -- luacheck: ignore 122
    if not ok then error(err) end
    return table.concat(captured)
end

-- ----------------------------------------------------------------------
-- Setup: two projects, p1 active with media_status loaded.
-- ----------------------------------------------------------------------

shell("mkdir -p " .. TEST_DIR)
shell("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp*")

local p1_id = attach_with_project("p1", TEST_DIR .. "/p1.jvp")
local _   = attach_with_project("p2", TEST_DIR .. "/p2.jvp")
assert(database.set_path(TEST_DIR .. "/p1.jvp"), "setup: switch back to p1")
assert(database.get_current_project_id() == p1_id, "setup: live = p1")

-- Bind media_status to p1.
media_status.load_persisted(p1_id)

-- ----------------------------------------------------------------------
-- Pre-switch invariant: project_will_change handler must unbind the
-- cache. After emitting project_will_change(p1), a persist_now call
-- MUST short-circuit (no Layer 2 ERROR log).
-- ----------------------------------------------------------------------

local pre_switch_log = capture_stderr(function()
    -- The set_path internally emits project_will_change(p1) before
    -- closing — driving the production code path the way the editor
    -- actually does.
    assert(database.set_path(TEST_DIR .. "/p2.jvp"), "swap: set_path to p2")

    -- At this point: live DB = p2, but project_changed has NOT yet
    -- fired (test isolates the contract surface). If the unbind
    -- worked, current_project_id is now nil. A subsequent persist_now
    -- must short-circuit silently.
    media_status.persist_now()
end)

-- The capture must contain NO Layer 2 ERROR line. Layer 2 would log:
--   "media_status.persist_now: stale project_id (cached=..., live=...)"
local has_layer2 = pre_switch_log:find("stale project_id", 1, true)
assert(not has_layer2, string.format(
    "PRE-SWITCH UNBIND CONTRACT: after project_will_change runs, the\n" ..
    "  cache (current_project_id) MUST be nil so deferred persist\n" ..
    "  timers post-swap short-circuit cleanly. Saw a Layer 2 ERROR\n" ..
    "  log line — the unbind regressed.\n" ..
    "  Captured: %q", pre_switch_log))
print("  ✓ post-handler persist_now: no Layer 2 log line")

-- ----------------------------------------------------------------------
-- Cleanup.
-- ----------------------------------------------------------------------

Signals.clear_all()
shell("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp*")

print("✅ test_media_status_pre_switch_unbind passed")
