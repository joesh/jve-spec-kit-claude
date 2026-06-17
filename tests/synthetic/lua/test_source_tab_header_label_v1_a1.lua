#!/usr/bin/env luajit
--- Source tab track headers display the abbreviated V1/A1 form (matching
--- the Rec tab convention), not the master's stored "Video 1"/"Audio N"
--- name. Domain behavior: when the user is viewing the master sequence
--- in the timeline, the leftmost text on each track row is the same
--- short label they see on record tracks.
---
--- Tests the pure derivation helper. The Qt rendering path consumes
--- the helper directly (verified by grep on usage; the rendering
--- function would otherwise need a Qt harness to inspect).

require("test_env")

print("=== test_source_tab_header_label_v1_a1.lua ===")

local labels = require("ui.timeline.track_header_label")

-- ── Source tab abbreviates VIDEO tracks to V<index> ──
assert(labels.for_display({name = "Video 1",  track_index = 1, track_type = "VIDEO"}, "source") == "V1",
    "source-tab VIDEO track_index=1 must render as V1")
assert(labels.for_display({name = "anything", track_index = 3, track_type = "VIDEO"}, "source") == "V3",
    "source-tab VIDEO track_index=3 must render as V3")
print("  ✓ source-tab VIDEO tracks render as V<index>")

-- ── Source tab abbreviates AUDIO tracks to A<index> ──
assert(labels.for_display({name = "Audio 1",  track_index = 1, track_type = "AUDIO"}, "source") == "A1",
    "source-tab AUDIO track_index=1 must render as A1")
assert(labels.for_display({name = "Audio 7",  track_index = 7, track_type = "AUDIO"}, "source") == "A7",
    "source-tab AUDIO track_index=7 must render as A7")
print("  ✓ source-tab AUDIO tracks render as A<index>")

-- ── Record tab preserves the stored name (user may have renamed it) ──
assert(labels.for_display({name = "B-roll",  track_index = 2, track_type = "VIDEO"}, "record") == "B-roll",
    "record-tab tracks must use track.name verbatim (user-renamed)")
assert(labels.for_display({name = "Dialogue",track_index = 1, track_type = "AUDIO"}, "record") == "Dialogue",
    "record-tab tracks must use track.name verbatim (user-renamed)")
print("  ✓ record-tab tracks preserve stored name")

-- ── A channel-backed track (synced master channel) resolves its label the
--    SAME way on either tab: user rename → probed iXML channel name → blank.
--    This is the synced-clip channel-naming feature; the label follows the
--    channel, not the tab. ──
for _, kind in ipairs({"source", "record"}) do
    assert(labels.for_display(
        {name = nil, channel_name = "BOOM", channel_backed = true,
         track_index = 3, track_type = "AUDIO"}, kind) == "BOOM",
        kind .. "-tab nameless channel track falls back to the probed channel name")
    assert(labels.for_display(
        {name = "", channel_name = "MAGGIE", channel_backed = true,
         track_index = 4, track_type = "AUDIO"}, kind) == "MAGGIE",
        kind .. "-tab empty name falls back to the probed channel name")
    assert(labels.for_display(
        {name = "Boom Op", channel_name = "BOOM", channel_backed = true,
         track_index = 3, track_type = "AUDIO"}, kind) == "Boom Op",
        kind .. "-tab user rename overrides the probed channel name")
    assert(labels.for_display(
        {name = nil, channel_name = nil, channel_backed = true,
         track_index = 5, track_type = "AUDIO"}, kind) == "",
        kind .. "-tab channel track with neither name nor probe is blank")
end
print("  ✓ channel-backed tracks resolve override → probed → blank on both tabs")

-- ── A plain (non-channel) source-tab track still abbreviates even with a
--    stored default name — the channel-name feature must not regress it. ──
assert(labels.for_display(
    {name = "Audio 1", channel_backed = false, track_index = 2, track_type = "AUDIO"},
    "source") == "A2",
    "plain source-tab AUDIO track still abbreviates (no channel backing)")

print("\n✅ test_source_tab_header_label_v1_a1.lua passed")
