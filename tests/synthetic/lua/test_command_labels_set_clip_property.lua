#!/usr/bin/env luajit
-- Regression: command_labels.detail_for_params("SetClipProperty", ...) now
-- reads params.property_name (the key SetClipProperty's SPEC actually uses),
-- so the history pane shows "Set Property — name = new name" instead of
-- just "Set Property".

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local labels = require("core.command_labels")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1; print(string.format("FAIL: %s — got %s, want %s", label, tostring(got), tostring(want))) end
end

print("=== command_labels: SetClipProperty detail ===\n")

-- Real-world payload: SetClipProperty writes to params.property_name.
check("property_name=name, value='new name'",
    labels.detail_for_params("SetClipProperty",
        { property_name = "name", value = "new name" }),
    "name = new name")

check("property_name=sequence_start, value=240",
    labels.detail_for_params("SetClipProperty",
        { property_name = "sequence_start", value = 240 }),
    "sequence_start = 240")

-- Legacy callers using params.field still work.
check("legacy params.field (back-compat)",
    labels.detail_for_params("SetClipProperty",
        { field = "source_in", value = 100 }),
    "source_in = 100")

-- property value being false (legitimate BOOLEAN) must not render "nil"
-- or an empty detail — the prior `if field and value then` truthy-check
-- dropped false. New code uses `value ~= nil`.
check("BOOLEAN false value renders",
    labels.detail_for_params("SetClipProperty",
        { property_name = "enabled", value = false }),
    "enabled = false")

-- Full label via label_for_command wraps base + " — " + detail.
check("full label via label_for_command",
    labels.label_for_command({
        type = "SetClipProperty",
        parameters = { property_name = "name", value = "new name" },
    }),
    "Set Property — name = new name")

-- Missing property_name → fall through to base label only.
do
    local full = labels.label_for_command({
        type = "SetClipProperty",
        parameters = { value = "orphan" },  -- no property_name
    })
    check("missing property_name: detail omitted, base returned",
        full, "Set Property")
end

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_command_labels_set_clip_property.lua passed")
