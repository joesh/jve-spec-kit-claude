-- LIVE CROSS-RATE VALIDATION — the forward MediaTimemapBA 9-byte form is
-- rate-general (spec 023; the original "generalize drt_writer off its
-- 23.976 ε quarantine" goal). Drives Resolve to author a forward clip at
-- NON-23.976 rates (25 and 29.97) and confirms Resolve writes the same
-- 9-byte 02|be(d) form — d=(N-1)/native — with no epsilon, no 41-byte
-- variant, at each rate. Ground truth from live Resolve, not JVE code.
--
-- Media: small ffmpeg-synthesized clips at exactly 25 and 30000/1001 fps,
-- embedded TC 01:00:00:00. Synthetic MEDIA is fine (the "follow the
-- fixtures" rule is about not inventing DRT/DRP byte forms — here Resolve
-- authors the real bytes). tests/fixtures/media is .gitignored (media is
-- local-only, synced to the VM by the runner like A005), so regenerate
-- with (run from repo root):
--   ffmpeg -y -f lavfi -i "testsrc=duration=2:size=640x360:rate=25" \
--     -timecode "01:00:00:00" -c:v libx264 -pix_fmt yuv420p \
--     tests/fixtures/media/synth_25fps_tc.mov
--   ffmpeg -y -f lavfi -i "testsrc=duration=2:size=640x360:rate=30000/1001" \
--     -timecode "01:00:00:00" -c:v libx264 -pix_fmt yuv420p \
--     tests/fixtures/media/synth_2997fps_tc.mov
--
-- ⚠ State-changing (verb authors + deletes a throwaway project). VM only,
-- needs --allow-test-verbs.
--
-- Run via:
--   scripts/run_live_resolve_test.sh test_drt_forward_mtba_cross_rate

local test_env   = require("test_env")
local fixture    = require(
    "synthetic.integration.live_resolve.live_fixture")
local drp_binary = require("importers.drp_binary")

-- Each: the fixture, the Resolve rate string, and the exact native rate
-- (num/den) the forward d must divide by. nb_frames is the whole-clip
-- length CreateTimelineFromClips places; the test derives N from d and
-- only asserts N is a clean integer, so it does not hard-code placement.
local CASES = {
    { name = "25fps",
      path = "tests/fixtures/media/synth_25fps_tc.mov",
      fps_str = "25",    num = 25,    den = 1 },
    { name = "29.97fps",
      path = "tests/fixtures/media/synth_2997fps_tc.mov",
      fps_str = "29.97", num = 30000, den = 1001 },
}

local fix = fixture.start("/tmp/jve-live-mtba-xrate.sock",
    { allow_test_verbs = true })
fixture.skip_unless_live(fix, "test_drt_forward_mtba_cross_rate")

local function validate_case(case)
    local native = case.num / case.den
    local out = "/tmp/jve/ref_xrate_" .. case.fps_str:gsub("%.", "_") .. ".drt"
    os.remove(out)
    fixture.expect_ok(fixture.request(fix, "author_reference_timeline", {
        media_path   = test_env.resolve_repo_path(case.path),
        timeline_fps = case.fps_str,
        out_drt_path = out,
    }), case.name .. ": author_reference_timeline")

    local p = assert(io.popen(string.format("unzip -p %q 2>/dev/null", out)))
    local xml = p:read("*a"); p:close()
    assert(xml and #xml > 0, case.name .. ": exported .drt empty")

    local forward = {}
    for hex in xml:gmatch("<MediaTimemapBA>(%x+)</MediaTimemapBA>") do
        if hex:sub(1, 2) == "02" then
            assert(#hex ~= 82, string.format(
                "%s: Resolve wrote the 41-byte .drp ε form in a .drt (%s) — "
                .. "the 9-byte generalization is WRONG at this rate",
                case.name, hex))
            assert(#hex == 18, string.format(
                "%s: forward 0x02 MTBA is %d bytes, expected 9 (02|be(d)); "
                .. "raw=%s", case.name, #hex / 2, hex))
            forward[#forward + 1] = hex
        end
    end
    assert(#forward > 0, case.name
        .. ": no forward 0x02 MTBA in exported .drt")

    for i, hex in ipairs(forward) do
        local d = drp_binary.decode_hex_double_be_at(hex, 1)
        assert(d and d > 0, string.format(
            "%s: forward MTBA[%d] d decode failed", case.name, i))
        local N = math.floor(d * native + 0.5) + 1
        local residual = math.abs(d * native - (N - 1))
        print(string.format(
            "  %-9s forward[%d]: d=%.9f s → N=%d  residual=%.3g",
            case.name, i, d, N, residual))
        assert(residual < 1e-6, string.format(
            "%s: forward MTBA[%d] d=%.9f is not a clean (N-1)/native at "
            .. "native=%.6f (nearest N=%d, residual=%.3g) — the 9-byte form "
            .. "is not rate-general here", case.name, i, d, native, N, residual))
    end
end

for _, case in ipairs(CASES) do
    validate_case(case)
end
fixture.stop(fix)

print("✅ CROSS-RATE: Resolve's .drt forward MTBA is the 9-byte rate-general "
    .. "form 02|be(d) at 25 and 29.97 fps — no epsilon, no 41-byte variant. "
    .. "drt_writer.build_media_timemap_ba's rate-general 9-byte emission is "
    .. "confirmed against live Resolve beyond 23.976.")
