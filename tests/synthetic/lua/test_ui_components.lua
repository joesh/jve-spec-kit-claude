#!/usr/bin/env lua
-- test_ui_components.lua
-- Test Phase 7 UI components (structure validation, no actual UI display)

-- Add src/lua to package path
package.path = package.path .. ";../src/lua/?.lua"

local preferences_panel = require("bug_reporter.ui.preferences_panel")
local submission_dialog = require("bug_reporter.ui.submission_dialog")
local oauth_dialogs = require("bug_reporter.ui.oauth_dialogs")

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

print("=== Testing UI Components (Phase 7) ===\n")

-- Test 1: Preferences panel structure
print("Test 1: Preferences panel module")
assert_not_nil(preferences_panel.create, "create function exists")
assert_not_nil(preferences_panel.save_preferences, "save_preferences function exists")
assert_not_nil(preferences_panel.load_preferences, "load_preferences function exists")
print()

-- Test 2: Load/save preferences
print("Test 2: Preferences persistence")
local test_prefs = {
    enable_capture = true,
    buffer_gestures = 300,
    video_privacy = "private",
    auto_upload_video = false,
    auto_create_issue = true,
    show_review_dialog = true,
    github_owner = "testuser",
    github_repo = "testrepo",
    github_labels = "bug, test"
}

local save_success = preferences_panel.save_preferences(test_prefs)
assert_true(save_success, "Preferences saved successfully")

local loaded_prefs = preferences_panel.load_preferences()
assert_not_nil(loaded_prefs, "Preferences loaded successfully")
assert_true(loaded_prefs.buffer_gestures == 300, "Buffer gestures value persisted")
assert_true(loaded_prefs.video_privacy == "private", "Video privacy value persisted")
assert_true(loaded_prefs.github_owner == "testuser", "GitHub owner persisted")
print()

-- Test 3: Default preferences
print("Test 3: Default preferences")
-- Delete prefs file to test defaults
os.remove(os.getenv("HOME") .. "/.jve_bug_reporter_prefs.json")
local defaults = preferences_panel.load_preferences()
assert_true(defaults.enable_capture == true, "Default enable_capture is true")
assert_true(defaults.buffer_gestures == 200, "Default buffer_gestures is 200")
assert_true(defaults.video_privacy == "unlisted", "Default video_privacy is unlisted")
assert_true(defaults.auto_upload_video == true, "Default auto_upload_video is true")
print()

-- Test 4: Submission dialog structure
print("Test 4: Submission dialog module")
assert_not_nil(submission_dialog.create, "create function exists")
assert_not_nil(submission_dialog.find_slideshow_video, "find_slideshow_video function exists")
assert_not_nil(submission_dialog.show_result, "show_result function exists")
assert_not_nil(submission_dialog.show_progress, "show_progress function exists")
assert_not_nil(submission_dialog.update_progress, "update_progress function exists")
print()

-- Test 5: Video path finding
print("Test 5: Video path finding")
-- Create a fake test directory with video
local test_dir = "/tmp/jve_ui_test_" .. os.time() .. "/"
os.execute("mkdir -p '" .. test_dir .. "'")
os.execute("touch '" .. test_dir .. "slideshow.mp4'")
local test_json_path = test_dir .. "capture.json"

local video_path = submission_dialog.find_slideshow_video(test_json_path)
assert_not_nil(video_path, "Slideshow video found")
assert_true(video_path:match("slideshow%.mp4"), "Video path is correct")

-- Test with missing video
os.execute("rm '" .. test_dir .. "slideshow.mp4'")
local no_video = submission_dialog.find_slideshow_video(test_json_path)
assert_true(no_video == nil, "Correctly returns nil when video missing")

-- Cleanup
os.execute("rm -rf '" .. test_dir .. "'")
print()

-- Test 6: OAuth dialogs structure
print("Test 6: OAuth dialogs module")
assert_not_nil(oauth_dialogs.show_youtube_credentials_dialog, "show_youtube_credentials_dialog exists")
assert_not_nil(oauth_dialogs.show_youtube_auth_dialog, "show_youtube_auth_dialog exists")
assert_not_nil(oauth_dialogs.show_github_token_dialog, "show_github_token_dialog exists")
assert_not_nil(oauth_dialogs.show_connection_test_result, "show_connection_test_result exists")
assert_not_nil(oauth_dialogs.show_auth_result, "show_auth_result exists")
print()

-- Test 7: UI graceful fallback without Qt
print("Test 7: Graceful fallback without Qt bindings")
-- These should return nil gracefully when Qt bindings not available
local panel = preferences_panel.create()
assert_true(panel == nil, "Preferences panel returns nil without Qt")

local submit_dialog = submission_dialog.show_progress()
assert_true(submit_dialog == nil, "Progress dialog returns nil without Qt")

local oauth_creds_dialog = oauth_dialogs.show_youtube_credentials_dialog()
assert_true(oauth_creds_dialog == nil, "OAuth dialog returns nil without Qt")
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
