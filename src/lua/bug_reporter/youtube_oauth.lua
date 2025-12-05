-- youtube_oauth.lua
-- YouTube OAuth 2.0 authentication flow for uploading bug report videos

local dkjson = require("dkjson")
local utils = require("bug_reporter.utils")
local logger = require("core.logger")

local YouTubeOAuth = {}

-- OAuth configuration
local OAUTH_CONFIG = {
    -- Users will need to create their own OAuth app at:
    -- https://console.cloud.google.com/apis/credentials
    client_id = nil,  -- Set from preferences
    client_secret = nil,  -- Set from preferences
    redirect_uri = "http://localhost:8080/oauth2callback",
    auth_url = "https://accounts.google.com/o/oauth2/v2/auth",
    token_url = "https://oauth2.googleapis.com/token",
    scopes = "https://www.googleapis.com/auth/youtube.upload"
}

-- Token storage path
local TOKEN_FILE = os.getenv("HOME") .. "/.jve_youtube_token.json"

-- Set OAuth credentials (from preferences)
-- @param client_id: OAuth client ID from Google Cloud Console
-- @param client_secret: OAuth client secret
function YouTubeOAuth.set_credentials(client_id, client_secret)
    OAUTH_CONFIG.client_id = client_id
    OAUTH_CONFIG.client_secret = client_secret
end

-- Generate authorization URL for user to visit
-- @return: Authorization URL string
function YouTubeOAuth.get_authorization_url()
    if not OAUTH_CONFIG.client_id then
        return nil, "OAuth client ID not configured"
    end

    local params = {
        client_id = OAUTH_CONFIG.client_id,
        redirect_uri = OAUTH_CONFIG.redirect_uri,
        response_type = "code",
        scope = OAUTH_CONFIG.scopes,
        access_type = "offline",  -- Request refresh token
        prompt = "consent"  -- Force consent to get refresh token
    }

    local query = {}
    for k, v in pairs(params) do
        table.insert(query, k .. "=" .. YouTubeOAuth.url_encode(v))
    end

    return OAUTH_CONFIG.auth_url .. "?" .. table.concat(query, "&")
end

-- URL encode a string (delegate to utils)
-- @param str: String to encode
-- @return: Encoded string
function YouTubeOAuth.url_encode(str)
    return utils.url_encode(str)
end

-- Exchange authorization code for tokens
-- @param auth_code: Authorization code from OAuth callback
-- @return: Token response (access_token, refresh_token, expires_in)
function YouTubeOAuth.exchange_code_for_tokens(auth_code)
    if not OAUTH_CONFIG.client_id or not OAUTH_CONFIG.client_secret then
        return nil, "OAuth credentials not configured"
    end

    local post_data = {
        code = auth_code,
        client_id = OAUTH_CONFIG.client_id,
        client_secret = OAUTH_CONFIG.client_secret,
        redirect_uri = OAUTH_CONFIG.redirect_uri,
        grant_type = "authorization_code"
    }

    local post_body = {}
    for k, v in pairs(post_data) do
        table.insert(post_body, k .. "=" .. YouTubeOAuth.url_encode(v))
    end
    post_body = table.concat(post_body, "&")

    -- Make POST request using curl
    local cmd = string.format(
        "curl -s -X POST '%s' -H 'Content-Type: application/x-www-form-urlencoded' -d '%s'",
        OAUTH_CONFIG.token_url,
        post_body:gsub("'", "'\\''")  -- Escape single quotes
    )

    local handle = io.popen(cmd)
    local response = handle:read("*a")
    handle:close()

    -- Parse JSON response
    local tokens, pos, err = dkjson.decode(response)
    if not tokens then
        return nil, "Failed to parse token response: " .. (err or "unknown error")
    end

    if tokens.error then
        return nil, "OAuth error: " .. (tokens.error_description or tokens.error)
    end

    -- Save tokens to file
    YouTubeOAuth.save_tokens(tokens)

    return tokens
end

