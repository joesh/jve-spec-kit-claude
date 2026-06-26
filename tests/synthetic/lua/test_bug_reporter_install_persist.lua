-- Feature 027 T024: install.lua persistence + validation behavior.
--
-- The install record at ~/.jve/install_id.json is the bug-reporter's
-- bootstrap state. If it's malformed or missing required fields, the
-- pipeline MUST fail loud rather than silently drift (FR-019a) — a
-- bug reporter that emits truncated reports is worse than one that
-- crashes on launch.
--
-- Black-box per Constitution III: tests describe persistence behavior
-- without naming the parser/serializer functions.

require("test_env")

local function require_or_red(modname, task)
    local ok, mod = pcall(require, modname)
    if not ok then
        error("RED — " .. modname .. " unloadable (" .. task .. " not landed): " .. tostring(mod))
    end
    return mod
end

local install = require_or_red("bug_reporter.install", "T033")

local TMP = "/tmp/jve_install_test_" .. tostring(math.random(1, 1e9))
os.execute("/bin/mkdir -p " .. TMP)
-- install.read uses HOME — redirect via the test-only hook T033 exposes.
if type(install.set_home_for_tests) == "function" then
    install.set_home_for_tests(TMP)
else
    error("RED — install.set_home_for_tests missing; T033 must expose a test-only home override")
end

local function path() return TMP .. "/.jve/install_id.json" end

local function cleanup()
    os.execute("/bin/rm -rf " .. TMP)
end

-- (1) Round-trip: write returns a record, read returns the same record.
do
    local record = {
        install_id = "550e8400-e29b-41d4-a716-446655440000",
        nonce = string.rep("a", 64),
        consent_accepted_ts = 1719279600,
        consent_version = 1,
        jve_sha_at_register = "8935293",
        hardware_snapshot = {
            platform = "Darwin",
            arch = "arm64",
        },
        country = "US",
        timezone = "America/Los_Angeles",
    }
    install.write(record)
    local roundtrip = install.read()
    assert(roundtrip, "install.read returned nil after write")
    assert(roundtrip.install_id == record.install_id,
        "round-trip install_id mismatch: " .. tostring(roundtrip.install_id))
    assert(roundtrip.nonce == record.nonce, "round-trip nonce mismatch")
end

-- (2) File perms after write: owner-only (600).
do
    local p = path()
    local pipe = assert(io.popen("/usr/bin/stat -f %A " .. p))
    local mode = pipe:read("*l")
    pipe:close()
    assert(mode == "600",
        "install file perms must be 600, got " .. tostring(mode))
end

-- (3) Malformed JSON → assert with file path + "parse" in the message.
do
    local f = assert(io.open(path(), "w"))
    f:write("{ this is not valid json }")
    f:close()
    local ok, err = pcall(install.read)
    assert(not ok, "expected install.read to assert on malformed JSON")
    local err_s = tostring(err)
    assert(err_s:find(path(), 1, true),
        "assert message must include the file path; got: " .. err_s)
    assert(err_s:lower():find("parse"),
        "assert message must include 'parse'; got: " .. err_s)
end

-- (4) Missing nonce field → assert.
do
    local f = assert(io.open(path(), "w"))
    f:write('{"install_id":"550e8400-e29b-41d4-a716-446655440000",' ..
        '"consent_accepted_ts":1719279600,"consent_version":1,' ..
        '"jve_sha_at_register":"8935293",' ..
        '"hardware_snapshot":{"platform":"Darwin","arch":"arm64"}}')
    f:close()
    local ok, err = pcall(install.read)
    assert(not ok, "expected install.read to assert on missing nonce field")
    assert(tostring(err):lower():find("nonce"),
        "assert message must mention nonce; got: " .. tostring(err))
end

-- (5) generate_id returns a UUID v4.
do
    local id = install.generate_id()
    assert(type(id) == "string" and #id == 36,
        "generate_id must return a 36-char string, got: " .. tostring(id))
    -- v4 UUID: 8-4-4-4-12 hex with version 4 nibble.
    assert(id:match("^[0-9a-f]+-[0-9a-f]+-4[0-9a-f]+-[89ab][0-9a-f]+-[0-9a-f]+$"),
        "generate_id must return a UUID v4, got: " .. id)
end

cleanup()
print("✅ test_bug_reporter_install_persist.lua passed")
