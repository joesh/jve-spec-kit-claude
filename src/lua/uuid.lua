-- UUID generator used across Lua modules.
-- Provides a single encapsulated implementation to avoid duplicated algorithms.

local M = {}

local seeded = false

local function warm_up_rng()
    -- Burn a few values after seeding to improve randomness characteristics
    math.random()
    math.random()
    math.random()
end

local function ensure_seeded()
    if not seeded then
        local now = os.time()
        local clock_component = math.floor(os.clock() * 1000000)
        math.randomseed(now + clock_component)
        warm_up_rng()
        seeded = true
    end
end

--- Seed the generator for deterministic runs (primarily for tests).
-- @param seed number Seed used for deterministic UUID generation.
function M.seed(seed)
    math.randomseed(seed)
    warm_up_rng()
    seeded = true
end

local function random_hex_digit()
    ensure_seeded()
    return string.format("%x", math.random(0, 0xf))
end

--- Generate RFC4122-style UUID (version 4).
-- @return string UUID string without braces.
function M.generate()
    ensure_seeded()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return (template:gsub("[xy]", function(c)
        if c == "x" then
            return random_hex_digit()
        end
        -- y: high bits 8..b
        return string.format("%x", math.random(8, 0xb))
    end))
end

--- Generate UUID with a namespace prefix (`prefix_uuid`).
-- @param prefix string Prefix to prepend.
-- @return string Prefixed UUID.
function M.generate_with_prefix(prefix)
    return string.format("%s_%s", prefix, M.generate())
end

return M
