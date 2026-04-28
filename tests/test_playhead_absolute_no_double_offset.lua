#!/usr/bin/env luajit
--- Regression test for the user-visible "doubled hour" bug.
---
--- Domain rule: in this codebase TC is the source of truth and the timebase
--- is absolute (per V13 timeline_placements_as: clips, marks, playhead all
--- live in absolute TC frames). The displayed timecode for any frame value
--- is therefore the raw TC representation of that frame at the sequence
--- frame rate — start_timecode_frame is metadata, never math added at
--- display time.
---
--- Concrete: a sequence whose start TC is 00:59:50:00 has
--- start_timecode_frame = 89750 (= 25 fps × 3590 s). When the playhead is
--- parked at the sequence start, playhead = 89750. The user must read
--- "00:59:50:00" on the playhead counter, the inspector "Playhead" field,
--- and the ruler tick at the start of content.
---
--- Pre-fix bug: format_sequence_timecode added start_timecode_frame to the
--- input frame, so display showed 89750 + 89750 = 179500 frames =
--- "01:59:40:00". Three display sites doubled the offset.
require("test_env")

local frame_utils = require("core.frame_utils")
local timecode    = require("core.timecode")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("FAIL: %s\n  got:  %s\n  want: %s",
            label, tostring(got), tostring(want)))
    end
end

print("=== test_playhead_absolute_no_double_offset ===\n")

-- anamnesis-gold-timeline: 25 fps, start TC 00:59:50:00 (= 89750 frames).
local seq = {
    frame_rate = { fps_numerator = 25, fps_denominator = 1 },
    start_timecode_frame = 89750,
}

-- ----------------------------------------------------------------------
-- Site 1: bare formatter — absolute frame in, raw TC out, no extra offset.
-- ----------------------------------------------------------------------
check("playhead 89750 (start of content) → 00:59:50:00",
    frame_utils.format_timecode(89750, seq.frame_rate), "00:59:50:00")
check("playhead 92265 (250 frames + 5 frames into content) → 01:01:30:15",
    frame_utils.format_timecode(92265, seq.frame_rate), "01:01:30:15")

-- ----------------------------------------------------------------------
-- Site 2: ruler labels — absolute frame in, raw TC out, no extra offset.
-- timeline_ruler must NOT pass start_timecode_frame as a tc_start arg.
-- ----------------------------------------------------------------------
check("ruler label at frame 89750 → 00:59:50:00",
    timecode.format_ruler_label(89750, seq.frame_rate), "00:59:50:00")
check("ruler label at frame 92265 → 01:01:30:15",
    timecode.format_ruler_label(92265, seq.frame_rate), "01:01:30:15")

-- ----------------------------------------------------------------------
-- Site 3: inspector field. Use the SCHEMA-DEFINED type for the playhead
-- field — that's the path the bug travels. If the schema still types
-- playhead_frame as TIMECODE_SEQUENCE, format will double-add the offset.
-- ----------------------------------------------------------------------
local field_widget = require("ui.inspector.field_widget")
local metadata_schemas = require("ui.metadata_schemas")
local FT = metadata_schemas.FIELD_TYPES
local sequence_provider = function() return seq end

local function field_type_for(schema_id, key)
    for _, s in ipairs(metadata_schemas.get_sections(schema_id)) do
        for _, f in ipairs(s.schema.fields) do
            if f.key == key then return f.type end
        end
    end
    return nil
end

local playhead_type  = field_type_for("sequence", "playhead_frame")
local mark_in_type   = field_type_for("sequence", "mark_in_frame")
local mark_out_type  = field_type_for("sequence", "mark_out_frame")
local start_tc_type  = field_type_for("sequence", "start_timecode_frame")

check("Inspector Playhead via schema-typed format → 00:59:50:00 (no doubled hour)",
    field_widget._format_value(playhead_type, 89750, sequence_provider),
    "00:59:50:00")
check("Inspector Mark In via schema-typed format → 00:59:50:00",
    field_widget._format_value(mark_in_type, 89750, sequence_provider),
    "00:59:50:00")
check("Inspector Mark Out via schema-typed format → 01:01:30:15",
    field_widget._format_value(mark_out_type, 92265, sequence_provider),
    "01:01:30:15")
check("Inspector Start Timecode via schema-typed format → 00:59:50:00",
    field_widget._format_value(start_tc_type, 89750, sequence_provider),
    "00:59:50:00")

local parsed_back = field_widget._parse_text(playhead_type, "00:59:50:00",
    sequence_provider)
check("Inspector parse '00:59:50:00' (Playhead schema type) → absolute frame 89750",
    parsed_back, 89750)

local parsed_late = field_widget._parse_text(playhead_type, "01:01:30:15",
    sequence_provider)
check("Inspector parse '01:01:30:15' (Playhead schema type) → absolute frame 92265",
    parsed_late, 92265)

-- ----------------------------------------------------------------------
-- Cross-site agreement: every TC formatter agrees on the same number.
-- ----------------------------------------------------------------------
local from_formatter  = frame_utils.format_timecode(92265, seq.frame_rate)
local from_ruler      = timecode.format_ruler_label(92265, seq.frame_rate)
local from_inspector  = field_widget._format_value(playhead_type, 92265,
    sequence_provider)
check("formatter == ruler",     from_formatter, from_ruler)
check("formatter == inspector", from_formatter, from_inspector)

-- ----------------------------------------------------------------------
-- Sanity: zero start_tc still works (most masters carry tc_origin=0).
-- ----------------------------------------------------------------------
local seq_zero = {
    frame_rate = { fps_numerator = 25, fps_denominator = 1 },
    start_timecode_frame = 0,
}
check("zero start_tc, frame 25 → 00:00:01:00",
    frame_utils.format_timecode(25, seq_zero.frame_rate), "00:00:01:00")

if fail > 0 then
    print(string.format("\n--- %d passed, %d FAILED ---", pass, fail))
    os.exit(1)
end
print(string.format("\n✅ %d assertions passed", pass))
