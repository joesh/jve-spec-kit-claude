-- bug_submission.lua
-- Orchestrates complete bug submission workflow: capture → video → upload → issue

local json_test_loader = require("bug_reporter.json_test_loader")
local youtube_uploader = require("bug_reporter.youtube_uploader")
local github_issue_creator = require("bug_reporter.github_issue_creator")
local logger = require("core.logger")
local utils = require("bug_reporter.utils")

local BugSubmission = {}

--- Submit complete bug report workflow: load test → upload video → create GitHub issue
-- Orchestrates the full bug submission process end-to-end. Loads test data from JSON,
-- optionally uploads slideshow video to YouTube, then creates a GitHub issue with
-- embedded video link and reproduction steps.
--
-- @param test_path string Path to captured test JSON file (required, must exist)
-- @param options table Optional submission configuration {
--     upload_video: boolean - Upload slideshow to YouTube (default: true),
--     create_issue: boolean - Create GitHub issue (default: true),
--     video_privacy: string - YouTube privacy: "unlisted"|"private"|"public" (default: "unlisted"),
--     issue_labels: array - GitHub issue labels (default: ["bug", "auto-reported"])
-- }
-- @return table|nil Success: {test_path: string, video_url: string|nil, issue_url: string|nil, errors: array}
-- @return nil, string Failure: nil + error message if test loading fails
-- @usage
--   local result, err = BugSubmission.submit_bug_report("tests/captures/capture-123/capture.json", {
--     upload_video = true,
--     create_issue = true
--   })
--   if result then
--     if result.video_url then print("Video: " .. result.video_url) end
--     if result.issue_url then print("Issue: " .. result.issue_url) end
--   else
--     print("Submission failed: " .. err)
--   end
function BugSubmission.submit_bug_report(test_path, options)
    -- Validate parameters
    local valid, err = utils.validate_non_empty(test_path, "test_path")
    if not valid then
        return nil, err
    end

    if not utils.file_exists(test_path) then
        return nil, "Test file not found: " .. test_path
    end

    options = options or {}
    local upload_video = options.upload_video ~= false
    local create_issue = options.create_issue ~= false

    local result = {
        test_path = test_path,
        video_url = nil,
        issue_url = nil,
        errors = {}
    }

    -- 1. Load test data
    logger.info("bug_reporter", "Loading bug report...")
    local test, err = json_test_loader.load(test_path)
    if not test then
        return nil, "Failed to load test: " .. err
    end

    logger.info("bug_reporter", "Test loaded: " .. test.test_name)

    -- 2. Upload video to YouTube (if enabled and video exists)
    if upload_video then
        local video_path = BugSubmission.find_slideshow_video(test_path)

        if video_path then
            logger.info("bug_reporter", "Uploading video to YouTube...")

            local metadata = {
                title = test.test_name or "JVE Bug Report",
                description = BugSubmission.format_video_description(test),
                tags = {"jve", "bug-report", "video-editor", test.category or "bug"}
            }

            local upload_result, err = youtube_uploader.upload_video(video_path, metadata)
            if upload_result then
                result.video_url = upload_result.url
                logger.info("bug_reporter", "✓ Video uploaded: " .. upload_result.url)
            else
                local error_msg = "Failed to upload video: " .. err
                table.insert(result.errors, error_msg)
                logger.error("bug_reporter", "✗ " .. error_msg)
            end
        else
            logger.info("bug_reporter", "No slideshow video found, skipping upload")
        end
    end

    -- 3. Create GitHub issue (if enabled)
    if create_issue then
        logger.info("bug_reporter", "Creating GitHub issue...")

        local issue_data = {
            title = BugSubmission.format_issue_title(test),
            body = github_issue_creator.format_bug_report_body(test),
            labels = options.issue_labels or {"bug", "auto-reported"},
            video_url = result.video_url,
            test_path = test_path,
            system_info = github_issue_creator.get_system_info()
        }

        local issue_result, err = github_issue_creator.create_issue(issue_data)
        if issue_result then
            result.issue_url = issue_result.url
            result.issue_number = issue_result.issue_number
            logger.info("bug_reporter", "✓ Issue created: " .. issue_result.url)
        else
            local error_msg = "Failed to create issue: " .. err
            table.insert(result.errors, error_msg)
            logger.error("bug_reporter", "✗ " .. error_msg)
        end
    end

    -- 4. Return result
    if result.video_url or result.issue_url then
        return result
    else
        return nil, "Submission failed: " .. table.concat(result.errors, "; ")
    end
end

-- Find slideshow video for test
-- @param test_path: Path to test JSON file
-- @return: Video path or nil
function BugSubmission.find_slideshow_video(test_path)
    local test_dir = test_path:match("(.*/)")
    if not test_dir then
        return nil
    end

    -- Look for slideshow.mp4 in same directory
    local video_path = test_dir .. "slideshow.mp4"
    local file = io.open(video_path, "r")
    if file then
        file:close()
        return video_path
    end

    return nil
end

