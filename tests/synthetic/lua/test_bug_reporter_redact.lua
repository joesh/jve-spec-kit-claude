-- Privacy redaction for capture.json (FR-019, FR-020).
--
-- Black-box: drive bug_reporter.redact through realistic samples
-- of command parameters and log lines and assert that no user home
-- or volume path makes it through.

print("=== test_bug_reporter_redact.lua ===")
require("test_env")

local redact = require("bug_reporter.redact")
local HOME = os.getenv("HOME") or ""
assert(#HOME > 0, "test requires HOME env var")

-- (1) raw HOME prefix → ~
local s1 = redact.redact_string(HOME .. "/Documents/foo.mov")
assert(s1:sub(1, 1) == "~", "HOME-prefixed path must redact to ~ ... got " .. s1)
assert(not s1:find(HOME, 1, true), "redacted output must not contain literal HOME")

-- (2) other-user home → ~<user>
local s2 = redact.redact_string("/Users/alice/Secrets/private.txt")
assert(s2:find("~<user>", 1, true),
    "/Users/<other>/... must redact to ~<user>; got " .. s2)
assert(not s2:find("alice", 1, true),
    "redacted output must not contain literal foreign-user name; got " .. s2)

-- (3) /Volumes → /Volumes/<redacted>/...
local s3 = redact.redact_string("/Volumes/AnamBack4/Footage/clip.mov")
assert(s3:find("/Volumes/<redacted>", 1, true),
    "/Volumes/<name>/... must redact; got " .. s3)
assert(not s3:find("AnamBack4", 1, true), "volume name leaked")

-- (4) Embedded substring in a log message redacts too
local msg = "Failed to open " .. HOME .. "/proj.jvp at offset 42"
local s4 = redact.redact_string(msg)
assert(not s4:find(HOME, 1, true), "embedded HOME in log message must redact: " .. s4)

-- (5) Parameters table walked recursively, paths replaced
local params = {
    path = HOME .. "/Movies/test.mov",
    nested = {
        url = "/Users/bob/file.txt",
        ok = true,
        count = 7,
    },
}
local out = redact.redact_parameters(params)
assert(out.path:sub(1, 1) == "~",
    "params.path must redact; got " .. tostring(out.path))
assert(out.nested.url:find("~<user>", 1, true),
    "nested foreign-user path must redact; got " .. tostring(out.nested.url))
assert(out.nested.ok == true and out.nested.count == 7,
    "non-string params must pass through unchanged")

-- (6) Non-table, non-string inputs pass through
assert(redact.redact_parameters(42) == 42, "numbers pass through")
assert(redact.redact_parameters(nil) == nil, "nil passes through")
assert(redact.redact_parameters(true) == true, "booleans pass through")

print("✅ test_bug_reporter_redact.lua passed")
