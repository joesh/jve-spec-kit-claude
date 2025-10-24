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

return M
