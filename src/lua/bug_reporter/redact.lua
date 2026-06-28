-- Privacy redaction for capture.json payloads (FR-019, FR-020).
--
-- Command parameters and log messages can carry user-controlled file
-- paths (ImportMedia { path = "/Users/joe/Secrets/foo.mov" }, log
-- lines like "loaded /Users/joe/Projects/..."). The consent text
-- promises these are stripped; this module enforces it at the export
-- boundary so the ring buffer can stay full-fidelity for in-session
-- introspection while what ships is sanitized.
--
-- Redaction rules:
--   * $HOME prefix → "~" (no install_id, no real username in paths)
--   * /Users/<name>/... → "~<name-redacted>/..." (other users' homes)
--   * /Volumes/<name>/... → "/Volumes/<redacted>/..."
--   * paths that survive both → still keep filename (last segment)
--     because the basename rarely identifies; full directory chain
--     is the leak.

local M = {}

local HOME = os.getenv("HOME")

local function redact_path(s)
    if HOME and #HOME > 0 and s:sub(1, #HOME) == HOME then
        return "~" .. s:sub(#HOME + 1)
    end
    local users_rest = s:match("^/Users/[^/]+(/?.*)$")
    if users_rest then
        return "~<user>" .. users_rest
    end
    local vol_name, vol_rest = s:match("^/Volumes/([^/]+)(.*)$")
    if vol_name then
        return "/Volumes/<redacted>" .. vol_rest
    end
    return s
end

local function looks_like_path(s)
    return type(s) == "string" and s:sub(1, 1) == "/" and s:find("/", 2, true) ~= nil
end

function M.redact_string(s)
    if type(s) ~= "string" then return s end
    -- In-line: walk for any /Users/X or $HOME-prefixed substrings.
    if HOME and #HOME > 0 then
        s = s:gsub(HOME:gsub("%W", "%%%1"), "~")
    end
    s = s:gsub("/Users/[^%s'\")%]}]+", function(m) return redact_path(m) end)
    s = s:gsub("/Volumes/[^%s'\")%]}]+", function(m) return redact_path(m) end)
    return s
end

local function redact_value(v, depth)
    if depth > 8 then return v end  -- defensive recursion bound
    if type(v) == "string" then
        if looks_like_path(v) then return redact_path(v) end
        return M.redact_string(v)
    end
    if type(v) == "table" then
        local out = {}
        for k, vv in pairs(v) do
            out[k] = redact_value(vv, depth + 1)
        end
        return out
    end
    return v
end

function M.redact_parameters(parameters)
    return redact_value(parameters, 0)
end

return M
