--- Lua wrapper for the projects table. Keeps parity with the modern Lua-first architecture.
local database = require("core.database")
local uuid = require("uuid")

local Project = {}
Project.__index = Project

local function resolve_db(db)
    if db then
        return db
    end
    local conn = database.get_connection()
    if not conn then
        error("Project: No database connection available")
    end
    return conn
end

local function ensure_settings_json(settings)
    if type(settings) == "string" and settings ~= "" then
        return settings
    end
    return "{}"
end

function Project.create(name, opts)
    assert(name and name ~= "", "Project.create: name is required")

    opts = opts or {}
    local now = os.time()

    -- Rule 2.13 / data-model.md: projects.fps_mismatch_policy is NOT NULL
    -- with no schema default. Caller must pick a valid value at create time.
    assert(opts.fps_mismatch_policy == "resample"
        or opts.fps_mismatch_policy == "passthrough", string.format(
        "Project.create: opts.fps_mismatch_policy must be 'resample' or "
        .. "'passthrough' (V13 NOT NULL); got %s",
        tostring(opts.fps_mismatch_policy)))

    local project = {
        id = opts.id or uuid.generate(),
        name = name,
        fps_mismatch_policy = opts.fps_mismatch_policy,
        settings = ensure_settings_json(opts.settings),
        created_at = opts.created_at or now,
        modified_at = opts.modified_at or now
    }

    return setmetatable(project, Project)
end

function Project.create_with_id(id, name, opts)
    opts = opts or {}
    opts.id = id
    return Project.create(name, opts)
end

function Project.load(id, db)
    assert(id and id ~= "", "Project.load: id is required")

    local conn = resolve_db(db)
    if not conn then
        return nil
    end

    local stmt = conn:prepare(
        "SELECT id, name, fps_mismatch_policy, created_at, modified_at, settings "
        .. "FROM projects WHERE id = ?")
    assert(stmt, "Project.load: failed to prepare query")

    stmt:bind_value(1, id)

    if not stmt:exec() then
        local err = stmt:last_error()
        stmt:finalize()
        error(string.format("Project.load: query failed for %s: %s", id, tostring(err)))
    end

    if not stmt:next() then
        stmt:finalize()
        return nil
    end

    local project = {
        id = stmt:value(0),
        name = stmt:value(1),
        fps_mismatch_policy = stmt:value(2),
        created_at = stmt:value(3),
        modified_at = stmt:value(4),
        settings = ensure_settings_json(stmt:value(5))
    }

    stmt:finalize()

    return setmetatable(project, Project)
end

function Project:save(db)
    assert(self and self.id and self.id ~= "", "Project.save: invalid project or missing id")
    assert(self.name and self.name ~= "", "Project.save: name is required")
    assert(self.fps_mismatch_policy == "resample"
        or self.fps_mismatch_policy == "passthrough", string.format(
        "Project.save: fps_mismatch_policy must be 'resample' or 'passthrough' "
        .. "(V13 NOT NULL); got %s on project %s",
        tostring(self.fps_mismatch_policy), tostring(self.id)))

    local conn = resolve_db(db)
    if not conn then
        return false
    end

    self.created_at = self.created_at or os.time()
    self.modified_at = os.time()
    self.settings = ensure_settings_json(self.settings)

    -- CRITICAL: Use ON CONFLICT DO UPDATE instead of INSERT OR REPLACE
    -- INSERT OR REPLACE triggers DELETE first, which cascades to delete sequences/clips via foreign keys!
    local stmt = conn:prepare([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            fps_mismatch_policy = excluded.fps_mismatch_policy,
            modified_at = excluded.modified_at,
            settings = excluded.settings
    ]])

    assert(stmt, "Project.save: failed to prepare insert statement")

    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.name)
    stmt:bind_value(3, self.fps_mismatch_policy)
    stmt:bind_value(4, self.created_at)
    stmt:bind_value(5, self.modified_at)
    stmt:bind_value(6, self.settings)

    local ok = stmt:exec()
    if not ok then
        local err = stmt:last_error()
        stmt:finalize()
        error(string.format("Project.save: failed for %s: %s", tostring(self.id), tostring(err)))
    end

    stmt:finalize()
    return ok
end

-- Count all projects in the database
function Project.count()
    local conn = assert(database.get_connection(), "Project.count: no database connection")
    local stmt = assert(conn:prepare("SELECT COUNT(*) FROM projects"), "Project.count: failed to prepare query")
    assert(stmt:exec(), "Project.count: query execution failed")
    assert(stmt:next(), "Project.count: no result row")
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

