-- Feature 027 T002: cluster signature is deterministic and matches the
-- shared Lua/TS fixture vectors. Black-box per Constitution III — this
-- test asserts behavior (same logical bug → same signature; ReportBug
-- trigger does not dominate cluster space) without naming any specific
-- function or implementation file in the assertion messages.

require("test_env")
local dkjson = require("dkjson")

-- Loader guard: until T008 lands, require() of the signature module
-- fails with "module 'X' not found". Catch that and produce an
-- actionable red message instead of a generic module-not-found crash.
-- Once T008 is in, this branch never fires.
local ok, signature = pcall(require, "bug_reporter.signature")
if not ok then
    local why = tostring(signature)
    assert(why:find("not found"),
        "bug_reporter.signature unloadable for an unexpected reason: " .. why)
    error("RED — bug_reporter.signature not implemented yet (T008). Loader error: " .. why)
end

local function read_fixture()
    local repo_root = os.getenv("PWD")
    -- tests run from tests/ directory under the harness; pwd is repo root or tests/
    local candidates = {
        repo_root .. "/tests/fixtures/signature_vectors.json",
        repo_root .. "/fixtures/signature_vectors.json",
        "tests/fixtures/signature_vectors.json",
        "fixtures/signature_vectors.json",
    }
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            local body = f:read("*a")
            f:close()
            local decoded, _, err = dkjson.decode(body)
            assert(decoded, "signature_vectors.json present at " .. path .. " but unparseable: " .. tostring(err))
            return decoded
        end
    end
    error("signature_vectors.json not found at any of: " .. table.concat(candidates, ", "))
end

local fixture = read_fixture()
assert(fixture.vectors and #fixture.vectors == 6,
    "fixture must carry exactly 6 vectors (current: " .. tostring(#(fixture.vectors or {})) .. ")")

local fail_count = 0
for _, v in ipairs(fixture.vectors) do
    local got = signature.compute(v.capture_type, v.last_commands, v.error_message, v.user_description)
    if got ~= v.expected_sig then
        fail_count = fail_count + 1
        print(string.format("FAIL %s\n  expected: %s\n  actual:   %s",
            v.name, v.expected_sig, tostring(got)))
    end
end

assert(fail_count == 0,
    string.format("%d/%d fixture vector(s) produced wrong signature — cluster-dedup invariant broken",
        fail_count, #fixture.vectors))

-- Independent cross-check: vectors A and B carry the same expected_sig
-- on purpose (case+punctuation normalization clusters them). If the
-- impl ever produces different hashes for these two, dedup will silently
-- create twin clusters in production.
local sig_a = signature.compute("user_submitted", {"RippleTrimEdge","MoveClip","AddTrack"}, nil,
    "Cuts disappear after undo")
local sig_b = signature.compute("user_submitted", {"RippleTrimEdge","MoveClip","AddTrack"}, nil,
    "CUTS, disappear! After... UNDO?")
assert(sig_a == sig_b,
    "case+punctuation variants of the same description MUST cluster — got " .. sig_a .. " vs " .. sig_b)

-- Independent cross-check: ReportBug as trailing command must be filtered
-- so F12 does not dominate cluster space (FR-012).
local sig_with_reportbug = signature.compute("user_submitted",
    {"RippleTrimEdge","MoveClip","ReportBug"}, nil, "x")
local sig_without_reportbug = signature.compute("user_submitted",
    {"RippleTrimEdge","MoveClip"}, nil, "x")
assert(sig_with_reportbug == sig_without_reportbug,
    "trailing ReportBug must be filtered before signing — same root cause must collapse to same cluster")

print("✅ test_bug_reporter_signature.lua passed")
