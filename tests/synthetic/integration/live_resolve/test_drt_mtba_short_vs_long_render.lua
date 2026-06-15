-- REGRESSION GUARD — a JVE-authored .drt renders a forward clip
-- identically whether its MediaTimemapBA is the 9-byte SHORT form (what
-- the writer emits and what Resolve's own .drt uses) or the 41-byte LONG
-- .drp-style form. Guards the generalization decision: drt_writer emits
-- the rate-general 9-byte form; this proves nothing is lost vs the heavy
-- form against live Resolve (spec 023; was the 23.976 ε quarantine).
--
-- GROUND TRUTH from Resolve-authored fixtures (decoded 2026-06-14):
--   • Resolve's own .drt (retime-test.drt) writes the forward clip's
--     MTBA as 9 bytes:  02 | be(d)            d=(dur-1)/native_rate
--   • Resolve's own .drp (resolve_authored_single_clip.drp) writes 41:
--     02 | be(d) | 0×8 | be(d+ε) | 0×8 | be(d)   ε=1/24000 at 23.976
-- The writer now emits the 9-byte .drt form (commit 44a4cdf5). This test
-- imports the writer's .drt twice — once as authored (9-byte) and once
-- with ONLY the MTBA expanded to the 41-byte .drp form (ε measured from
-- resolve_authored_single_clip.drp for this 23.976 fixture) — and compares
-- the imported clip's body via read_timeline. MTBA is the sole variable.
--
-- DOMAIN EXPECTATION (not from code): a 1× forward clip placed on a
-- timeline has a body — the imported Resolve item is kind="media" with
-- record_duration == the clip's timeline duration and a real source
-- range. The MTBA is a speed curve; for a 1× clip it must not change
-- whether the clip has a body. So the two imports MUST be identical. If
-- they diverge, the writer's 9-byte choice is unsafe and the 41-byte form
-- is load-bearing — that would be the answer, recorded by the failure.
-- (Settled 2026-06-14: they render identically — record_duration=24,
-- kind=media — which is why the writer emits 9-byte.)
--
-- ⚠ State-changing on the CURRENT Resolve project (imports + deletes two
-- fixture timelines). VM test environment only.
--
-- Run via:
--   scripts/run_live_resolve_test.sh test_drt_mtba_short_vs_long_render

local test_env        = require("test_env")
local payload_builder = require("core.resolve_bridge.payload_builder")
local drt_writer      = require("exporters.drt_writer")
local enc             = require("exporters.drt_binary")
local fixture         = require(
    "synthetic.integration.live_resolve.live_fixture")
local db_fixture      = require(
    "synthetic.integration.live_resolve.live_db_fixture")

-- 23.976fps A005 fixture with real embedded TC (108 video frames) — the
-- writer's author_a005_compatible path requires 23.976 media.
local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")
local FPS_NUM, FPS_DEN = 24000, 1001
local MEDIA_FRAMES = 108
local IN_OFFSET = 30
local DUR       = 24
local SEQ_START = 120

-- ── DB fixture: one forward clip trimmed IN_OFFSET into the media ───
local ctx = db_fixture.build_a005_trimmed_db({
    db_path = "/tmp/jve/test_drt_mtba_short_vs_long_render.db",
    media_path = MEDIA_PATH, fps_num = FPS_NUM, fps_den = FPS_DEN,
    media_frames = MEDIA_FRAMES, in_offset = IN_OFFSET,
    dur = DUR, seq_start = SEQ_START,
})

-- ── author the writer's .drt (native 9-byte MTBA) ───────────────────
local payload = payload_builder.build(ctx.db, "p1", "e1")
local OUT_9  = "/tmp/jve/mtba_short.drt"   -- writer's native output
local OUT_41 = "/tmp/jve/mtba_long.drt"    -- synthesized .drp-style variant
os.remove(OUT_41); os.remove(OUT_9)
local authored = drt_writer.author_a005_compatible(OUT_9, payload)

local media_paths, seen = {}, {}
for _, ref in ipairs(payload.media_refs) do
    if not seen[ref.file_path] then
        seen[ref.file_path] = true
        media_paths[#media_paths + 1] = ref.file_path
    end
end

-- ── synthesize the 41-byte LONG variant: unzip the native .drt, replace
-- ONLY the 18-hex 9-byte forward MTBA (02 + be(d)) with the 41-byte .drp
-- form (02 | be(d) | 0×8 | be(d+ε) | 0×8 | be(d)), re-zip. ε=1/24000 is
-- the value measured from resolve_authored_single_clip.drp at 23.976;
-- legitimate here because this fixture IS 23.976. ────────────────────
-- The forward MTBA's curve spans the whole MEDIA (drt_writer passes
-- media.duration_frames), so d = (media_frames - 1) / native_rate — NOT
-- the clip's trimmed duration. (Resolve's own .drt agrees: the forward
-- blob decodes to the media frame count — test_drt_forward_mtba_resolve_authored.)
local native_rate = FPS_NUM / FPS_DEN
local d_secs = (MEDIA_FRAMES - 1) / native_rate
-- ε is the literal value measured from resolve_authored_single_clip.drp
-- at 23.976 (feedback_drt_drp_follow_fixtures) — NOT a formula. This test
-- is 23.976-only (author_a005_compatible requires it); a different rate
-- would need its own fixture-measured ε.
local EPS    = 1 / 24000
local be_d   = enc.encode_be_double(d_secs)
local zeros  = "0000000000000000"
local SHORT_HEX = "02" .. be_d                   -- writer's 9-byte form
local LONG_HEX  = "02" .. be_d .. zeros
    .. enc.encode_be_double(d_secs + EPS) .. zeros .. be_d

