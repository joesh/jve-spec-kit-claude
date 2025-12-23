--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~225 LOC
-- Volatility: unknown
--
-- @file github_issue_creator.lua
-- Original intent (unreviewed):
-- github_issue_creator.lua
-- Create GitHub issues for bug reports with video links
local dkjson = require("dkjson")
local utils = require("bug_reporter.utils")
local logger = require("core.logger")

local GitHubIssueCreator = {}

-- GitHub configuration
local GITHUB_CONFIG = {
    api_url = "https://api.github.com",
    owner = nil,  -- Repository owner (e.g., "joevt")
    repo = nil,   -- Repository name (e.g., "jve-spec-kit-claude")
    token = nil   -- Personal access token
}

-- Token storage path
local TOKEN_FILE = os.getenv("HOME") .. "/.jve_github_token"

-- Set GitHub repository
-- @param owner: Repository owner
-- @param repo: Repository name
function GitHubIssueCreator.set_repository(owner, repo)
    GITHUB_CONFIG.owner = owner
    GITHUB_CONFIG.repo = repo
end

-- Set GitHub personal access token
-- @param token: GitHub PAT with 'repo' scope
function GitHubIssueCreator.set_token(token)
    GITHUB_CONFIG.token = token

    -- Save token to file securely
    local success, err = utils.write_secure_file(TOKEN_FILE, token)
    if not success then
        logger.warn("bug_reporter", "Failed to save GitHub token: " .. (err or "unknown error"))
    end
end

-- Load GitHub token from file
-- @return: Token string or nil
function GitHubIssueCreator.load_token()
    local file = io.open(TOKEN_FILE, "r")
    if not file then
        return nil
    end

    local token = file:read("*a"):gsub("%s+", "")
    file:close()

    GITHUB_CONFIG.token = token
    return token
end

--- Create GitHub issue for bug report using GitHub API v3
-- Creates a new issue in the configured GitHub repository with formatted bug report.
-- Requires GitHub Personal Access Token with 'repo' scope.
--
-- @param issue_data table Issue data (required) {
--   title: string - Issue title (required, non-empty),
--   body: string - Issue body markdown (optional),
--   labels: array - Array of label strings (defaults to {"bug", "auto-reported"}),
--   video_url: string - YouTube video URL to embed (optional),
--   test_path: string - Path to test JSON file for reproduction (optional)
-- }
-- @return table|nil Success: {url: string, issue_number: number}
-- @return nil, string Failure: nil + error message describing what went wrong
-- @usage
--   local result, err = GitHubIssueCreator.create_issue({
--     title = "Timeline crash when splitting clip",
--     body = "## Steps to Reproduce\n1. Load project\n2. Split clip at 00:01:00:00",
--     labels = {"bug", "timeline", "crash"}
--   })
--   if result then
--     print("Issue created: " .. result.url)
--   else
--     print("Failed: " .. err)
--   end
function GitHubIssueCreator.create_issue(issue_data)
    -- Validate parameters
    if not issue_data then
        return nil, "issue_data is required"
    end

    if not issue_data.title or issue_data.title == "" then
        return nil, "Issue title is required"
    end

    -- Load token if not set
    if not GITHUB_CONFIG.token then
        GitHubIssueCreator.load_token()
    end

    if not GITHUB_CONFIG.token then
        return nil, "GitHub token not configured"
    end

    if not GITHUB_CONFIG.owner or not GITHUB_CONFIG.repo then
        return nil, "GitHub repository not configured"
    end

    -- Build issue body with video and test info
    local body = issue_data.body or ""

    if issue_data.video_url then
        body = body .. "\n\n## Video Reproduction\n\n"
        body = body .. "Watch the bug reproduction: " .. issue_data.video_url
    end

    if issue_data.test_path then
        body = body .. "\n\n## Automated Test\n\n"
        body = body .. "Test file: `" .. issue_data.test_path .. "`\n\n"
        body = body .. "Run with:\n```bash\n"
        body = body .. "./jve --run-test " .. issue_data.test_path .. "\n"
        body = body .. "```"
    end

    -- Add system info
    if issue_data.system_info then
        body = body .. "\n\n## System Information\n\n"
        body = body .. "```\n"
        body = body .. issue_data.system_info
        body = body .. "\n```"
    end

    -- Build issue JSON
    local issue_json = {
        title = issue_data.title or "Bug Report",
        body = body,
        labels = issue_data.labels or {"bug", "auto-reported"}
    }

    local json_str = dkjson.encode(issue_json)
    local escaped_json = json_str:gsub("'", "'\\''")

    -- Create issue via GitHub API
    local api_endpoint = string.format(
        "%s/repos/%s/%s/issues",
        GITHUB_CONFIG.api_url,
        GITHUB_CONFIG.owner,
        GITHUB_CONFIG.repo
    )

    local cmd = string.format(
        "curl -s -X POST '%s' " ..
        "-H 'Authorization: token %s' " ..
        "-H 'Accept: application/vnd.github.v3+json' " ..
        "-H 'Content-Type: application/json' " ..
        "-d '%s'",
        api_endpoint,
        GITHUB_CONFIG.token,
        escaped_json
    )

    local handle = io.popen(cmd)
    local response = handle:read("*a")
    handle:close()

    -- Parse response
    local data, pos, err = dkjson.decode(response)
    if not data then
        return nil, "Failed to parse GitHub response: " .. (err or "unknown error")
    end

    if data.message then
        return nil, "GitHub API error: " .. data.message
    end

    if not data.html_url then
        return nil, "No issue URL in response"
    end

    return {
        issue_number = data.number,
        url = data.html_url
    }
