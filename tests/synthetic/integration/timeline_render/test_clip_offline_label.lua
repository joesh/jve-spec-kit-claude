--- The timeline renderer must paint a status label prefix on clips whose
-- media is offline or codec-unavailable:
--   • offline (FileNotFound) → "OFFLINE - <clip name>"
--   • codec unavailable (Unsupported or DecodeFailed) → "CODEC UNAVAIL - <clip name>"
--   • online clip → no prefix
--
-- Domain rule: the label is the user's primary signal that a clip is
-- unplayable and why. A missing or wrong prefix misleads the editor about
-- how to recover (relink vs codec install).
--
-- Real path: import fixture media, place a clip, then use
-- media_status.update_from_tmb (the same path the TMB takes when it
-- discovers a decode error during playback) to mark the media path
-- offline with the appropriate error_code.  The next render call
-- stamps clip.offline + clip.error_code from the status cache and the
-- renderer draws the correct label.
--
-- Converted from tests/synthetic/lua/test_timeline_renderer_codec_label.lua
-- (which stubbed _G.timeline, the state module, and the view) — this
-- version drives the real app and reads the real draw-command queue.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test tests/synthetic/integration/batch_timeline_render.lua

local env          = require("synthetic.integration.timeline_render.render_env")
local media_status = require("core.media.media_status")

print("=== test_clip_offline_label ===")

env.boot()

local widget = env.video_widget()

-- The fixture's media_path (what media_status keyed on).
local TC_FIXTURE_PATH = "/tmp/jve/render_env_chirp_30s_tc.mp4"

-- Collect all text draw commands from the REAL queue.
local function text_commands()
    local out = {}
    for _, c in ipairs(env.draw_commands(widget)) do
        if c.type == "text" then out[#out + 1] = c end
    end
    return out
end

local function find_label_prefix(prefix)
    for _, c in ipairs(text_commands()) do
        if type(c.text) == "string" and c.text:sub(1, #prefix) == prefix then
            return c
        end
    end
    return nil
end

-- Wait (polling) until a text draw command with the expected prefix
-- appears, then return it.  The status→re-render path is asynchronous
-- and a fixed pump is flaky under parallel test load.
local function assert_label_prefix(prefix, description)
    local waited = 0
    while waited < 10000 do
        local cmd = find_label_prefix(prefix)
        if cmd then return cmd end
        env.pump(100)
        waited = waited + 100
    end
    local found = {}
    for _, c in ipairs(text_commands()) do
        if type(c.text) == "string" then found[#found + 1] = c.text end
    end
    error(string.format(
        "%s: expected a text command starting with %q within 10s; found %d text command(s):\n  %s",
        description, prefix, #found,
        table.concat(found, "\n  ")))
end

-- Assert that no text command has any offline/codec prefix.
local function assert_no_prefix(description)
    for _, c in ipairs(text_commands()) do
        if type(c.text) == "string" then
            local t = c.text
            assert(not t:find("^OFFLINE %-") and not t:find("^CODEC UNAVAIL %-"),
                string.format("%s: unexpected prefix in label %q", description, t))
        end
    end
end

-- Restore media status to online after each sub-test so sub-tests don't
-- leak state into each other.
local function mark_online()
    media_status.update_from_tmb(TC_FIXTURE_PATH, false, nil)
    env.pump(80)
end

------------------------------------------------------------------------
-- Sub-test A: online clip — no prefix
------------------------------------------------------------------------
print("  A: online clip — no prefix")
do
    local seq = env.fresh_sequence("Offline Label A")
    local tracks = env.tracks()
    assert(tracks.V1, "no V1 track")
    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0, duration = 240 },
    })
    env.view_frames(480, 0)
    mark_online()   -- ensure we start clean
    assert_no_prefix("online clip")
    print("    OK")
end

------------------------------------------------------------------------
-- Sub-test B: offline (FileNotFound) → "OFFLINE - " prefix
------------------------------------------------------------------------
print("  B: offline (FileNotFound) → 'OFFLINE - ' prefix")
do
    local seq = env.fresh_sequence("Offline Label B")
    local tracks = env.tracks()
    assert(tracks.V1, "no V1 track")
    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0, duration = 240 },
    })
    env.view_frames(480, 0)

    -- Mark the media offline via the TMB path (FileNotFound = file missing).
    media_status.update_from_tmb(TC_FIXTURE_PATH, true, "FileNotFound")
    env.pump(150)

    local cmd = assert_label_prefix("OFFLINE - ", "offline clip")
    assert(type(cmd.text) == "string",
        "text command missing .text field")
    -- The clip name was set to "clip@0" by render_env.place_clips.
    assert(cmd.text:find("clip@", 1, true),
        string.format("OFFLINE label should contain clip name; got: %q", cmd.text))

    mark_online()
    print("    OK")
end

------------------------------------------------------------------------
-- Sub-test C: codec unavailable (Unsupported) → "CODEC UNAVAIL - " prefix
------------------------------------------------------------------------
print("  C: Unsupported → 'CODEC UNAVAIL - ' prefix")
do
    local seq = env.fresh_sequence("Offline Label C")
    local tracks = env.tracks()
    assert(tracks.V1, "no V1 track")
    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0, duration = 240 },
    })
    env.view_frames(480, 0)

    media_status.update_from_tmb(TC_FIXTURE_PATH, true, "Unsupported")
    env.pump(150)

    assert_label_prefix("CODEC UNAVAIL - ", "Unsupported clip")

    mark_online()
    print("    OK")
end

------------------------------------------------------------------------
-- Sub-test D: DecodeFailed also maps to "CODEC UNAVAIL - "
------------------------------------------------------------------------
print("  D: DecodeFailed → 'CODEC UNAVAIL - ' prefix")
do
    local seq = env.fresh_sequence("Offline Label D")
    local tracks = env.tracks()
    assert(tracks.V1, "no V1 track")
    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0, duration = 240 },
    })
    env.view_frames(480, 0)

    media_status.update_from_tmb(TC_FIXTURE_PATH, true, "DecodeFailed")
    env.pump(150)

    assert_label_prefix("CODEC UNAVAIL - ", "DecodeFailed clip")

    mark_online()
    print("    OK")
end

print("✅ test_clip_offline_label.lua passed")
