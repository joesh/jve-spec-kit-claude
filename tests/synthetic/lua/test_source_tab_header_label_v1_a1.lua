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

print("\n✅ test_source_tab_header_label_v1_a1.lua passed")
