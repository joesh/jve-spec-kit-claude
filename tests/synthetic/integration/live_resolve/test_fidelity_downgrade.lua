-- T034 — LIVE fidelity honesty (spec 023, FR-015; quickstart step 3).
--
-- Imports a 3-clip fixture timeline, grades it through Resolve's own
-- write surfaces (apply_test_grade → SetCDL / SetLUT), then asserts
-- read_grades classifies each clip HONESTLY:
--   clip A: CDL-only primary corrector  → fidelity "primary", with the
--           applied CDL values round-tripped (Resolve EDL+CDL export).
--   clip B: node LUT applied            → fidelity "partial" — JVE must
--           NOT claim full reproduction; cdl must be absent (the
--           contract gates cdl strictly on primary).
--   clip C: untouched                   → fidelity "none" (genuinely
--           ungraded; distinct from row-omission).
--
-- The power-window/secondary ⇒ "unrepresentable" leg has no scripting
-- write surface (Resolve's API can't author windows) — it remains a
-- manual quickstart step under T045. "partial" already proves the
-- FR-015 downgrade path: a grade JVE cannot fully reproduce is never
-- approximated as primary.
--
-- ⚠ State-changing on the CURRENT Resolve project: run against the VM
-- test environment (memory: project_vm_test_environment). The test
-- deletes the timeline it creates.
--
-- Run via (absolute path):
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--       $PWD/tests/synthetic/integration/live_resolve/test_fidelity_downgrade.lua

local fixture = require("synthetic.integration.live_resolve.live_fixture")
local drt_writer = require("exporters.drt_writer")

local FPS = 24000 / 1001
local MEDIA_FRAMES = 108

local function repo_root()
    local src = debug.getinfo(1, "S").source:sub(2)
    return src:gsub("/tests/synthetic/integration/live_resolve/[^/]+$", "")
end

local MEDIA_UUID = "0b34aaaa-aaaa-4aaa-8aaa-00000000000a"
local CLIP_A = "0b34c0de-1111-4aaa-8aaa-000000000001"  -- CDL primary
local CLIP_B = "0b34c0de-2222-4aaa-8aaa-000000000002"  -- LUT → partial
local CLIP_C = "0b34c0de-3333-4aaa-8aaa-000000000003"  -- untouched → none

-- Resolve ships this LUT on every install (verified on the VM).
local LUT_PATH = "/Library/Application Support/Blackmagic Design/"
    .. "DaVinci Resolve/LUT/Film Looks/DCI-P3 Kodak 2383 D60.cube"

-- Non-trivial, channel-distinct CDL so a swapped channel or dropped
-- component cannot pass (rule: non-trivial values).
local CDL = {
    slope  = { 1.2, 0.9, 0.85 },
    offset = { 0.02, -0.01, 0.03 },
    power  = { 0.95, 1.1, 1.05 },
    sat    = 0.8,
}
-- EDL/CDL text round-trip quantizes to a few decimals; 1e-3 still
-- catches channel swaps (channel deltas here are >= 0.03).
local TOL = 1e-3

local function make_clip(id, name, source_in, sequence_start)
    return {
        id             = id,
        media_uuid     = MEDIA_UUID,
        source_in      = source_in,
        source_out     = source_in + 36,
        sequence_start = sequence_start,
        duration       = 36,
        enabled        = true,
        name           = name,
    }
end

local payload = {
    project = { name = "JVE T034 fidelity", fps = FPS },
    media_refs = {
        {
            file_uuid       = MEDIA_UUID,
            file_path       = repo_root()
                .. "/tests/fixtures/media/A005_C052_0925BL_001.mp4",
            native_rate     = FPS,
            duration_frames = MEDIA_FRAMES,
            start_tc_frame  = 0,
            track_type      = "video",
        },
    },
    sequence = {
        name   = "JVE T034 fidelity",
        fps    = FPS,
        width  = 1920,
        height = 1080,
        tracks = {
            {
                type = "video",
                clips = {
                    make_clip(CLIP_A, "t034 cdl",  11, 120),
                    make_clip(CLIP_B, "t034 lut",  47, 240),
                    make_clip(CLIP_C, "t034 none", 71, 360),
                },
            },
        },
    },
}

local function approx(a, b, label)
    assert(type(a) == "number",
        label .. ": expected number, got " .. tostring(a))
    assert(math.abs(a - b) <= TOL, string.format(
        "%s: %.6f differs from applied %.6f (tol %.0e)", label, a, b, TOL))
end

-- ── live run ─────────────────────────────────────────────────────────
local fix = fixture.start("/tmp/jve-live-fidelity.sock")
fixture.skip_unless_live(fix, "test_fidelity_downgrade")

