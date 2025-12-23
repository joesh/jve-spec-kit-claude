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
        print("WARNING: Project.save: No database connection available")
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
    if not name or name == "" then
        print("ERROR: Project.create: name is required")
        return nil
    end

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
    if not id or id == "" then
        print("ERROR: Project.load: id is required")
        return nil
    end

    local conn = resolve_db(db)
    if not conn then
        return nil
    end

    local stmt = conn:prepare("SELECT id, name, created_at, modified_at, settings FROM projects WHERE id = ?")
    if not stmt then
        print("WARNING: Project.load: failed to prepare query")
        return nil
    end

    stmt:bind_value(1, id)

    if not stmt:exec() then
        print(string.format("WARNING: Project.load: query failed for %s", id))
        stmt:finalize()
        return nil
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
    if not self or not self.id or self.id == "" then
        print("ERROR: Project.save: invalid project or missing id")
        return false
    end

    if not self.name or self.name == "" then
        print("ERROR: Project.save: name is required")
        return false
    end

    local conn = resolve_db(db)
    if not conn then
        return false
    end

    self.created_at = self.created_at or os.time()
    self.modified_at = os.time()
    self.settings = ensure_settings_json(self.settings)

    local stmt = conn:prepare([[
        INSERT OR REPLACE INTO projects (id, name, created_at, modified_at, settings)
        VALUES (?, ?, ?, ?, ?)
    ]])

    if not stmt then
        print("WARNING: Project.save: failed to prepare insert statement")
        return false
    end

    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.name)
    stmt:bind_value(3, self.created_at)
    stmt:bind_value(4, self.modified_at)
    stmt:bind_value(5, self.settings)

    local ok = stmt:exec()
    if not ok then
        print(string.format("WARNING: Project.save: failed for %s", self.id))
    end

    stmt:finalize()
    return ok
end

return Project
