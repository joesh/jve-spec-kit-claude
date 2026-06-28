-- ~/.jve/install_id.json persistence (feature 027 T033).
--
-- Single source of truth for the bug-reporter's bootstrap state:
-- install_id (UUID v4), per-install nonce, consent metadata, hardware
-- snapshot at last successful /register or /heartbeat, country +
-- timezone returned by the Worker, and jve_sha_at_register (which
-- gates the FR-018 hardware re-snapshot on every heartbeat).
--
-- Writes go through utils.write_secure_file → qt_fs_atomic_write_secure
-- (POSIX open + O_NOFOLLOW + O_EXCL temp + fsync + rename) so the file
-- is mode-0600, never partially written, and never redirected through
-- an attacker-planted symlink in $HOME.
--
-- Schema is versioned at the file level. If we read a file with a
-- schema_version we don't know how to handle, we ASSERT — silent
-- drift is worse than a loud crash (FR-019a). When the schema changes,
-- bump SCHEMA_VERSION and add a migration in M.read.
--
-- Malformed JSON or missing required fields also ASSERT.

local dkjson = require("dkjson")
local utils  = require("bug_reporter.utils")
local uuid   = require("uuid")

local M = {}

local SCHEMA_VERSION = 1

local home_override
local UUID_V4_PATTERN = "^[0-9a-f]+%-[0-9a-f]+%-4[0-9a-f]+%-[89ab][0-9a-f]+%-[0-9a-f]+$"
local HEX64_PATTERN   = "^[0-9a-f]+$"

local function home()
    if home_override then return home_override end
    local h = os.getenv("HOME")
    assert(h and h ~= "",
        "bug_reporter.install: HOME env var is unset — required to locate ~/.jve/")
    return h
end

local function jve_dir() return home() .. "/.jve" end
local function path()    return jve_dir() .. "/install_id.json" end

function M.set_home_for_tests(dir)
    home_override = dir
end

function M.generate_id()
    return uuid.generate()
end

local function validate(record, src)
    assert(type(record) == "table",
        "bug_reporter.install: " .. src .. " is not a JSON object")
    assert(type(record.schema_version) == "number",
        "bug_reporter.install: " .. src .. " missing schema_version (required since rewrite)")
    assert(record.schema_version == SCHEMA_VERSION,
        "bug_reporter.install: " .. src .. " schema_version=" .. tostring(record.schema_version) ..
        " but current is " .. SCHEMA_VERSION .. " (no migration registered)")
    assert(type(record.install_id) == "string" and record.install_id:match(UUID_V4_PATTERN),
        "bug_reporter.install: " .. src .. " missing or invalid install_id")
    assert(type(record.nonce) == "string" and #record.nonce == 64
        and record.nonce:match(HEX64_PATTERN),
        "bug_reporter.install: " .. src .. " missing or invalid nonce (need 64-hex)")
    assert(type(record.consent_accepted_ts) == "number" and record.consent_accepted_ts > 0,
        "bug_reporter.install: " .. src .. " missing consent_accepted_ts")
    assert(type(record.consent_version) == "number" and record.consent_version > 0,
        "bug_reporter.install: " .. src .. " missing consent_version")
    assert(type(record.jve_sha_at_register) == "string" and #record.jve_sha_at_register == 7,
        "bug_reporter.install: " .. src .. " missing jve_sha_at_register")
end

function M.read()
    local p = path()
    local f = io.open(p, "r")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    local decoded, _, err = dkjson.decode(body)
    assert(decoded,
        "bug_reporter.install: failed to parse " .. p ..
        ": " .. tostring(err or "unknown"))
    -- Backfill schema_version=1 for files written before the rewrite.
    -- This is the ONE migration we accept (the original schema was V1
    -- in all but name). Future bumps MUST do explicit migration here
    -- and reject older versions cleanly.
    if decoded.schema_version == nil then
        decoded.schema_version = 1
    end
    validate(decoded, p)
    return decoded
end

function M.write(record)
    record.schema_version = SCHEMA_VERSION
    validate(record, "in-memory record")
    assert(utils.mkdir_p(jve_dir()))
    local ok, err = utils.write_secure_file(path(),
        dkjson.encode(record, { indent = true }))
    assert(ok, "bug_reporter.install: write failed: " .. tostring(err))
end

return M
