-- T014 — helper import_timeline contract
--           (spec 023, contracts/helper-protocol.md §import_timeline).
--
-- Asserts every observable surface of the verb that does NOT require a
-- live import:
--   • bad_request paths (missing drt_path, malformed media_paths,
--     nonexistent files) — these reach helper.py without ever touching
--     Resolve and exercise the validation block.
--   • Structured error envelope (closed-set code, non-empty message).
--   • Idempotency-key gate (FR-008): omitting change_token must NOT be
--     silently accepted by the protocol layer.
--
-- The success-shape `{mapping, unrelinked}` is asserted when the verb's
-- relink + identity-mapping land in T029 (mapping/relink against the
-- live scripting surface). We deliberately do NOT poke the live
-- `ImportTimelineFromFile` path here: when Resolve is up, an
-- ill-formed DRT raises a modal "Unable to Import Project" dialog in
-- the user's editor — see todo_t014_extend_import_timeline_success_shape
-- for the deferred assertion that T029 must wire against an
-- authored-by-payload_builder fixture.
--
-- Run via `jve --test`.

local fixture  = require("synthetic.binding.helper_fixture")
local protocol = require("core.resolve_bridge.protocol")

local fix = fixture.start("/tmp/jve-contract-import.sock")

local VALID_TOKEN = {
    project_id = "p-test",
    sequence_id = "s-test",
    mutation_generation = 1,
}

