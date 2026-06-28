--- utils.lua
-- Shared utility functions for bug reporter system
local Utils = {}
local time_utils = require("core.time_utils")

-- Internal: escape single quotes within a string for the '...' shell
-- form. Returns the escaped middle only — callers MUST wrap in '...'
-- themselves. Use Utils.shell_quoted_arg for the safe form.
local function escape_inner_quotes(str)
    return (str:gsub("'", [['\'']]))
end

-- Return a fully-quoted shell argument: `'<escaped>'`. Inside single
-- quotes /bin/sh expands NOTHING (no $, no backticks, no globs); the
-- only thing that needs escaping is the closing quote itself, handled
-- by escape_inner_quotes. Safe for arbitrary path/text input.
function Utils.shell_quoted_arg(str)
    assert(str ~= nil, "Utils.shell_quoted_arg: nil arg")
    return "'" .. escape_inner_quotes(str) .. "'"
end

-- DEPRECATED. Returns inner escape only (no surrounding quotes); a
-- caller that forgets the surrounding `'...'` produces a shell-injection
-- vector. Use Utils.shell_quoted_arg instead. Retained for the slideshow
-- generator which already wraps the result in `'...'` inside its format
-- string; new callers must NOT use this.
function Utils.shell_escape(str)
    if not str then return "" end
    return escape_inner_quotes(str)
end

-- URL encode a string (for HTTP requests)
-- @param str: String to encode
-- @return: URL-encoded string
function Utils.url_encode(str)
    if not str then
        return ""
    end
    str = string.gsub(str, "\n", "\r\n")
    str = string.gsub(str, "([^%w %-%_%.%~])",
        function(c) return string.format("%%%02X", string.byte(c)) end)
    str = string.gsub(str, " ", "+")
    return str
end

-- Get platform-appropriate temporary directory
-- @return: Temp directory path
function Utils.get_temp_dir()
    if package.config:sub(1,1) == '\\' then
        -- Windows
        return os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
    else
        -- Unix-like
        return os.getenv("TMPDIR") or "/tmp"
    end
end

-- Check if a file exists
-- @param path: File path to check
-- @return: Boolean
function Utils.file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

-- Human-readable datestamp suitable for filenames
-- Example: 2025-12-15_14-03-27
function Utils.human_datestamp_for_filename(timestamp_seconds)
    return time_utils.human_datestamp_for_filename(timestamp_seconds)
end

-- Validate that a string is non-empty
-- @param str: String to validate
-- @param name: Parameter name for error message
-- @return: String or nil, error
function Utils.validate_non_empty(str, name)
    if not str or str == "" then
        return nil, (name or "Parameter") .. " is required"
    end
    return str
end

-- Get monotonic timestamp in milliseconds
-- Uses os.time() which is wall-clock time but monotonic on most systems
-- Note: Only second precision, not millisecond, but correct for long-running sessions
-- @param start_time: Optional start time to calculate elapsed from
-- @return: Timestamp in milliseconds
function Utils.get_time_ms(start_time)
    local current = os.time()
    if start_time then
        return (current - start_time) * 1000
    end
    return current * 1000
end

-- Create directory recursively. Returns (true) or (false, errmsg).
-- Wraps qt_fs_mkdir_p so existing callers keep their (ok, err) contract.
function Utils.mkdir_p(path)
    local ok, err = qt_fs_mkdir_p(path)
    if ok then return true end
    return false, "Failed to create directory: " .. tostring(path) .. ": " .. tostring(err)
end

-- Atomic, symlink-resistant, mode-0600 file write for credential content.
-- Delegates to qt_fs_atomic_write_secure (POSIX open + O_NOFOLLOW + EXCL temp
-- + fsync + rename). Replaces the prior touch+chmod+io.open path which had a
-- TOCTOU window (file briefly world-readable), no O_NOFOLLOW (symlink redirect),
-- and was non-atomic (crash mid-write bricked the file).
local MODE_0600 = tonumber("600", 8)

function Utils.write_secure_file(path, content)
    return qt_fs_atomic_write_secure(path, content, MODE_0600)
end

return Utils
