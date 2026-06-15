-- LIVE VALIDATION — confirm a Resolve-authored .drt writes the forward
-- (un-retimed) clip's MediaTimemapBA as the 9-byte rate-general form,
-- with NO epsilon and NO 41-byte .drp-style variant. This is the
-- fixture-grounded ground truth the DRT writer's generalization rests on
-- (spec 023; drt_writer.build_media_timemap_ba emits 02|be(d), any fps).
--
-- WHY: an earlier session believed Resolve's .drt forward MTBA was the
-- 41-byte 0x02 form 02|be(d)|0×8|be(d+ε)|0×8|be(d) with ε hardcoded to
-- 1/24000, and quarantined the writer to 23.976. The Resolve-authored
-- .drt fixture (retime-test.drt) shows the forward form is actually 9
-- bytes (02|be(d), no ε) — a .drp-only encoding had been mistaken for
-- the .drt one. This test drives Resolve ITSELF to author a forward clip
-- and export a .drt, then asserts the on-wire forward MTBA is the 9-byte
-- form — proving the fact against live Resolve, not against JVE code.
--
-- d = (duration_frames − 1) / native_rate (seconds); the −1 reflects the
-- curve spanning frames 0..N−1 inclusive. The test decodes d and asserts
-- it encodes exactly (N−1)/native for an integer N — the writer's formula
-- — at whatever rate Resolve applied, without assuming the clip length.
--
-- Mechanism (helper test-verb author_reference_timeline): author one clip
-- in a throwaway project at timeline_fps → Export(DRT). The .drt lands on
-- the VM filesystem (this test runs on the VM), read back locally.
--
-- ⚠ State-changing on the CURRENT Resolve project (creates + deletes a
-- throwaway project). VM test environment only. Needs --allow-test-verbs
-- (author_reference_timeline lives in TEST_VERB_TABLE).
--
-- Run via:
--   scripts/run_live_resolve_test.sh test_drt_forward_mtba_resolve_authored

local test_env   = require("test_env")
local fixture    = require(
    "synthetic.integration.live_resolve.live_fixture")
local drp_binary = require("importers.drp_binary")

-- ── what we author ──────────────────────────────────────────────────
-- The committed 23.976 A005 fixture (108 video frames). native_rate =
-- 24000/1001. A future sweep at other rates needs media at those rates;
-- the assertion below is rate-agnostic, so only the fixture changes.
local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")
local TIMELINE_FPS = "23.976"
local NATIVE_NUM, NATIVE_DEN = 24000, 1001
local NATIVE_RATE = NATIVE_NUM / NATIVE_DEN

local SOCK = "/tmp/jve-live-mtba-authored.sock"
local OUT_DRT = "/tmp/jve/ref_" .. TIMELINE_FPS:gsub("%.", "_") .. ".drt"
os.execute("mkdir -p /tmp/jve")
os.remove(OUT_DRT)

local fix = fixture.start(SOCK, { allow_test_verbs = true })
fixture.skip_unless_live(fix, "test_drt_forward_mtba_resolve_authored")

-- ── drive Resolve to author + export ────────────────────────────────
-- The verb is self-contained: it authors in a throwaway project, exports
-- the .drt, then restores the colorist's project and deletes the
-- throwaway. Nothing to tear down here — only the .drt file remains.
local res = fixture.expect_ok(
    fixture.request(fix, "author_reference_timeline", {
        media_path   = MEDIA_PATH,
        timeline_fps = TIMELINE_FPS,
        out_drt_path = OUT_DRT,
    }), "author_reference_timeline")
print(string.format(
    "  authored at fps_set=%s; item source_in=%s record_start=%s",
    tostring(res.timeline_fps_set),
    res.item and tostring(res.item.source_in) or "nil",
    res.item and tostring(res.item.record_start) or "nil"))

