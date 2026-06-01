--- Shared fixture for spec-023 T008 DRT-writer tests.
-- The spike pins to a single source media file (A005_C052_0925BL_001.mp4,
-- the only video file in tests/fixtures/media/) and exercises the writer's
-- single emission path against a payload modelled on a typical 1-hour-start
-- timeline. Tests override only the fields they vary.

local M = {}

-- ─── Canonical spike values ────────────────────────────────────────────────

M.FR_24       = 24
M.FR_23976    = 24000 / 1001
M.TC_1H       = 24 * 3600                          -- 86400 frames @ 24fps

M.A005_PATH   = "/Users/joe/Local/jve-spec-kit-claude/"
    .. "tests/fixtures/media/A005_C052_0925BL_001.mp4"
M.A005_UUID   = "11111111-1111-4111-8111-111111111111"
M.A005_NATIVE_RATE = M.FR_23976                    -- A005's container rate
M.A005_DURATION_FRAMES = 108

-- ─── Plain-substring helpers (Lua's pattern syntax interprets `-` as a
--     quantifier — `string.find(..., plain=true)` is the literal form). ────

function M.plain_count(haystack, needle)
    local n, pos = 0, 1
    while true do
        local lo = haystack:find(needle, pos, true)
        if not lo then return n end
        n = n + 1
        pos = lo + #needle
    end
end

-- Standardized output path for spike tests; ensures /tmp/jve exists.
function M.out_path(test_name)
    assert(type(test_name) == "string" and test_name ~= "",
        "drt_spike_fixture.out_path: test_name required")
    os.execute("mkdir -p /tmp/jve")
    return "/tmp/jve/" .. test_name .. ".drp"
end

-- Read one member out of a zip archive, asserting it exists. Spike tests
-- frequently roll their own; centralize so callers can't silently rely on
-- empty-string returns when unzip fails.
function M.unzip_member(archive_path, member_glob)
    assert(type(archive_path) == "string" and archive_path ~= "",
        "drt_spike_fixture.unzip_member: archive_path required")
    assert(type(member_glob) == "string" and member_glob ~= "",
        "drt_spike_fixture.unzip_member: member_glob required")
    local h = io.popen(string.format(
        "unzip -p '%s' '%s'", archive_path, member_glob))
    local body = h:read("*a")
    h:close()
    assert(body and #body > 0, string.format(
        "drt_spike_fixture.unzip_member: '%s' not found (or empty) in %s",
        member_glob, archive_path))
    return body
end

-- Decode 16-hex-char little-endian double back to a Lua number.
local ffi = require("ffi")
function M.le_hex_to_double(hex)
    assert(#hex == 16,
        "drt_spike_fixture.le_hex_to_double: expected 16 hex chars, got "
        .. #hex)
    local buf = ffi.new("uint8_t[8]")
    for i = 0, 7 do
        buf[i] = tonumber(hex:sub(i * 2 + 1, i * 2 + 2), 16)
    end
    return ffi.cast("double*", buf)[0]
end

-- ─── Base payload ──────────────────────────────────────────────────────────
-- Returns a fresh table tree each call so tests can mutate freely without
-- bleeding into siblings.

function M.build_a005_payload()
    return {
        project = { name = "single_clip", fps = M.FR_24 },
        media_refs = {
            {
                file_uuid       = M.A005_UUID,
                file_path       = M.A005_PATH,
                duration_frames = M.A005_DURATION_FRAMES,
                start_tc_frame  = 0,
                native_rate     = M.A005_NATIVE_RATE,
            },
        },
        sequence = {
            name  = "single_clip",
            fps   = M.FR_24,
            width = 1920, height = 1080,
            tracks = {
                {
                    type = "video",
                    clips = {
                        {
                            id             = "12345678-1234-4123-8123-1234567890ab",
                            media_uuid     = M.A005_UUID,
                            sequence_start = M.TC_1H,
                            duration       = M.A005_DURATION_FRAMES,
                            source_in      = 0,
                            name           = "A005 spike clip",
                        },
                    },
                },
                {
                    type = "audio",
                    clips = {
                        {
                            id             = "22345678-1234-4123-8123-1234567890ab",
                            media_uuid     = M.A005_UUID,
                            sequence_start = M.TC_1H,
                            duration       = M.A005_DURATION_FRAMES,
                            source_in      = 0,
                            name           = "A005 spike audio",
                        },
                    },
                },
            },
        },
    }
end

return M
