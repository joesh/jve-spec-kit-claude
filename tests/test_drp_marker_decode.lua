-- DRP clip-marker decoder — black-box test (run via `jve --test`, needs qt_zstd_decompress).
--
-- Domain truth: markers a user CREATED in DaVinci Resolve on a known clip, then
-- exported to DRP. The decoder must recover exactly what the user entered —
-- frame, color, name, note, duration, custom data — without us tracing the codec.
--
-- Fixture `markers_16color_edge.drp` was authored by adding, to one timeline
-- clip, one marker of each of Resolve's 16 colors plus edge cases (empty note,
-- empty custom data). The companion `.truth.json` records exactly what was
-- entered. We assert recovered == entered.

require("test_env")
local drp_binary = require("importers.drp_binary")
local dkjson = require("dkjson")

assert(type(qt_zstd_decompress) == "function",
    "this test needs C++ bindings — run with: jve --test tests/test_drp_marker_decode.lua")

local FIXTURE_DIR = assert(os.getenv("JVE_REPO"),
    "set JVE_REPO to the repo root") .. "/tests/fixtures/resolve/"
local DRP = FIXTURE_DIR .. "markers_16color_edge.drp"
local TRUTH = FIXTURE_DIR .. "markers_16color_edge.truth.json"

-- Read a single entry from a .drp (ZIP) via `unzip -p` — the same mechanism
-- the importer uses; avoids needing a Lua zip module.
local function read_zip_entry(zip_path, entry)
    local h = assert(io.popen(string.format("unzip -p %q %q", zip_path, entry), "r"))
    local data = h:read("*a")
    h:close()
    assert(data and #data > 0, "failed to read " .. entry .. " from " .. zip_path)
    return data
end

-- Load the project XML and the ground truth.
local project_xml = read_zip_entry(DRP, "project.xml")
local truth_file = assert(io.open(TRUTH, "r"), "missing truth: " .. TRUTH)
local truth = assert(dkjson.decode(truth_file:read("*a")))
truth_file:close()

-- Find the Sm2TiItemLockableBlob owned by the clip the markers were added to,
-- and decode its FieldsBlob.
local function decode_markers_for(owner_uid)
    for block in project_xml:gmatch("<Sm2TiItemLockableBlob.-</Sm2TiItemLockableBlob>") do
        local owner = block:match("<BlobOwner>(.-)</BlobOwner>")
        if owner == owner_uid then
            local hex = block:match("<FieldsBlob>(.-)</FieldsBlob>")
            assert(hex, "owner blob has no FieldsBlob")
            hex = hex:gsub("%s+", "")
            return drp_binary.decode_clip_markers(hex)
        end
    end
    return nil
end

local markers = decode_markers_for(truth.countdown_uid)
assert(markers, "decode_clip_markers returned nil for the marker-bearing clip")

-- Index recovered markers by frame for assertion.
local by_frame = {}
for _, m in ipairs(markers) do by_frame[m.frame] = m end

local function check(expected)
    local got = by_frame[expected.frame]
    assert(got, string.format("no marker recovered at frame %d", expected.frame))
    local function eq(field, want)
        assert(got[field] == want, string.format(
            "frame %d: %s = %q, expected %q",
            expected.frame, field, tostring(got[field]), tostring(want)))
    end
    eq("color", expected.color)
    eq("name", expected.name)
    eq("note", expected.note)
    eq("duration", expected.duration)
    eq("custom_data", expected.customData or "")
end

-- 1. All 16 Resolve colors round-trip with exact name/note/duration/custom data.
local n = 0
for _, c in ipairs(truth.colors) do check(c); n = n + 1 end
assert(n == 16, "expected 16 color markers in truth, got " .. n)

-- 2. Edge cases that Resolve actually persisted (empty note, empty custom data).
--    Markers the experiment recorded as added=false (empty name) are absent by
--    design — Resolve rejects empty-name markers.
local edge_expected = 0
for _, e in ipairs(truth.edge) do
    if e.added then check(e); edge_expected = edge_expected + 1 end
end

-- 3. Exactly the persisted markers, nothing invented.
local total_expected = 16 + edge_expected
assert(#markers == total_expected, string.format(
    "recovered %d markers, expected %d", #markers, total_expected))

-- 4. Duration markers: at least one span > 1 frame (width is driven by duration).
local has_span = false
for _, m in ipairs(markers) do if m.duration > 1 then has_span = true end end
assert(has_span, "expected at least one duration (span) marker > 1 frame")

print(string.format("✅ test_drp_marker_decode.lua passed (%d markers, 16 colors + %d edges)",
    #markers, edge_expected))
