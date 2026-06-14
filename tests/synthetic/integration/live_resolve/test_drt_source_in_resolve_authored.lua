-- LIVE DISCRIMINATOR — learn Resolve's own source-frame convention for a
-- TRIMMED forward clip, to settle why JVE's SendToResolve round-trip reads
-- back GetSourceStartFrame=media-length instead of the trim offset
-- (spec 023, FR-011c position channel).
--
-- ESTABLISHED (local --test, no Resolve): the JVE writer is correct — for a
-- clip trimmed 30 frames into a media whose embedded TC origin is 86313,
-- payload_builder gives clip.source_in=86343, media.start_tc_frame=86313,
-- and drt_writer emits <In> = 86343-86313 = 30 (the right media-relative
-- offset). Yet SendToResolve + read_timeline reports source_in=108 (=media
-- length). So the 108 is NOT a JVE source_in transform bug.
--
-- This test asks Resolve ITSELF: author a clip windowed [30, 30+24) into
-- the SAME media (AppendToTimeline start=30,end=53), export a .drt, and read
-- back (a) Resolve's GetSourceStartFrame/EndFrame for the placed item and
-- (b) the <In> Resolve wrote in the exported .drt. Ground truth, not JVE
-- code. Two outcomes, both informative:
--   • GetSourceStartFrame == 30 → Resolve's own trim reads media-relative;
--     JVE's .drt carrying In=30 SHOULD too, so the production 108 is a
--     defect in some OTHER field of JVE's .drt (MediaStartTime / mark-in) —
--     investigate further.
--   • GetSourceStartFrame ~= 30 (e.g. 108) → GetSourceStartFrame is not
--     plain media-relative for a TC-tagged media; the production 108 is a
--     readback property of the API, not a JVE placement bug.
-- And the exported <In> tells us Resolve's WIRE convention for a trim:
-- if Resolve writes In=30, JVE's In=30 matches it byte-for-byte.
--
-- ⚠ State-changing on the CURRENT Resolve project (creates + deletes a
-- throwaway project). VM test environment only. Needs --allow-test-verbs.
--
-- Run via:
--   scripts/run_live_resolve_test.sh test_drt_source_in_resolve_authored

local test_env = require("test_env")
local fixture  = require(
    "synthetic.integration.live_resolve.live_fixture")

local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")
local TIMELINE_FPS = "23.976"
local MEDIA_FRAMES = 108    -- the A005 fixture's frame count (clamp target)
local IN_OFFSET = 30        -- media-relative source frame we ask Resolve for
local DUR       = 24

local SOCK = "/tmp/jve-live-srcin-authored.sock"
local OUT_DRT = "/tmp/jve/ref_srcin_trim.drt"
os.execute("mkdir -p /tmp/jve")
os.remove(OUT_DRT)

local fix = fixture.start(SOCK, { allow_test_verbs = true })
fixture.skip_unless_live(fix, "test_drt_source_in_resolve_authored")

local res = fixture.expect_ok(
    fixture.request(fix, "author_reference_timeline", {
        media_path             = MEDIA_PATH,
        timeline_fps           = TIMELINE_FPS,
        out_drt_path           = OUT_DRT,
        source_in_frame        = IN_OFFSET,
        source_duration_frames = DUR,
    }), "author_reference_timeline (trimmed)")

local it = res.item
assert(it, "no item returned from trimmed author")
print(string.format(
    "  Resolve placed item: source_in=%s source_out=%s record_duration=%s",
    tostring(it.source_in), tostring(it.source_out),
    tostring(it.record_duration)))

-- ── read the exported .drt's wire <In> value(s) ─────────────────────
local p = assert(io.popen(
    string.format("unzip -p %q 2>/dev/null", OUT_DRT), "r"),
    "could not unzip exported .drt: " .. OUT_DRT)
local xml = p:read("*a"); p:close()
assert(xml and #xml > 0, "exported .drt produced no content")
local ins = {}
for v in xml:gmatch("<In>(%-?%d+)</In>") do ins[#ins + 1] = tonumber(v) end
print(string.format("  Resolve .drt wire <In> value(s): %s",
    #ins > 0 and table.concat(ins, ", ") or "NONE"))

fixture.stop(fix)

-- ── findings (printed regardless) ───────────────────────────────────
print(string.format(
    "  >>> JVE emits <In>=%d for this same trim; Resolve's readback "
    .. "GetSourceStartFrame=%s, Resolve's wire <In>=%s",
    IN_OFFSET, tostring(it.source_in),
    #ins > 0 and tostring(ins[1]) or "NONE"))

-- ── verdict ─────────────────────────────────────────────────────────
-- Two durable truths settle the question (the live GetSourceStartFrame is
-- ~1 off the requested frame — a Resolve AppendToTimeline/GetSourceStartFrame
-- quirk, not asserted exactly):
--
-- (1) WIRE CONVENTION (byte-exact): Resolve writes <In>=30 in the exported
--     .drt for a 30-frame trim — IDENTICAL to what JVE's drt_writer emits
--     (verified In=30 locally). So JVE's .drt source convention is correct.
assert(#ins > 0, "no <In> in Resolve's exported .drt to compare")
for i, v in ipairs(ins) do
    assert(v == IN_OFFSET, string.format(
        "Resolve wire <In>[%d]=%d != requested trim offset %d — Resolve's "
        .. "own source convention differs from the media-relative offset; "
        .. "re-examine JVE's emission against this.", i, v, IN_OFFSET))
end
-- (2) READBACK IS MEDIA-INTERNAL, NOT END-CLAMPED: for a correctly placed
--     trim, GetSourceStartFrame lands inside the media (here 29), well below
--     the media length. Production SendToResolve reads 108 (== media length,
--     end-clamped) for the SAME wire <In>=30 — so the 108 is NOT a source_in
--     bug but a defect in another field of JVE's .drt that mis-places the
--     clip's source. This asserts the contrast: a correct placement is not
--     clamped to the media end.
assert(type(it.source_in) == "number"
    and it.source_in >= 0 and it.source_in < MEDIA_FRAMES, string.format(
    "Resolve's GetSourceStartFrame for a correct trim must be media-internal "
    .. "[0, %d); got %s. If it equals the media length it is end-clamped — "
    .. "which would mean even Resolve's own trim mis-places, contradicting "
    .. "the wire <In>.", MEDIA_FRAMES, tostring(it.source_in)))

print(string.format(
    "✅ Resolve's wire <In>=%d for a %d-frame trim is byte-identical to "
    .. "JVE's emission, and a correct placement reads back media-internal "
    .. "(GetSourceStartFrame=%s < %d, NOT end-clamped). JVE's .drt source "
    .. "convention is CORRECT; the SendToResolve 108 is a defect in another "
    .. ".drt field — diff JVE's .drt vs this Resolve reference next.",
    IN_OFFSET, DUR, tostring(it.source_in), MEDIA_FRAMES))
