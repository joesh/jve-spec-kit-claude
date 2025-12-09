#!/usr/bin/env lua
-- test_upload_system.lua
-- Test Phase 6 upload system (structure validation, no actual uploads)

-- Add src/lua to package path
package.path = package.path .. ";../src/lua/?.lua"

local youtube_oauth = require("bug_reporter.youtube_oauth")
local youtube_uploader = require("bug_reporter.youtube_uploader")
local github_issue_creator = require("bug_reporter.github_issue_creator")
local bug_submission = require("bug_reporter.bug_submission")

-- Test utilities
local test_count = 0
local pass_count = 0

local function assert_true(condition, message)
    test_count = test_count + 1
    if condition then
        pass_count = pass_count + 1
        print("✓ " .. message)
        return true
    else
        print("✗ " .. message)
        return false
    end
end

local function assert_not_nil(value, message)
    return assert_true(value ~= nil, message)
end

print("=== Testing Upload System (Phase 6) ===\n")

-- Test 1: YouTube OAuth structure
print("Test 1: YouTube OAuth module")
assert_not_nil(youtube_oauth.set_credentials, "set_credentials exists")
assert_not_nil(youtube_oauth.get_authorization_url, "get_authorization_url exists")
assert_not_nil(youtube_oauth.exchange_code_for_tokens, "exchange_code_for_tokens exists")
assert_not_nil(youtube_oauth.refresh_access_token, "refresh_access_token exists")
assert_not_nil(youtube_oauth.get_access_token, "get_access_token exists")
assert_not_nil(youtube_oauth.is_authenticated, "is_authenticated exists")
print()

-- Test 2: OAuth URL generation
print("Test 2: OAuth URL generation")
youtube_oauth.set_credentials("test_client_id", "test_client_secret")
local auth_url = youtube_oauth.get_authorization_url()
assert_not_nil(auth_url, "Authorization URL generated")
assert_true(auth_url:match("accounts.google.com"), "URL contains Google OAuth endpoint")
assert_true(auth_url:match("client_id=test_client_id"), "URL contains client ID")
assert_true(auth_url:match("scope=.*youtube"), "URL contains YouTube scope")
print()

-- Test 3: URL encoding
print("Test 3: URL encoding")
local encoded = youtube_oauth.url_encode("hello world & test=value")
assert_true(encoded == "hello+world+%26+test%3Dvalue", "URL encoding correct")
print()

-- Test 4: YouTube uploader structure
print("Test 4: YouTube uploader module")
assert_not_nil(youtube_uploader.upload_video, "upload_video exists")
assert_not_nil(youtube_uploader.simple_upload, "simple_upload exists")
assert_not_nil(youtube_uploader.initiate_resumable_upload, "initiate_resumable_upload exists")
assert_not_nil(youtube_uploader.upload_video_file, "upload_video_file exists")
assert_not_nil(youtube_uploader.check_upload_progress, "check_upload_progress exists")
print()

-- Test 5: GitHub issue creator structure
print("Test 5: GitHub issue creator module")
assert_not_nil(github_issue_creator.set_repository, "set_repository exists")
assert_not_nil(github_issue_creator.set_token, "set_token exists")
assert_not_nil(github_issue_creator.create_issue, "create_issue exists")
assert_not_nil(github_issue_creator.add_comment, "add_comment exists")
assert_not_nil(github_issue_creator.search_issues, "search_issues exists")
assert_not_nil(github_issue_creator.get_system_info, "get_system_info exists")
assert_not_nil(github_issue_creator.format_bug_report_body, "format_bug_report_body exists")
print()

-- Test 6: System info generation
print("Test 6: System info generation")
local sys_info = github_issue_creator.get_system_info()
assert_not_nil(sys_info, "System info generated")
assert_true(sys_info:match("OS:"), "Contains OS info")
assert_true(sys_info:match("Lua Version:"), "Contains Lua version")
print()

-- Test 7: Bug report formatting
print("Test 7: Bug report formatting")
local test_data = {
    capture_metadata = {
        description = "Test bug description",
        error_message = "Test error: something went wrong"
    },
    command_log = {
        {command = "Command1"},
        {command = "Command2"},
        {command = "Command3"}
    },
    log_output = {
        {level = "info", message = "Info message"},
        {level = "warning", message = "Warning message"},
        {level = "error", message = "Error message"}
    }
}

local body = github_issue_creator.format_bug_report_body(test_data)
assert_not_nil(body, "Body formatted")
assert_true(body:match("Description"), "Contains description section")
assert_true(body:match("Error Message"), "Contains error section")
assert_true(body:match("Steps to Reproduce"), "Contains steps section")
assert_true(body:match("Log Output"), "Contains log section")
assert_true(body:match("Command1"), "Contains command steps")
print()

-- Test 8: Bug submission orchestrator structure
print("Test 8: Bug submission orchestrator")
assert_not_nil(bug_submission.submit_bug_report, "submit_bug_report exists")
assert_not_nil(bug_submission.batch_submit, "batch_submit exists")
assert_not_nil(bug_submission.find_slideshow_video, "find_slideshow_video exists")
assert_not_nil(bug_submission.format_video_description, "format_video_description exists")
assert_not_nil(bug_submission.format_issue_title, "format_issue_title exists")
assert_not_nil(bug_submission.check_configuration, "check_configuration exists")
print()

-- Test 9: Issue title formatting
print("Test 9: Issue title formatting")
local test1 = {
    capture_metadata = {
        title = "Custom Title"
    }
}
local title1 = bug_submission.format_issue_title(test1)
assert_true(title1 == "Custom Title", "Uses custom title when provided")

local test2 = {
    test_name = "Test Name"
}
local title2 = bug_submission.format_issue_title(test2)
assert_true(title2 == "Test Name", "Uses test name as fallback")

local test3 = {
    test_id = "test-123",
    capture_metadata = {
        error_message = "This is a very long error message that should be truncated to a reasonable length for the issue title to avoid making it too long"
    }
}
local title3 = bug_submission.format_issue_title(test3)
assert_true(#title3 <= 80, "Truncates long error messages")
assert_true(title3:match("This is a very long error"), "Preserves beginning of error message")
print()

-- Test 10: Video description formatting
print("Test 10: Video description formatting")
local test_with_meta = {
    test_id = "test-456",
    capture_metadata = {
        description = "Bug in timeline",
        error_message = "Null pointer exception",
        timestamp = os.time()
    }
}
local description = bug_submission.format_video_description(test_with_meta)
assert_not_nil(description, "Description generated")
assert_true(description:match("Joe's Video Editor"), "Contains JVE attribution")
assert_true(description:match("Bug in timeline"), "Contains test description")
assert_true(description:match("Null pointer exception"), "Contains error message")
assert_true(description:match("test%-456"), "Contains test ID")
print()

-- Test 11: Configuration check
print("Test 11: Configuration check")
local config_status = bug_submission.check_configuration()
assert_not_nil(config_status, "Configuration status returned")
assert_not_nil(config_status.youtube, "YouTube status present")
assert_not_nil(config_status.github, "GitHub status present")
assert_not_nil(config_status.messages, "Status messages present")
assert_true(#config_status.messages > 0, "Contains status messages")
print()

-- Summary
print("=== Test Summary ===")
print(string.format("Passed: %d / %d tests", pass_count, test_count))
if pass_count == test_count then
    print("✓ All tests passed!")
    os.exit(0)
else
    print("✗ Some tests failed")
    os.exit(1)
end
