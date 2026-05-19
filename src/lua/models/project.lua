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

-- 018 T007 (FR-028 / FR-036a): every project has master_clock_hz and
-- default_fps in its settings JSON. The canonical master clock is
-- 705,600,000 (a.k.a. "flicks") — exactly divides every supported audio
-- rate (8k/11.025k/16k/22.05k/24k/32k/44.1k/48k/88.2k/96k/176.4k/192k)
-- AND every supported frame rate (24/25/30/48/50/60/100/120 plus the
-- 1001-denominator NTSC family). Subframe ticks ↔ samples is therefore
-- lossless integer arithmetic for every rate combination. The clock is
-- immutable post-create (INV-6), so SetProjectMasterClock no longer
-- exists — there's no rate-precision reason for a user to ever change it.
-- Captured as a string constant so the default path doesn't pay an encode
-- on every project create.
local DEFAULT_PROJECT_SETTINGS_JSON =
    '{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}'

local function ensure_settings_json(settings)
    if type(settings) ~= "string" or settings == "" then
        return DEFAULT_PROJECT_SETTINGS_JSON
    end
    -- Caller-provided settings MUST already carry master_clock_hz and
    -- default_fps (FR-028, rule 2.13 — no silent injection of required values).
    -- json_decode + integer presence check.
    local json = require("dkjson")
    local decoded = json.decode(settings)
    assert(type(decoded) == "table", string.format(
        "Project.create: opts.settings is not valid JSON: %s", tostring(settings)))
    assert(decoded.master_clock_hz and decoded.master_clock_hz > 0, string.format(
        "Project.create: opts.settings missing master_clock_hz (FR-028); got %s",
        tostring(settings)))
    assert(decoded.default_fps and decoded.default_fps.num
        and decoded.default_fps.num > 0
        and decoded.default_fps.den and decoded.default_fps.den > 0,
        string.format(
        "Project.create: opts.settings missing default_fps {num,den} (FR-036a); got %s",
        tostring(settings)))
    return settings
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

    -- Transaction stays open. Caller invokes Sequence.rebind_to_project for
    -- every sequence, then Project.commit_identity_update() to commit.
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