-- Refresh access token using refresh token
-- @return: New token response
function YouTubeOAuth.refresh_access_token()
    local tokens = YouTubeOAuth.load_tokens()
    if not tokens or not tokens.refresh_token then
        return nil, "No refresh token available - need to re-authenticate"
    end

    local post_data = {
        refresh_token = tokens.refresh_token,
        client_id = OAUTH_CONFIG.client_id,
        client_secret = OAUTH_CONFIG.client_secret,
        grant_type = "refresh_token"
    }

    local post_body = {}
    for k, v in pairs(post_data) do
        table.insert(post_body, k .. "=" .. YouTubeOAuth.url_encode(v))
    end
    post_body = table.concat(post_body, "&")

    local cmd = string.format(
        "curl -s -X POST '%s' -H 'Content-Type: application/x-www-form-urlencoded' -d '%s'",
        OAUTH_CONFIG.token_url,
        post_body:gsub("'", "'\\''")
    )

    local handle = io.popen(cmd)
    local response = handle:read("*a")
    handle:close()

    local new_tokens, pos, err = dkjson.decode(response)
    if not new_tokens then
        return nil, "Failed to parse refresh response: " .. (err or "unknown error")
    end

    if new_tokens.error then
        return nil, "Refresh error: " .. (new_tokens.error_description or new_tokens.error)
    end

    -- Preserve refresh token if not included in response
    if not new_tokens.refresh_token then
        new_tokens.refresh_token = tokens.refresh_token
    end

    -- Save updated tokens
    YouTubeOAuth.save_tokens(new_tokens)

    return new_tokens
end

-- Get valid access token (refreshes if expired)
-- @return: Access token string, or nil + error
function YouTubeOAuth.get_access_token()
    local tokens = YouTubeOAuth.load_tokens()
    if not tokens then
        return nil, "Not authenticated - need to run OAuth flow"
    end

    -- Check if token is expired (with 5 minute buffer)
    if tokens.expires_at and os.time() >= (tokens.expires_at - 300) then
        -- Token expired, refresh it
        local new_tokens, err = YouTubeOAuth.refresh_access_token()
        if not new_tokens then
            return nil, err
        end
        tokens = new_tokens
    end

    return tokens.access_token
end

-- Save tokens to file
-- @param tokens: Token response from OAuth
function YouTubeOAuth.save_tokens(tokens)
    -- Add expiration timestamp
    if tokens.expires_in then
        tokens.expires_at = os.time() + tokens.expires_in
    end

    local json = dkjson.encode(tokens, {indent = true})

    -- Use secure file write to prevent race condition
    local success, err = utils.write_secure_file(TOKEN_FILE, json)
    if not success then
        logger.warn("bug_reporter", "Failed to save YouTube tokens: " .. (err or "unknown error"))
    end
end

-- Load tokens from file
-- @return: Token object, or nil if not found
function YouTubeOAuth.load_tokens()
    local file = io.open(TOKEN_FILE, "r")
    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()

    local tokens, pos, err = dkjson.decode(content)
    return tokens
end

-- Check if user is authenticated
-- @return: Boolean
function YouTubeOAuth.is_authenticated()
    local tokens = YouTubeOAuth.load_tokens()
    return tokens ~= nil and tokens.access_token ~= nil
end

-- Clear stored tokens (logout)
function YouTubeOAuth.clear_tokens()
    os.remove(TOKEN_FILE)
end

-- Start simple HTTP server to receive OAuth callback
-- This is a minimal implementation for receiving the auth code
-- @param callback: Function(auth_code) to call when code received
-- @return: Server shutdown function
function YouTubeOAuth.start_callback_server(callback)
    -- Create simple HTTP server using nc (netcat)
    -- This is a basic implementation - production should use proper HTTP server

    local temp_dir = utils.get_temp_dir()
    local response_file = temp_dir .. "/jve_oauth_response.txt"
    local code_file = temp_dir .. "/jve_oauth_code.txt"

    local server_script = string.format([[
#!/bin/bash
while true; do
    echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h1>Authorization Successful!</h1><p>You can close this window and return to JVE.</p></body></html>" | nc -l 8080 > %s

    # Extract auth code from response
    code=$(grep 'GET /' %s | sed 's/.*code=\([^& ]*\).*/\1/')

    if [ -n "$code" ]; then
        echo "$code" > %s
        break
    fi
done
]], response_file, response_file, code_file)

    -- Write server script
    local script_path = temp_dir .. "/jve_oauth_server.sh"
    local file = io.open(script_path, "w")
    file:write(server_script)
    file:close()
    os.execute("chmod +x '" .. script_path .. "'")

    -- Start server in background
    os.execute(script_path .. " &")

    -- Return function to check for code
    return function()
        local file = io.open(code_file, "r")
        if file then
            local code = file:read("*a"):gsub("%s+", "")
            file:close()
            os.remove(code_file)
            os.remove(response_file)
            os.execute("pkill -f jve_oauth_server")
            return code
        end
        return nil
    end
end

return YouTubeOAuth
