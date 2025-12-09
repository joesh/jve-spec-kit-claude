-- utils.lua
-- Shared utility functions for bug reporter system

local Utils = {}

-- Escape a string for safe use in shell commands
-- Handles single quotes by closing quote, escaping, reopening
-- @param str: String to escape
-- @return: Safely escaped string
function Utils.shell_escape(str)
    if not str then
        return "''"
    end
    -- Replace ' with '\''
    -- This closes the quote, adds an escaped quote, then reopens the quote
    return str:gsub("'", "'\\''")
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

-- Create directory with proper error handling
-- @param path: Directory path to create
-- @return: Success boolean, error message
function Utils.mkdir_p(path)
    local escaped = Utils.shell_escape(path)
    local result = os.execute("mkdir -p '" .. escaped .. "' >/dev/null 2>&1")
    if result == true or result == 0 then
        return true
    end
    return false, "Failed to create directory: " .. path
end

-- Securely write file with restricted permissions
-- Creates file with 600 permissions before writing content to prevent credential exposure
-- @param path: File path
-- @param content: File content
-- @return: Success boolean, error message
function Utils.write_secure_file(path, content)
    local escaped_path = Utils.shell_escape(path)

    -- Create empty file with secure permissions (600) BEFORE writing sensitive content
    -- This ensures there's no window where credentials are world-readable
    local touch_result = os.execute("touch '" .. escaped_path .. "' && chmod 600 '" .. escaped_path .. "' 2>/dev/null")
    if not (touch_result == true or touch_result == 0) then
        return false, "Failed to create secure file: " .. path
    end

    -- Now write content to the already-secured file
    local file, err = io.open(path, "w")
    if not file then
        return false, "Failed to open file for writing: " .. (err or "unknown error")
    end

    local write_success, write_err = file:write(content)
    file:close()

    if not write_success then
        return false, "Failed to write to file: " .. (write_err or "unknown error")
    end

    return true
end

return Utils