--- 018 FR-036b: read current master_clock_hz from projects.settings JSON.
function Project.get_master_clock_hz_for_id(id)
    assert(id and id ~= "", "Project.get_master_clock_hz_for_id: id required")
    local conn = resolve_db(nil)
    local stmt = conn:prepare(
        "SELECT json_extract(settings, '$.master_clock_hz') FROM projects WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec(), "Project.get_master_clock_hz_for_id: exec failed")
    assert(stmt:next(), string.format(
        "Project.get_master_clock_hz_for_id: project %s not found", id))
    local v = stmt:value(0); stmt:finalize()
    assert(type(v) == "number" and v > 0, string.format(
        "Project.get_master_clock_hz_for_id: project %s has invalid mch=%s",
        id, tostring(v)))
    return v
end

--- 018 FR-036a: read current default_fps from projects.settings JSON. Returns
--- (num, den) integer pair. Asserts the key is present (rule 2.13 — never
--- silently invent a default).
function Project.get_default_fps(id)
    assert(id and id ~= "", "Project.get_default_fps: id required")
    local conn = resolve_db(nil)
    local stmt = conn:prepare([[
        SELECT json_extract(settings, '$.default_fps.num'),
               json_extract(settings, '$.default_fps.den')
        FROM projects WHERE id = ?
    ]])
    assert(stmt, "Project.get_default_fps: prepare failed")
    stmt:bind_value(1, id)
    assert(stmt:exec(), "Project.get_default_fps: exec failed")
    assert(stmt:next(), string.format("Project.get_default_fps: project %s not found", id))
    local n, d = stmt:value(0), stmt:value(1)
    stmt:finalize()
    assert(type(n) == "number" and n > 0 and type(d) == "number" and d > 0,
        string.format("Project.get_default_fps: project %s has invalid default_fps (%s/%s)",
            id, tostring(n), tostring(d)))
    return n, d
end

--- 018 FR-036a: write projects.settings.default_fps to (num, den). Read-modify-
--- write the settings JSON to preserve other keys (including master_clock_hz —
--- triggers INV-6 guard, but value is unchanged so trigger sees IS NOT distinct
--- and stays quiet). Returns the prior (num, den) for undo.
function Project.set_default_fps(id, fps_numerator, fps_denominator)
    assert(id and id ~= "", "Project.set_default_fps: id required")
    assert(type(fps_numerator) == "number" and fps_numerator > 0
        and math.floor(fps_numerator) == fps_numerator,
        string.format("Project.set_default_fps: fps_numerator must be positive integer; got %s",
            tostring(fps_numerator)))
    assert(type(fps_denominator) == "number" and fps_denominator > 0
        and math.floor(fps_denominator) == fps_denominator,
        string.format("Project.set_default_fps: fps_denominator must be positive integer; got %s",
            tostring(fps_denominator)))

    local conn = resolve_db(nil)
    local fetch = conn:prepare("SELECT settings FROM projects WHERE id = ?")
    assert(fetch, "Project.set_default_fps: fetch prepare failed")
    fetch:bind_value(1, id)
    assert(fetch:exec(), "Project.set_default_fps: fetch exec failed")
    assert(fetch:next(), string.format(
        "Project.set_default_fps: project %s not found", id))
    local settings_str = fetch:value(0)
    fetch:finalize()
    assert(type(settings_str) == "string" and settings_str ~= "",
        "Project.set_default_fps: settings JSON missing on project " .. id)

    local json = require("dkjson")
    local decoded = json.decode(settings_str)
    assert(type(decoded) == "table",
        "Project.set_default_fps: settings not valid JSON")
    local old = decoded.default_fps
    assert(type(old) == "table" and old.num and old.den,
        "Project.set_default_fps: existing default_fps missing (FR-028)")
    local prior_num, prior_den = old.num, old.den
    assert(prior_num ~= fps_numerator or prior_den ~= fps_denominator, string.format(
        "Project.set_default_fps: new fps %d/%d equals current; no-op rejected",
        fps_numerator, fps_denominator))

    decoded.default_fps = { num = fps_numerator, den = fps_denominator }
    local new_settings = json.encode(decoded)

    local upd = conn:prepare(
        "UPDATE projects SET settings = ?, modified_at = ? WHERE id = ?")
    assert(upd, "Project.set_default_fps: update prepare failed")
    upd:bind_value(1, new_settings)
    upd:bind_value(2, os.time())
    upd:bind_value(3, id)
    local ok = upd:exec()
    local err
    if not ok then err = conn:last_error() end
    upd:finalize()
    assert(ok, "Project.set_default_fps: exec failed: " .. tostring(err))
    return prior_num, prior_den
end

--- 018 FR-028: every project carries master_clock_hz in settings JSON. This
--- accessor parses the settings string and asserts the key is present
--- (rule 2.13 — never silently fall back to a default).
function Project:get_master_clock_hz()
    assert(type(self.settings) == "string" and self.settings ~= "",
        "Project:get_master_clock_hz: settings missing on project " .. tostring(self.id))
    local json = require("dkjson")
    local decoded = json.decode(self.settings)
    assert(type(decoded) == "table",
        "Project:get_master_clock_hz: settings not JSON on project " .. tostring(self.id))
    assert(decoded.master_clock_hz and decoded.master_clock_hz > 0,
        "Project:get_master_clock_hz: master_clock_hz missing on project " .. tostring(self.id))
    return decoded.master_clock_hz
end

--- Commit the identity update transaction started by update_identity.
function Project.commit_identity_update()
    local conn = resolve_db(nil)
    local ok, err = conn:exec("COMMIT;")
    assert(ok ~= false, "Project.commit_identity_update: COMMIT failed: " .. tostring(err))
    conn:exec("PRAGMA defer_foreign_keys = OFF;")
end

return Project
