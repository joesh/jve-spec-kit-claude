#!/usr/bin/env luajit
-- TDD regression: a DRP master clip's audio_channels must reflect the file's
-- TRUE embedded-audio channel count, decoded from the BtAudioInfo TracksBA
-- blob — NOT the number of BtAudioInfo elements.
--
-- Bug: for an A/V clip the importer set audio_channels = #own_bt_audio_info_ids
-- (count of BtAudioInfo elements). A camera file (BRAW/MOV) packs ALL its audio
-- channels into a SINGLE interleaved BtAudioInfo whose TracksBA.NumChannels
-- carries the real count (e.g. 2). So a 2-channel clip was undercounted to 1 —
-- only one embedded audio track / media_ref was created, and the second channel
-- was silently dropped. Verified ground truth: Resolve's UI shows the clip as
-- two channels, the BRAW SDK reports 2, and the DRP TracksBA decodes to
-- NumChannels=2.
--
-- A genuinely mono A/V clip (TracksBA.NumChannels=1) must STAY 1 — the fix must
-- not blanket every clip to 2.
--
-- Black-box: drives the public parse_drp_file over a committed, Resolve-authored
-- fixture (sample_project.drp) that already exhibits the pattern. Needs the
-- C++ qt_xml_parse binding, so it runs under the binding/integration harness.
--
-- Run via: ./build/bin/jve --test tests/synthetic/binding/test_drp_embedded_audio_channels.lua

local test_env = require("test_env")

print("=== test_drp_embedded_audio_channels.lua ===")

local drp_importer = require("importers.drp_importer")

local fixture_path = test_env.require_fixture("tests/fixtures/resolve/sample_project.drp")
local f = io.open(fixture_path)
assert(f, "fixture not found: " .. fixture_path)
f:close()

local result = drp_importer.parse_drp_file(fixture_path)
assert(result.success, "parse_drp_file failed: " .. tostring(result.error))

-- Return the media_item whose file_path ends with the given basename.
local function media_for(basename)
    for _, item in pairs(result.media_items) do
        if item.file_path and item.file_path:find(basename, 1, true) then
            return item
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Case A: a 2-channel A/V clip. A001_07232330_C004.mp4 has a single embedded
-- BtAudioInfo whose TracksBA.NumChannels = 2. The file genuinely carries two
-- audio channels (matches Resolve's UI), so the imported media must expose 2 —
-- enough for the per-channel model to build two embedded audio tracks.
--------------------------------------------------------------------------------

print("\n--- Case A: stereo embedded A/V clip → 2 channels ---")
local stereo = media_for("A001_07232330_C004.mp4")
assert(stereo, "media_items should contain A001_07232330_C004.mp4")
assert(stereo.audio_channels == 2, string.format(
    "A001_07232330_C004.mp4 has TracksBA.NumChannels=2 (Resolve shows two "
    .. "channels); imported audio_channels must be 2, got %s",
    tostring(stereo.audio_channels)))
print("  ✓ A001_07232330_C004.mp4: audio_channels = 2 (from TracksBA, not element count)")

--------------------------------------------------------------------------------
-- Case B: a mono A/V clip. "audio tracks tutorial.mov" has a single embedded
-- BtAudioInfo whose TracksBA.NumChannels = 1. It must STAY 1 — the fix reads the
-- real channel count, it does not blanket every clip to 2.
--------------------------------------------------------------------------------

print("\n--- Case B: mono embedded A/V clip → 1 channel (must not inflate) ---")
local mono = media_for("audio tracks tutorial.mov")
assert(mono, "media_items should contain audio tracks tutorial.mov")
assert(mono.audio_channels == 1, string.format(
    "audio tracks tutorial.mov has TracksBA.NumChannels=1; imported "
    .. "audio_channels must stay 1, got %s", tostring(mono.audio_channels)))
print("  ✓ audio tracks tutorial.mov: audio_channels = 1 (genuine mono preserved)")

print("\n✅ test_drp_embedded_audio_channels.lua passed")
