local M = {}

-- Provide deterministic JSON helpers via bundled dkjson
local function ensure_json_helpers()
    if _G.qt_json_encode and _G.qt_json_decode then
        return
    end

    local ok, dkjson = pcall(require, "dkjson")
    if not ok then
        error("dkjson module is required for Lua regression tests: " .. tostring(dkjson))
    end

    if not _G.qt_json_encode then
        _G.qt_json_encode = function(value)
            local encoded, err = dkjson.encode(value)
            if not encoded then
                error(err or "qt_json_encode failed")
            end
            return encoded
        end
    end

    if not _G.qt_json_decode then
        _G.qt_json_decode = function(str)
            local decoded, _, err = dkjson.decode(str)
            if err then
                error(err)
            end
            return decoded
        end
    end
end

-- Provide a stub for the Qt single-shot timer used for UI listener debouncing
local function ensure_timer_stub()
    if _G.qt_create_single_shot_timer then
        return
    end

    function _G.qt_create_single_shot_timer(_, callback)
        if callback then
            callback()
        end
        return {}
    end
end

ensure_json_helpers()
ensure_timer_stub()

-- Force nil calls to raise useful errors (parity with layout.lua)
local function enforce_nil_call_protection()
    if not debug or not debug.setmetatable then
        return
    end

    local current = getmetatable(nil) or {}
    if current.__call == nil then
        current.__call = function()
            error("attempt to call nil value", 2)
        end
        debug.setmetatable(nil, current)
    end
end

enforce_nil_call_protection()

-- Lightweight dependency guards for tests
local function enforce(expected, fn)
    if type(fn) ~= "function" then
        error(string.format("Missing required dependency '%s'", tostring(expected)), 3)
    end
    return fn
end

local function enforce_table(tbl, specs)
    if type(tbl) ~= "table" or type(specs) ~= "table" then
        return
    end
    for key, descriptor in pairs(specs) do
        local expected = descriptor or key
        local candidate = tbl[key]
        tbl[key] = enforce(expected, candidate)
    end
end

M.enforce = enforce
M.enforce_table = enforce_table

return M
