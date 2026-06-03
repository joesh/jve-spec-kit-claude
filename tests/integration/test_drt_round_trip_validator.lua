require("test_env")

-- FR-004 validator (spec 023): drt_round_trip.validate is the pre-send
-- gate that refuses to ship a corrupt or identity-drifted .drt to Resolve.
-- Black-box: happy path + every observable failure mode through the
-- public surface.
--
-- Happy path mirrors T004's PAYLOAD (single video track, 3 clips, distinct
-- non-trivial values) so a future change to the writer that breaks the
-- round-trip is caught here before it hits the bridge command path.

local writer   = require("exporters.drt_writer")
local rt       = require("exporters.drt_round_trip")
local importer = require("importers.drp_importer")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

local FR_23976       = 24000 / 1001
local TC_1H_AT_23976 = 24 * 3600

local function fresh_payload()
    -- Returns a deep-enough copy so callers can mutate tracks/clips
    -- without contaminating the next test's payload.
    local MEDIA = {
        {
            file_uuid       = "11111111-1111-4111-8111-111111111111",
            file_path       = "/Volumes/Media/A.mov",
            duration_frames = 7200,
            start_tc_frame  = TC_1H_AT_23976,
            native_rate     = FR_23976,
        },
        {
            file_uuid       = "22222222-2222-4222-8222-222222222222",
            file_path       = "/Volumes/Media/B.mov",
            duration_frames = 4800,
            start_tc_frame  = 0,
            native_rate     = FR_23976,
        },
    }
    local CLIPS = {
        { id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          media_uuid = MEDIA[1].file_uuid, sequence_start = 0,
          duration = 240, source_in = TC_1H_AT_23976 + 120,
          name = "A sel" },
        { id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          media_uuid = MEDIA[2].file_uuid, sequence_start = 240,
          duration = 360, source_in = 60,
          name = "B sel" },
    }
    return {
        project    = { name = "RT test", fps = FR_23976 },
        media_refs = MEDIA,
        sequence   = {
            name = "Seq1", fps = FR_23976, width = 1920, height = 1080,
            tracks = {
                { type = "video", clips = CLIPS },
            },
        },
    }, CLIPS
end

os.execute("mkdir -p /tmp/jve")
local OUT = "/tmp/jve/test_drt_round_trip_validator.drt"

-- ─── happy path ───────────────────────────────────────────────────────
do
    os.remove(OUT)
    local payload = fresh_payload()
    writer.author(OUT, payload)
    local ok, code, msg = rt.validate(OUT, payload)
    check("happy path: valid file + matching payload → ok=true", ok)
    check("happy path: no failure code returned", code == nil)
    check("happy path: no failure message returned", msg == nil)
end

-- ─── identity-marker carrier present on disk (FR-002, spec.md:116) ──
-- Independent of the validator: parse the just-authored file through
-- the production drp_importer and confirm every clip carries its own
-- identity marker with custom_data == clip.id. If the writer ever
-- regresses to dropping the Sm2TiItemLockableBlob, this catches it
-- even if the validator's marker check were itself broken.
do
    os.remove(OUT)
    local payload = fresh_payload()
    writer.author(OUT, payload)
    local parsed = importer.parse_drp_file(OUT)
    check("identity carrier: parse_drp_file succeeded", parsed.success)
    check("identity carrier: exactly one parsed timeline",
        type(parsed.timelines) == "table" and #parsed.timelines == 1)
    local seen_ids = {}
    for _, track in ipairs(parsed.timelines[1].tracks) do
        for _, clip in ipairs(track.clips) do
            local found
            if type(clip.markers) == "table" then
                for _, m in ipairs(clip.markers) do
                    if m.color == "Purple"
                        and m.name == "JVE clip identity"
                        and m.custom_data == clip.clip_id then
                        found = m
                        break
                    end
                end
            end
            check("identity carrier: clip " .. tostring(clip.clip_id)
                  .. " has identity marker with matching custom_data",
                found ~= nil)
            seen_ids[clip.clip_id] = true
        end
    end
    check("identity carrier: payload clip 'aaaa...' appears in parse",
        seen_ids["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])
    check("identity carrier: payload clip 'bbbb...' appears in parse",
        seen_ids["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"])
end

-- ─── parse failure: nonexistent file ─────────────────────────────────
do
    os.remove(OUT)
    local payload = fresh_payload()
    local ok, code, msg = rt.validate(OUT, payload)
    check("nonexistent file: ok=false", ok == false)
    check("nonexistent file: code=drt_round_trip_failed",
        code == "drt_round_trip_failed")
    check("nonexistent file: msg mentions importer rejection",
        type(msg) == "string" and msg:find("rejected", 1, true))
end

-- ─── identity drift: payload claims a clip the file doesn't carry ────
do
    os.remove(OUT)
    local payload, clips = fresh_payload()
    writer.author(OUT, payload)
    -- The on-disk file has 2 clips. Tell the validator we expected 3.
    table.insert(clips, {
        id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        media_uuid = payload.media_refs[1].file_uuid,
        sequence_start = 600, duration = 120,
        source_in = TC_1H_AT_23976 + 300,
        name = "C phantom",
    })
    local ok, code, msg = rt.validate(OUT, payload)
    check("identity drift: ok=false", ok == false)
    check("identity drift: code=drt_round_trip_failed",
        code == "drt_round_trip_failed")
    -- The validator may fail-fast on count drift OR on per-id absence
    -- depending on order; both messages are actionable. Accept either.
    check("identity drift: msg points at the drift",
        type(msg) == "string"
        and (msg:find("drift", 1, true)
             or msg:find("cccccccc-cccc-4ccc-8ccc-cccccccccccc", 1, true)))
end

os.remove(OUT)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0,
    "test_drt_round_trip_validator.lua: failures present")
print("✅ test_drt_round_trip_validator.lua passed")
