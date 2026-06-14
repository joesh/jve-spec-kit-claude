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
local database = require("core.database")
local Project  = require("models.project")
local Sequence = require("models.sequence")
local Track    = require("models.track")
local Media    = require("models.media")
local Clip     = require("models.clip")
local payload_builder = require("core.resolve_bridge.payload_builder")
local drt_writer      = require("exporters.drt_writer")
local fixture  = require(
    "synthetic.integration.live_resolve.live_fixture")

local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")
local FPS_NUM, FPS_DEN = 24000, 1001
local MEDIA_FRAMES = 108
local IN_OFFSET, DUR, SEQ_START = 30, 24, 120

-- ── author JVE's .drt for a clip trimmed 30 frames in ───────────────
local DB_PATH = "/tmp/jve/test_drt_field_diff.db"
os.remove(DB_PATH); os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH), "schema init failed")
local db = database.get_connection()
db:exec(require("import_schema"))
Project.create("p", { id = "p1", fps_mismatch_policy = "passthrough",
    settings = { master_clock_hz = 705600000,
                 default_fps = { num = FPS_NUM, den = FPS_DEN } } }):save()
Sequence.create("m", "p1", { fps_numerator = FPS_NUM, fps_denominator = FPS_DEN },
    1920, 1080, { id = "m", kind = "master" }):save()
Sequence.create("e", "p1", { fps_numerator = FPS_NUM, fps_denominator = FPS_DEN },
    1920, 1080, { id = "e1", kind = "sequence", audio_sample_rate = 48000 }):save()
Track.create_video("V1", "e1", { id = "e1-v1", index = 1 }):save()
Track.create_video("V1", "m", { id = "m-v1", index = 1 }):save()
db:exec("UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'")
local media = Media.create({ id = "med-tc01", project_id = "p1",
    name = "A005_C052_0925BL_001_tc01.mp4", file_path = MEDIA_PATH,
    duration_frames = MEDIA_FRAMES, fps_numerator = FPS_NUM,
    fps_denominator = FPS_DEN, audio_channels = 0, metadata = "{}" })
media:save()
db:exec(string.format([[
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame, sequence_start_frame,
        duration_frames, audio_sample_rate, enabled, volume, playhead_frame,
        created_at, modified_at)
    VALUES ('mr-tc01','p1','m','m-v1','med-tc01',0,%d,0,%d,NULL,1,1.0,0,0,0);
]], MEDIA_FRAMES, MEDIA_FRAMES))
local TC_ORIGIN = media:get_start_tc()
local ABS_SOURCE_IN = TC_ORIGIN + IN_OFFSET
local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
Clip.create({ id = "0b50c0de-7007-4aaa-8aaa-000000000001", project_id = "p1",
    owner_sequence_id = "e1", track_id = "e1-v1", sequence_id = "m",
    name = "A005_C052_0925BL_001_tc01.mp4", sequence_start_frame = SEQ_START,
    duration_frames = DUR, source_in_frame = ABS_SOURCE_IN,
    source_out_frame = ABS_SOURCE_IN + DUR, source_in_subframe = sub_in,
    source_out_subframe = sub_out, master_layer_track_id = nil,
    fps_mismatch_policy = "passthrough", enabled = true, volume = 1.0,
    playhead_frame = 0 })
local JVE_DRT = "/tmp/jve/jve_trim.drt"
os.remove(JVE_DRT)
drt_writer.author_a005_compatible(JVE_DRT,
    payload_builder.build(db, "p1", "e1"))
print(string.format("  JVE .drt authored: clip trimmed %d in, TC origin %d",
    IN_OFFSET, TC_ORIGIN))

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
local function unzip_xml(path)
    local p = assert(io.popen(string.format("unzip -p %q 2>/dev/null", path)))
    local x = p:read("*a"); p:close()
    assert(x and #x > 0, "no content from " .. path)
    return x
end
local jve_xml = unzip_xml(JVE_DRT)
local res_xml = unzip_xml(RES_DRT)

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
    local jf = child_fields(subtree(jve_xml, tag))
    local rf = child_fields(subtree(res_xml, tag))
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
