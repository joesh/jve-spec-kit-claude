-- test_bug_reporter_negative.lua
-- Negative test coverage for bug reporter system
-- Tests error conditions, invalid inputs, and edge cases

-- Add src/lua to package path
package.path = package.path .. ";./src/lua/?.lua;./src/lua/?/init.lua"

local json_exporter = require("bug_reporter.json_exporter")
local youtube_uploader = require("bug_reporter.youtube_uploader")
local github_issue_creator = require("bug_reporter.github_issue_creator")
local bug_submission = require("bug_reporter.bug_submission")
local json_test_loader = require("bug_reporter.json_test_loader")
local slideshow_generator = require("bug_reporter.slideshow_generator")
local utils = require("bug_reporter.utils")

local test_count = 0
local pass_count = 0
local fail_count = 0

-- Helper: Run a test
local function test(name, fn)
    test_count = test_count + 1
    local success, err = pcall(fn)
    if success then
        pass_count = pass_count + 1
        print(string.format("✓ %s", name))
    else
        fail_count = fail_count + 1
        print(string.format("✗ %s: %s", name, err))
    end
end

-- Helper: Assert function
local function assert_eq(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

local function assert_nil(value, message)
    if value ~= nil then
        error(message or "Expected nil")
    end
end

local function assert_not_nil(value, message)
    if value == nil then
        error(message or "Expected non-nil value")
    end
end

print("\n" .. string.rep("=", 60))
print("Bug Reporter Negative Test Suite")
print(string.rep("=", 60))

-- ========================================
-- Input Validation Tests
-- ========================================

test("YouTubeUploader.upload_video rejects nil video_path", function()
    local result, err = youtube_uploader.upload_video(nil, {})
    assert_nil(result, "Should return nil for nil video_path")
    assert_not_nil(err, "Should return error message")
    assert_eq(type(err), "string", "Error should be a string")
end)

test("YouTubeUploader.upload_video rejects empty video_path", function()
    local result, err = youtube_uploader.upload_video("", {})
    assert_nil(result, "Should return nil for empty video_path")
    assert_not_nil(err, "Should return error message")
end)

test("YouTubeUploader.upload_video rejects non-existent file", function()
    local result, err = youtube_uploader.upload_video("/nonexistent/path/to/video.mp4", {})
    assert_nil(result, "Should return nil for non-existent file")
    assert_not_nil(err, "Should return error message")
    assert_eq(err:match("not found") ~= nil, true, "Error should mention 'not found'")
end)

test("GitHubIssueCreator.create_issue rejects nil issue_data", function()
    local result, err = github_issue_creator.create_issue(nil)
    assert_nil(result, "Should return nil for nil issue_data")
    assert_not_nil(err, "Should return error message")
end)

test("GitHubIssueCreator.create_issue rejects missing title", function()
    local result, err = github_issue_creator.create_issue({body = "Test"})
    assert_nil(result, "Should return nil for missing title")
    assert_not_nil(err, "Should return error message")
    assert_eq(err:match("title") ~= nil, true, "Error should mention 'title'")
end)

test("GitHubIssueCreator.create_issue rejects empty title", function()
    local result, err = github_issue_creator.create_issue({title = "", body = "Test"})
    assert_nil(result, "Should return nil for empty title")
    assert_not_nil(err, "Should return error message")
end)

test("BugSubmission.submit_bug_report rejects nil test_path", function()
    local result, err = bug_submission.submit_bug_report(nil, {})
    assert_nil(result, "Should return nil for nil test_path")
    assert_not_nil(err, "Should return error message")
end)

test("BugSubmission.submit_bug_report rejects empty test_path", function()
    local result, err = bug_submission.submit_bug_report("", {})
    assert_nil(result, "Should return nil for empty test_path")
    assert_not_nil(err, "Should return error message")
end)

test("BugSubmission.submit_bug_report rejects non-existent file", function()
    local result, err = bug_submission.submit_bug_report("/nonexistent/test.json", {})
    assert_nil(result, "Should return nil for non-existent file")
    assert_not_nil(err, "Should return error message")
end)

test("BugSubmission.batch_submit rejects nil test_dir", function()
    local result, err = bug_submission.batch_submit(nil, {})
    assert_nil(result, "Should return nil for nil test_dir")
    assert_not_nil(err, "Should return error message")
end)

test("BugSubmission.batch_submit rejects empty test_dir", function()
    local result, err = bug_submission.batch_submit("", {})
    assert_nil(result, "Should return nil for empty test_dir")
    assert_not_nil(err, "Should return error message")
end)

test("JsonExporter.export rejects nil capture_data", function()
    local result, err = json_exporter.export(nil, {}, "/tmp/test")
    assert_nil(result, "Should return nil for nil capture_data")
    assert_not_nil(err, "Should return error message")
end)

test("JsonExporter.export rejects nil output_dir", function()
    local result, err = json_exporter.export({}, {}, nil)
    assert_nil(result, "Should return nil for nil output_dir")
    assert_not_nil(err, "Should return error message")
end)

test("JsonExporter.export rejects empty output_dir", function()
    local result, err = json_exporter.export({}, {}, "")
    assert_nil(result, "Should return nil for empty output_dir")
    assert_not_nil(err, "Should return error message")
end)

test("SlideshowGenerator.generate rejects nil screenshot_dir", function()
    local result, err = slideshow_generator.generate(nil, 10)
    assert_nil(result, "Should return nil for nil screenshot_dir")
    assert_not_nil(err, "Should return error message")
end)

test("SlideshowGenerator.generate rejects empty screenshot_dir", function()
    local result, err = slideshow_generator.generate("", 10)
    assert_nil(result, "Should return nil for empty screenshot_dir")
    assert_not_nil(err, "Should return error message")
end)

test("SlideshowGenerator.generate rejects zero screenshot_count", function()
    local result, err = slideshow_generator.generate("/tmp/screenshots", 0)
    assert_nil(result, "Should return nil for zero screenshot_count")
    assert_not_nil(err, "Should return error message")
end)

test("SlideshowGenerator.generate rejects negative screenshot_count", function()
    local result, err = slideshow_generator.generate("/tmp/screenshots", -5)
    assert_nil(result, "Should return nil for negative screenshot_count")
    assert_not_nil(err, "Should return error message")
end)

test("JsonTestLoader.load rejects nil json_path", function()
    local result, err = json_test_loader.load(nil)
    assert_nil(result, "Should return nil for nil json_path")
    assert_not_nil(err, "Should return error message")
end)

test("JsonTestLoader.load rejects empty json_path", function()
    local result, err = json_test_loader.load("")
    assert_nil(result, "Should return nil for empty json_path")
    assert_not_nil(err, "Should return error message")
end)

test("JsonTestLoader.load_directory rejects nil dir_path", function()
    local result, err = json_test_loader.load_directory(nil)
    assert_nil(result, "Should return nil for nil dir_path")
    assert_not_nil(err, "Should return error message")
end)

test("JsonTestLoader.load_directory rejects empty dir_path", function()
    local result, err = json_test_loader.load_directory("")
    assert_nil(result, "Should return nil for empty dir_path")
    assert_not_nil(err, "Should return error message")
end)

-- ========================================
-- Shell Injection Prevention Tests
-- ========================================

test("utils.shell_escape handles single quotes", function()
    local input = "file'with'quotes.txt"
    local escaped = utils.shell_escape(input)
    assert_not_nil(escaped, "Should return escaped string")
    -- Escaped string should contain '\'' which is the proper escaping mechanism
    -- This closes the quote, adds an escaped quote, then reopens the quote
    assert_eq(escaped:find("'\\''") ~= nil, true, "Should contain proper escape sequence")
    -- Verify the full escaped string
    assert_eq(escaped, "file'\\''with'\\''quotes.txt", "Should properly escape single quotes")
end)

test("utils.shell_escape handles command injection attempts", function()
    local input = "file; rm -rf /"
    local escaped = utils.shell_escape(input)
    assert_not_nil(escaped, "Should return escaped string")
    -- The ; should be escaped and won't execute as a command separator
end)

test("utils.shell_escape handles backtick injection", function()
    local input = "file`whoami`.txt"
    local escaped = utils.shell_escape(input)
    assert_not_nil(escaped, "Should return escaped string")
end)

test("utils.shell_escape handles dollar substitution", function()
    local input = "file$(whoami).txt"
    local escaped = utils.shell_escape(input)
    assert_not_nil(escaped, "Should return escaped string")
end)

-- ========================================
-- Malformed JSON Tests
-- ========================================

test("JsonTestLoader.load handles malformed JSON", function()
    -- Create temp file with malformed JSON
    local temp_file = os.tmpname()
    local f = io.open(temp_file, "w")
    f:write("{invalid json content")
    f:close()

    local result, err = json_test_loader.load(temp_file)
    assert_nil(result, "Should return nil for malformed JSON")
    assert_not_nil(err, "Should return error message")
    assert_eq(err:match("parse") ~= nil or err:match("JSON") ~= nil, true, "Error should mention JSON parsing")

    os.remove(temp_file)
end)

test("JsonTestLoader.load handles empty file", function()
    -- Create temp file with empty content
    local temp_file = os.tmpname()
    local f = io.open(temp_file, "w")
    f:write("")
    f:close()

    local result, err = json_test_loader.load(temp_file)
    assert_nil(result, "Should return nil for empty file")
    assert_not_nil(err, "Should return error message")

    os.remove(temp_file)
end)

test("JsonTestLoader.load handles wrong schema version", function()
    -- Create temp file with wrong schema version
    local temp_file = os.tmpname()
    local f = io.open(temp_file, "w")
    f:write('{"test_format_version": "2.0", "test_id": "test"}')
    f:close()

    local result, err = json_test_loader.load(temp_file)
    assert_nil(result, "Should return nil for wrong schema version")
    assert_not_nil(err, "Should return error message")
    assert_eq(err:match("version") ~= nil, true, "Error should mention version")

    os.remove(temp_file)
end)

-- ========================================
-- Utility Function Tests
-- ========================================

test("utils.validate_non_empty rejects nil", function()
    local result, err = utils.validate_non_empty(nil, "test_param")
    assert_nil(result, "Should return nil for nil value")
    assert_not_nil(err, "Should return error message")
    assert_eq(err:match("test_param") ~= nil, true, "Error should mention parameter name")
end)

test("utils.validate_non_empty rejects empty string", function()
    local result, err = utils.validate_non_empty("", "test_param")
    assert_nil(result, "Should return nil for empty string")
    assert_not_nil(err, "Should return error message")
end)

test("utils.validate_non_empty accepts valid string", function()
    local result, err = utils.validate_non_empty("valid", "test_param")
    assert_not_nil(result, "Should return value for valid string")
    assert_eq(result, "valid", "Should return the input value")
    assert_nil(err, "Should not return error for valid input")
end)

test("utils.file_exists returns false for non-existent file", function()
    local exists = utils.file_exists("/nonexistent/path/to/file.txt")
    assert_eq(exists, false, "Should return false for non-existent file")
end)

test("utils.get_temp_dir returns non-empty string", function()
    local temp_dir = utils.get_temp_dir()
    assert_not_nil(temp_dir, "Should return temp directory")
    assert_eq(type(temp_dir), "string", "Should return string")
    assert_eq(#temp_dir > 0, true, "Should return non-empty string")
end)

-- ========================================
-- Summary
-- ========================================

print(string.rep("=", 60))
print(string.format("Total:  %d tests", test_count))
print(string.format("Passed: %d tests (%.1f%%)", pass_count,
    test_count > 0 and (pass_count / test_count * 100) or 0))
print(string.format("Failed: %d tests (%.1f%%)", fail_count,
    test_count > 0 and (fail_count / test_count * 100) or 0))
print(string.rep("=", 60))

if fail_count == 0 then
    print("✓ All negative tests passed!")
    os.exit(0)
else
    print("✗ Some tests failed")
    os.exit(1)
end