local drt_path = "/tmp/jve-t034-fidelity.drt"
os.remove(drt_path)
local authored = drt_writer.author_a005_compatible(drt_path, payload)

local token = {
    project_id          = "t034-project",
    sequence_id         = "t034-sequence",
    mutation_generation = 1,
}

local imported = fixture.expect_ok(
    fixture.request(fix, "import_timeline", {
        drt_path       = drt_path,
        media_roots    = {},
        clip_positions = authored.emit_order,
        change_token   = token,
    }), "import_timeline")
assert(#imported.mapping == 3, string.format(
    "T034: all 3 fixture clips must map+relink (got %d mapped, "
    .. "%d unrelinked) — fidelity asserts are meaningless on a "
    .. "partial import", #imported.mapping, #imported.unrelinked))

local item_by_clip = {}
for _, row in ipairs(imported.mapping) do
    item_by_clip[row.jve_guid] = row.resolve_item_id
end

fixture.expect_ok(fixture.request(fix, "apply_test_grade", {
    resolve_item_id = item_by_clip[CLIP_A],
    cdl             = CDL,
    change_token    = token,
}), "apply CDL to clip A")
fixture.expect_ok(fixture.request(fix, "apply_test_grade", {
    resolve_item_id = item_by_clip[CLIP_B],
    lut_path        = LUT_PATH,
    change_token    = token,
}), "apply LUT to clip B")
print("  ✓ grades applied (A: CDL primary, B: node LUT)")

local rg = fixture.expect_ok(
    fixture.request(fix, "read_grades", {}), "read_grades")
local grade_by_item = {}
for _, g in ipairs(rg.grades) do
    grade_by_item[g.resolve_item_id] = g
end

-- clip A — primary, CDL values round-tripped
local ga = grade_by_item[item_by_clip[CLIP_A]]
assert(ga, "T034: clip A missing from read_grades")
assert(ga.fidelity == "primary", string.format(
    "T034: CDL-only clip must classify primary, got %q",
    tostring(ga.fidelity)))
assert(type(ga.cdl) == "table", "T034: primary clip must carry cdl")
approx(ga.cdl.slope[1],  CDL.slope[1],  "A slope.r")
approx(ga.cdl.slope[2],  CDL.slope[2],  "A slope.g")
approx(ga.cdl.slope[3],  CDL.slope[3],  "A slope.b")
approx(ga.cdl.offset[1], CDL.offset[1], "A offset.r")
approx(ga.cdl.offset[2], CDL.offset[2], "A offset.g")
approx(ga.cdl.offset[3], CDL.offset[3], "A offset.b")
approx(ga.cdl.power[1],  CDL.power[1],  "A power.r")
approx(ga.cdl.power[2],  CDL.power[2],  "A power.g")
approx(ga.cdl.power[3],  CDL.power[3],  "A power.b")
approx(ga.cdl.sat,       CDL.sat,       "A sat")
print("  ✓ clip A: primary, CDL round-tripped exactly")

-- clip B — LUT present ⇒ honest downgrade to partial, cdl absent
local gb = grade_by_item[item_by_clip[CLIP_B]]
assert(gb, "T034: clip B missing from read_grades")
assert(gb.fidelity == "partial", string.format(
    "T034 FR-015: LUT-carrying clip must downgrade to partial "
    .. "(never approximated as primary), got %q", tostring(gb.fidelity)))
assert(gb.cdl == nil,
    "T034: cdl is gated on primary — partial clip must not carry one")
assert(type(gb.lut) == "table" and type(gb.lut.ref) == "string"
    and gb.lut.ref ~= "", "T034: partial clip must surface lut.ref")
print("  ✓ clip B: partial (LUT), no cdl claimed")

-- clip C — untouched ⇒ none (present, distinct from omission)
local gc = grade_by_item[item_by_clip[CLIP_C]]
assert(gc, "T034: ungraded clip C must be PRESENT with fidelity none "
    .. "(absence means item-deleted, a different state)")
assert(gc.fidelity == "none", string.format(
    "T034: untouched clip must classify none, got %q",
    tostring(gc.fidelity)))
assert(gc.cdl == nil and gc.lut == nil,
    "T034: ungraded clip carries neither cdl nor lut")
print("  ✓ clip C: none (genuinely ungraded)")

-- ── teardown ─────────────────────────────────────────────────────────
local del = fixture.expect_ok(
    fixture.request(fix, "delete_timeline", {
        resolve_timeline_id = imported.resolve_timeline_id,
        change_token        = token,
    }), "delete_timeline")
assert(del.deleted == true, "T034 teardown: fixture timeline must delete")
print("  ✓ teardown: fixture timeline deleted")

fixture.stop(fix)
print("✅ test_fidelity_downgrade.lua passed")
