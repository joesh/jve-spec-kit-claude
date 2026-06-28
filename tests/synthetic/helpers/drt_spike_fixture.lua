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

local path_utils = require("core.path_utils")
M.A005_PATH   = path_utils.resolve_repo_root() .. "/"
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
                kind            = "video",
                duration_frames = M.A005_DURATION_FRAMES,
                start_tc_frame  = 0,
                native_rate     = M.A005_NATIVE_RATE,
                -- Source-file mtime (µs); the Clip blob's date + f13 derive from
                -- it. The producer always supplies it (media.file_mtime_us).
                file_mtime_us   = 1471909574000000,
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
                            source_out     = M.A005_DURATION_FRAMES,  -- forward: source_in + duration
                            name           = "A005 spike clip",
                            enabled        = true,
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
                            source_out     = M.A005_DURATION_FRAMES,  -- forward: source_in + duration
                            name           = "A005 spike audio",
                            enabled        = true,
                            -- Embedded mono audio of the A005 master, file
                            -- channel 1. The producer (payload_builder.
                            -- build_audio_routing) attaches a routing descriptor
                            -- to every audio clip; mirror that here so the writer
                            -- can synthesize VirtualAudioTrackBA + MediaTrackIdx.
                            routing = {
                                kind            = "mono",
                                media_track_idx = 0,
                                source_channel  = 0,
                            },
                        },
                    },
                },
            },
        },
    }
end

-- ─── Standalone-audio payload (gap #2 / T017) ───────────────────────────────
-- The only real Sm2MpAudioClip fixture is resolve_authored_full.drp's
-- test_click_48k_stereo.wav. These canonical values reproduce its media-pool
-- item byte-for-byte (Clip blob path/date/mtime, TracksBA rate/channels/dur).
M.TEST_CLICK_PATH =
    "/Users/joe/Local/jve-spec-kit-claude/tests/fixtures/media/test_click_48k_stereo.wav"
M.TEST_CLICK_UUID            = "50b4735c-1053-4964-99cb-142c85df11c9"
M.TEST_CLICK_SAMPLE_RATE     = 48000
M.TEST_CLICK_NUM_CHANNELS    = 2
M.TEST_CLICK_DURATION_SAMPLES = 144000
M.TEST_CLICK_MTIME_US        = 1775764733195782   -- "Thu Apr  9 12:58:53 2026"

-- A payload with the A005 video clip (keeps SeqContainer/MediaExtents valid)
-- PLUS one standalone-audio media + an audio clip referencing it, so the
-- writer authors a real Sm2MpAudioClip media-pool item. `audio_overrides`
-- patches the audio media (e.g. num_channels = 1 for the mono form).
function M.build_standalone_audio_payload(audio_overrides)
    local p = M.build_a005_payload()
    local audio = {
        file_uuid        = M.TEST_CLICK_UUID,
        file_path        = M.TEST_CLICK_PATH,
        kind             = "audio",
        native_rate      = M.FR_24,        -- audio timeline clip plays at seq fps
        duration_frames  = 72,             -- clip MediaTimemapBA span (frames)
        start_tc_frame   = 0,              -- zero-origin → integer <In>
        file_mtime_us    = M.TEST_CLICK_MTIME_US,
        sample_rate      = M.TEST_CLICK_SAMPLE_RATE,
        num_channels     = M.TEST_CLICK_NUM_CHANNELS,
        duration_samples = M.TEST_CLICK_DURATION_SAMPLES,
    }
    for k, v in pairs(audio_overrides or {}) do audio[k] = v end
    p.media_refs[#p.media_refs + 1] = audio

    local stereo = audio.num_channels == 2
    p.sequence.tracks[#p.sequence.tracks + 1] = {
        type = "audio",
        clips = {
            {
                id             = "33345678-1234-4123-8123-1234567890ab",
                media_uuid     = audio.file_uuid,
                sequence_start = M.TC_1H,
                duration       = 72,
                source_in      = 0,
                source_out     = 72,
                name           = "standalone audio clip",
                enabled        = true,
                routing = stereo
                    and { kind = "stereo", media_track_idx = 0, source_channel = nil }
                    or  { kind = "mono",   media_track_idx = 0, source_channel = 0 },
            },
        },
    }
    return p
end

return M
