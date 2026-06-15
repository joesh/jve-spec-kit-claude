-- LIVE DIFF — localize the .drt field that makes Resolve clamp a JVE-sent
-- clip's source to media-end (the SendToResolve source_in=108 defect).
--
-- Established: JVE's wire <In>=30 is byte-identical to Resolve's for the
-- same 30-frame trim (test_drt_source_in_resolve_authored). Yet JVE's
-- SendToResolve clip reads back GetSourceStartFrame=108 while Resolve's own
-- reads 29. Same <In>, different placement → a DIFFERENT field in JVE's
-- .drt is wrong. This authors BOTH .drts for the same clip and diffs the
-- timeline-item (Sm2TiVideoClip) and media-pool item (Sm2MpVideoClip)
-- element-by-element, printing every child tag whose value differs.
--
-- ⚠ State-changing (verb authors+deletes a throwaway project). VM only,
-- needs --allow-test-verbs.
--
-- Run via:
--   scripts/run_live_resolve_test.sh test_drt_field_diff_jve_vs_resolve

local test_env = require("test_env")
local payload_builder = require("core.resolve_bridge.payload_builder")
local drt_writer      = require("exporters.drt_writer")
local fixture  = require(
    "synthetic.integration.live_resolve.live_fixture")
local db_fixture = require(
    "synthetic.integration.live_resolve.live_db_fixture")

local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")
local IN_OFFSET, DUR = 30, 24

-- ── author JVE's .drt for a clip trimmed IN_OFFSET frames in ────────
local ctx = db_fixture.build_a005_trimmed_db({
    db_path = "/tmp/jve/test_drt_field_diff.db", media_path = MEDIA_PATH,
    in_offset = IN_OFFSET, dur = DUR,
})
local JVE_DRT = "/tmp/jve/jve_trim.drt"
os.remove(JVE_DRT)
drt_writer.author_a005_compatible(JVE_DRT,
    payload_builder.build(ctx.db, "p1", "e1"))
print(string.format("  JVE .drt authored: clip trimmed %d in, TC origin %d",
    IN_OFFSET, ctx.tc_origin))

-- ── author Resolve's .drt for the same trim ─────────────────────────
local RES_DRT = "/tmp/jve/res_trim.drt"
os.remove(RES_DRT)
local fix = fixture.start("/tmp/jve-live-fielddiff.sock",
    { allow_test_verbs = true })
fixture.skip_unless_live(fix, "test_drt_field_diff_jve_vs_resolve")
fixture.expect_ok(fixture.request(fix, "author_reference_timeline", {
    media_path = MEDIA_PATH, timeline_fps = "23.976",
    out_drt_path = RES_DRT, source_in_frame = IN_OFFSET,
    source_duration_frames = DUR }), "author Resolve trim ref")
fixture.stop(fix)

-- ── read both archives' inner XML ───────────────────────────────────
local jve_xml = fixture.unzip_drt_xml(JVE_DRT)
local res_xml = fixture.unzip_drt_xml(RES_DRT)

-- ── extract one element subtree by tag, parse direct child <tag>val</tag>
local function subtree(xml, tag)
    local lo = xml:find("<" .. tag .. "[ >]")
    if not lo then return nil end
    local hi = xml:find("</" .. tag .. ">", lo, true)
    if not hi then return nil end
    return xml:sub(lo, hi + #tag + 2)
end
local function child_fields(sub)
    local f = {}
    if not sub then return f end
    for k, v in sub:gmatch("<([%w_]+)>([^<]*)</%1>") do
        if f[k] == nil then f[k] = v end   -- first occurrence
    end
    return f
end

local function diff_element(tag)
    print(string.format("\n=== %s — fields that differ (JVE | Resolve) ===", tag))
    -- Durable guard: both archives must carry the element and parse. (We do
    -- NOT assert on the diff size — which fields differ is the transient bug
    -- state and shrinks once the drt_writer FieldsBlob fix lands.)
    local jt = assert(subtree(jve_xml, tag),
        "JVE-authored .drt is missing element " .. tag)
    local rt = assert(subtree(res_xml, tag),
        "Resolve-authored .drt is missing element " .. tag)
    local jf = child_fields(jt)
    local rf = child_fields(rt)
    local keys, seen = {}, {}
    for k in pairs(jf) do if not seen[k] then seen[k]=true; keys[#keys+1]=k end end
    for k in pairs(rf) do if not seen[k] then seen[k]=true; keys[#keys+1]=k end end
    table.sort(keys)
    local any = false
    for _, k in ipairs(keys) do
        local a, b = jf[k], rf[k]
        if a ~= b then
            any = true
            local function short(s)
                s = tostring(s)
                return #s > 60 and (s:sub(1,57) .. "...") or s
            end
            print(string.format("  %-22s  %s  |  %s", k, short(a), short(b)))
        end
    end
    if not any then print("  (no differing direct-child fields)") end
end

diff_element("Sm2TiVideoClip")
diff_element("Sm2MpVideoClip")
print("\n✅ field diff complete — inspect the differing tags above for the "
    .. "field that mis-places JVE's clip source (Resolve reads 29, JVE 108).")
