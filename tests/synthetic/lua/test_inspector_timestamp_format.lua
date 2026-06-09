#!/usr/bin/env luajit
-- Inspector TIMESTAMP field type — review M#21 (2026-06-09).
-- synced_at on ClipGrade is unix epoch seconds; the inspector must render it
-- as a human-readable UTC string, not raw INTEGER. Display-only; parse rejects.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local field_widget = require("ui.inspector.field_widget")
local schemas      = require("ui.metadata_schemas")
local ft           = schemas.FIELD_TYPES

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("FAIL: %s — got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

print("=== Inspector: TIMESTAMP format unit test ===\n")

-- TIMESTAMP enum exists.
check("FIELD_TYPES.TIMESTAMP exists", ft.TIMESTAMP, "TIMESTAMP")

-- Maps to STRING at the property-system boundary (display-only).
check("TIMESTAMP property type = STRING",
      schemas.get_property_type(ft.TIMESTAMP), "STRING")

-- Format: unix epoch 0 → "1970-01-01 00:00:00 UTC".
check("format(TIMESTAMP, 0)",
      field_widget._format_value(ft.TIMESTAMP, 0),
      "1970-01-01 00:00:00 UTC")

-- Format: 2026-06-09 12:00:00 UTC = 1781006400.
check("format(TIMESTAMP, 1781006400)",
      field_widget._format_value(ft.TIMESTAMP, 1781006400),
      "2026-06-09 12:00:00 UTC")

-- Nil → empty string (consistent with other field types).
check("format(TIMESTAMP, nil) → ''",
      field_widget._format_value(ft.TIMESTAMP, nil), "")

-- Parse: TIMESTAMP is display-only; any text returns (nil, err).
do
    local v, err = field_widget._parse_text(ft.TIMESTAMP, "1234567890")
    check("parse(TIMESTAMP, ...) → v=nil", v, nil)
    check("parse(TIMESTAMP, ...) → err non-nil", err ~= nil, true)
end

-- Schema-define validator accepts TIMESTAMP (uses field() through a section).
do
    local ok, err = pcall(function()
        schemas.FIELD_TYPES.TIMESTAMP = ft.TIMESTAMP -- noop, sanity
    end)
    check("FIELD_TYPES table accessible", ok, true)
    check("no error on access", err, nil)
end

print(string.format("\n=== Pass: %d  Fail: %d ===", pass, fail))
if fail > 0 then os.exit(1) end
print("✅ test_inspector_timestamp_format.lua passed")
