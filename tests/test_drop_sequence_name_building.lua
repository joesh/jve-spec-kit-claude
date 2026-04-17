#!/usr/bin/env luajit

-- Regression: when a drop onto a blank timeline creates a new sequence, that
-- sequence is named after the first clip placed into it — exactly the clip's
-- name if only one clip was added, or "<clip> (+N more)" where N is the count
-- of additional clips (feature spec 010, FR-011 + clarification session).
--
-- This is a pure naming function. It must be callable from tests and other
-- modules without touching Qt widgets or the database — expressed as a stable
-- contract so downstream regressions (e.g., mis-pluralisation, off-by-one) are
-- caught in isolation.

require('test_env')

-- Helper lives in its own pure-Lua module so it is testable without Qt.
-- (timeline_panel.lua touches qt_constants at module load and cannot be
-- required in a pure-Lua test.)
local drop_naming = require('ui.timeline.drop_naming')

print("=== build_drop_sequence_name() contract ===")

-- Single clip: name is the clip's filename verbatim, no suffix, no parentheses.
assert(drop_naming.build_drop_sequence_name("clip.mov", 0) == "clip.mov",
    "single-clip drop must use the clip's name verbatim; got: "
    .. tostring(drop_naming.build_drop_sequence_name("clip.mov", 0)))

-- Two clips dropped → the first clip's name plus "(+1 more)" — "more" is
-- singular-or-plural-agnostic (we picked "+N more" deliberately to avoid
-- plural switching mid-label at N=1).
assert(drop_naming.build_drop_sequence_name("clip.mov", 1) == "clip.mov (+1 more)",
    "two-clip drop must suffix (+1 more); got: "
    .. tostring(drop_naming.build_drop_sequence_name("clip.mov", 1)))

-- Four clips → (+3 more).
assert(drop_naming.build_drop_sequence_name("clip.mov", 3) == "clip.mov (+3 more)",
    "four-clip drop must suffix (+3 more); got: "
    .. tostring(drop_naming.build_drop_sequence_name("clip.mov", 3)))

-- Real-world filenames with spaces, dots, and uppercase preserved.
assert(drop_naming.build_drop_sequence_name("A001_C001.mov", 3) == "A001_C001.mov (+3 more)",
    "spec-example filename must round-trip exactly")

assert(drop_naming.build_drop_sequence_name("very long name with spaces.R3D", 12)
    == "very long name with spaces.R3D (+12 more)",
    "long-name round-trip must preserve the first-clip name exactly")

-- Short name, single additional clip — boundary.
assert(drop_naming.build_drop_sequence_name("a", 1) == "a (+1 more)",
    "one-character name drop must round-trip")

print("✅ test_drop_sequence_name_building.lua passed")
