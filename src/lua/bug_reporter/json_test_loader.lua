-- json_test_loader.lua
-- Load and parse JSON test files

local dkjson = require("dkjson")
local logger = require("core.logger")
local utils = require("bug_reporter.utils")

local JsonTestLoader = {}

-- Load a test from JSON file
-- @param json_path: Path to JSON test file
-- @return: Test object, or nil + error
function JsonTestLoader.load(json_path)
    -- Validate parameters
    local valid, err = utils.validate_non_empty(json_path, "json_path")
    if not valid then
        return nil, err
    end

    local file = io.open(json_path, "r")
    if not file then
        return nil, "Failed to open test file: " .. json_path
    end

    local content = file:read("*a")
    file:close()

    -- Parse JSON
    local test, pos, err = dkjson.decode(content)
    if not test then
        return nil, "Failed to parse JSON: " .. (err or "unknown error")
    end

    -- Validate schema version
    if test.test_format_version ~= "1.0" then
        return nil, "Unsupported test format version: " .. tostring(test.test_format_version)
    end

    -- Add metadata
    test._source_file = json_path
    test._loaded_at = os.time()

    return test
end

-- Load all tests from a directory
-- @param dir_path: Path to directory containing test JSON files
-- @return: Array of test objects, or nil + error
function JsonTestLoader.load_directory(dir_path)
    -- Validate parameters
    local valid, err = utils.validate_non_empty(dir_path, "dir_path")
    if not valid then
        return nil, err
    end

    -- Get list of JSON files in directory
    local handle = io.popen("find '" .. dir_path .. "' -name '*.json' -type f 2>/dev/null")
    if not handle then
        return nil, "Failed to list directory: " .. dir_path
    end

    local files_str = handle:read("*a")
    handle:close()

    if not files_str or files_str == "" then
        return {}, nil  -- Empty directory, not an error
    end

    -- Split into lines
    local test_files = {}
    for line in files_str:gmatch("[^\n]+") do
        table.insert(test_files, line)
    end

    -- Load each test file
    local tests = {}
    local errors = {}

    for _, file_path in ipairs(test_files) do
        local test, err = JsonTestLoader.load(file_path)
        if test then
            table.insert(tests, test)
        else
            table.insert(errors, {
                file = file_path,
                error = err
            })
        end
    end

    -- Report errors but continue
    if #errors > 0 then
        logger.warn("bug_reporter", #errors .. " test(s) failed to load")
        for _, error_info in ipairs(errors) do
            logger.warn("bug_reporter", "  " .. error_info.file .. ": " .. error_info.error)
        end
    end

    return tests, nil
end

-- Get test summary information
-- @param test: Test object
-- @return: Summary table
function JsonTestLoader.get_summary(test)
    return {
        test_id = test.test_id,
        test_name = test.test_name,
        category = test.category,
        capture_type = test.capture_metadata and test.capture_metadata.capture_type,
        gesture_count = test.gesture_log and #test.gesture_log or 0,
        command_count = test.command_log and #test.command_log or 0,
        log_count = test.log_output and #test.log_output or 0,
        screenshot_count = test.screenshots and test.screenshots.screenshot_count or 0
    }
end

return JsonTestLoader
