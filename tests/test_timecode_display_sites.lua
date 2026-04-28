#!/usr/bin/env luajit
--- Locks in: every TC display site formats the absolute frame at the
--- sequence rate. No site adds start_timecode_frame as an offset — under
--- V13, all timeline positions live in absolute timecode space, and the
--- TC string IS the position.
---
--- Three sites, one contract:
---   1. timeline_panel: playhead counter widget
---   2. timeline_ruler: ruler tick labels
---   3. inspector field_widget: TIMECODE fields
---
--- Tests prove behavior, not implementation: input is "playhead at
--- absolute frame F" and "sequence at frame rate R"; expected output is
--- the TC string for that frame at that rate.
require("test_env")

local timecode = require("core.timecode")
local frame_utils = require("core.frame_utils")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("FAIL: %s\n  got:  %s\n  want: %s", label, tostring(got), tostring(want)))
    end
end

print("=== test_timecode_display_sites ===\n")

-- Realistic sequence shape (anamnesis-gold-timeline): 25 fps, start TC 00:59:50:00.
local seq = {
    frame_rate = { fps_numerator = 25, fps_denominator = 1 },
    start_timecode_frame = 89750,
}

-- Site 1: playhead counter — same call timeline_panel.get_formatted_playhead_timecode makes.
print("Site 1: playhead counter")
check("playhead at absolute frame 92265 → 01:01:30:15",
    frame_utils.format_timecode(92265, seq.frame_rate), "01:01:30:15")
check("playhead at absolute frame 89750 (start of content) → 00:59:50:00",
    frame_utils.format_timecode(89750, seq.frame_rate), "00:59:50:00")

-- Site 2: ruler labels — timecode.format_ruler_label is what timeline_ruler.lua calls.
print("\nSite 2: ruler labels")
check("ruler label at absolute frame 92265 → 01:01:30:15",
    timecode.format_ruler_label(92265, seq.frame_rate), "01:01:30:15")
check("ruler label at absolute frame 89750 → 00:59:50:00",
    timecode.format_ruler_label(89750, seq.frame_rate), "00:59:50:00")

-- Site 3: inspector field. All TC fields are TIMECODE — no special
-- "sequence-relative" type exists. Format/parse never apply an offset.
print("\nSite 3: inspector field_widget")
local field_widget = require("ui.inspector.field_widget")
local FT = require("ui.metadata_schemas").FIELD_TYPES
local sequence_provider = function() return seq end

check("Playhead field (TIMECODE) at frame 92265 → 01:01:30:15",
    field_widget._format_value(FT.TIMECODE, 92265, sequence_provider),
    "01:01:30:15")
check("Playhead field (TIMECODE) at frame 89750 → 00:59:50:00",
    field_widget._format_value(FT.TIMECODE, 89750, sequence_provider),
    "00:59:50:00")
check("Start Timecode field (TIMECODE) at frame 89750 → 00:59:50:00",
    field_widget._format_value(FT.TIMECODE, 89750, sequence_provider),
    "00:59:50:00")
check("Duration field (TIMECODE) of 110 frames → 00:00:04:10",
    field_widget._format_value(FT.TIMECODE, 110, sequence_provider),
    "00:00:04:10")

-- Round-trip: typed displayed TC == displayed TC after parse+format.
print("\nSite 3 round-trip: parse(displayed) == absolute frame")
local raw_92265, perr = field_widget._parse_text(FT.TIMECODE, "01:01:30:15", sequence_provider)
check("parse '01:01:30:15' → absolute frame 92265", raw_92265, 92265)
check("parse no error", perr, nil)
local raw_89750 = field_widget._parse_text(FT.TIMECODE, "00:59:50:00", sequence_provider)
check("parse '00:59:50:00' → absolute frame 89750", raw_89750, 89750)

-- Cross-site invariant: inspector field, formatter, ruler all agree.
print("\nCross-site agreement at absolute frame 92265:")
local from_helper = frame_utils.format_timecode(92265, seq.frame_rate)
local from_ruler  = timecode.format_ruler_label(92265, seq.frame_rate)
local from_inspector = field_widget._format_value(FT.TIMECODE, 92265, sequence_provider)
check("formatter == ruler",    from_helper, from_ruler)
check("formatter == inspector", from_helper, from_inspector)

if fail > 0 then
    print(string.format("\n--- %d passed, %d FAILED ---", pass, fail))
    os.exit(1)
end
print(string.format("\n✅ %d assertions passed", pass))