--- Replace project identity (id + name) in a template database.
-- Used by project_templates to stamp a new identity on a copied .jvp.
-- Temporarily defers foreign key checks since sequences reference projects(id).
-- @param old_id string: current project id
-- @param new_id string: new project id (UUID)
-- @param new_name string: new project name
function Project.update_identity(old_id, new_id, new_name)
    assert(old_id and old_id ~= "", "Project.update_identity: old_id required")
    assert(new_id and new_id ~= "", "Project.update_identity: new_id required")
    assert(new_name and new_name ~= "", "Project.update_identity: new_name required")

    local conn = resolve_db(nil)

    -- Defer FK checks: project.id is referenced by sequences.project_id
    conn:exec("PRAGMA defer_foreign_keys = ON;")
    conn:exec("BEGIN;")

    local stmt = assert(conn:prepare("UPDATE projects SET id = ?, name = ? WHERE id = ?"),
        "Project.update_identity: failed to prepare UPDATE")
    stmt:bind_value(1, new_id)
    stmt:bind_value(2, new_name)
    stmt:bind_value(3, old_id)
    local ok = stmt:exec()
    stmt:finalize()

    if not ok then
        conn:exec("ROLLBACK;")
        error("Project.update_identity: UPDATE failed")
    end

    -- Caller MUST update sequences before commit; return a commit function
    -- Actually, we leave the transaction open — caller calls Sequence.rebind_to_project
    -- then calls Project.commit_identity_update()
end

--- Feature 013: read the project's fps-mismatch policy.
--- Returns 'resample' | 'passthrough'. Asserts loudly if the column value is
--- missing or unexpected (rule 1.14: projects.fps_mismatch_policy is NOT NULL
--- per schema V9; encountering anything else is DB corruption).
function Project.get_fps_mismatch_policy(id, db)
    assert(id and id ~= "", "Project.get_fps_mismatch_policy: id is required")
    local conn = resolve_db(db)
    local stmt = conn:prepare(
        "SELECT fps_mismatch_policy FROM projects WHERE id = ?")
    assert(stmt, "Project.get_fps_mismatch_policy: prepare failed")
    stmt:bind_value(1, id)
    assert(stmt:exec(), "Project.get_fps_mismatch_policy: exec failed")
    assert(stmt:next(), string.format(
        "Project.get_fps_mismatch_policy: project %s not found", id))
    local policy = stmt:value(0)
    stmt:finalize()
    assert(policy == "resample" or policy == "passthrough", string.format(
        "Project.get_fps_mismatch_policy: project %s has invalid value '%s' "
        .. "(expected 'resample' or 'passthrough')", id, tostring(policy)))
    return policy
end

--- Update the project's fps_mismatch_policy column. NOT NULL — caller
--- must pass 'resample' or 'passthrough' (rule 2.13).
--- Returns the prior value so undoers can restore.
function Project.set_fps_mismatch_policy(id, policy)
    assert(id and id ~= "", "Project.set_fps_mismatch_policy: id required")
    assert(policy == "resample" or policy == "passthrough", string.format(
        "Project.set_fps_mismatch_policy: policy must be 'resample' or "
        .. "'passthrough'; got %s", tostring(policy)))
    local conn = resolve_db(nil)
    local fetch = conn:prepare("SELECT fps_mismatch_policy FROM projects WHERE id = ?")
    assert(fetch, "Project.set_fps_mismatch_policy: fetch prepare failed")
    fetch:bind_value(1, id)
    assert(fetch:exec(), "Project.set_fps_mismatch_policy: fetch exec failed")
    assert(fetch:next(), string.format(
        "Project.set_fps_mismatch_policy: project %s not found", id))
    local prior = fetch:value(0)
    fetch:finalize()

    local upd = conn:prepare(
        "UPDATE projects SET fps_mismatch_policy = ?, modified_at = ? WHERE id = ?")
    assert(upd, "Project.set_fps_mismatch_policy: update prepare failed")
    upd:bind_value(1, policy)
    upd:bind_value(2, os.time())
    upd:bind_value(3, id)
    local ok = upd:exec()
    upd:finalize()
    assert(ok, "Project.set_fps_mismatch_policy: exec failed")
    return prior
end

--- Commit the identity update transaction started by update_identity.
function Project.commit_identity_update()
    local conn = resolve_db(nil)
    local ok, err = conn:exec("COMMIT;")
    assert(ok ~= false, "Project.commit_identity_update: COMMIT failed: " .. tostring(err))
    conn:exec("PRAGMA defer_foreign_keys = OFF;")
end

return Project