local WORK = "/tmp/jve/mtba_work"
os.execute(string.format("rm -rf %q && mkdir -p %q", WORK, WORK))
assert(os.execute(string.format("cd %q && unzip -q %q", WORK, OUT_9)) == 0,
    "unzip of authored .drt failed")

-- Find which extracted file carries the forward MTBA, and how many.
local swapped = 0
local find = io.popen(string.format(
    "grep -rl '<MediaTimemapBA>' %q 2>/dev/null", WORK))
local files = {}
for line in find:lines() do files[#files + 1] = line end
find:close()
for _, path in ipairs(files) do
    local fh = assert(io.open(path, "rb")); local txt = fh:read("*a"); fh:close()
    local new = txt:gsub("<MediaTimemapBA>(%x+)</MediaTimemapBA>",
        function(hex)
            -- 18 hex = the writer's native 9-byte forward form. Confirm it
            -- matches our recomputed 02+be(d), then expand to 41 bytes.
            if hex:lower() == SHORT_HEX:lower() then
                swapped = swapped + 1
                return "<MediaTimemapBA>" .. LONG_HEX .. "</MediaTimemapBA>"
            end
            return "<MediaTimemapBA>" .. hex .. "</MediaTimemapBA>"
        end)
    if new ~= txt then
        local wf = assert(io.open(path, "wb")); wf:write(new); wf:close()
    end
end
assert(swapped > 0, string.format(
    "no 9-byte forward MTBA (%s) found in the writer's authored .drt to "
    .. "expand — has the writer's forward MTBA form changed?", SHORT_HEX))
print(string.format("  expanded %d short MTBA blob(s) → 41-byte long form",
    swapped))
assert(os.execute(string.format("cd %q && zip -q -X -r %q .", WORK, OUT_41))
    == 0, "re-zip of 41-byte variant failed")

-- ── import each and read back the forward clip's body ───────────────
local SOCK = "/tmp/jve-live-mtba-render.sock"
local fix = fixture.start(SOCK)
fixture.skip_unless_live(fix, "test_drt_mtba_short_vs_long_render")

local GEN = 0
local function import_and_read(drt_path, label)
    GEN = GEN + 1
    local imp = fixture.expect_ok(fixture.request(fix, "import_timeline", {
        drt_path       = drt_path,
        media_paths    = media_paths,
        clip_positions = authored.emit_order,
        change_token   = { project_id = "p1", sequence_id = "e1",
                           mutation_generation = GEN },
    }), label .. ": import_timeline")
    assert(#imp.mapping == 1, string.format(
        "%s: expected 1 mapped clip, got %d", label, #imp.mapping))
    local tl = fixture.expect_ok(fixture.request(fix, "read_timeline", {}),
        label .. ": read_timeline")
    -- The sole video media item is the forward clip under test.
    local body
    for _, it in ipairs(tl.items) do
        if it.kind == "media" then body = it end
    end
    -- Delete the just-imported timeline (import_timeline returns its id)
    -- so the live Resolve project is left clean and the next import's
    -- read_timeline is unambiguous.
    GEN = GEN + 1
    fixture.expect_ok(fixture.request(fix, "delete_timeline", {
        resolve_timeline_id = imp.resolve_timeline_id,
        change_token        = { project_id = "p1", sequence_id = "e1",
                                mutation_generation = GEN },
    }), label .. ": delete_timeline")
    return body
end

local long_body  = import_and_read(OUT_41, "LONG(41-byte)")
print(string.format(
    "  LONG : kind=%s record_duration=%s source_in=%s source_out=%s",
    long_body and long_body.kind or "NONE",
    long_body and tostring(long_body.record_duration),
    long_body and tostring(long_body.source_in),
    long_body and tostring(long_body.source_out)))

local short_body = import_and_read(OUT_9, "SHORT(9-byte)")
print(string.format(
    "  SHORT: kind=%s record_duration=%s source_in=%s source_out=%s",
    short_body and short_body.kind or "NONE",
    short_body and tostring(short_body.record_duration),
    short_body and tostring(short_body.source_in),
    short_body and tostring(short_body.source_out)))

fixture.stop(fix)

-- ── verdict ─────────────────────────────────────────────────────────
-- Baseline must have a body: the writer's native 9-byte form is what we
-- ship, so it must render a full-bodied clip.
assert(short_body and short_body.kind == "media"
    and short_body.record_duration == DUR, string.format(
    "SHORT (9-byte) — the writer's native forward MTBA — did not import a "
    .. "full-bodied clip (record_duration expected %d). The writer's "
    .. "shipped form must render.", DUR))

-- The 41-byte .drp-style form must render IDENTICALLY. If this fires, the
-- two forms diverge, the 9-byte choice loses something, and the 41-byte
-- form would be load-bearing — that would be the answer, by the failure.
assert(long_body and long_body.kind == "media"
    and long_body.record_duration == short_body.record_duration
    and long_body.source_in  == short_body.source_in
    and long_body.source_out == short_body.source_out, string.format(
    "REGRESSION: 9-byte and 41-byte MTBA render DIFFERENTLY.\n"
    .. "  SHORT(9) : duration=%s source=[%s,%s]\n"
    .. "  LONG(41) : kind=%s duration=%s source=[%s,%s]\n"
    .. "→ the writer's 9-byte generalization is unsafe; the 41-byte form "
    .. "is load-bearing for a JVE-authored .drt.",
    tostring(short_body.record_duration),
    tostring(short_body.source_in), tostring(short_body.source_out),
    long_body and long_body.kind or "NONE",
    long_body and tostring(long_body.record_duration),
    long_body and tostring(long_body.source_in),
    long_body and tostring(long_body.source_out)))

print("✅ the writer's native 9-byte forward MTBA renders identically to "
    .. "the 41-byte .drp form in a JVE-authored .drt — the 9-byte "
    .. "generalization loses nothing against live Resolve.")
