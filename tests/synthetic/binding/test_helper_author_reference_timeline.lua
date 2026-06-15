-- author_reference_timeline contract (spec 023; TEST_VERB, --allow-test-verbs).
--
-- Test-only state-changing verb: authors a clip in a throwaway project at a
-- caller-specified frame rate and exports a .drt — used to capture real
-- Resolve-authored bytes (MTBA, source <In>) at arbitrary rates. Optional
-- trim args (source_in_frame + source_duration_frames) window the clip.
--
-- Contract-test scope (mirrors §apply_test_grade): asserts ONLY the wire
-- arg gates the helper enforces BEFORE any Resolve call (CreateProject) —
-- never the happy path, which would author + delete a throwaway project in
-- the operator's open Resolve (forbidden here per
-- feedback_contract_tests_must_not_poke_live_resolve). The happy path is
-- exercised by the VM live tests (test_drt_forward_mtba_resolve_authored,
-- test_drt_source_in_resolve_authored).
--
-- All malformed-arg cases below return bad_request before the verb touches
-- the Resolve API, so this is safe to run against an open Resolve. The
-- trim-gate cases pass a real (existing) media path + valid fps + out path
-- so validation reaches the trim block, but bad trim args still fail before
-- CreateProject.
--
-- Run via `jve --test`.

local test_env = require("test_env")
local fixture  = require("synthetic.binding.helper_fixture")

local fix = fixture.start("/tmp/jve-contract-author-ref.sock")

-- A real, existing media path so the os.path.exists gate passes and the
-- trim-arg gates are reachable. Never authored (trim args are malformed).
local REAL_MEDIA = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")
local OUT = "/tmp/jve/contract_author_ref.drt"

-- ─── missing media_path → bad_request ──────────────────────────────
do
    local r = fixture.request(fix, "author_reference_timeline", {
        timeline_fps = "23.976", out_drt_path = OUT,
    })
    fixture.assert_structured_error(r, "bad_request", "missing media_path")
    assert(r.error.message:find("media_path", 1, true),
        "bad_request should name the missing arg: " .. r.error.message)
    print("  ✓ missing media_path → bad_request")
end

-- ─── missing timeline_fps → bad_request ────────────────────────────
do
    local r = fixture.request(fix, "author_reference_timeline", {
        media_path = REAL_MEDIA, out_drt_path = OUT,
    })
    fixture.assert_structured_error(r, "bad_request", "missing timeline_fps")
    assert(r.error.message:find("timeline_fps", 1, true),
        "bad_request should name the missing arg: " .. r.error.message)
    print("  ✓ missing timeline_fps → bad_request")
end

-- ─── missing out_drt_path → bad_request ────────────────────────────
do
    local r = fixture.request(fix, "author_reference_timeline", {
        media_path = REAL_MEDIA, timeline_fps = "23.976",
    })
    fixture.assert_structured_error(r, "bad_request", "missing out_drt_path")
    assert(r.error.message:find("out_drt_path", 1, true),
        "bad_request should name the missing arg: " .. r.error.message)
    print("  ✓ missing out_drt_path → bad_request")
end

-- ─── nonexistent media_path → bad_request ──────────────────────────
do
    local r = fixture.request(fix, "author_reference_timeline", {
        media_path   = "/tmp/jve/does_not_exist_xyz.mov",
        timeline_fps = "23.976", out_drt_path = OUT,
    })
    fixture.assert_structured_error(r, "bad_request", "nonexistent media")
    assert(r.error.message:find("does not exist", 1, true),
        "bad_request should report the missing file: " .. r.error.message)
    print("  ✓ nonexistent media_path → bad_request")
end

-- ─── trim: negative source_in_frame → bad_request ──────────────────
do
    local r = fixture.request(fix, "author_reference_timeline", {
        media_path   = REAL_MEDIA, timeline_fps = "23.976",
        out_drt_path = OUT,
        source_in_frame = -5, source_duration_frames = 24,
    })
    fixture.assert_structured_error(r, "bad_request", "negative source_in")
    assert(r.error.message:find("source_in_frame", 1, true),
        "bad_request should name source_in_frame: " .. r.error.message)
    print("  ✓ negative source_in_frame → bad_request")
end

-- ─── trim: source_in_frame present, duration missing → bad_request ─
-- (the both-or-neither pairing gate fires first)
do
    local r = fixture.request(fix, "author_reference_timeline", {
        media_path   = REAL_MEDIA, timeline_fps = "23.976",
        out_drt_path = OUT, source_in_frame = 30,
    })
    fixture.assert_structured_error(r, "bad_request", "duration missing")
    assert(r.error.message:find("both", 1, true)
        and r.error.message:find("source_duration_frames", 1, true),
        "bad_request should name the pairing requirement: " .. r.error.message)
    print("  ✓ source_in_frame without duration → bad_request")
end

-- ─── trim: duration present, source_in_frame missing → bad_request ─
-- (symmetric pairing violation — the other half)
do
    local r = fixture.request(fix, "author_reference_timeline", {
        media_path   = REAL_MEDIA, timeline_fps = "23.976",
        out_drt_path = OUT, source_duration_frames = 24,
    })
    fixture.assert_structured_error(r, "bad_request", "source_in missing")
    assert(r.error.message:find("both", 1, true)
        and r.error.message:find("source_in_frame", 1, true),
        "bad_request should name the pairing requirement: " .. r.error.message)
    print("  ✓ source_duration_frames without source_in_frame → bad_request")
end

-- ─── trim: non-positive duration → bad_request ─────────────────────
do
    local r = fixture.request(fix, "author_reference_timeline", {
        media_path   = REAL_MEDIA, timeline_fps = "23.976",
        out_drt_path = OUT,
        source_in_frame = 30, source_duration_frames = 0,
    })
    fixture.assert_structured_error(r, "bad_request", "zero duration")
    assert(r.error.message:find("source_duration_frames", 1, true),
        "bad_request should name source_duration_frames: " .. r.error.message)
    print("  ✓ zero source_duration_frames → bad_request")
end

-- ─── trim: non-integral float frame count → bad_request ────────────
-- JSON numbers may arrive as float; only integral values coerce.
do
    local r = fixture.request(fix, "author_reference_timeline", {
        media_path   = REAL_MEDIA, timeline_fps = "23.976",
        out_drt_path = OUT,
        source_in_frame = 30, source_duration_frames = 24.5,
    })
    fixture.assert_structured_error(r, "bad_request", "fractional duration")
    assert(r.error.message:find("source_duration_frames", 1, true),
        "bad_request should name source_duration_frames: " .. r.error.message)
    print("  ✓ non-integral source_duration_frames → bad_request")
end

-- ─── unknown args field → bad_request ──────────────────────────────
do
    local r = fixture.request(fix, "author_reference_timeline", {
        media_path   = REAL_MEDIA, timeline_fps = "23.976",
        out_drt_path = OUT, bogus_field = "x",
    })
    fixture.assert_structured_error(r, "bad_request", "unknown args field")
    assert(r.error.message:find("bogus_field", 1, true),
        "bad_request should name the unknown field: " .. r.error.message)
    print("  ✓ unknown args field → bad_request")
end

fixture.stop(fix)

print("✅ test_helper_author_reference_timeline.lua passed")