-- Format video description from test data
-- @param test: Test object
-- @return: Description string
function BugSubmission.format_video_description(test)
    local lines = {}

    table.insert(lines, "Automatically generated bug report from JVE (Joe's Video Editor)")
    table.insert(lines, "")

    if test.capture_metadata and test.capture_metadata.description then
        table.insert(lines, test.capture_metadata.description)
        table.insert(lines, "")
    end

    if test.capture_metadata and test.capture_metadata.error_message then
        table.insert(lines, "Error: " .. test.capture_metadata.error_message)
        table.insert(lines, "")
    end

    table.insert(lines, "This video shows a slideshow of screenshots captured during the bug occurrence.")
    table.insert(lines, "")
    table.insert(lines, "Test ID: " .. test.test_id)
    table.insert(lines, "Captured: " .. os.date("%Y-%m-%d %H:%M:%S", test.capture_metadata.timestamp))

    return table.concat(lines, "\n")
end

-- Format GitHub issue title from test data
-- @param test: Test object
-- @return: Title string
function BugSubmission.format_issue_title(test)
    -- Use custom title if provided
    if test.capture_metadata and test.capture_metadata.title then
        return test.capture_metadata.title
    end

    -- Use test name if available
    if test.test_name then
        return test.test_name
    end

    -- Generate title from error message
    if test.capture_metadata and test.capture_metadata.error_message then
        local error_msg = test.capture_metadata.error_message
        -- Take first line of error message
        local first_line = error_msg:match("([^\n]+)")
        if first_line and #first_line > 0 then
            -- Truncate to reasonable length
            if #first_line > 80 then
                return first_line:sub(1, 77) .. "..."
            end
            return first_line
        end
    end

    -- Fallback
    return "Bug Report - " .. test.test_id
end

-- Batch submit multiple bug reports
-- @param test_dir: Directory containing test JSON files
-- @param options: Submission options (same as submit_bug_report)
-- @return: Summary {total, succeeded, failed, results}
function BugSubmission.batch_submit(test_dir, options)
    -- Validate parameters
    local valid, err = utils.validate_non_empty(test_dir, "test_dir")
    if not valid then
        return nil, err
    end

    options = options or {}

    local summary = {
        total = 0,
        succeeded = 0,
        failed = 0,
        results = {}
    }

    -- Load all tests
    local tests, err = json_test_loader.load_directory(test_dir)
    if not tests then
        return nil, "Failed to load tests: " .. err
    end

    summary.total = #tests

    -- Submit each test
    for _, test in ipairs(tests) do
        logger.info("bug_reporter", "\n" .. string.rep("=", 60))
        logger.info("bug_reporter", "Submitting: " .. test.test_name)
        logger.info("bug_reporter", string.rep("=", 60))

        local result, err = BugSubmission.submit_bug_report(test._source_file, options)

        if result then
            summary.succeeded = summary.succeeded + 1
        else
            summary.failed = summary.failed + 1
        end

        table.insert(summary.results, {
            test_name = test.test_name,
            success = result ~= nil,
            result = result,
            error = err
        })
    end

    return summary
end

-- Print submission summary
-- @param summary: Summary from batch_submit
function BugSubmission.print_summary(summary)
    logger.info("bug_reporter", "\n" .. string.rep("=", 60))
    logger.info("bug_reporter", "Bug Submission Summary")
    logger.info("bug_reporter", string.rep("=", 60))
    logger.info("bug_reporter", string.format("Total:     %d reports", summary.total))
    logger.info("bug_reporter", string.format("Succeeded: %d reports (%.1f%%)", summary.succeeded,
        summary.total > 0 and (summary.succeeded / summary.total * 100) or 0))
    logger.info("bug_reporter", string.format("Failed:    %d reports (%.1f%%)", summary.failed,
        summary.total > 0 and (summary.failed / summary.total * 100) or 0))

    if summary.failed > 0 then
        logger.info("bug_reporter", "\nFailed submissions:")
        for _, result in ipairs(summary.results) do
            if not result.success then
                logger.error("bug_reporter", "  ✗ " .. result.test_name .. ": " .. (result.error or "unknown error"))
            end
        end
    end

    if summary.succeeded > 0 then
        logger.info("bug_reporter", "\nSuccessful submissions:")
        for _, result in ipairs(summary.results) do
            if result.success and result.result then
                local details = {}
                if result.result.video_url then
                    table.insert(details, "video: " .. result.result.video_url)
                end
                if result.result.issue_url then
                    table.insert(details, "issue: " .. result.result.issue_url)
                end
                logger.info("bug_reporter", "  ✓ " .. result.test_name)
                if #details > 0 then
                    logger.info("bug_reporter", "    " .. table.concat(details, ", "))
                end
            end
        end
    end

    logger.info("bug_reporter", string.rep("=", 60))
end

-- Check if submission is configured
-- @return: {youtube: boolean, github: boolean, messages: array}
function BugSubmission.check_configuration()
    local status = {
        youtube = false,
        github = false,
        messages = {}
    }

    -- Check YouTube
    local youtube_oauth = require("bug_reporter.youtube_oauth")
    if youtube_oauth.is_authenticated() then
        status.youtube = true
        table.insert(status.messages, "✓ YouTube authentication configured")
    else
        table.insert(status.messages, "✗ YouTube not authenticated (run: jve --auth-youtube)")
    end

    -- Check GitHub
    github_issue_creator.load_token()
    -- Try to make a simple API call to test token
    local test_result = github_issue_creator.search_issues("test")
    if test_result then
        status.github = true
        table.insert(status.messages, "✓ GitHub authentication configured")
    else
        table.insert(status.messages, "✗ GitHub not authenticated (run: jve --set-github-token)")
    end

    return status
end

return BugSubmission
