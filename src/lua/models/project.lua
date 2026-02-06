--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~112 LOC
-- Volatility: unknown
--
-- @file project.lua
-- Original intent (unreviewed):
-- Lua wrapper for the projects table. Keeps parity with the modern Lua-first architecture.
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

    local project = {
        id = opts.id or uuid.generate(),
        name = name,
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

    local stmt = conn:prepare("SELECT id, name, created_at, modified_at, settings FROM projects WHERE id = ?")
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
        created_at = stmt:value(2),
        modified_at = stmt:value(3),
        settings = ensure_settings_json(stmt:value(4))
    }

    stmt:finalize()

    return setmetatable(project, Project)
end

function Project:save(db)
    assert(self and self.id and self.id ~= "", "Project.save: invalid project or missing id")
    assert(self.name and self.name ~= "", "Project.save: name is required")

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
        INSERT INTO projects (id, name, created_at, modified_at, settings)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            modified_at = excluded.modified_at,
            settings = excluded.settings
    ]])

    assert(stmt, "Project.save: failed to prepare insert statement")

    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.name)
    stmt:bind_value(3, self.created_at)
    stmt:bind_value(4, self.modified_at)
    stmt:bind_value(5, self.settings)

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

-- Ensure a default project exists, creating one if needed
-- Returns the default project (existing or newly created)
function Project.ensure_default()
    local existing = Project.load("default_project")
    if existing then
        return existing
    end

    local project = Project.create("Untitled Project", {id = "default_project"})
    if project and project:save() then
        return project
    end
    return nil
end

return Project
