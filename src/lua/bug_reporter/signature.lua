-- Cluster signature for the bug-reporter pipeline (feature 027 T008).
--
-- Two reports of the SAME root cause must produce the SAME signature so
-- the Cloudflare Worker (T047) collapses them into one cluster. Two
-- reports of DIFFERENT root causes must produce DIFFERENT signatures.
-- The Lua side (this file) and the TypeScript side
-- (bug-reporter-worker/src/signature.ts, T040) MUST agree byte-for-byte
-- on the hash for every vector in tests/fixtures/signature_vectors.json.
--
-- Formula (per data-model.md §Signature, FR-012):
--   sig_input_commands = last_3_commands.reject(c == "ReportBug").join(",")
--   sig_input_text     = capture_type == "automatic"
--                          and normalize_error(error_message)
--                           or normalize_title(user_description)
--   sig                = sha256(sig_input_commands .. "|" .. sig_input_text)
--
-- jve_sha is intentionally NOT included — the same root cause from
-- two different builds must still cluster (FR-012 line 119).

local M = {}

-- normalize_title: lowercase, collapse non-alphanumeric to single space,
-- take first 5 tokens, rejoin with single space. Strips punctuation and
-- case variance so case+punct variants of the same description cluster.
function M.normalize_title(s)
    if s == nil then return "" end
    s = string.lower(s)
    -- Lua-pattern `[^%w]` matches any non-alphanumeric (treats ASCII
    -- only; non-ASCII bytes pass through, which is fine — they're rare
    -- in user-visible text and consistent across Lua + TS).
    s = string.gsub(s, "[^%w]+", " ")
    local tokens = {}
    for tok in string.gmatch(s, "%S+") do
        tokens[#tokens + 1] = tok
        if #tokens == 5 then break end
    end
    return table.concat(tokens, " ")
end

-- normalize_error: strip noise that varies per run but isn't part of
-- the bug identity — absolute paths, hex IDs, timestamps, line numbers.
-- Then lowercase + collapse whitespace + trim.
function M.normalize_error(s)
    if s == nil then return "" end
    -- 1) Absolute path prefixes ending in `.<lowercase-ext>`. The
    --    extension anchor avoids stripping plain Unix paths like "/tmp"
    --    that don't end in an extension (the path delimiters might be
    --    part of an error message even when they aren't filesystem paths).
    s = string.gsub(s, "/[%w_./%-]+%.%l+", "")
    -- 2) 0x-prefixed hex IDs (handle [0-9a-fA-F]).
    s = string.gsub(s, "0[xX][%x]+", "")
    -- 3) Standalone hex runs of length >= 16 (most-likely a UUID hex,
    --    blob hash, etc.). Lua patterns can't bound with {16,}; use a
    --    gsub-with-callback that drops only when long enough.
    s = string.gsub(s, "%x+", function(run)
        if #run >= 16 then return "" end
        return nil  -- nil = keep original (gsub callback contract)
    end)
    -- 4) ISO-8601 timestamps (YYYY-MM-DDTHH:MM:SS, optional .fractional
    --    seconds and timezone suffix).
    s = string.gsub(s, "%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%.%d]*%a*[%+%-]?[%d:]*", "")
    -- 5) Unix-second integers >= 10^9 (10-digit-or-longer integer).
    s = string.gsub(s, "%d+", function(run)
        if #run >= 10 then return "" end
        return nil
    end)
    -- 6) Trailing `:N` line numbers attached to any remaining tokens.
    s = string.gsub(s, ":(%d+)", "")
    -- 7) Lowercase, collapse whitespace, trim.
    s = string.lower(s)
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

-- Filter trailing ReportBug entries so the F12 trigger doesn't dominate
-- cluster space (FR-012). Only the trailing one is stripped — earlier
-- ReportBug entries (rare, only if user filed two bugs back-to-back)
-- survive.
local function strip_trailing_reportbug(commands)
    if not commands or #commands == 0 then return {} end
    local last_idx = #commands
    if commands[last_idx] == "ReportBug" then
        local copy = {}
        for i = 1, last_idx - 1 do copy[i] = commands[i] end
        return copy
    end
    return commands
end

-- Compute the cluster signature. Returns lowercase 64-char hex.
function M.compute(capture_type, last_3_commands, error_message, user_description)
    assert(capture_type == "automatic" or capture_type == "user_submitted",
        "signature.compute: capture_type must be 'automatic' or 'user_submitted', got " .. tostring(capture_type))

    local filtered = strip_trailing_reportbug(last_3_commands)
    local sig_input_commands = table.concat(filtered, ",")
    local sig_input_text
    if capture_type == "automatic" then
        sig_input_text = M.normalize_error(error_message)
    else
        sig_input_text = M.normalize_title(user_description)
    end

    local payload = sig_input_commands .. "|" .. sig_input_text
    return qt_sha256(payload)
end

return M
