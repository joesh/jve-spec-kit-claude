--- Tests' user-visible primitive for "fresh project lifecycle".
-- Mirrors the NewProject + OpenProject flow without the interactive dialog,
-- so a test exercises the SAME signal cascade a real user does.
--
-- Use INSTEAD OF: database.init(path) + raw INSERT INTO projects/sequences +
-- command_manager.init(seq, project). Direct database/command_manager init
-- bypasses the project_changed signal cascade and leaks state across tests
-- in a long-lived JVE (root cause of the batch_binding hang surfaced
-- 2026-05-29). See feedback_tests_drive_via_user_primitives memory.

local M = {}

local project_templates = require("core.project_templates")
local command_manager = require("core.command_manager")

local function pick_template(name)
    for _, t in ipairs(project_templates.TEMPLATES) do
        if t.name == name then return t end
    end
    error("blank_project: unknown template " .. tostring(name), 2)
end

-- Wipe a .jvp + its WAL/SHM siblings. Used both as pre-create cleanup
-- (so create_from_template's pre-existence assert doesn't trip on a
-- leftover from a prior test run) AND as the public end-of-test cleanup
-- (so tests don't pollute /tmp/jve with stale .jvp + WAL/SHM trails).
local function wipe(path)
    os.remove(path)
    os.remove(path .. "-shm")
    os.remove(path .. "-wal")
end

--- Remove the .jvp + its WAL/SHM siblings created by open_fresh.
--- Tests should call this at the end of their script to keep
--- /tmp/jve clean. The on-disk file removal is safe even with
--- JVE's connection still open (macOS keeps the inode alive until
--- the last fd closes; --test mode exits immediately after).
--- @param path string the same absolute path passed to open_fresh
function M.cleanup(path)
    assert(path and path ~= "", "blank_project.cleanup: path required")
    wipe(path)
end

--- Create a fresh `.jvp` from the named template and open it via OpenProject.
--- After this returns, JVE is in the state it would be in just after a user
--- picked File → New Project (template, name) then File → Open Project.
--- All project_will_change / project_changed handlers fire as on the real
--- path, so prior-test state is properly cleaned up by JVE itself.
---
--- @param path string absolute path for the new .jvp (will be wiped first)
--- @param opts table|nil { template_name="Film 24fps", project_name="Test Project" }
--- @return table { project_id=string, sequence_id=string, template=table }
---   `template` is the picked TEMPLATES entry so callers building
---   additional sequences via CreateSequence don't have to re-look it up.
function M.open_fresh(path, opts)
    assert(path and path ~= "", "blank_project.open_fresh: path required")
    opts = opts or {}
    local template_name = opts.template_name or "Film 24fps"
    local project_name = opts.project_name or "Test Project"

    wipe(path)
    local template = pick_template(template_name)

    project_templates.create_project_from_template(template, project_name, path)

    -- String form (not the Command object form) — command_manager.execute
    -- only honors `no_project_context` when given a name string; passing a
    -- Command object trips the active-project gate on cold start.
    local result = command_manager.execute("OpenProject", { project_path = path })
    assert(result and result.success,
        "blank_project.open_fresh: OpenProject failed: " ..
        tostring(result and result.error_message or "(no result)"))

    -- command_manager.execute normalizes the executor return to
    -- {success, error_message, result_data}; the project_id/sequence_id
    -- the executor returned are dropped. Read them from the just-
    -- initialized command_manager (post_open_init called .init on it).
    local project_id = command_manager.get_active_project_id()
    local sequence_id = command_manager.get_active_sequence_id()
    assert(project_id and project_id ~= "",
        "blank_project.open_fresh: OpenProject succeeded but active project_id is empty")
    return { project_id = project_id, sequence_id = sequence_id, template = template }
end

return M
