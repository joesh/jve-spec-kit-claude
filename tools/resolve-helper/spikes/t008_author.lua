-- T008 author script — authors a JVE-side DRP for Resolve-acceptance test.
--
-- Output: tests/fixtures/resolve/jve_authored_single_clip.drp  (gitignored;
-- co-located with the source-of-truth Resolve fixtures so the .drp lives
-- next to its sibling references — kitchen-sink, empty-timeline,
-- retime-test, etc.)
--
-- The output file is named .drp (not .drt) because Resolve's
-- "File > Import > Timeline..." path treats .drt files as
-- FCPXML/EDL-style timeline-only documents and produces an empty
-- timeline named after the file. Our archive is DRP-shaped (full
-- project envelope), so it must be imported via
-- "File > Import > Project..." — which expects the .drp extension.
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test \
--          <repo-root>/tools/resolve-helper/spikes/t008_author.lua
--
-- After running, drag the .drp into Resolve via File > Import > Project,
-- then run t008_probe_canonical.py to verify the JVE-written clip DbId
-- survives the round-trip.

local writer = require("exporters.drt_writer")

-- 24 fps end-to-end (Joe: "23.976 is archaic broadcast TV"). At 24 fps
-- exact, project-epoch 86400 frames = 01:00:00:00 SMPTE NDF cleanly.
local FR_24    = 24
local FR_23976 = 24000 / 1001        -- A005 source file's native rate
local TC_1H    = 24 * 3600

-- Resolve script dir, walk up to repo root (tools/resolve-helper/spikes/
-- → ../../..). The previous /tmp location did not survive macOS reboots;
-- the previous in-spike output/ dir was a separate namespace from the
-- existing Resolve fixtures.
local script_dir = debug.getinfo(1, "S").source:sub(2):gsub("/[^/]+$", "")
local repo_root = script_dir:gsub("/tools/resolve%-helper/spikes$", "")
assert(repo_root ~= script_dir, "t008_author: script not at expected "
    .. "tools/resolve-helper/spikes/ path — gsub did not match. Got: "
    .. script_dir .. " (relocate script or update the gsub pattern)")
local OUT_PATH = repo_root
    .. "/tests/fixtures/resolve/jve_authored_single_clip.drp"

local result = writer.author(OUT_PATH, {
    project = { name = "single_clip", fps = FR_24 },
    media_refs = {
        {
            file_uuid       = "11111111-1111-4111-8111-111111111111",
            file_path       = "/Users/joe/Local/jve-spec-kit-claude/"
                .. "tests/fixtures/media/A005_C052_0925BL_001.mp4",
            duration_frames = 108,
            start_tc_frame  = 0,
            native_rate     = FR_23976,
        },
    },
    sequences = {
        {
            name = "single_clip",
            fps  = FR_24,
            width = 1920, height = 1080,
            tracks = {
                {
                    type = "video",
                    clips = {
                        {
                            id             = "12345678-1234-4123-8123-1234567890ab",
                            media_uuid     = "11111111-1111-4111-8111-111111111111",
                            -- Absolute project-epoch frames (sequence.lua:1007).
                            -- 86400 @ 24 fps = 01:00:00:00.
                            sequence_start = TC_1H,
                            duration       = 108,
                            source_in      = 0,
                            name           = "A005_C052_0925BL_001 — JVE-exported",
                        },
                    },
                },
            },
        },
    },
})

print("DRP written: " .. result.path)
print("Stage tree (transient): " .. result.stage)
