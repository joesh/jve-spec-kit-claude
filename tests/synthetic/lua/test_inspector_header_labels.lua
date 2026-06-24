#!/usr/bin/env luajit
-- The Inspector header for a selected record sequence is labeled "Record:"
-- (the user-visible content kind). The "sequence" schema_id is the
-- internal term — record sequences (kind='sequence') are surfaced as
-- "Record" in the UI; master sequences (kind='master') route through
-- a separate "master_clip" schema labeled "Master Clip:".
-- The header shows only the identity line; no In/Out/Dur mark summary
-- is appended for any schema.

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
    sb._format_single_header("sequence", "MySeq"), "Record: MySeq")
check("single clip",
    sb._format_single_header("clip", "MyClip"), "Clip: MyClip")

check("multi sequence",
    sb._format_multi_header("sequence", 3, false), "Records: 3 selected")
check("multi clip",
    sb._format_multi_header("clip", 2, false), "Clips: 2 selected")
check("multi sequence read-only",
    sb._format_multi_header("sequence", 3, true), "Records: 3 selected (read-only)")

check("single master_clip",
    sb._format_single_header("master_clip", "Boom"), "Master Clip: Boom")
check("multi master_clip",
    sb._format_multi_header("master_clip", 2, false), "Master Clips: 2 selected")
check("multi master_clip read-only",
    sb._format_multi_header("master_clip", 2, true),
    "Master Clips: 2 selected (read-only)")

check("split header",
    sb._format_split_header({ clip = 2, sequence = 1 }, "clip"),
    "2 clips, 1 record — editing 2 clips")
check("split header with master_clip",
    sb._format_split_header({ clip = 1, master_clip = 2 }, "master_clip"),
    "1 clip, 2 master clips — editing 2 master clips")

-- build_selection_header dispatches to the right formatter and returns
-- a single identity line (no marks summary appended).
check("dispatch: single sequence",
    sb._build_selection_header(
        { schema_counts = { sequence = 1 } },
        "single", "sequence", { "MySeq" }, 1, false),
    "Record: MySeq")
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
    "2 clips, 1 record — editing 2 clips")

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_header_labels.lua passed")