end

-- Add comment to existing issue
-- @param issue_number: GitHub issue number
-- @param comment: Comment text
-- @return: Comment URL, or nil + error
function GitHubIssueCreator.add_comment(issue_number, comment)
    if not GITHUB_CONFIG.token then
        GitHubIssueCreator.load_token()
    end

    if not GITHUB_CONFIG.token then
        return nil, "GitHub token not configured"
    end

    local comment_json = dkjson.encode({body = comment})
    local escaped_json = comment_json:gsub("'", "'\\''")

    local api_endpoint = string.format(
        "%s/repos/%s/%s/issues/%d/comments",
        GITHUB_CONFIG.api_url,
        GITHUB_CONFIG.owner,
        GITHUB_CONFIG.repo,
        issue_number
    )

    local cmd = string.format(
        "curl -s -X POST '%s' " ..
        "-H 'Authorization: token %s' " ..
        "-H 'Accept: application/vnd.github.v3+json' " ..
        "-H 'Content-Type: application/json' " ..
        "-d '%s'",
        api_endpoint,
        GITHUB_CONFIG.token,
        escaped_json
    )

    local handle = io.popen(cmd)
    local response = handle:read("*a")
    handle:close()

    local data, pos, err = dkjson.decode(response)
    if not data then
        return nil, "Failed to parse response: " .. (err or "unknown error")
    end

    if data.message then
        return nil, "GitHub API error: " .. data.message
    end

    return data.html_url
end

-- Search for existing issues by title
-- @param search_term: Search term (e.g., error message)
-- @return: Array of matching issues
function GitHubIssueCreator.search_issues(search_term)
    if not GITHUB_CONFIG.owner or not GITHUB_CONFIG.repo then
        return nil, "GitHub repository not configured"
    end

    -- URL encode search term
    local encoded_term = search_term:gsub("([^%w %-%_%.%~])",
        function(c) return string.format("%%%02X", string.byte(c)) end):gsub(" ", "+")

    local query = string.format(
        "repo:%s/%s %s",
        GITHUB_CONFIG.owner,
        GITHUB_CONFIG.repo,
        encoded_term
    )
    query = query:gsub(" ", "+")

    local api_endpoint = string.format(
        "%s/search/issues?q=%s",
        GITHUB_CONFIG.api_url,
        query
    )

    local cmd = string.format("curl -s '%s'", api_endpoint)

    local handle = io.popen(cmd)
    local response = handle:read("*a")
    handle:close()

    local data, pos, err = dkjson.decode(response)
    if not data then
        return nil, "Failed to parse response: " .. (err or "unknown error")
    end

    if data.message then
        return nil, "GitHub API error: " .. data.message
    end

    return data.items or {}
end

-- Get system information for bug report
-- @return: System info string
function GitHubIssueCreator.get_system_info()
    local info = {}

    -- OS info
    local uname = io.popen("uname -a"):read("*a"):gsub("\n", "")
    table.insert(info, "OS: " .. uname)

    -- JVE version (TODO: get from app)
    table.insert(info, "JVE Version: dev")

    -- Qt version
    -- TODO: Get from Qt bindings

    -- Lua version
    table.insert(info, "Lua Version: " .. _VERSION)

    return table.concat(info, "\n")
end

-- Format bug report body from capture data
-- @param test: Test object from JSON
-- @return: Formatted body text
function GitHubIssueCreator.format_bug_report_body(test)
    local body = {}

    -- Description
    if test.capture_metadata and test.capture_metadata.description then
        table.insert(body, "## Description\n")
        table.insert(body, test.capture_metadata.description)
        table.insert(body, "")
    end

    -- Error message
    if test.capture_metadata and test.capture_metadata.error_message then
        table.insert(body, "## Error Message\n")
        table.insert(body, "```")
        table.insert(body, test.capture_metadata.error_message)
        table.insert(body, "```")
        table.insert(body, "")
    end

    -- Steps to reproduce
    if test.command_log and #test.command_log > 0 then
        table.insert(body, "## Steps to Reproduce\n")
        for i, cmd in ipairs(test.command_log) do
            table.insert(body, string.format("%d. %s", i, cmd.command))
        end
        table.insert(body, "")
    end

    -- Log output (warnings and errors)
    if test.log_output then
        local important_logs = {}
        for _, log in ipairs(test.log_output) do
            if log.level == "warning" or log.level == "error" then
                table.insert(important_logs, log)
            end
        end

        if #important_logs > 0 then
            table.insert(body, "## Log Output\n")
            table.insert(body, "```")
            for _, log in ipairs(important_logs) do
                table.insert(body, string.format("[%s] %s", log.level, log.message))
            end
            table.insert(body, "```")
            table.insert(body, "")
        end
    end

    return table.concat(body, "\n")
end

return GitHubIssueCreator
