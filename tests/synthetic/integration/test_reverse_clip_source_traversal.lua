-- Integration: reverse-clip source traversal against REAL bindings
-- (real TMB, real decoded media).
--
-- REPLACES (from tests/synthetic/lua/):
--   test_reverse_clip_playback.lua
--
-- The original was WHITE-BOX, mock-heavy: it replaced qt_constants /
-- Sequence / Track / renderer with fakes and asserted on the speed-ratio
-- math (source_out - source_in) / duration. That speed-ratio rule (forward
-- 1.0×, reverse −1.0×, slow-mo 0.5×/−0.5×, zero/nil asserts) is ALREADY
-- pinned domain-pure in test_playback_engine_contract.lua DR-17. This file
-- carries only the REMAINING domain scenario that DR-17 leaves uncovered:
--
--   RV-1  A reversed clip (source_in > source_out) plays its source content
--         backwards: as the timeline frame advances, the decoded source
--         frame walks DOWN through the media. A forward clip walks it UP, and
--         the two are mirror images about the clip's source midpoint. Pinned
--         against a REAL TMB priming a REAL clip from real media — the
--         observable is the TMB's reported source_frame per timeline frame,
--         derived from NLE convention (reverse = play media tail→head), NOT
--         from tracing the speed-ratio formula.
--
-- SCENARIOS ALREADY COVERED ELSEWHERE (not duplicated here):
--   §1 _compute_video_speed_ratio forward/reverse/slow-mo values  → DR-17
--   §2 _build_tmb_clip accepts negative / rejects zero speed       → DR-17 (zero asserts)
--
-- SCENARIOS DROPPED (unconvertible — needed a fake to observe):
--   §3/§4 "_provide_clips sends speed_ratio=−1.0 / negative audio speed to
--     TMB" — the original observed the value by intercepting a MOCK
--     TMB_ADD_CLIPS and reading clip.speed_ratio off the captured table. The
--     real TMB binding consumes clips opaquely; there is no real read-back of
--     the per-clip speed_ratio the Lua layer pushed. RV-1 instead pins the
--     OBSERVABLE consequence of a negative speed (source content walks
--     backwards), which is the domain behavior the user actually sees. The
--     plumbing value itself is an implementation detail.
--
-- OPEN QUESTIONS:
--   None.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_reverse_clip_source_traversal.lua

local ienv = require("synthetic.integration.integration_test_env")
local EMP  = ienv.require_emp()

print("=== test_reverse_clip_source_traversal.lua ===")

require("test_env")

