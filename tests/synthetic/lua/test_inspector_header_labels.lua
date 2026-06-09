#!/usr/bin/env luajit
-- The Inspector header for a selected sequence is labeled "Sequence:"
-- (the content object — the panel that hosts it is still called
-- "Timeline", Premiere convention). The header shows only the identity
-- line; no In/Out/Dur mark summary is appended for any schema.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local sb = require("ui.inspector.selection_binding")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print(string.format("FAIL: %s — got %s, want %s", label, tostring(got), tostring(want)))
    end
end

print("=== Inspector header labels ===\n")

-- Format helpers: individual label formatters.
check("single sequence",
    sb._format_single_header("sequence", "MySeq"), "Sequence: MySeq")
check("single clip",
    sb._format_single_header("clip", "MyClip"), "Clip: MyClip")

check("multi sequence",
    sb._format_multi_header("sequence", 3, false), "Sequences: 3 selected")
check("multi clip",
    sb._format_multi_header("clip", 2, false), "Clips: 2 selected")
check("multi sequence read-only",
    sb._format_multi_header("sequence", 3, true), "Sequences: 3 selected (read-only)")

check("split header",
    sb._format_split_header({ clip = 2, sequence = 1 }, "clip"),
    "2 clips, 1 sequence — editing 2 clips")

-- build_selection_header dispatches to the right formatter and returns
-- a single identity line (no marks summary appended).
check("dispatch: single sequence",
    sb._build_selection_header(
        { schema_counts = { sequence = 1 } },
        "single", "sequence", { "MySeq" }, 1, false),
    "Sequence: MySeq")
check("dispatch: single clip",
    sb._build_selection_header(
        { schema_counts = { clip = 1 } },
        "single", "clip", { "MyClip" }, 1, false),
    "Clip: MyClip")
check("dispatch: multi-edit clip",
    sb._build_selection_header(
        { schema_counts = { clip = 2 } },
        "multi_edit", "clip", { "A", "B" }, 2, false),
    "Clips: 2 selected")
check("dispatch: heterogeneous",
    sb._build_selection_header(
        { schema_counts = { clip = 2, sequence = 1 } },
        "multi_edit", "clip", { "A", "B" }, 2, true),
    "2 clips, 1 sequence — editing 2 clips")

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_header_labels.lua passed")
