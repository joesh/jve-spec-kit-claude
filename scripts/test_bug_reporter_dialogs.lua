-- test_bug_reporter_dialogs.lua
-- Run from JVEEditor Lua console to test bug reporter dialogs
-- Usage: dofile("scripts/test_bug_reporter_dialogs.lua")

local function test_dialog(name, create_fn)
    print("Testing: " .. name)
    local dialog = create_fn()
    if dialog then
        print("  ✓ Dialog created")
        -- Show dialog non-blocking
        if qt_show_dialog then
            qt_show_dialog(dialog, false)
            print("  ✓ Dialog shown (close it to continue)")
        else
            print("  ✗ qt_show_dialog not available")
        end
    else
        print("  ✗ Dialog creation failed (Qt bindings available?)")
    end
    return dialog ~= nil
end

print("\n=== Bug Reporter Dialog Tests ===\n")

-- Test 1: Preferences Panel
local prefs = require("bug_reporter.ui.preferences_panel")
test_dialog("Preferences Panel", function()
    return prefs.create()
end)

print("\n[Press Enter to continue to next dialog...]")
io.read()

-- Test 2: OAuth - YouTube Credentials
local oauth = require("bug_reporter.ui.oauth_dialogs")
test_dialog("YouTube Credentials Dialog", function()
    return oauth.show_youtube_credentials_dialog()
end)

print("\n[Press Enter to continue...]")
io.read()

-- Test 3: OAuth - GitHub Token
test_dialog("GitHub Token Dialog", function()
    return oauth.show_github_token_dialog()
end)

print("\n[Press Enter to continue...]")
io.read()

-- Test 4: Connection Test Result
test_dialog("Connection Test (Success)", function()
    return oauth.show_connection_test_result(true, "Successfully connected to API")
end)

print("\n[Press Enter to continue...]")
io.read()

test_dialog("Connection Test (Failure)", function()
    return oauth.show_connection_test_result(false, "Connection timed out after 30 seconds")
end)

print("\n[Press Enter to continue...]")
io.read()

-- Test 5: Submission Dialog (needs test path)
local submission = require("bug_reporter.ui.submission_dialog")
test_dialog("Submission Progress Dialog", function()
    return submission.show_progress()
end)

print("\n[Press Enter to continue...]")
io.read()

test_dialog("Submission Result (Success)", function()
    return submission.show_result({
        video_url = "https://youtu.be/dQw4w9WgXcQ",
        issue_url = "https://github.com/owner/repo/issues/123"
    })
end)

print("\n=== All dialog tests complete ===\n")