-- ════════════════════════════════════════════════════════════════════════════
-- RV-1  Reverse clip plays source content backwards; forward plays it forwards.
--
-- Two REAL TMBs over the SAME real media, same timeline extent, same source
-- span [SRC_LO, SRC_HI). The forward clip maps timeline 0→N onto source
-- SRC_LO→SRC_HI (ascending). The reverse clip maps timeline 0→N onto source
-- SRC_HI→SRC_LO (descending). We prime each TMB at a spread of timeline
-- positions and read the source frame the TMB resolves for that position.
--
-- Domain expectation (NLE convention — what the operator sees):
--   forward: later timeline frame ⇒ later source frame  (monotone ↑)
--   reverse: later timeline frame ⇒ earlier source frame (monotone ↓)
-- and at the same timeline position the two are mirror images about the
-- clip's source midpoint: forward_src + reverse_src ≈ SRC_LO + SRC_HI.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (RV-1) reverse clip walks source content backwards --")
do
    local media_path = ienv.test_media_path(ienv.STANDARD_MEDIA)
    local RATE_NUM, RATE_DEN = 24000, 1001
    -- Source span well inside the 108-frame fixture so neither endpoint
    -- clamps. Non-trivial offset (not starting at 0) exercises the source
    -- coordinate math, per the test-quality rule against zero parameters.
    local SRC_LO, SRC_HI = 20, 80          -- 60 source frames
    local DURATION       = SRC_HI - SRC_LO -- 1.0× timeline span (60 frames)

    --- Build a single-clip TMB whose source mapping is forward or reversed.
    -- A reversed clip is encoded the NLE way: source_in > source_out.
    local function build_clip_tmb(reversed)
        local tmb = EMP.TMB_CREATE(0)
        assert(tmb, "RV-1: TMB_CREATE returned nil")
        EMP.TMB_SET_SEQUENCE_RATE(tmb, RATE_NUM, RATE_DEN)
        local src_in  = reversed and SRC_HI or SRC_LO
        local src_out = reversed and SRC_LO or SRC_HI
        EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, { {
            clip_id        = reversed and "rev" or "fwd",
            media_path     = media_path,
            sequence_start = 0,
            duration       = DURATION,
            source_in      = src_in,
            source_out     = src_out,
            rate_num       = RATE_NUM,
            rate_den       = RATE_DEN,
            -- (source_out - source_in)/duration: +1.0 forward, −1.0 reverse.
            speed_ratio    = (src_out - src_in) / DURATION,
        } })
        return tmb
    end

    --- Resolve the source frame the TMB reports for a timeline position.
    -- Primes the playhead (so the reader seeks) then asks for the frame and
    -- returns its source_frame from the real metadata. Pumps Qt events and
    -- retries so the background reader has time to actually decode.
    local function source_frame_at(tmb, direction, timeline_frame)
        EMP.TMB_SET_PLAYHEAD(tmb, timeline_frame, direction, 1.0)
        local src
        ienv.wait_until(function()
            qt_constants.CONTROL.PROCESS_EVENTS()
            local _, meta = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, timeline_frame)
            if meta and meta.clip_id ~= "" and not meta.offline then
                src = meta.source_frame
                return true
            end
            return false
        end, 5, string.format("source frame at timeline %d (dir=%d)",
            timeline_frame, direction))
        assert(src ~= nil, "RV-1: no source_frame resolved")
        return src
    end

    local tmb_fwd = build_clip_tmb(false)
    local tmb_rev = build_clip_tmb(true)

    -- Sample three interior timeline positions (not the endpoints, where the
    -- reader may clamp): early / middle / late.
    local PROBES = { 5, 30, 55 }

    local fwd_src, rev_src = {}, {}
    for _, tf in ipairs(PROBES) do
        fwd_src[tf] = source_frame_at(tmb_fwd,  1, tf)
        rev_src[tf] = source_frame_at(tmb_rev, -1, tf)
        print(string.format("  timeline %2d  forward src=%d  reverse src=%d",
            tf, fwd_src[tf], rev_src[tf]))
    end

    -- Forward is monotone ascending across probes; reverse monotone descending.
    assert(fwd_src[5] < fwd_src[30] and fwd_src[30] < fwd_src[55], string.format(
        "RV-1 forward: source frame must rise as timeline advances; got %d,%d,%d",
        fwd_src[5], fwd_src[30], fwd_src[55]))
    assert(rev_src[5] > rev_src[30] and rev_src[30] > rev_src[55], string.format(
        "RV-1 reverse: source frame must fall as timeline advances; got %d,%d,%d",
        rev_src[5], rev_src[30], rev_src[55]))

    -- Mirror symmetry: at any timeline position the forward and reverse source
    -- frames are reflections about the clip's source midpoint, i.e.
    -- forward_src + reverse_src ≈ SRC_LO + SRC_HI. Allow ±1 for the reader's
    -- frame-rounding at the chosen rate.
    local MID_SUM = SRC_LO + SRC_HI
    for _, tf in ipairs(PROBES) do
        local sum = fwd_src[tf] + rev_src[tf]
        assert(math.abs(sum - MID_SUM) <= 1, string.format(
            "RV-1 mirror: forward+reverse source at timeline %d must reflect "
            .. "about %d (got %d+%d=%d)",
            tf, MID_SUM, fwd_src[tf], rev_src[tf], sum))
    end

    EMP.TMB_RELEASE_ALL(tmb_fwd); EMP.TMB_CLOSE(tmb_fwd)
    EMP.TMB_RELEASE_ALL(tmb_rev); EMP.TMB_CLOSE(tmb_rev)
    print("  PASS: reverse walks source backwards, mirrors forward about the midpoint")
end

print("\nPASS test_reverse_clip_source_traversal.lua")
os.exit(0)