-- ── read the exported .drt back (this test runs ON the VM) ───────────
-- Resolve's EXPORT_DRT writes a ZIP archive (PK…), same container JVE's
-- writer uses; unzip_drt_xml streams the inner XML.
local xml = fixture.unzip_drt_xml(OUT_DRT)

-- ── extract every MediaTimemapBA hex blob ───────────────────────────
local blobs = {}
for hex in xml:gmatch("<MediaTimemapBA>(%x+)</MediaTimemapBA>") do
    blobs[#blobs + 1] = hex
end
assert(#blobs > 0, "no <MediaTimemapBA> in exported .drt — Resolve may "
    .. "emit a different forward-curve shape than the writer assumes; "
    .. "dump:\n" .. xml:sub(1, 800))

-- ── validate EVERY forward 0x02 blob: 9-byte, reject 41-byte ─────────
-- 0x02 = un-retimed forward curve. 9 bytes (18 hex) = tag + be(d), the
-- rate-general form. 41 bytes (82 hex) = the .drp-only ε form; if Resolve
-- ever wrote that in a .drt, the writer's generalization would be wrong.
-- A .drt carries the forward MTBA in BOTH the timeline-item
-- (Sm2TiVideoClip) and the media-pool item (Sm2MpVideoClip), so a single
-- clip exports more than one forward blob — validate all of them. Each
-- encodes (Nᵢ − 1)/native for an integer Nᵢ (the timeline-item and the
-- media-pool item may span different frame counts).
local forward = {}
for i, hex in ipairs(blobs) do
    local tag = hex:sub(1, 2)
    print(string.format("  MTBA[%d]: %d bytes, tag=%s", i, #hex / 2, tag))
    if tag == "02" then
        assert(#hex ~= 82, string.format(
            "Resolve wrote the 41-byte .drp-style forward MTBA in a .drt "
            .. "(%s) — the writer's 9-byte generalization is WRONG; the "
            .. "ε form is load-bearing after all.", hex))
        assert(#hex == 18, string.format(
            "forward 0x02 MTBA is %d bytes, expected the 9-byte form "
            .. "(02|be(d)); raw=%s", #hex / 2, hex))
        forward[#forward + 1] = hex
    end
end
assert(#forward > 0, "no 0x02 forward MTBA in the exported .drt — Resolve "
    .. "emitted only non-forward (retime/keyframe) curves")

-- ── decode each d, assert it is exactly (N−1)/native for an integer N ─
for i, hex in ipairs(forward) do
    local d = drp_binary.decode_hex_double_be_at(hex, 1)
    assert(d and d > 0, string.format(
        "forward MTBA[%d] d decode failed or non-positive", i))
    local d_frames = d * NATIVE_RATE             -- = N − 1
    local N = math.floor(d_frames + 0.5) + 1     -- nearest integer N
    -- 1e-6 sits above float rounding (~2e-14 for N~100) and well below the
    -- smallest meaningful curve step (the .drp ε 1/24000 ≈ 4e-5); any
    -- non-integer-frame encoding would push residual past 1e-3.
    local residual = math.abs(d * NATIVE_RATE - (N - 1))
    print(string.format(
        "    forward[%d]: d=%.9f s → (N-1)=%.6f → N=%d  residual=%.3g",
        i, d, d_frames, N, residual))
    assert(residual < 1e-6, string.format(
        "forward MTBA[%d] d=%.9f does not encode a clean (N-1)/native for "
        .. "any integer N at %s (nearest N=%d, residual=%.3g) — Resolve's "
        .. "forward curve is not the simple (frames-1)/rate the writer "
        .. "emits.", i, d, TIMELINE_FPS, N, residual))
end

fixture.stop(fix)

print(string.format(
    "✅ Resolve's .drt forward MTBA at %s is the 9-byte rate-general form "
    .. "02|be(d), d=(N-1)/native — no epsilon, no 41-byte variant, across "
    .. "all %d forward blob(s). Confirms drt_writer.build_media_timemap_ba "
    .. "against live Resolve.", TIMELINE_FPS, #forward))