-- ─── bad_request: missing drt_path ──────────────────────────────────────
do
    local r = fixture.request(fix, "import_timeline", {
        media_paths = { "/tmp" },
        change_token = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request", "missing drt_path")
    assert(r.error.message:find("drt_path", 1, true),
        "bad_request message should name the missing arg: "
        .. r.error.message)
    print("  ✓ missing drt_path → bad_request")
end

-- ─── bad_request: malformed media_paths ─────────────────────────────────
do
    local r = fixture.request(fix, "import_timeline", {
        drt_path = "/tmp/does-not-matter.drt",
        media_paths = "/tmp",  -- string, contract says list[string]
        change_token = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request", "media_paths wrong type")
    assert(r.error.message:find("media_paths", 1, true),
        "bad_request should name the wrong-typed arg: "
        .. r.error.message)
    print("  ✓ malformed media_paths → bad_request")
end

-- ─── bad_request: media_paths entry not a non-empty string ─────────────
do
    local r = fixture.request(fix, "import_timeline", {
        drt_path = "/tmp/does-not-matter.drt",
        media_paths = { "" },
        change_token = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request", "empty media_paths entry")
    assert(r.error.message:find("media_paths", 1, true),
        "bad_request should name media_paths: " .. r.error.message)
    print("  ✓ empty media_paths entry → bad_request")
end

-- ─── bad_request: media_paths entry does not exist ──────────────────────
-- Pre-import is what makes Resolve link DRT items byte-correctly
-- (materializing from the DRT's embedded pool XML yields degenerate
-- item source ranges — live-bisected 2026-06-10); a missing media file
-- can therefore never produce a faithful timeline. Checked before any
-- Resolve mutation.
do
    local tmp_drt = "/tmp/jve-contract-import-media.drt"
    local f = io.open(tmp_drt, "w"); f:write("x"); f:close()
    local missing = "/tmp/jve-contract-no-such-media-" .. os.time() .. ".mp4"
    os.remove(missing)
    local r = fixture.request(fix, "import_timeline", {
        drt_path        = tmp_drt,
        media_paths     = { missing },
        clip_positions  = {
            { clip_id = "c1", track_type = "video",
              track_index = 1, record_start = 0 },
        },
        change_token    = VALID_TOKEN,
    })
    os.remove(tmp_drt)
    fixture.assert_structured_error(r, "bad_request",
        "nonexistent media_paths entry")
    assert(r.error.message:find(missing, 1, true),
        "message should name the missing media path: " .. r.error.message)
    print("  ✓ nonexistent media_paths entry → bad_request")
end

-- ─── bad_request: drt_path does not exist ───────────────────────────────
do
    local missing = "/tmp/jve-contract-no-such-drt-" .. os.time() .. ".drt"
    os.remove(missing)  -- belt-and-braces in case of collision
    local r = fixture.request(fix, "import_timeline", {
        drt_path = missing,
        media_paths = {},
        change_token = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request", "drt_path nonexistent")
    assert(r.error.message:find(missing, 1, true)
        or r.error.message:find("does not exist", 1, true),
        "message should explain the path doesn't exist: "
        .. r.error.message)
    print("  ✓ nonexistent drt_path → bad_request")
end

-- ─── idempotency-key gate (protocol-level, FR-008) ──────────────────────
-- Omitting change_token on a state-changing verb must fail on the JVE
-- side (protocol.idempotency_key asserts) — never reach the helper.
-- This is the boundary check that prevents un-idempotent state mutation.
do
    local ok, err = pcall(protocol.idempotency_key, {
        verb = "import_timeline",
        args = {},  -- no change_token
    })
    assert(not ok, "missing change_token must raise on the client side")
    assert(tostring(err):find("change_token", 1, true),
        "error should name change_token: " .. tostring(err))
    print("  ✓ missing change_token → client-side assertion (FR-008)")
end

-- ─── bad_request: missing clip_positions ───────────────────────────────
-- clip_positions is the JVE-side position map the helper uses to derive
-- the identity mapping (FR-021: helper holds no JVE state). Missing →
-- the helper can't determine which Resolve item is which JVE clip.
do
    -- Real .drt path so the drt_path-exists check passes; helper then
    -- gets to the clip_positions check.
    local tmp_drt = "/tmp/jve-contract-import-positions.drt"
    local f = io.open(tmp_drt, "w")
    assert(f, "fixture: couldn't create scratch DRT")
    f:write("not really a DRT but the path exists\n")
    f:close()
    local r = fixture.request(fix, "import_timeline", {
        drt_path     = tmp_drt,
        media_paths  = {},
        change_token = VALID_TOKEN,
    })
    os.remove(tmp_drt)
    fixture.assert_structured_error(r, "bad_request", "missing clip_positions")
    assert(r.error.message:find("clip_positions", 1, true),
        "bad_request should name clip_positions: " .. r.error.message)
    print("  ✓ missing clip_positions → bad_request")
end

-- ─── bad_request: clip_positions wrong outer type ──────────────────────
do
    local tmp_drt = "/tmp/jve-contract-import-positions.drt"
    local f = io.open(tmp_drt, "w"); f:write("x"); f:close()
    local r = fixture.request(fix, "import_timeline", {
        drt_path        = tmp_drt,
        media_paths     = {},
        clip_positions  = "not-a-list",
        change_token    = VALID_TOKEN,
    })
    os.remove(tmp_drt)
    fixture.assert_structured_error(r, "bad_request",
        "clip_positions wrong outer type")
    assert(r.error.message:find("clip_positions", 1, true),
        "bad_request should name clip_positions: " .. r.error.message)
    print("  ✓ clip_positions wrong outer type → bad_request")
end

-- ─── bad_request: clip_positions entry malformed ───────────────────────
do
    local tmp_drt = "/tmp/jve-contract-import-positions.drt"
    local f = io.open(tmp_drt, "w"); f:write("x"); f:close()
    local r = fixture.request(fix, "import_timeline", {
        drt_path        = tmp_drt,
        media_paths     = {},
        clip_positions  = {
            { clip_id = "c1", track_type = "purple",
              track_index = 1, record_start = 0 },
        },
        change_token    = VALID_TOKEN,
    })
    os.remove(tmp_drt)
    fixture.assert_structured_error(r, "bad_request",
        "clip_positions invalid track_type")
    assert(r.error.message:find("track_type", 1, true),
        "bad_request should name track_type: " .. r.error.message)
    print("  ✓ clip_positions invalid track_type → bad_request")
end

-- ─── bad_request: clip_positions duplicate position key ────────────────
-- JVE clips MUST NOT stack at the same (track, record_start) — that's
-- a JVE timeline invariant. Helper rejects defensively.
do
    local tmp_drt = "/tmp/jve-contract-import-positions.drt"
    local f = io.open(tmp_drt, "w"); f:write("x"); f:close()
    local r = fixture.request(fix, "import_timeline", {
        drt_path        = tmp_drt,
        media_paths     = {},
        clip_positions  = {
            { clip_id = "c1", track_type = "video",
              track_index = 1, record_start = 0 },
            { clip_id = "c2", track_type = "video",
              track_index = 1, record_start = 0 },  -- duplicate key
        },
        change_token    = VALID_TOKEN,
    })
    os.remove(tmp_drt)
    fixture.assert_structured_error(r, "bad_request",
        "clip_positions duplicate position key")
    assert(r.error.message:find("duplicate", 1, true),
        "bad_request should name duplicate: " .. r.error.message)
    print("  ✓ clip_positions duplicate position key → bad_request")
end

fixture.stop(fix)

print("✅ test_helper_import_timeline.lua passed")
