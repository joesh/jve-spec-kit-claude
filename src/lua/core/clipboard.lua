-- Clipboard storage for complex editor payloads
-- Keeps most recent payload in-memory (Lua-side only)

local M = {}

local current_payload = nil

local function deep_copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local result = {}
    seen[value] = result
    for k, v in pairs(value) do
        result[deep_copy(k, seen)] = deep_copy(v, seen)
    end
    return result
end

--- Store a new payload on the clipboard.
-- @param payload table|nil Payload to store (nil clears the clipboard)
function M.set(payload)
    if payload == nil then
        current_payload = nil
        return
    end
    if type(payload) ~= "table" then
        error("clipboard payload must be a table or nil")
    end
    payload.timestamp = os.time()
    payload.version = (payload.version or 0) + 1
    current_payload = deep_copy(payload)
end

--- Retrieve the current clipboard payload (deep copy).
-- @return table|nil Payload copy or nil when clipboard is empty.
function M.get()
    if not current_payload then
        return nil
    end
    return deep_copy(current_payload)
end

--- Clear clipboard contents.
function M.clear()
    current_payload = nil
end

--- Describe clipboard state for logging/debugging.
-- @return string Human-readable summary.
function M.describe()
    if not current_payload then
        return "Clipboard(empty)"
    end
    local kind = tostring(current_payload.kind or "unknown")
    local count = current_payload.count or (current_payload.clips and #current_payload.clips)
                    or (current_payload.items and #current_payload.items) or "n/a"
    return string.format("Clipboard(kind=%s, count=%s)", kind, tostring(count))
end

return M
