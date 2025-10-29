-- Lua representation of timeline sequences.
-- Mirrors the behaviour of the legacy C++ model closely enough for imports and commands.

local database = require("core.database")
local uuid = require("uuid")

local Sequence = {}
Sequence.__index = Sequence

local function resolve_db(db)
    if db then
        return db
    end
    local conn = database.get_connection()
    if not conn then
        print("WARNING: Sequence.save: No database connection available")
    end
    return conn
end

local function clamp_resolution(value, fallback)
    if type(value) ~= "number" or value <= 0 then
        return fallback
    end
    return math.floor(value)
end

local function validate_frame_rate(value)
    if type(value) ~= "number" or value <= 0 then
        return nil
    end
    return value
end

function Sequence.create(name, project_id, frame_rate, width, height, opts)
    if not name or name == "" then
        print("ERROR: Sequence.create: name is required")
        return nil
    end
    if not project_id or project_id == "" then
        print("ERROR: Sequence.create: project_id is required")
        return nil
    end

    local fr = validate_frame_rate(frame_rate) or 30.0
    local w = clamp_resolution(width, 1920)
    local h = clamp_resolution(height, 1080)

    opts = opts or {}
    local now = os.time()

    local sequence = {
        id = opts.id or uuid.generate(),
        project_id = project_id,
        name = name,
        kind = opts.kind or "timeline",
        frame_rate = fr,
        width = w,
        height = h,
        timecode_start = opts.timecode_start or 0,
        created_at = opts.created_at or now,
        modified_at = opts.modified_at or now
    }

    return setmetatable(sequence, Sequence)
end

function Sequence.load(id, db)
    if not id or id == "" then
        print("ERROR: Sequence.load: id is required")
        return nil
    end

    local conn = resolve_db(db)
    if not conn then
        return nil
    end

    local stmt = conn:prepare([[
        SELECT id, project_id, name, kind, frame_rate, width, height, timecode_start
        FROM sequences WHERE id = ?
    ]])

    if not stmt then
        print("WARNING: Sequence.load: failed to prepare query")
        return nil
    end

    stmt:bind_value(1, id)
    if not stmt:exec() then
        print(string.format("WARNING: Sequence.load: query failed for %s", id))
        stmt:finalize()
        return nil
    end

    if not stmt:next() then
        stmt:finalize()
        return nil
    end

    local sequence = {
        id = stmt:value(0),
        project_id = stmt:value(1),
        name = stmt:value(2),
        kind = stmt:value(3),
        frame_rate = stmt:value(4),
        width = stmt:value(5),
        height = stmt:value(6),
        timecode_start = stmt:value(7) or 0,
        created_at = os.time(),
        modified_at = os.time()
    }

    stmt:finalize()
    return setmetatable(sequence, Sequence)
end

function Sequence:save(db)
    if not self or not self.id or self.id == "" then
        print("ERROR: Sequence.save: invalid sequence or missing id")
        return false
    end
    if not self.project_id or self.project_id == "" then
        print("ERROR: Sequence.save: project_id is required")
        return false
    end

    local conn = resolve_db(db)
    if not conn then
        return false
    end

    self.modified_at = os.time()

    local stmt = conn:prepare([[
        INSERT OR REPLACE INTO sequences
        (id, project_id, name, kind, frame_rate, width, height, timecode_start)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]])

    if not stmt then
        local err = conn.last_error and conn:last_error() or "unknown error"
        print("WARNING: Sequence.save: failed to prepare insert statement: " .. err)
        return false
    end

    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.project_id)
    stmt:bind_value(3, self.name)
    stmt:bind_value(4, self.kind or "timeline")
    stmt:bind_value(5, self.frame_rate)
    stmt:bind_value(6, self.width)
    stmt:bind_value(7, self.height)
    stmt:bind_value(8, self.timecode_start or 0)

    local ok = stmt:exec()
    if not ok then
        print(string.format("WARNING: Sequence.save: failed for %s", self.id))
    end

    stmt:finalize()
    return ok
end

return Sequence
